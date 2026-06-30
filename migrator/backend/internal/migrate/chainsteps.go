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

// runForge runs forge against exactly the RPC we pass — never a chain default or
// an ambient environment RPC. It rejects an empty or non-URL rpc, and pins both
// the forge --rpc-url (in args) and every foundry env RPC-resolution variable
// (ETH_RPC_URL / FOUNDRY_ETH_RPC_URL) to that same URL, so a stray value in the
// loaded environment can never override our configured endpoint. It logs the
// sanitized command (private key masked, RPC shown for auditability).
func runForge(ctx context.Context, run *StepRun, rpc string, extraEnv map[string]string, dir string, args []string) (string, error) {
	rpc = strings.TrimSpace(rpc)
	if rpc == "" {
		return "", fmt.Errorf("refusing to run forge with an empty RPC URL — set the chain RPC in config")
	}
	if !strings.Contains(rpc, "://") {
		return "", fmt.Errorf("RPC URL %q must be a full URL (http(s)/ws), not a chain alias or name", rpc)
	}
	env := map[string]string{}
	for k, v := range extraEnv {
		env[k] = v
	}
	// These win over anything in the process environment (RunEnv appends them last).
	env["ETH_RPC_URL"] = rpc
	env["FOUNDRY_ETH_RPC_URL"] = rpc

	run.log("$ (cwd %s) using rpc %s", dir, rpc)
	run.log("$ %s", redactForgeArgs(args))
	return runner.RunEnv(ctx, run.logger(), env, dir, "forge", args...)
}

// redactForgeArgs renders a forge command line with the --private-key value masked.
func redactForgeArgs(args []string) string {
	out := make([]string, len(args))
	copy(out, args)
	for i := 0; i+1 < len(out); i++ {
		if out[i] == "--private-key" {
			out[i+1] = "****"
		}
	}
	return "forge " + strings.Join(out, " ")
}

