#!/usr/bin/env bash
set -euo pipefail

# Copies normalized Berachain Ponder history into the dedicated Celo Ponder
# database, after the Celo Ponder instance has booted and created its tables.
#
# Per the 2026-06-12 decision, the Celo Ponder instance runs against its own
# fresh database (Ponder refuses to start against a schema owned by a
# different build id), and this script backfills the legacy Berachain rows
# (transfer_event, transfer_account, allowance, approval_event) into it so the
# combined DB serves as the cross-chain continuity ledger.
#
# Safety:
#   - Refuses to run unless the source DB carries the 'ponder_18_to_6'
#     normalization marker (never copies raw 18-decimal rows).
#   - Refuses to run unless the source DB carries the external balance wipe
#     marker (never copies non-app external balances into the ledger).
#   - Inserts are ON CONFLICT DO NOTHING, so reruns are idempotent.
#   - Ponder's realtime reorg triggers log every insert into _reorg__* tables,
#     and crash recovery / reorg handling replays that log in reverse — which
#     would delete backfilled rows. Each table copy therefore deletes the
#     reorg-log entries for the Berachain chain id inside the same
#     transaction, so the backfilled rows leave no trace in the operation log.
#   - Verifies per-table row counts and value totals after copying and dies
#     on any mismatch.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_ENV="${ROOT_ENV:-$ROOT_DIR/.env}"
ARTIFACT_ROOT="${MIGRATION_ARTIFACT_ROOT:-$ROOT_DIR/migration-artifacts}"
RUN_ID="${MIGRATION_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
CLI_RUN_ID=""

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Backfills normalized Berachain Ponder history into the dedicated Celo Ponder
database. Run only after the Celo Ponder instance has booted and created its
tables, and after run-migration.sh has normalized and wiped the source DB.

Options:
  --root-env PATH       Env file to load. Default: .env.
  --id ID               Artifact subdirectory name. Default: UTC timestamp.
  -h, --help            Show this help.

Required env:
  MIGRATION_DB_CONNECTION_STRING, MIGRATION_DB_PONDER_SUFFIX,
  MIGRATION_DB_CELO_PONDER_SUFFIX

Optional env:
  BERA_CHAIN_ID (default 80094)
  CELO_PONDER_SCHEMA (default public; schema the Celo Ponder app writes to)
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-env)
      ROOT_ENV="${2:-}"
      shift 2
      ;;
    --id|--run-id)
      CLI_RUN_ID="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf "error: unknown argument: %s\n" "$1" >&2
      exit 1
      ;;
  esac
done

