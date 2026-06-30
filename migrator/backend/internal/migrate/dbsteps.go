package migrate

import (
	"context"
	"fmt"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

// runWalletSnapshot writes the smart-wallet deploy input and a wallet snapshot
// from the app DB. Read-only.
func runWalletSnapshot(ctx context.Context, s *Session, run *StepRun) error {
	dir, err := s.ensureArtifactDir()
	if err != nil {
		return err
	}
	appPool, err := s.appPool(ctx)
	if err != nil {
		return err
	}

	rows, err := appPool.Query(ctx, `
		SELECT DISTINCT ON (LOWER(TRIM(eoa_address)), smart_index)
			LOWER(TRIM(eoa_address)) AS owner,
			smart_index AS salt,
			LOWER(TRIM(smart_address)) AS expected
		FROM wallets
		WHERE smart_index IS NOT NULL
			AND LOWER(TRIM(eoa_address)) ~ '^0x[0-9a-f]{40}$'
			AND LOWER(TRIM(COALESCE(smart_address, ''))) ~ '^0x[0-9a-f]{40}$'
		ORDER BY LOWER(TRIM(eoa_address)), smart_index, id;
	`)
	if err != nil {
		return fmt.Errorf("querying smart wallets: %w", err)
	}
	defer rows.Close()

	owners := []string{}
	salts := []int64{}
	expected := []string{}
	for rows.Next() {
		var owner, exp string
		var salt int64
		if err := rows.Scan(&owner, &salt, &exp); err != nil {
			return err
		}
		owners = append(owners, owner)
		salts = append(salts, salt)
		expected = append(expected, exp)
	}
	if err := rows.Err(); err != nil {
		return err
	}

	if err := writeJSONFile(filepath.Join(dir, "smart-wallet-deploy-input.json"), map[string]any{
		"owners":             owners,
		"salts":              salts,
		"expected_addresses": expected,
	}); err != nil {
		return err
	}

	var walletCount, addressCount int
	_ = appPool.QueryRow(ctx, `SELECT COUNT(*) FROM wallets`).Scan(&walletCount)
	_ = appPool.QueryRow(ctx, `
		SELECT COUNT(*) FROM (
			SELECT LOWER(TRIM(eoa_address)) a FROM wallets WHERE LOWER(TRIM(eoa_address)) ~ '^0x[0-9a-f]{40}$'
			UNION
			SELECT LOWER(TRIM(smart_address)) a FROM wallets WHERE LOWER(TRIM(COALESCE(smart_address,''))) ~ '^0x[0-9a-f]{40}$'
		) t`).Scan(&addressCount)

	run.setData("wallet_count", walletCount)
	run.setData("address_count", addressCount)
	run.setData("smart_wallet_count", len(owners))
	run.log("snapshot: %d wallet rows, %d unique addresses, %d smart wallets to deploy", walletCount, addressCount, len(owners))
	return nil
}

// runNormalizeApp divides retained W9 earnings from 18- to 6-decimal units.
func runNormalizeApp(ctx context.Context, s *Session, run *StepRun) error {
	dir, err := s.ensureArtifactDir()
	if err != nil {
		return err
	}
	pool, err := s.appPool(ctx)
	if err != nil {
		return err
	}
	scale := s.cfg.Get("MIGRATION_DECIMAL_SCALE")

	if done, err := hasDecimalMarker(ctx, pool, "app_w9_18_to_6"); err != nil {
		return err
	} else if done {
		run.log("app W9 normalization marker already present; leaving totals unchanged")
		return nil
	}

	var rowsCount int64
	var totalBefore string
	if err := pool.QueryRow(ctx, `SELECT COUNT(*), COALESCE(SUM(amount_received),0)::text FROM w9_wallet_earnings`).Scan(&rowsCount, &totalBefore); err != nil {
		return fmt.Errorf("app W9 before-audit: %w", err)
	}
	run.setData("w9_rows", rowsCount)
	run.setData("w9_total_before", totalBefore)
	_ = writeJSONFile(filepath.Join(dir, "app-db-normalization-before.json"), map[string]any{"rows": rowsCount, "total_before": totalBefore, "scale": scale})

	if !s.cfg.Broadcast() {
		run.log("dry run: W9 totals left unchanged (rows=%d, total=%s)", rowsCount, totalBefore)
		return nil
	}

	if _, err := pool.Exec(ctx, decimalMarkerTableSQL); err != nil {
		return err
	}
	body := fmt.Sprintf(`
		UPDATE w9_wallet_earnings
		SET amount_received = FLOOR(amount_received / %[1]s), updated_at = NOW()
		WHERE amount_received <> FLOOR(amount_received / %[1]s);
		INSERT INTO migration_decimal_normalization (id, scale) VALUES ('app_w9_18_to_6', %[1]s);
	`, scale)
	if err := execTx(ctx, pool, body); err != nil {
		return fmt.Errorf("app W9 normalization: %w", err)
	}

	var totalAfter string
	_ = pool.QueryRow(ctx, `SELECT COALESCE(SUM(amount_received),0)::text FROM w9_wallet_earnings`).Scan(&totalAfter)
	run.setData("w9_total_after", totalAfter)
	_ = writeJSONFile(filepath.Join(dir, "app-db-normalization-after.json"), map[string]any{"rows": rowsCount, "total_after": totalAfter})
	run.log("normalized W9 totals: %s → %s", totalBefore, totalAfter)
	return nil
}

type holderRow struct {
	Address string `json:"address"`
	Balance string `json:"balance"`
}

// runBalanceArtifacts derives the app-distribution and external-holder balance
// artifacts from the legacy Ponder transfer events (normalizing 18→6 on the fly).
// Read-only: the legacy Ponder DB is never mutated — the normalized history is
// pulled into the new Celo Ponder DB later by the backfill step.
func runBalanceArtifacts(ctx context.Context, s *Session, run *StepRun) error {
	dir, err := s.ensureArtifactDir()
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
	amtExpr := amountExpr(normalized, s.cfg.Get("MIGRATION_DECIMAL_SCALE"))

	external, err := queryHolderRows(ctx, ponderPool, funded, amtExpr, false)
	if err != nil {
		return fmt.Errorf("external holders: %w", err)
	}
	app, err := queryHolderRows(ctx, ponderPool, funded, amtExpr, true)
	if err != nil {
		return fmt.Errorf("app holders: %w", err)
	}
	if err := writeHolderArtifact(filepath.Join(dir, "external-holder-balances.json"), "Positive normalized balances for holders not in app.wallets or the extra funded set.", external); err != nil {
		return err
	}
	if err := writeHolderArtifact(filepath.Join(dir, "app-wallet-distribution.json"), "Desired final Celo balances for app wallets plus extra funded addresses.", app); err != nil {
		return err
	}
	run.setData("app_recipient_count", len(app))
	run.setData("external_holder_count", len(external))
	run.log("wrote %d app distribution rows and %d external holder rows (legacy Ponder unchanged)", len(app), len(external))
	return nil
}

// runSeedRecovery seeds recovery_balances in the bot DB from the external-holder
// artifact so non-migrated holders can claim post-migration.
func runSeedRecovery(ctx context.Context, s *Session, run *StepRun) error {
	if !s.cfg.Broadcast() {
		run.log("dry run: skipping recovery_balances seeding (no DB writes)")
		return nil
	}
	dir := s.artifactDir()
	var artifact holderBalances
	if err := readJSONFile(filepath.Join(dir, "external-holder-balances.json"), &artifact); err != nil {
		return fmt.Errorf("reading external holder artifact (run the balance artifacts step first): %w", err)
	}
	chainIDStr, err := castChainID(ctx, s.cfg.Get("OLD_CHAIN_RPC"))
	if err != nil {
		return err
	}
	chainID, ok := parseBig(chainIDStr)
	if !ok {
		return fmt.Errorf("could not resolve old chain id")
	}
	botPool, err := s.botPool(ctx)
	if err != nil {
		return err
	}
	if _, err := botPool.Exec(ctx, recoveryBalancesTableSQL); err != nil {
		return err
	}

	addresses := []string{}
	amounts := []string{}
	for _, h := range artifact.Holders {
		a := strings.ToLower(strings.TrimSpace(h.Address))
		amt := strings.TrimSpace(h.Balance)
		if !hexAddrRe.MatchString(a) || amt == "" || amt == "0" {
			continue
		}
		addresses = append(addresses, a)
		amounts = append(amounts, amt)
	}
	if len(addresses) == 0 {
		run.log("no external holders to seed")
		return nil
	}
	tag, err := botPool.Exec(ctx, `
		INSERT INTO recovery_balances(address, chain_id, amount)
		SELECT addr, $1::bigint, amt::numeric
		FROM unnest($2::text[], $3::text[]) AS t(addr, amt)
		ON CONFLICT (address) DO NOTHING;
	`, chainID.Int64(), addresses, amounts)
	if err != nil {
		return fmt.Errorf("seeding recovery_balances: %w", err)
	}
	run.setData("recovery_rows_seeded", tag.RowsAffected())
	run.setData("recovery_rows_total", len(addresses))
	run.log("seeded %d recovery balances (chain %s); %d rows inserted", len(addresses), chainIDStr, tag.RowsAffected())
	return nil
}

// --- shared DB helpers ------------------------------------------------------

const decimalMarkerTableSQL = `
CREATE TABLE IF NOT EXISTS migration_decimal_normalization (
	id TEXT PRIMARY KEY,
	scale NUMERIC(78, 0) NOT NULL,
	applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);`

const recoveryBalancesTableSQL = `
CREATE TABLE IF NOT EXISTS recovery_balances(
	address TEXT PRIMARY KEY,
	chain_id BIGINT NOT NULL,
	amount NUMERIC(78, 0) NOT NULL,
	claim_status TEXT NOT NULL DEFAULT 'unclaimed',
	claimed_by TEXT,
	claimed_by_user_id TEXT,
	claim_tx_hash TEXT,
	claim_tx_chain_id BIGINT,
	claimed_at TIMESTAMPTZ,
	created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
	updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);
CREATE INDEX IF NOT EXISTS recovery_balances_status_idx ON recovery_balances(claim_status);`

func hasDecimalMarker(ctx context.Context, p *pgxpool.Pool, id string) (bool, error) {
	var tableCount int
	if err := p.QueryRow(ctx, `SELECT COUNT(*) FROM pg_tables WHERE tablename='migration_decimal_normalization'`).Scan(&tableCount); err != nil {
		return false, err
	}
	if tableCount == 0 {
		return false, nil
	}
	var n int
	if err := p.QueryRow(ctx, `SELECT COUNT(*) FROM migration_decimal_normalization WHERE id=$1`, id).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// execTx runs a multi-statement body in a single transaction.
func execTx(ctx context.Context, p *pgxpool.Pool, body string) error {
	tx, err := p.Begin(ctx)
	if err != nil {
		return err
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, body); err != nil {
		return err
	}
	return tx.Commit(ctx)
}

func queryHolderRows(ctx context.Context, p *pgxpool.Pool, funded []string, amtExpr string, appSide bool) ([]holderRow, error) {
	predicate := "NOT EXISTS"
	if appSide {
		predicate = "EXISTS"
	}
	// The legacy Ponder DB is single-chain (Berachain) and no longer carries a
	// chain_id column, so balances are derived per address from the transfer_event
	// deltas directly.
	q := fmt.Sprintf(`
		WITH funded AS (SELECT DISTINCT LOWER(a) AS address FROM unnest($1::text[]) a),
		movements AS (
			SELECT LOWER("from") AS address, -(%[1]s) AS delta FROM transfer_event
			UNION ALL
			SELECT LOWER("to") AS address, (%[1]s) AS delta FROM transfer_event
		),
		balances AS (
			SELECT address, GREATEST(SUM(delta), 0) AS balance FROM movements GROUP BY address
		),
		sel AS (
			SELECT b.address, b.balance
			FROM balances b
			WHERE %[2]s (SELECT 1 FROM funded f WHERE f.address = b.address)
			AND b.balance > 0
		)
		SELECT address, balance::text FROM sel ORDER BY address;
	`, amtExpr, predicate)

	rows, err := p.Query(ctx, q, funded)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []holderRow{}
	for rows.Next() {
		var h holderRow
		if err := rows.Scan(&h.Address, &h.Balance); err != nil {
			return nil, err
		}
		out = append(out, h)
	}
	return out, rows.Err()
}

func writeHolderArtifact(path, note string, holders []holderRow) error {
	addresses := make([]string, len(holders))
	amounts := make([]string, len(holders))
	for i, h := range holders {
		addresses[i] = h.Address
		amounts[i] = h.Balance
	}
	return writeJSONFile(path, map[string]any{
		"generated_at": time.Now().UTC().Format(time.RFC3339),
		"note":         note,
		"addresses":    addresses,
		"amounts":      amounts,
		"holders":      holders,
	})
}