// setProgress records batch progress for the UI (a progress bar + label).
func setProgress(run *StepRun, done, total int, label string) {
	run.setData("progress", map[string]any{"done": done, "total": total, "label": label})
}

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
	args := forgeArgs("script/UpgradeToBeraWipe.s.sol:UpgradeToBeraWipe", cfg.Get("OLD_CHAIN_RPC"), cfg.Get("CONTRACT_DEPLOYER_PRIVATE_KEY"), cfg.Broadcast(), cfg.Get("MIGRATION_FORGE_CUPS"))
	env := map[string]string{"SFLUV_V2_PROXY": cfg.Get("OLD_TOKEN"), "EXPECTED_CHAIN_ID": cfg.Get("BERA_CHAIN_ID")}
	if _, err := runForge(ctx, run, cfg.Get("OLD_CHAIN_RPC"), env, s.contractsDir(), args); err != nil {
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
		env := map[string]string{
			"ACCOUNT_FACTORY_ADDRESS": cfg.Get("ACCOUNT_FACTORY_ADDRESS"),
			"EXPECTED_CHAIN_ID":       cfg.Get("NEW_CHAIN_ID"),
		}
		totalBatches := (count + batchSize - 1) / batchSize
		batchIdx := 0
		for start := 0; start < count; start += batchSize {
			end := start + batchSize
			if end > count {
				end = count
			}
			setProgress(run, batchIdx, totalBatches, fmt.Sprintf("Deploying batch %d/%d (wallets %d–%d of %d)", batchIdx+1, totalBatches, start+1, end, count))
			batchPath := filepath.Join(batchDir, fmt.Sprintf("batch-%d.json", start))
			run.log("deploying batch %d/%d (wallets %d–%d)", batchIdx+1, totalBatches, start+1, end)
			args := forgeArgs(
				"script/DeploySmartWalletBatch.s.sol:DeploySmartWalletBatch",
				cfg.Get("NEW_CHAIN_RPC"), cfg.Get("WALLET_DEPLOYER_PRIVATE_KEY"), cfg.Broadcast(), cfg.Get("MIGRATION_FORGE_CUPS"),
				"--sig", "run(string,uint256,uint256,string)", inputPath, strconv.Itoa(start), strconv.Itoa(batchSize), batchPath,
			)
			if _, err := runForge(ctx, run, cfg.Get("NEW_CHAIN_RPC"), env, s.contractsDir(), args); err != nil {
				return fmt.Errorf("batch %d failed: %w", start, err)
			}
			batchIdx++
		}
		setProgress(run, totalBatches, totalBatches, "Deployment complete")
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

// runDistribute mints/deposits each holder's balance on the new token, in
// bounded batches so progress is visible and a partial run resumes cleanly
// (DistributeBatch sends only the remaining delta per recipient).
func runDistribute(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	dir := s.artifactDir()
	distPath := filepath.Join(dir, "app-wallet-distribution.json")

	var dist struct {
		Addresses []string `json:"addresses"`
		Amounts   []string `json:"amounts"`
	}
	if err := readJSONFile(distPath, &dist); err != nil {
		return fmt.Errorf("reading distribution artifact (run the balance artifacts step first): %w", err)
	}
	total := len(dist.Addresses)
	run.setData("recipient_count", total)
	if total == 0 {
		run.log("no app-wallet recipients to distribute to")
		return nil
	}
	if len(dist.Amounts) != total {
		return fmt.Errorf("distribution artifact addresses/amounts length mismatch (%d vs %d)", total, len(dist.Amounts))
	}

	batchSize, err := strconv.Atoi(cfg.Get("SMART_WALLET_BATCH_SIZE"))
	if err != nil || batchSize <= 0 {
		return fmt.Errorf("invalid SMART_WALLET_BATCH_SIZE")
	}
	distributorAddr, err := privateKeyAddress(ctx, cfg.Get("DISTRIBUTOR_PRIVATE_KEY"))
	if err != nil {
		return err
	}
	env := map[string]string{"SFLUV_V3_PROXY": cfg.Get("NEW_TOKEN"), "DISTRIBUTOR": distributorAddr, "EXPECTED_CHAIN_ID": cfg.Get("NEW_CHAIN_ID")}
	batchDir := filepath.Join(dir, "distribution-batches")
	if err := os.MkdirAll(batchDir, 0o755); err != nil {
		return fmt.Errorf("creating distribution batch dir: %w", err)
	}

	totalBatches := (total + batchSize - 1) / batchSize
	run.log("distributing to %d recipients in %d batch(es) (broadcast=%v)", total, totalBatches, cfg.Broadcast())
	batchIdx := 0
	for start := 0; start < total; start += batchSize {
		end := start + batchSize
		if end > total {
			end = total
		}
		chunkPath := filepath.Join(batchDir, fmt.Sprintf("distribution-batch-%d.json", start))
		if err := writeJSONFile(chunkPath, map[string]any{
			"addresses": dist.Addresses[start:end],
			"amounts":   dist.Amounts[start:end],
		}); err != nil {
			return err
		}
		setProgress(run, batchIdx, totalBatches, fmt.Sprintf("Distributing batch %d/%d (recipients %d–%d of %d)", batchIdx+1, totalBatches, start+1, end, total))
		run.log("distributing batch %d/%d (recipients %d–%d)", batchIdx+1, totalBatches, start+1, end)
		args := forgeArgs(
			"script/DistributeBatch.s.sol:DistributeBatch",
			cfg.Get("NEW_CHAIN_RPC"), cfg.Get("DISTRIBUTOR_PRIVATE_KEY"), cfg.Broadcast(), cfg.Get("MIGRATION_FORGE_CUPS"),
			"--sig", "run(string)", chunkPath,
		)
		if _, err := runForge(ctx, run, cfg.Get("NEW_CHAIN_RPC"), env, s.contractsDir(), args); err != nil {
			return fmt.Errorf("distribution batch %d failed: %w", batchIdx+1, err)
		}
		batchIdx++
	}
	setProgress(run, totalBatches, totalBatches, "Distribution complete")
	return nil
}

// runWrapUnwrapCheck simulates wrapping then unwrapping a tiny amount of backing
// on Celo SFLUV to prove the backing is recoverable before minting all balances.
// It is ALWAYS a dry-run simulation (forge without --broadcast) — no live
// transactions are sent in any mode — and aborts the migration if the roundtrip
// would fail. The simulation still executes depositFor/withdrawTo against a fork
// of the live chain, so role/allowance/balance problems are caught.
func runWrapUnwrapCheck(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	distributorAddr, err := privateKeyAddress(ctx, cfg.Get("DISTRIBUTOR_PRIVATE_KEY"))
	if err != nil {
		return err
	}
	env := map[string]string{
		"SFLUV_V3_PROXY":    cfg.Get("NEW_TOKEN"),
		"DISTRIBUTOR":       distributorAddr,
		"EXPECTED_CHAIN_ID": cfg.Get("NEW_CHAIN_ID"),
	}
	if amt := strings.TrimSpace(cfg.Get("WRAP_CHECK_AMOUNT")); amt != "" {
		env["WRAP_CHECK_AMOUNT"] = amt
	}
	if rk := strings.TrimSpace(cfg.Get("REDEEMER_PRIVATE_KEY")); rk != "" {
		env["WRAP_CHECK_REDEEMER_KEY"] = rk
	}
	// Always simulate: pass broadcast=false regardless of MIGRATION_BROADCAST so
	// the check never sends live transactions.
	args := forgeArgs("script/WrapUnwrapCheck.s.sol:WrapUnwrapCheck",
		cfg.Get("NEW_CHAIN_RPC"), cfg.Get("DISTRIBUTOR_PRIVATE_KEY"), false, cfg.Get("MIGRATION_FORGE_CUPS"),
		"--sig", "run()")
	run.log("wrap/unwrap backing-recovery check (dry-run simulation; no live transactions)")
	if _, err := runForge(ctx, run, cfg.Get("NEW_CHAIN_RPC"), env, s.contractsDir(), args); err != nil {
		return fmt.Errorf("wrap/unwrap check failed — backing may not be recoverable; aborting before distribution: %w", err)
	}
	run.setData("wrap_unwrap_ok", true)
	run.log("backing is recoverable (wrap/unwrap roundtrip simulated successfully)")
	return nil
}

// rolesArtifact is CheckRoles' output: the Berachain MINTER/REDEEMER holders.
type rolesArtifact struct {
	Minters   []string `json:"minters"`
	Redeemers []string `json:"redeemers"`
}

// runReplicateRoles finds the MINTER/REDEEMER holders on the Berachain token
// (scanning all SFLUV holders plus the funded service accounts) and grants the
// same roles on the Celo token. Detection is read-only and always runs; the
// grant is skipped on a dry run.
func runReplicateRoles(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	dir, err := s.ensureArtifactDir()
	if err != nil {
		return err
	}

	// Candidate set: every address that ever sent or received SFLUV on Berachain,
	// plus the configured funded service accounts (e.g. the faucet/minter).
	ponderPool, err := s.ponderPool(ctx)
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	addresses := []string{}
	add := func(a string) {
		a = strings.ToLower(strings.TrimSpace(a))
		if !hexAddrRe.MatchString(a) || a == "0x0000000000000000000000000000000000000000" || seen[a] {
			return
		}
		seen[a] = true
		addresses = append(addresses, a)
	}
	rows, err := ponderPool.Query(ctx, `
		SELECT addr FROM (
			SELECT LOWER("from") AS addr FROM transfer_event
			UNION
			SELECT LOWER("to") AS addr FROM transfer_event
		) t`)
	if err != nil {
		return fmt.Errorf("querying Berachain holders: %w", err)
	}
	for rows.Next() {
		var a string
		if err := rows.Scan(&a); err != nil {
			rows.Close()
			return err
		}
		add(a)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		return err
	}
	extra, err := parseExtraFunded(cfg.Get("MIGRATION_EXTRA_FUNDED_ADDRESSES"))
	if err != nil {
		return err
	}
	for _, a := range extra {
		add(a)
	}
	run.setData("candidate_address_count", len(addresses))
	run.log("checking %d candidate addresses for MINTER/REDEEMER on Berachain", len(addresses))

	holdersPath := filepath.Join(dir, "bera-holders.json")
	if err := writeJSONFile(holdersPath, map[string]any{"addresses": addresses}); err != nil {
		return err
	}

	// Detect roles on Berachain (read-only).
	rolesPath := filepath.Join(dir, "bera-roles.json")
	checkArgs := []string{
		"script", "script/CheckRoles.s.sol:CheckRoles",
		"--rpc-url", cfg.Get("OLD_CHAIN_RPC"),
		"--sig", "run(string,string)", holdersPath, rolesPath,
	}
	if c := strings.TrimSpace(cfg.Get("MIGRATION_FORGE_CUPS")); c != "" {
		checkArgs = append(checkArgs, "--compute-units-per-second", c)
	}
	checkEnv := map[string]string{"SFLUV_PROXY": cfg.Get("OLD_TOKEN"), "EXPECTED_CHAIN_ID": cfg.Get("BERA_CHAIN_ID")}
	if _, err := runForge(ctx, run, cfg.Get("OLD_CHAIN_RPC"), checkEnv, s.contractsDir(), checkArgs); err != nil {
		return fmt.Errorf("detecting Berachain roles: %w", err)
	}

	var roles rolesArtifact
	if err := readJSONFile(rolesPath, &roles); err != nil {
		return fmt.Errorf("reading detected roles: %w", err)
	}
	run.setData("minter_count", len(roles.Minters))
	run.setData("redeemer_count", len(roles.Redeemers))
	run.setData("minters", roles.Minters)
	run.setData("redeemers", roles.Redeemers)
	run.log("Berachain role holders: %d MINTER, %d REDEEMER", len(roles.Minters), len(roles.Redeemers))

	if !cfg.Broadcast() {
		run.log("dry run: detected roles written to %s; skipping the grant on Celo", rolesPath)
		return nil
	}
	if len(roles.Minters) == 0 && len(roles.Redeemers) == 0 {
		run.log("no MINTER/REDEEMER holders to replicate")
		return nil
	}

	adminKey := strings.TrimSpace(cfg.Get("CELO_ADMIN_PRIVATE_KEY"))
	if adminKey == "" {
		return fmt.Errorf("CELO_ADMIN_PRIVATE_KEY is required to grant roles on Celo (needs DEFAULT_ADMIN, or MINTER_ADMIN+REDEEMER_ADMIN)")
	}
	adminAddr, err := privateKeyAddress(ctx, adminKey)
	if err != nil {
		return err
	}
	grantArgs := forgeArgs("script/GrantRoles.s.sol:GrantRoles",
		cfg.Get("NEW_CHAIN_RPC"), adminKey, cfg.Broadcast(), cfg.Get("MIGRATION_FORGE_CUPS"),
		"--sig", "run(string)", rolesPath)
	grantEnv := map[string]string{
		"SFLUV_PROXY":       cfg.Get("NEW_TOKEN"),
		"CELO_ADMIN":        adminAddr,
		"EXPECTED_CHAIN_ID": cfg.Get("NEW_CHAIN_ID"),
	}
	if _, err := runForge(ctx, run, cfg.Get("NEW_CHAIN_RPC"), grantEnv, s.contractsDir(), grantArgs); err != nil {
		return fmt.Errorf("granting roles on Celo: %w", err)
	}
	run.log("replicated MINTER/REDEEMER roles onto Celo SFLUV")
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

	start := new(big.Int).Add(complete, big.NewInt(1))
	if err := writeJSONFile(filepath.Join(dir, "migration-result.json"), map[string]any{
		"generated_at":                     time.Now().UTC().Format(time.RFC3339),
		"old_token":                        cfg.Get("OLD_TOKEN"),
		"new_token":                        cfg.Get("NEW_TOKEN"),
		"celo_distribution_complete_block": complete.String(),
		"ponder_start_block":               start.String(),
	}); err != nil {
		return err
	}

	// A local anvil mines only on transactions, so its head is frozen at the
	// distribution block. Two problems for the new Ponder follow, both fixed by
	// mining empty blocks here (best-effort: anvil_mine 404s on a live RPC, where
	// the chain advances on its own and the head is already far past the start):
	//
	//  1. The start block (complete+1) doesn't exist yet -> BlockNotFoundError.
	//  2. Ponder treats blocks within finalityBlockCount of the head as
	//     unfinalized and its realtime sync begins at head - finalityBlockCount.
	//     If the head is only a few blocks above the start block, the start block
	//     falls inside that window and Ponder indexes from BEFORE it. Mining past
	//     start + a finality buffer makes the start block finalized, so Ponder
	//     does a clean historical sync from exactly the start block.
	//
	// finalityBlockCount is 30 for Celo (Ponder's default); 64 covers it with margin.
	const ponderFinalityBuffer = 64
	target := new(big.Int).Add(start, big.NewInt(ponderFinalityBuffer))
	toMine := new(big.Int).Sub(target, headBig)
	if toMine.Sign() > 0 {
		countHex := "0x" + toMine.Text(16)
		if _, err := runner.Run(ctx, run.logger(), "", "cast", "rpc", "--rpc-url", cfg.Get("NEW_CHAIN_RPC"), "anvil_mine", countHex); err != nil {
			run.log("note: could not advance the chain past the Ponder start block (expected on a live RPC; on a local anvil, mine ~%d blocks before starting Ponder): %s", ponderFinalityBuffer, err)
		} else {
			run.log("mined %s empty block(s) so the Ponder start block %s is finalized and indexing begins exactly there (local anvil; head now %s)", toMine.String(), start.String(), target.String())
		}
	}
	return nil
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