if [[ -f "$ROOT_ENV" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ROOT_ENV"
  set +a
fi

ARTIFACT_ROOT="${MIGRATION_ARTIFACT_ROOT:-$ARTIFACT_ROOT}"
RUN_ID="${MIGRATION_RUN_ID:-$RUN_ID}"
if [[ -n "$CLI_RUN_ID" ]]; then
  RUN_ID="$CLI_RUN_ID"
fi
BERA_CHAIN_ID="${BERA_CHAIN_ID:-80094}"
CELO_PONDER_SCHEMA="${CELO_PONDER_SCHEMA:-public}"
ARTIFACT_DIR="$ARTIFACT_ROOT/bera-backfill-$RUN_ID"
AUDIT_JSON="$ARTIFACT_DIR/bera-backfill-audit.json"

die() {
  printf "error: %s\n" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

require_env() {
  local key="$1"
  local value="${!key-}"
  [[ -n "$value" ]] || die "$key is required in $ROOT_ENV or the environment"
}

db_url_for() {
  local connection_string="$1"
  local db_name="$2"
  node - "$connection_string" "$db_name" <<'NODE'
const [rawConnectionString, dbName] = process.argv.slice(2);
const url = new URL(rawConnectionString);
if (url.protocol !== "postgres:" && url.protocol !== "postgresql:") {
  throw new Error(`unsupported postgres URL protocol: ${url.protocol}`);
}
if (!dbName || dbName.includes("/")) {
  throw new Error(`invalid database name: ${dbName}`);
}
url.pathname = `/${dbName}`;
process.stdout.write(url.toString());
NODE
}

psql_scalar() {
  local db_url="$1"
  local sql="$2"
  psql "$db_url" -X -qAt -v ON_ERROR_STOP=1 -c "$sql" | tr -d '[:space:]'
}

for command in node psql; do
  require_cmd "$command"
done

for key in \
  MIGRATION_DB_CONNECTION_STRING \
  MIGRATION_DB_PONDER_SUFFIX \
  MIGRATION_DB_CELO_PONDER_SUFFIX; do
  require_env "$key"
done

[[ "$BERA_CHAIN_ID" =~ ^[0-9]+$ ]] || die "BERA_CHAIN_ID must be an integer"
[[ "$CELO_PONDER_SCHEMA" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || die "invalid CELO_PONDER_SCHEMA: $CELO_PONDER_SCHEMA"

SRC_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_PONDER_SUFFIX")"
DST_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_CELO_PONDER_SUFFIX")"

mkdir -p "$ARTIFACT_DIR"

printf "Source DB:        %s\n" "$MIGRATION_DB_PONDER_SUFFIX"
printf "Target DB:        %s (schema %s)\n" "$MIGRATION_DB_CELO_PONDER_SUFFIX" "$CELO_PONDER_SCHEMA"
printf "Berachain chain:  %s\n" "$BERA_CHAIN_ID"
printf "Artifacts:        %s\n\n" "$ARTIFACT_DIR"

# --- Source preconditions -----------------------------------------------

marker="$(psql_scalar "$SRC_DB_URL" "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'migration_decimal_normalization';")"
[[ "$marker" != "0" ]] || die "source DB has no normalization marker table; run run-migration.sh first"
marker="$(psql_scalar "$SRC_DB_URL" "SELECT COUNT(*) FROM migration_decimal_normalization WHERE id = 'ponder_18_to_6';")"
[[ "$marker" != "0" ]] || die "source DB is not normalized to 6 decimals; refusing to copy raw 18-decimal rows"
marker="$(psql_scalar "$SRC_DB_URL" "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'migration_external_balance_wipe';")"
[[ "$marker" != "0" ]] || die "source DB has no external balance wipe marker table; run run-migration.sh first"
marker="$(psql_scalar "$SRC_DB_URL" "SELECT COUNT(*) FROM migration_external_balance_wipe WHERE id = 'external_transfer_account_rows';")"
[[ "$marker" != "0" ]] || die "source DB external balances were not wiped; refusing to copy non-app balances into the continuity ledger"

# --- Target preconditions -----------------------------------------------

for table in transfer_event transfer_account allowance approval_event; do
  exists="$(psql_scalar "$DST_DB_URL" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$CELO_PONDER_SCHEMA' AND table_name = '$table';")"
  [[ "$exists" != "0" ]] || die "target table $CELO_PONDER_SCHEMA.$table does not exist; boot the Celo Ponder instance first so it creates its tables"
done

# --- Copy ----------------------------------------------------------------

# copy_table NAME "COL, COL, ..." "CONFLICT_COL, ..." VALUE_COL
copy_table() {
  local table="$1"
  local cols="$2"
  local conflict_cols="$3"
  local value_col="$4"
  local csv="$ARTIFACT_DIR/$table.csv"
  local src_count dst_count src_sum dst_sum reorg_exists

  printf "Copying %-18s" "$table"

  psql "$SRC_DB_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "\\copy (SELECT $cols FROM $table WHERE chain_id = $BERA_CHAIN_ID) TO '$csv' WITH (FORMAT csv)" >/dev/null

  reorg_exists="$(psql_scalar "$DST_DB_URL" "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema = '$CELO_PONDER_SCHEMA' AND table_name = '_reorg__$table';")"

  {
    printf '%s\n' "BEGIN;"
    printf '%s\n' "CREATE TEMP TABLE staging_$table (LIKE \"$CELO_PONDER_SCHEMA\".\"$table\" INCLUDING DEFAULTS);"
    printf '%s\n' "\\copy staging_$table($cols) FROM '$csv' WITH (FORMAT csv)"
    printf '%s\n' "INSERT INTO \"$CELO_PONDER_SCHEMA\".\"$table\" ($cols) SELECT $cols FROM staging_$table ON CONFLICT ($conflict_cols) DO NOTHING;"
    if [[ "$reorg_exists" != "0" ]]; then
      # Remove the reorg-log entries Ponder's triggers just recorded for our
      # inserts; otherwise crash recovery or a chain reorg would revert the
      # backfilled rows. Only Berachain-tagged entries are touched, so live
      # Celo indexing is unaffected.
      printf '%s\n' "DELETE FROM \"$CELO_PONDER_SCHEMA\".\"_reorg__$table\" WHERE chain_id = $BERA_CHAIN_ID;"
    fi
    printf '%s\n' "COMMIT;"
  } | psql "$DST_DB_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null

  src_count="$(psql_scalar "$SRC_DB_URL" "SELECT COUNT(*) FROM $table WHERE chain_id = $BERA_CHAIN_ID;")"
  dst_count="$(psql_scalar "$DST_DB_URL" "SELECT COUNT(*) FROM \"$CELO_PONDER_SCHEMA\".\"$table\" WHERE chain_id = $BERA_CHAIN_ID;")"
  src_sum="$(psql_scalar "$SRC_DB_URL" "SELECT COALESCE(SUM($value_col), 0)::text FROM $table WHERE chain_id = $BERA_CHAIN_ID;")"
  dst_sum="$(psql_scalar "$DST_DB_URL" "SELECT COALESCE(SUM($value_col), 0)::text FROM \"$CELO_PONDER_SCHEMA\".\"$table\" WHERE chain_id = $BERA_CHAIN_ID;")"

  [[ "$src_count" == "$dst_count" ]] || die "$table row count mismatch after copy: source $src_count, target $dst_count"
  [[ "$src_sum" == "$dst_sum" ]] || die "$table $value_col total mismatch after copy: source $src_sum, target $dst_sum"

  printf " rows=%s %s_total=%s OK\n" "$dst_count" "$value_col" "$dst_sum"
  printf '%s\n' "{\"table\": \"$table\", \"rows\": $dst_count, \"${value_col}_total\": \"$dst_sum\"}" >> "$ARTIFACT_DIR/.audit-lines"
}

rm -f "$ARTIFACT_DIR/.audit-lines"
copy_table "transfer_event" 'id, chain_id, hash, amount, timestamp, "from", "to"' "chain_id, id" "amount"
copy_table "transfer_account" "chain_id, address, balance, is_owner" "chain_id, address" "balance"
copy_table "allowance" "chain_id, owner, spender, amount" "chain_id, owner, spender" "amount"
copy_table "approval_event" "id, chain_id, amount, timestamp, owner, spender" "chain_id, id" "amount"

node - "$ARTIFACT_DIR/.audit-lines" "$AUDIT_JSON" "$BERA_CHAIN_ID" "$MIGRATION_DB_PONDER_SUFFIX" "$MIGRATION_DB_CELO_PONDER_SUFFIX" "$CELO_PONDER_SCHEMA" <<'NODE'
const fs = require("fs");
const [linesPath, outputPath, chainId, sourceDb, targetDb, targetSchema] = process.argv.slice(2);
const tables = fs.readFileSync(linesPath, "utf8")
  .split("\n")
  .filter((line) => line.trim().length > 0)
  .map((line) => JSON.parse(line));
fs.writeFileSync(outputPath, `${JSON.stringify({
  generated_at: new Date().toISOString(),
  chain_id: Number(chainId),
  source_db: sourceDb,
  target_db: targetDb,
  target_schema: targetSchema,
  note: "Berachain Ponder history backfilled into the Celo Ponder DB. Row counts and value totals verified equal between source and target for this chain id.",
  tables,
}, null, 2)}\n`);
NODE
rm -f "$ARTIFACT_DIR/.audit-lines"

printf "\nBackfill complete. Audit: %s\n" "$AUDIT_JSON"
