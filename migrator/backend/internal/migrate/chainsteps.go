package migrate

import (
	"context"
	"fmt"
	"math/big"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/SFLuv/migrator/backend/internal/runner"
)

// runBackups dumps the app and Ponder databases before any mutation.
func runBackups(ctx context.Context, s *Session, run *StepRun) error {
	dir, err := s.ensureArtifactDir()
	if err != nil {
		return err
	}
	appURL, err := s.cfg.AppDBURL()
	if err != nil {
		return err
	}
	ponderURL, err := s.cfg.PonderDBURL()
	if err != nil {
		return err
	}

	appFile := filepath.Join(dir, "app-db-before.dump")
	run.log("dumping app database → %s", appFile)
	if _, err := runner.Run(ctx, run.logger(), "", "pg_dump", "--format=custom", "--no-owner", "--no-acl", appURL, "-f", appFile); err != nil {
		return fmt.Errorf("app db dump failed: %w", err)
	}
	run.setData("app_dump", appFile)

	ponderFile := filepath.Join(dir, "ponder-db-before.dump")
	run.log("dumping ponder database → %s", ponderFile)
	if _, err := runner.Run(ctx, run.logger(), "", "pg_dump", "--format=custom", "--no-owner", "--no-acl", ponderURL, "-f", ponderFile); err != nil {
		return fmt.Errorf("ponder db dump failed: %w", err)
	}
	run.setData("ponder_dump", ponderFile)
	return nil
}

// runBeraLock upgrades the old token to the write-locking implementation.
func runBeraLock(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	run.log("upgrading %s to SFLUVBeraWipe on Berachain (broadcast=%v)", cfg.Get("OLD_TOKEN"), cfg.Broadcast())
	args := forgeArgs("script/UpgradeToBeraWipe.s.sol:UpgradeToBeraWipe", cfg.Get("OLD_CHAIN_RPC"), cfg.Get("CONTRACT_DEPLOYER_PRIVATE_KEY"), cfg.Broadcast())
	env := map[string]string{"SFLUV_V2_PROXY": cfg.Get("OLD_TOKEN")}
	if _, err := runner.RunEnv(ctx, run.logger(), env, s.contractsDir(), "forge", args...); err != nil {
		return fmt.Errorf("lock upgrade failed: %w", err)
	}
	return nil
}

type deployInput struct {
	Owners   []string `json:"owners"`
	Salts    []any    `json:"salts"`
	Expected []string `json:"expected_addresses"`
}

type batchFile struct {
	Owners          []string `json:"owners"`
	Salts           []any    `json:"salts"`
	Addresses       []string `json:"addresses"`
	AlreadyDeployed []bool   `json:"already_deployed"`
}

type deployedWallet struct {
	Owner           string `json:"owner"`
	Salt            string `json:"salt"`
	Address         string `json:"address"`
	AlreadyDeployed bool   `json:"already_deployed"`
	Balance         string `json:"balance,omitempty"`
}

