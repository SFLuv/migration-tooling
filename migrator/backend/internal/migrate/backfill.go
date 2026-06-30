package migrate

import (
	"bytes"
	"context"
	"fmt"
	"math/big"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

var uintRe = regexp.MustCompile(`^[0-9]+$`)
var identRe = regexp.MustCompile(`^[a-zA-Z_][a-zA-Z0-9_]*$`)

// eventTable describes a Ponder event table copied (with on-the-fly decimal
// normalization) during the backfill.
type eventTable struct {
	name       string
	cols       string // staging/insert column list (verbatim, quoted)
	selectExpr string // source SELECT list; %[1]s is the decimal scale
	conflict   string // ON CONFLICT target columns
	valueCol   string // amount column normalized + summed for verification
}

// selectExpr placeholder: %[1]s = decimal scale. The Ponder schema is
// single-chain and carries no chain_id column (Ponder's event id already encodes
// the source chain), so rows are copied as-is with on-the-fly decimal
// normalization and de-duplicated on their natural primary key.
var backfillEventTables = []eventTable{
	{
		name:       "transfer_event",
		cols:       `id, hash, amount, timestamp, "from", "to"`,
		selectExpr: `id, hash, FLOOR(amount / %[1]s), timestamp, "from", "to"`,
		conflict:   "id",
		valueCol:   "amount",
	},
	{
		name:       "allowance",
		cols:       `owner, spender, amount`,
		selectExpr: `owner, spender, FLOOR(amount / %[1]s)`,
		conflict:   "owner, spender",
		valueCol:   "amount",
	},
	{
		name:       "approval_event",
		cols:       `id, amount, timestamp, owner, spender`,
		selectExpr: `id, FLOOR(amount / %[1]s), timestamp, owner, spender`,
		conflict:   "id",
		valueCol:   "amount",
	},
}

// requiredTargetTables must exist in the Celo Ponder DB before backfilling.
var requiredTargetTables = []string{"transfer_event", "allowance", "approval_event", "transfer_account"}

// backfillWarning is the prominent pre-run instruction for the backfill step: the
// operator must boot the new Celo Ponder instance (so it creates its tables)
// before the legacy history can be pulled into it.
func backfillWarning(s *Session) string {
	block := readPonderStartBlock(s)
	if block == "" {
		block = "<run the Completion step first to resolve the block>"
	}
	dbName := s.cfg.Get("MIGRATION_DB_CELO_PONDER_SUFFIX")
	target := dbName
	if redacted, err := s.cfg.CeloPonderDBURLRedacted(); err == nil && redacted != "" {
		target = redacted
	}
	return fmt.Sprintf(
		"START THE NEW CELO PONDER INSTANCE AT BLOCK %s POINTING TO %s (database %q) BEFORE RUNNING THIS STEP",
		block, target, dbName,
	)
}

// backfillSnippets returns copyable blocks the operator needs to stand up the
// Celo Ponder instance before running the backfill: a ready Celo ponder.config.ts
// and a one-line command that points Ponder at the Celo DB/RPC and starts it.
func backfillSnippets(s *Session) []Snippet {
	block := readPonderStartBlock(s)
	if block == "" {
		block = "<run Completion to resolve the start block>"
	}
	celoChainID := s.cfg.Get("NEW_CHAIN_ID")
	if celoChainID == "" {
		celoChainID = "42220"
	}
	schema := s.cfg.Get("CELO_PONDER_SCHEMA")
	if schema == "" {
		schema = "public"
	}
	newToken := strings.ToLower(strings.TrimSpace(s.cfg.Get("NEW_TOKEN")))
	rpc := s.cfg.Get("NEW_CHAIN_RPC")
	dbURL, _ := s.cfg.CeloPonderDBURL()

	config := fmt.Sprintf(`import { createConfig } from "ponder";
import { erc20ABI } from "./abis/erc20ABI";

const startBlock = Number(process.env.PONDER_START_BLOCK ?? %[1]s);

export default createConfig({
  chains: {
    celo: {
      id: %[2]s,
      rpc: process.env.PONDER_RPC_URL_1,
    },
  },
  contracts: {
    ERC20: {
      chain: "celo",
      abi: erc20ABI,
      address: "%[3]s",
      startBlock,
    },
  },
});
`, block, celoChainID, newToken)

	run := fmt.Sprintf(`# Local anvil only: anvil freezes its head between transactions, so the start
# block may not exist yet, and it would sit inside Ponder's finality window
# (~30 blocks) causing Ponder to index from before it. Mine 64 empty blocks so
# the start block exists and is finalized. No-op on a live RPC (anvil_mine 404s).
cast rpc --rpc-url '%[3]s' anvil_mine 0x40 >/dev/null 2>&1 || true

cd repos/app/ponder && \
DATABASE_URL='%[1]s' \
DATABASE_SCHEMA='%[2]s' \
PONDER_RPC_URL_1='%[3]s' \
CHAIN_ID=%[4]s PONDER_CHAIN_ID=%[4]s \
PONDER_START_BLOCK=%[5]s \
pnpm exec ponder start`, dbURL, schema, rpc, celoChainID, block)

	return []Snippet{
		{Title: "Celo ponder.config.ts — replace repos/app/ponder/ponder.config.ts", Language: "ts", Content: config},
		{Title: "Start the Celo Ponder instance (mines a block for local anvil; contains DB credentials)", Language: "bash", Content: run},
	}
}

// readPonderStartBlock reads the Ponder start block resolved by the completion
// step from the migration result artifact, if present.
func readPonderStartBlock(s *Session) string {
	var result struct {
		PonderStartBlock string `json:"ponder_start_block"`
	}
	if err := readJSONFile(filepath.Join(s.artifactDir(), "migration-result.json"), &result); err != nil {
		return ""
	}
	return strings.TrimSpace(result.PonderStartBlock)
}

// runBackfill pulls the Berachain Ponder history into the dedicated Celo Ponder
// database, normalizing 18→6 decimals during the copy. The legacy Ponder DB is
// only read from; it is never mutated. transfer_event/allowance/approval_event
// are copied with normalized amounts, and transfer_account is rebuilt from the
// app-distribution artifact (app + funded only; external holders are excluded
// since they recover their balance separately).
func runBackfill(ctx context.Context, s *Session, run *StepRun) error {
	if !s.cfg.Broadcast() {
		run.log("dry run: skipping Celo Ponder backfill (no DB writes)")
		return nil
	}

	// Retained only for the audit record below; the Ponder schema no longer stores
	// a chain_id column, so it is never written into any table.
	beraChainID := s.cfg.Get("BERA_CHAIN_ID")
	if beraChainID == "" {
		beraChainID = "80094"
	}
	schema := s.cfg.Get("CELO_PONDER_SCHEMA")
	if schema == "" {
		schema = "public"
	}
	if !identRe.MatchString(schema) {
		return fmt.Errorf("invalid CELO_PONDER_SCHEMA %q", schema)
	}
	scale := s.cfg.Get("MIGRATION_DECIMAL_SCALE")
	if !uintRe.MatchString(scale) {
		return fmt.Errorf("MIGRATION_DECIMAL_SCALE must be an integer, got %q", scale)
	}

	src, err := s.ponderPool(ctx)
	if err != nil {
		return err
	}
	dst, err := s.celoPonderPool(ctx)
	if err != nil {
		return err
	}

	// The Celo Ponder instance must have created its tables (boot it first).
	for _, name := range requiredTargetTables {
		exists, err := tableExistsInSchema(ctx, dst, schema, name)
		if err != nil {
			return err
		}
		if !exists {
			return fmt.Errorf("target table %s.%s does not exist — boot the new Celo Ponder instance first so it creates its tables", schema, name)
		}
	}
	run.log("target Ponder tables present in schema %q; legacy Ponder is read-only", schema)

	audits := make([]map[string]any, 0, len(requiredTargetTables))

	// Event tables: copy with normalized amounts.
	for _, t := range backfillEventTables {
		rows, total, err := copyEventTable(ctx, src, dst, schema, t, scale)
		if err != nil {
			return err
		}
		run.log("copied %s: rows=%d %s_total=%s (normalized)", t.name, rows, t.valueCol, total)
		audit := map[string]any{"table": t.name, "rows": rows, t.valueCol + "_total": total}
		audits = append(audits, audit)
		run.setData(t.name, audit)
	}

	// transfer_account: rebuilt from the app distribution artifact (app + funded).
	taRows, taTotal, err := backfillTransferAccount(ctx, s, dst, schema)
	if err != nil {
		return err
	}
	run.log("rebuilt transfer_account: rows=%d balance_total=%s (app + funded only)", taRows, taTotal)
	taAudit := map[string]any{"table": "transfer_account", "rows": taRows, "balance_total": taTotal}
	audits = append(audits, taAudit)
	run.setData("transfer_account", taAudit)

	// Custom (non-onchain) table: migrate the registered webhooks so the new
	// Ponder instance fires the same per-address hooks (src/db.ts ponder_hooks).
	hookRows, err := backfillPonderHooks(ctx, src, dst, run)
	if err != nil {
		return err
	}
	run.log("migrated ponder_hooks: %d webhook registration(s)", hookRows)
	audits = append(audits, map[string]any{"table": "ponder_hooks", "rows": hookRows})
	run.setData("ponder_hooks", hookRows)

	dir, err := s.ensureArtifactDir()
	if err != nil {
		return err
	}
	auditPath := filepath.Join(dir, "bera-backfill-audit.json")
	if err := writeJSONFile(auditPath, map[string]any{
		"generated_at":  time.Now().UTC().Format(time.RFC3339),
		"chain_id":      beraChainID,
		"scale":         scale,
		"source_db":     s.cfg.Get("MIGRATION_DB_PONDER_SUFFIX"),
		"target_db":     s.cfg.Get("MIGRATION_DB_CELO_PONDER_SUFFIX"),
		"target_schema": schema,
		"note":          "Berachain Ponder history pulled into the Celo Ponder DB with 18→6 decimal normalization applied during the copy. The legacy Ponder DB was not modified. transfer_account holds app + funded balances only (external holders excluded). Custom ponder_hooks webhook registrations are migrated too.",
		"tables":        audits,
	}); err != nil {
		return err
	}
	run.setData("audit", auditPath)
	run.log("backfill complete; audit written to %s", auditPath)
	return nil
}

// copyEventTable copies one event table's Berachain rows from src to dst via the
// COPY protocol, normalizing the amount column (FLOOR(amount/scale)) on the source
// side, inserting ON CONFLICT DO NOTHING, clearing the Ponder reorg log for the
// chain id, then verifying counts and the normalized total match.
func copyEventTable(ctx context.Context, src, dst *pgxpool.Pool, schema string, t eventTable, scale string) (int64, string, error) {
	// 1. COPY the normalized rows out of the source into a buffer. The legacy
	//    Ponder DB is single-chain, so every row is copied (no chain_id filter).
	var buf bytes.Buffer
	srcConn, err := src.Acquire(ctx)
	if err != nil {
		return 0, "", err
	}
	defer srcConn.Release()
	selectList := fmt.Sprintf(t.selectExpr, scale)
	outSQL := fmt.Sprintf(`COPY (SELECT %s FROM %s) TO STDOUT WITH (FORMAT csv)`,
		selectList, qident(t.name))
	if _, err := srcConn.Conn().PgConn().CopyTo(ctx, &buf, outSQL); err != nil {
		return 0, "", fmt.Errorf("copy out %s: %w", t.name, err)
	}

	// 2. Stage, insert ON CONFLICT, verify against the staged set, and clear the
	//    reorg log — one transaction on one connection so the temp table stays in
	//    scope (and the verification can isolate exactly the rows we copied even if
	//    the live Ponder has already indexed some new rows).
	dstConn, err := dst.Acquire(ctx)
	if err != nil {
		return 0, "", err
	}
	defer dstConn.Release()

	reorgExists, err := tableExistsInSchema(ctx, dst, schema, "_reorg__"+t.name)
	if err != nil {
		return 0, "", err
	}

	tx, err := dstConn.Begin(ctx)
	if err != nil {
		return 0, "", err
	}
	defer tx.Rollback(ctx)

	if err := ensureLiveQueryTable(ctx, tx); err != nil {
		return 0, "", err
	}
	staging := "staging_" + t.name
	if _, err := tx.Exec(ctx, fmt.Sprintf(`CREATE TEMP TABLE %s (LIKE %s.%s INCLUDING DEFAULTS) ON COMMIT DROP`,
		qident(staging), qident(schema), qident(t.name))); err != nil {
		return 0, "", fmt.Errorf("create staging for %s: %w", t.name, err)
	}
	inSQL := fmt.Sprintf(`COPY %s(%s) FROM STDIN WITH (FORMAT csv)`, qident(staging), t.cols)
	if _, err := tx.Conn().PgConn().CopyFrom(ctx, &buf, inSQL); err != nil {
		return 0, "", fmt.Errorf("copy in %s: %w", t.name, err)
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(`INSERT INTO %s.%s (%s) SELECT %s FROM %s ON CONFLICT (%s) DO NOTHING`,
		qident(schema), qident(t.name), t.cols, t.cols, qident(staging), t.conflict)); err != nil {
		return 0, "", fmt.Errorf("insert %s: %w", t.name, err)
	}

	// 3. Verify every staged row landed in the target and the normalized totals
	//    match, joining on the natural primary key so concurrent live rows are
	//    excluded from the comparison.
	join := pkJoinCond(t.conflict, "tgt", "s")
	staged, err := txScanInt(ctx, tx, fmt.Sprintf(`SELECT COUNT(*) FROM %s`, qident(staging)))
	if err != nil {
		return 0, "", err
	}
	present, err := txScanInt(ctx, tx, fmt.Sprintf(`SELECT COUNT(*) FROM %s.%s tgt JOIN %s s ON %s`,
		qident(schema), qident(t.name), qident(staging), join))
	if err != nil {
		return 0, "", err
	}
	if staged != present {
		return 0, "", fmt.Errorf("%s row count mismatch after copy: staged %d, present in target %d", t.name, staged, present)
	}
	stagedSum, err := txScanText(ctx, tx, fmt.Sprintf(`SELECT COALESCE(SUM(%s),0)::text FROM %s`, t.valueCol, qident(staging)))
	if err != nil {
		return 0, "", err
	}
	presentSum, err := txScanText(ctx, tx, fmt.Sprintf(`SELECT COALESCE(SUM(tgt.%s),0)::text FROM %s.%s tgt JOIN %s s ON %s`,
		t.valueCol, qident(schema), qident(t.name), qident(staging), join))
	if err != nil {
		return 0, "", err
	}
	if stagedSum != presentSum {
		return 0, "", fmt.Errorf("%s normalized %s total mismatch: staged %s, present in target %s", t.name, t.valueCol, stagedSum, presentSum)
	}

	if err := clearReorgLog(ctx, tx, schema, t.name, reorgExists); err != nil {
		return 0, "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, "", err
	}
	return present, presentSum, nil
}

// backfillTransferAccount inserts the app + funded balances (from the
// app-distribution artifact, already normalized) into the Celo Ponder
// transfer_account tagged with the Berachain chain id. External holders are
// excluded — they recover their balance via recovery_balances instead.
func backfillTransferAccount(ctx context.Context, s *Session, dst *pgxpool.Pool, schema string) (int64, string, error) {
	var dist holderBalances
	if err := readJSONFile(filepath.Join(s.artifactDir(), "app-wallet-distribution.json"), &dist); err != nil {
		return 0, "", fmt.Errorf("reading app distribution artifact (run the balance artifacts step first): %w", err)
	}

	addrs := make([]string, 0, len(dist.Holders))
	amts := make([]string, 0, len(dist.Holders))
	expected := big.NewInt(0)
	for _, h := range dist.Holders {
		a := strings.ToLower(strings.TrimSpace(h.Address))
		amt := strings.TrimSpace(h.Balance)
		if !hexAddrRe.MatchString(a) || amt == "" || amt == "0" {
			continue
		}
		if v, ok := new(big.Int).SetString(amt, 10); ok {
			expected.Add(expected, v)
		}
		addrs = append(addrs, a)
		amts = append(amts, amt)
	}

	dstConn, err := dst.Acquire(ctx)
	if err != nil {
		return 0, "", err
	}
	defer dstConn.Release()
	reorgExists, err := tableExistsInSchema(ctx, dst, schema, "_reorg__transfer_account")
	if err != nil {
		return 0, "", err
	}

	tx, err := dstConn.Begin(ctx)
	if err != nil {
		return 0, "", err
	}
	defer tx.Rollback(ctx)

	if err := ensureLiveQueryTable(ctx, tx); err != nil {
		return 0, "", err
	}
	if len(addrs) > 0 {
		if _, err := tx.Exec(ctx, fmt.Sprintf(`
			INSERT INTO %s.%s (address, balance, is_owner)
			SELECT addr, amt::numeric, false
			FROM unnest($1::text[], $2::text[]) AS t(addr, amt)
			ON CONFLICT (address) DO NOTHING`,
			qident(schema), qident("transfer_account")), addrs, amts); err != nil {
			return 0, "", fmt.Errorf("insert transfer_account: %w", err)
		}
	}
	if err := clearReorgLog(ctx, tx, schema, "transfer_account", reorgExists); err != nil {
		return 0, "", err
	}
	if err := tx.Commit(ctx); err != nil {
		return 0, "", err
	}

	// Verify by the inserted address set so concurrent live rows are excluded.
	var dstCount int64
	if err := dst.QueryRow(ctx, fmt.Sprintf(`SELECT COUNT(*) FROM %s.%s WHERE address = ANY($1::text[])`,
		qident(schema), qident("transfer_account")), addrs).Scan(&dstCount); err != nil {
		return 0, "", err
	}
	var dstSum string
	if err := dst.QueryRow(ctx, fmt.Sprintf(`SELECT COALESCE(SUM(balance),0)::text FROM %s.%s WHERE address = ANY($1::text[])`,
		qident(schema), qident("transfer_account")), addrs).Scan(&dstSum); err != nil {
		return 0, "", err
	}
	if int(dstCount) != len(addrs) || dstSum != expected.String() {
		return 0, "", fmt.Errorf("transfer_account verification mismatch: target rows=%d total=%s, expected rows=%d total=%s", dstCount, dstSum, len(addrs), expected.String())
	}
	return dstCount, dstSum, nil
}

// clearReorgLog empties the Ponder reorg log entries that our inserts recorded,
// so crash recovery / a reorg cannot revert the backfilled rows. The reorg table
// no longer has a chain_id column to filter on; the backfill runs immediately
// after the Celo Ponder instance is booted (at the post-migration start block),
// so the only entries present are from this backfill plus, at most, a handful of
// just-indexed blocks — clearing them all is safe at cutover.
func clearReorgLog(ctx context.Context, tx pgx.Tx, schema, table string, reorgExists bool) error {
	if !reorgExists {
		return nil
	}
	if _, err := tx.Exec(ctx, fmt.Sprintf(`DELETE FROM %s.%s`,
		qident(schema), qident("_reorg__"+table))); err != nil {
		return fmt.Errorf("clear reorg log for %s: %w", table, err)
	}
	return nil
}

// pkJoinCond builds an equality join condition over the primary-key columns
// (the ON CONFLICT target) between two relation aliases, e.g.
// `tgt."owner" = s."owner" AND tgt."spender" = s."spender"`.
func pkJoinCond(conflict, left, right string) string {
	parts := strings.Split(conflict, ",")
	conds := make([]string, 0, len(parts))
	for _, p := range parts {
		c := strings.TrimSpace(p)
		if c == "" {
			continue
		}
		conds = append(conds, fmt.Sprintf("%s.%s = %s.%s", left, qident(c), right, qident(c)))
	}
	return strings.Join(conds, " AND ")
}

// txScanInt / txScanText run a single-value query on an open transaction.
func txScanInt(ctx context.Context, tx pgx.Tx, sql string) (int64, error) {
	var v int64
	if err := tx.QueryRow(ctx, sql).Scan(&v); err != nil {
		return 0, err
	}
	return v, nil
}

func txScanText(ctx context.Context, tx pgx.Tx, sql string) (string, error) {
	var v string
	if err := tx.QueryRow(ctx, sql).Scan(&v); err != nil {
		return "", err
	}
	return v, nil
}

// ensureLiveQueryTable creates the session-local table that Ponder's live-query
// trigger writes to on every row change of a data table. The running Ponder
// instance creates it as a TEMP table in its own connection; our backfill writes
// from a different connection that has no such table, so an insert into a Ponder
// table would otherwise fail with: relation "live_query_tables" does not exist.
// Creating an equivalent TEMP table in this transaction makes the trigger a
// harmless no-op for our bulk writes (and ON COMMIT DROP cleans it up). This does
// not touch the live Ponder process or take any lock.
func ensureLiveQueryTable(ctx context.Context, tx pgx.Tx) error {
	if _, err := tx.Exec(ctx, `CREATE TEMP TABLE IF NOT EXISTS live_query_tables (table_name text PRIMARY KEY) ON COMMIT DROP`); err != nil {
		return fmt.Errorf("creating live_query_tables shim: %w", err)
	}
	return nil
}

// findTableSchema returns the schema holding the named table (preferring public
// when it exists in several), or "" if it does not exist.
func findTableSchema(ctx context.Context, p *pgxpool.Pool, table string) (string, error) {
	var schema string
	err := p.QueryRow(ctx,
		`SELECT table_schema FROM information_schema.tables
		 WHERE table_name = $1
		 ORDER BY (table_schema = 'public') DESC, table_schema
		 LIMIT 1`, table).Scan(&schema)
	if err == pgx.ErrNoRows {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return schema, nil
}

// backfillPonderHooks migrates the per-address webhook registrations from the
// legacy Ponder DB's custom ponder_hooks table (created by the app's ponder
// src/db.ts, outside the Ponder schema) into the new Celo Ponder DB, so the new
// instance fires the same hooks. The table has no Ponder reorg/live-query
// triggers, so a plain copy is safe; ids are preserved and the id sequence is
// reset so future registrations don't collide. Idempotent.
func backfillPonderHooks(ctx context.Context, src, dst *pgxpool.Pool, run *StepRun) (int64, error) {
	srcSchema, err := findTableSchema(ctx, src, "ponder_hooks")
	if err != nil {
		return 0, err
	}
	if srcSchema == "" {
		run.log("no ponder_hooks table in the source Ponder DB; no webhook registrations to migrate")
		return 0, nil
	}

	dstSchema, err := findTableSchema(ctx, dst, "ponder_hooks")
	if err != nil {
		return 0, err
	}
	if dstSchema == "" {
		// The new Ponder instance normally creates it on boot; create defensively.
		dstSchema = "public"
		if _, err := dst.Exec(ctx, `CREATE TABLE IF NOT EXISTS public.ponder_hooks(id SERIAL PRIMARY KEY NOT NULL, address TEXT NOT NULL, url TEXT NOT NULL)`); err != nil {
			return 0, err
		}
		if _, err := dst.Exec(ctx, `CREATE INDEX IF NOT EXISTS hook_address ON public.ponder_hooks(address)`); err != nil {
			return 0, err
		}
	}

	rows, err := src.Query(ctx, fmt.Sprintf(`SELECT id, address, url FROM %s.%s`, qident(srcSchema), qident("ponder_hooks")))
	if err != nil {
		return 0, err
	}
	defer rows.Close()
	ids := []int64{}
	addrs := []string{}
	urls := []string{}
	for rows.Next() {
		var id int64
		var addr, url string
		if err := rows.Scan(&id, &addr, &url); err != nil {
			return 0, err
		}
		ids = append(ids, id)
		addrs = append(addrs, addr)
		urls = append(urls, url)
	}
	if err := rows.Err(); err != nil {
		return 0, err
	}
	if len(ids) == 0 {
		run.log("source ponder_hooks is empty; nothing to migrate")
		return 0, nil
	}

	dstTable := qident(dstSchema) + "." + qident("ponder_hooks")
	if _, err := dst.Exec(ctx, fmt.Sprintf(`
		INSERT INTO %s (id, address, url)
		SELECT id::int, addr, url FROM unnest($1::bigint[], $2::text[], $3::text[]) AS t(id, addr, url)
		ON CONFLICT (id) DO NOTHING`, dstTable), ids, addrs, urls); err != nil {
		return 0, fmt.Errorf("insert ponder_hooks: %w", err)
	}
	if _, err := dst.Exec(ctx,
		fmt.Sprintf(`SELECT setval(pg_get_serial_sequence($1, 'id'), GREATEST((SELECT COALESCE(MAX(id), 0) FROM %s), 1), true)`, dstTable),
		dstSchema+".ponder_hooks"); err != nil {
		run.log("note: could not reset ponder_hooks id sequence: %s", err)
	}

	var count int64
	if err := dst.QueryRow(ctx, fmt.Sprintf(`SELECT COUNT(*) FROM %s`, dstTable)).Scan(&count); err != nil {
		return 0, err
	}
	return count, nil
}

func tableExistsInSchema(ctx context.Context, p *pgxpool.Pool, schema, table string) (bool, error) {
	var n int
	if err := p.QueryRow(ctx,
		`SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = $1 AND table_name = $2`,
		schema, table).Scan(&n); err != nil {
		return false, err
	}
	return n > 0, nil
}

// qident double-quotes a SQL identifier (validated identifiers only).
func qident(name string) string {
	return `"` + strings.ReplaceAll(name, `"`, `""`) + `"`
}
