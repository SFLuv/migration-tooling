package migrate

import (
	"context"
	"fmt"
	"math/big"
	"strings"
)

type checkResult struct {
	Name   string `json:"name"`
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

// runPreflight performs all read-only safety checks before any migration step.
// It fails if any critical check fails, recording every check (and key live
// values) for the UI.
func runPreflight(ctx context.Context, s *Session, run *StepRun) error {
	cfg := s.cfg
	var checks []checkResult
	var failed []string

	// add records a check; critical failures block the migration.
	add := func(name string, ok bool, critical bool, detail string) {
		checks = append(checks, checkResult{Name: name, OK: ok, Detail: detail})
		run.setData("checks", checks)
		status := "ok"
		if !ok {
			status = "FAIL"
			if critical {
				failed = append(failed, name)
			} else {
				status = "warn"
			}
		}
		run.log("[%s] %s — %s", status, name, detail)
	}

	oldRPC := cfg.Get("OLD_CHAIN_RPC")
	newRPC := cfg.Get("NEW_CHAIN_RPC")
	oldToken := cfg.Get("OLD_TOKEN")
	newToken := cfg.Get("NEW_TOKEN")

	// RPC reachability.
	if block, err := castBlockNumber(ctx, oldRPC); err != nil {
		add("Berachain RPC", false, true, err.Error())
	} else {
		add("Berachain RPC", true, true, "latest block "+block)
	}
	if block, err := castBlockNumber(ctx, newRPC); err != nil {
		add("Celo RPC", false, true, err.Error())
	} else {
		add("Celo RPC", true, true, "latest block "+block)
	}

	// Database connectivity.
	checkDB(ctx, s, add)

	// Token decimals + scale.
	oldDec, oldDecErr := castCall(ctx, oldRPC, oldToken, "decimals()(uint8)")
	newDec, newDecErr := castCall(ctx, newRPC, newToken, "decimals()(uint8)")
	if oldDecErr != nil {
		add("Old token decimals", false, true, oldDecErr.Error())
	} else {
		add("Old token decimals", true, true, oldDec)
	}
	if newDecErr != nil {
		add("New token decimals", false, true, newDecErr.Error())
	} else {
		add("New token decimals", true, true, newDec)
	}
	if oldDecErr == nil && newDecErr == nil {
		expected, err := expectedScale(oldDec, newDec)
		if err != nil {
			add("Decimal scale", false, true, err.Error())
		} else if expected != cfg.Get("MIGRATION_DECIMAL_SCALE") {
			add("Decimal scale", false, true, fmt.Sprintf("MIGRATION_DECIMAL_SCALE=%s but decimals %s→%s require %s", cfg.Get("MIGRATION_DECIMAL_SCALE"), oldDec, newDec, expected))
		} else {
			add("Decimal scale", true, true, "matches token decimals ("+expected+")")
		}

		// Underlying backing decimals must match the new token.
		if underlying, err := castCall(ctx, newRPC, newToken, "underlying()(address)"); err != nil {
			add("New token underlying", false, true, err.Error())
		} else if uDec, err := castCall(ctx, newRPC, underlying, "decimals()(uint8)"); err != nil {
			add("Underlying decimals", false, true, err.Error())
		} else if uDec != newDec {
			add("Underlying decimals", false, true, fmt.Sprintf("underlying %s has %s decimals, new token has %s", underlying, uDec, newDec))
		} else {
			add("Underlying decimals", true, true, "matches new token ("+uDec+")")
			run.setData("underlying", underlying)
		}
	}

	// Roles.
	distributorAddr, distErr := privateKeyAddress(ctx, cfg.Get("DISTRIBUTOR_PRIVATE_KEY"))
	deployerAddr, depErr := privateKeyAddress(ctx, cfg.Get("CONTRACT_DEPLOYER_PRIVATE_KEY"))
	walletDeployerAddr, wdErr := privateKeyAddress(ctx, cfg.Get("WALLET_DEPLOYER_PRIVATE_KEY"))

	if distErr != nil {
		add("Distributor key", false, true, distErr.Error())
	} else if minterRole, err := castKeccak(ctx, "MINTER"); err != nil {
		add("Distributor MINTER role", false, true, err.Error())
	} else if has, err := castCall(ctx, newRPC, newToken, "hasRole(bytes32,address)(bool)", minterRole, distributorAddr); err != nil {
		add("Distributor MINTER role", false, true, err.Error())
	} else if !strings.EqualFold(has, "true") {
		add("Distributor MINTER role", false, true, distributorAddr+" lacks MINTER_ROLE on the new token")
	} else {
		add("Distributor MINTER role", true, true, distributorAddr)
	}

	if depErr != nil {
		add("Deployer key", false, true, depErr.Error())
	} else if has, err := castCall(ctx, oldRPC, oldToken, "hasRole(bytes32,address)(bool)", "0x0000000000000000000000000000000000000000000000000000000000000000", deployerAddr); err != nil {
		add("Deployer admin role", false, true, err.Error())
	} else if !strings.EqualFold(has, "true") {
		add("Deployer admin role", false, true, deployerAddr+" lacks DEFAULT_ADMIN_ROLE on the old token")
	} else {
		add("Deployer admin role", true, true, deployerAddr)
	}

	// Gas balances for every account that signs transactions.
	gasCheck := func(name, rpc, addr string, err error) {
		if err != nil {
			add(name, false, true, err.Error())
			return
		}
		bal, berr := castBalance(ctx, rpc, addr)
		if berr != nil {
			add(name, false, true, berr.Error())
			return
		}
		v, ok := parseBig(bal)
		if !ok || v.Sign() <= 0 {
			add(name, false, true, addr+" has no gas")
			return
		}
		add(name, true, true, addr+" — "+bal+" wei")
	}
	gasCheck("Deployer gas (Berachain)", oldRPC, deployerAddr, depErr)
	gasCheck("Wallet deployer gas (Celo)", newRPC, walletDeployerAddr, wdErr)
	gasCheck("Distributor gas (Celo)", newRPC, distributorAddr, distErr)

	// Backing-token sufficiency: the distributor must hold (and have approved)
	// enough underlying to back the full projected distribution.
	if err := checkBacking(ctx, s, newRPC, newToken, distributorAddr, distErr, run, add); err != nil {
		add("Backing sufficiency", false, true, err.Error())
	}

	// Wallet integrity.
	if appPool, err := s.appPool(ctx); err != nil {
		add("Wallet integrity", false, true, err.Error())
	} else if critical, warnings, err := walletIntegrity(ctx, appPool); err != nil {
		add("Wallet integrity", false, true, err.Error())
	} else {
		if critical > 0 {
			add("Wallet integrity", false, true, fmt.Sprintf("%d wallet row(s) would be silently excluded — fix before running", critical))
		} else {
			add("Wallet integrity", true, true, "no critical rows")
		}
		if warnings > 0 {
			add("Wallet integrity (warnings)", false, false, fmt.Sprintf("%d non-EOA row(s) have no smart address", warnings))
		}
	}

	if len(failed) > 0 {
		return fmt.Errorf("preflight failed: %s", strings.Join(failed, ", "))
	}
	return nil
}

func checkDB(ctx context.Context, s *Session, add func(string, bool, bool, string)) {
	if p, err := s.appPool(ctx); err != nil {
		add("App database", false, true, err.Error())
	} else if err := pingDB(ctx, p); err != nil {
		add("App database", false, true, err.Error())
	} else {
		add("App database", true, true, "connected")
	}
	if p, err := s.ponderPool(ctx); err != nil {
		add("Ponder database", false, true, err.Error())
	} else if err := pingDB(ctx, p); err != nil {
		add("Ponder database", false, true, err.Error())
	} else {
		add("Ponder database", true, true, "connected")
	}
	if p, err := s.botPool(ctx); err != nil {
		add("Bot database", false, true, err.Error())
	} else if err := pingDB(ctx, p); err != nil {
		add("Bot database", false, true, err.Error())
	} else {
		add("Bot database", true, true, "connected")
	}
}

func checkBacking(ctx context.Context, s *Session, newRPC, newToken, distributorAddr string, distErr error, run *StepRun, add func(string, bool, bool, string)) error {
	if distErr != nil {
		return distErr
	}
	underlying, err := castCall(ctx, newRPC, newToken, "underlying()(address)")
	if err != nil {
		return err
	}

	appPool, err := s.appPool(ctx)
	if err != nil {
		return err
	}
	ponderPool, err := s.ponderPool(ctx)
	if err != nil {
		return err
	}
	extra, err := parseExtraFunded(s.cfg.Get("MIGRATION_EXTRA_FUNDED_ADDRESSES"))
	if err != nil {
		return err
	}
	funded, err := fundedAddresses(ctx, appPool, extra)
	if err != nil {
		return err
	}
	normalized, err := ponderNormalized(ctx, ponderPool)
	if err != nil {
		return err
	}
	projected, err := projectedDistributionTotal(ctx, ponderPool, funded, amountExpr(normalized, s.cfg.Get("MIGRATION_DECIMAL_SCALE")))
	if err != nil {
		return err
	}
	run.setData("projected_distribution_base_units", projected.String())
	run.setData("funded_address_count", len(funded))
	add("Projected distribution", true, false, projected.String()+" base units across "+itoa(len(funded))+" funded addresses")

	supplyStr, err := castCall(ctx, newRPC, newToken, "totalSupply()(uint256)")
	if err != nil {
		return err
	}
	supply, ok := parseBig(supplyStr)
	if !ok {
		return fmt.Errorf("unexpected totalSupply %q", supplyStr)
	}
	remaining := bigSubFloorZero(projected, supply)
	run.setData("remaining_to_back", remaining.String())
	add("Already distributed", true, false, "new token totalSupply "+supply.String())

	// Berachain total-supply bound (decimal-adjusted): the distributor must be
	// able to back the FULL old-chain SFLUV supply converted to new-token units,
	// not just the funded subset. The 18->6 decimal difference is applied by
	// dividing by MIGRATION_DECIMAL_SCALE (10^(old-new), verified above).
	oldRPC := s.cfg.Get("OLD_CHAIN_RPC")
	oldToken := s.cfg.Get("OLD_TOKEN")
	scaleBig, ok := parseBig(s.cfg.Get("MIGRATION_DECIMAL_SCALE"))
	if !ok || scaleBig.Sign() <= 0 {
		return fmt.Errorf("invalid MIGRATION_DECIMAL_SCALE")
	}
	beraSupplyStr, err := castCall(ctx, oldRPC, oldToken, "totalSupply()(uint256)")
	if err != nil {
		return err
	}
	beraSupply, ok := parseBig(beraSupplyStr)
	if !ok {
		return fmt.Errorf("unexpected Berachain totalSupply %q", beraSupplyStr)
	}
	beraSupplyNewUnits := new(big.Int).Div(beraSupply, scaleBig)
	run.setData("bera_total_supply", beraSupply.String())
	run.setData("bera_total_supply_new_units", beraSupplyNewUnits.String())
	add("Berachain SFLUV total supply", true, false,
		fmt.Sprintf("%s old-decimal units = %s new-token units after dividing by %s", beraSupply.String(), beraSupplyNewUnits.String(), scaleBig.String()))

	// Required backing is the strict bound: max of the projected funded
	// distribution and the full Berachain supply (both in new-token units),
	// less what the new token already has minted.
	remainingVsBera := bigSubFloorZero(beraSupplyNewUnits, supply)
	required := bigMax(remaining, remainingVsBera)
	run.setData("required_backing", required.String())

	balStr, err := castCall(ctx, newRPC, underlying, "balanceOf(address)(uint256)", distributorAddr)
	if err != nil {
		return err
	}
	bal, _ := parseBig(balStr)
	if bal == nil {
		bal = big.NewInt(0)
	}
	if !bigGTE(bal, required) {
		add("Backing balance covers Berachain supply", false, true,
			fmt.Sprintf("distributor backing %s < required %s (Berachain-supply bound %s, projected %s)", bal.String(), required.String(), remainingVsBera.String(), remaining.String()))
	} else {
		add("Backing balance covers Berachain supply", true, true,
			fmt.Sprintf("%s covers required %s (Berachain-supply bound, decimal-adjusted)", bal.String(), required.String()))
	}

	allowStr, err := castCall(ctx, newRPC, underlying, "allowance(address,address)(uint256)", distributorAddr, newToken)
	if err != nil {
		return err
	}
	allow, _ := parseBig(allowStr)
	if allow == nil {
		allow = big.NewInt(0)
	}
	if !bigGTE(allow, required) {
		add("Backing allowance covers Berachain supply", false, true,
			fmt.Sprintf("distributor allowance %s < required %s", allow.String(), required.String()))
	} else {
		add("Backing allowance covers Berachain supply", true, true,
			fmt.Sprintf("%s covers required %s", allow.String(), required.String()))
	}
	return nil
}

func expectedScale(oldDec, newDec string) (string, error) {
	o, ok1 := new(big.Int).SetString(strings.TrimSpace(oldDec), 10)
	n, ok2 := new(big.Int).SetString(strings.TrimSpace(newDec), 10)
	if !ok1 || !ok2 {
		return "", fmt.Errorf("non-numeric decimals (%q, %q)", oldDec, newDec)
	}
	if o.Cmp(n) < 0 {
		return "", fmt.Errorf("old decimals < new decimals is unsupported")
	}
	diff := new(big.Int).Sub(o, n)
	return new(big.Int).Exp(big.NewInt(10), diff, nil).String(), nil
}

func itoa(n int) string { return fmt.Sprintf("%d", n) }