// runDeploySmartWallets deploys the smart wallets on Celo in bounded batches and
// merges the per-batch outputs into deployed-smart-wallets.json.
func runDeploySmartWallets(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	dir := s.artifactDir()
	inputPath := filepath.Join(dir, "smart-wallet-deploy-input.json")

	var input deployInput
	if err := readJSONFile(inputPath, &input); err != nil {
		return fmt.Errorf("reading smart wallet deploy input (run the snapshot step first): %w", err)
	}
	count := len(input.Owners)
	run.setData("smart_wallet_count", count)
	run.log("smart wallets to deploy: %d", count)

	batchDir := filepath.Join(dir, "smart-wallet-batches")
	if err := os.MkdirAll(batchDir, 0o755); err != nil {
		return fmt.Errorf("creating batch dir: %w", err)
	}

	if count > 0 {
		batchSize, err := strconv.Atoi(cfg.Get("SMART_WALLET_BATCH_SIZE"))
		if err != nil || batchSize <= 0 {
			return fmt.Errorf("invalid SMART_WALLET_BATCH_SIZE")
		}
		env := map[string]string{"ACCOUNT_FACTORY_ADDRESS": cfg.Get("ACCOUNT_FACTORY_ADDRESS")}
		for start := 0; start < count; start += batchSize {
			batchPath := filepath.Join(batchDir, fmt.Sprintf("batch-%d.json", start))
			run.log("deploying batch starting at %d", start)
			args := forgeArgs(
				"script/DeploySmartWalletBatch.s.sol:DeploySmartWalletBatch",
				cfg.Get("NEW_CHAIN_RPC"), cfg.Get("WALLET_DEPLOYER_PRIVATE_KEY"), cfg.Broadcast(),
				"--sig", "run(string,uint256,uint256,string)", inputPath, strconv.Itoa(start), strconv.Itoa(batchSize), batchPath,
			)
			if _, err := runner.RunEnv(ctx, run.logger(), env, s.contractsDir(), "forge", args...); err != nil {
				return fmt.Errorf("batch %d failed: %w", start, err)
			}
		}
	}

	wallets, err := mergeSmartWalletBatches(batchDir, count)
	if err != nil {
		return err
	}
	if err := writeJSONFile(filepath.Join(dir, "deployed-smart-wallets.json"), map[string]any{
		"generated_at": time.Now().UTC().Format(time.RFC3339),
		"count":        len(wallets),
		"wallets":      wallets,
	}); err != nil {
		return err
	}
	run.setData("deployed_count", len(wallets))

	// Link each deployed wallet to its target balance for an auditable artifact.
	linked := linkWalletBalances(dir, wallets)
	if err := writeJSONFile(filepath.Join(dir, "deployed-smart-wallet-balances.json"), map[string]any{
		"generated_at": time.Now().UTC().Format(time.RFC3339),
		"count":        len(linked),
		"wallets":      linked,
	}); err != nil {
		return err
	}
	return nil
}

var batchFileRe = regexp.MustCompile(`^batch-(\d+)\.json$`)

func mergeSmartWalletBatches(batchDir string, expected int) ([]deployedWallet, error) {
	entries, err := os.ReadDir(batchDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []deployedWallet{}, nil
		}
		return nil, err
	}
	type named struct {
		idx  int
		name string
	}
	var files []named
	for _, e := range entries {
		m := batchFileRe.FindStringSubmatch(e.Name())
		if m == nil {
			continue
		}
		n, _ := strconv.Atoi(m[1])
		files = append(files, named{idx: n, name: e.Name()})
	}
	sort.Slice(files, func(i, j int) bool { return files[i].idx < files[j].idx })

	var rows []deployedWallet
	for _, f := range files {
		var b batchFile
		if err := readJSONFile(filepath.Join(batchDir, f.name), &b); err != nil {
			return nil, fmt.Errorf("reading %s: %w", f.name, err)
		}
		for i := range b.Addresses {
			row := deployedWallet{Address: b.Addresses[i]}
			if i < len(b.Owners) {
				row.Owner = b.Owners[i]
			}
			if i < len(b.Salts) {
				row.Salt = fmt.Sprintf("%v", b.Salts[i])
			}
			if i < len(b.AlreadyDeployed) {
				row.AlreadyDeployed = b.AlreadyDeployed[i]
			}
			rows = append(rows, row)
		}
	}
	if expected > 0 && len(rows) != expected {
		return nil, fmt.Errorf("deployed wallet count mismatch: got %d, expected %d", len(rows), expected)
	}
	if rows == nil {
		rows = []deployedWallet{}
	}
	return rows, nil
}

type holderBalances struct {
	Holders []struct {
		Address string `json:"address"`
		Balance string `json:"balance"`
	} `json:"holders"`
}

func linkWalletBalances(dir string, wallets []deployedWallet) []deployedWallet {
	var dist holderBalances
	balances := map[string]string{}
	if err := readJSONFile(filepath.Join(dir, "app-wallet-distribution.json"), &dist); err == nil {
		for _, h := range dist.Holders {
			balances[strings.ToLower(h.Address)] = h.Balance
		}
	}
	out := make([]deployedWallet, len(wallets))
	for i, w := range wallets {
		w.Balance = balances[strings.ToLower(w.Address)]
		if w.Balance == "" {
			w.Balance = "0"
		}
		out[i] = w
	}
	return out
}

// runDistribute mints/deposits each holder's balance on the new token.
func runDistribute(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	dir := s.artifactDir()
	distPath := filepath.Join(dir, "app-wallet-distribution.json")

	var dist struct {
		Addresses []string `json:"addresses"`
	}
	if err := readJSONFile(distPath, &dist); err != nil {
		return fmt.Errorf("reading distribution artifact (run the balance artifacts step first): %w", err)
	}
	run.setData("recipient_count", len(dist.Addresses))
	if len(dist.Addresses) == 0 {
		run.log("no app-wallet recipients to distribute to")
		return nil
	}

	distributorAddr, err := privateKeyAddress(ctx, cfg.Get("DISTRIBUTOR_PRIVATE_KEY"))
	if err != nil {
		return err
	}
	run.log("distributing to %d recipients (broadcast=%v)", len(dist.Addresses), cfg.Broadcast())
	args := forgeArgs(
		"script/DistributeBatch.s.sol:DistributeBatch",
		cfg.Get("NEW_CHAIN_RPC"), cfg.Get("DISTRIBUTOR_PRIVATE_KEY"), cfg.Broadcast(),
		"--sig", "run(string)", distPath,
	)
	env := map[string]string{"SFLUV_V3_PROXY": cfg.Get("NEW_TOKEN"), "DISTRIBUTOR": distributorAddr}
	if _, err := runner.RunEnv(ctx, run.logger(), env, s.contractsDir(), "forge", args...); err != nil {
		return fmt.Errorf("distribution failed: %w", err)
	}
	return nil
}

// runCompletion resolves the Celo completion block and writes the result.
func runCompletion(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	dir, err := s.ensureArtifactDir()
	if err != nil {
		return err
	}
	head, err := castBlockNumber(ctx, cfg.Get("NEW_CHAIN_RPC"))
	if err != nil {
		return err
	}
	headBig, _ := parseBig(head)
	if headBig == nil {
		headBig = big.NewInt(0)
	}
	receiptMax := maxBroadcastBlock(s.contractsDir())
	complete := bigMax(headBig, receiptMax)
	run.setData("chain_head", headBig.String())
	run.setData("max_broadcast_block", receiptMax.String())
	run.setData("celo_distribution_complete_block", complete.String())
	run.setData("ponder_start_block", new(big.Int).Add(complete, big.NewInt(1)).String())
	run.log("completion block: %s (chain head %s, max receipt %s); start Celo Ponder at %s",
		complete.String(), headBig.String(), receiptMax.String(), new(big.Int).Add(complete, big.NewInt(1)).String())

	return writeJSONFile(filepath.Join(dir, "migration-result.json"), map[string]any{
		"generated_at":                     time.Now().UTC().Format(time.RFC3339),
		"old_token":                        cfg.Get("OLD_TOKEN"),
		"new_token":                        cfg.Get("NEW_TOKEN"),
		"celo_distribution_complete_block": complete.String(),
		"ponder_start_block":               new(big.Int).Add(complete, big.NewInt(1)).String(),
	})
}

// maxBroadcastBlock scans forge broadcast receipts for the highest block number.
func maxBroadcastBlock(contractsDir string) *big.Int {
	max := big.NewInt(0)
	for _, script := range []string{"DeploySmartWalletBatch.s.sol", "DistributeBatch.s.sol"} {
		scriptDir := filepath.Join(contractsDir, "broadcast", script)
		chains, err := os.ReadDir(scriptDir)
		if err != nil {
			continue
		}
		for _, c := range chains {
			if !c.IsDir() {
				continue
			}
			var latest struct {
				Receipts []struct {
					BlockNumber string `json:"blockNumber"`
				} `json:"receipts"`
			}
			if err := readJSONFile(filepath.Join(scriptDir, c.Name(), "run-latest.json"), &latest); err != nil {
				continue
			}
			for _, r := range latest.Receipts {
				bn := strings.TrimSpace(r.BlockNumber)
				if bn == "" {
					continue
				}
				var v *big.Int
				var ok bool
				if strings.HasPrefix(bn, "0x") || strings.HasPrefix(bn, "0X") {
					v, ok = new(big.Int).SetString(bn[2:], 16)
				} else {
					v, ok = new(big.Int).SetString(bn, 10)
				}
				if ok && v.Cmp(max) > 0 {
					max = v
				}
			}
		}
	}
	return max
}
