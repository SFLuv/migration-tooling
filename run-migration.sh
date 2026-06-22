#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACTS_DIR="$ROOT_DIR/repos/contracts"
ROOT_ENV="${ROOT_ENV:-$ROOT_DIR/.env}"
ARTIFACT_ROOT="${MIGRATION_ARTIFACT_ROOT:-$ROOT_DIR/migration-artifacts}"
RUN_ID="${MIGRATION_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
DECIMAL_SCALE="${MIGRATION_DECIMAL_SCALE:-1000000000000}"
SMART_WALLET_BATCH_SIZE="${SMART_WALLET_BATCH_SIZE:-50}"
MIGRATION_BROADCAST="${MIGRATION_BROADCAST:-true}"
CLI_ARTIFACT_ROOT=""
CLI_RUN_ID=""
CLI_DRY_RUN="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Runs the Berachain-to-Celo migration preparation and app-wallet distribution.
Configuration is loaded from the root .env by default.

Options:
  --root-env PATH       Env file to load. Default: .env.
  --artifact-root PATH  Directory for migration artifacts. Default: migration-artifacts.
  --id ID               Call trace / artifact id. Rerunning with the same id
                        resumes that run: steps recorded as completed in its
                        call trace are skipped and its artifacts are kept.
  --run-id ID           Alias for --id. Default: UTC timestamp.
  --dry-run             Run forge scripts without --broadcast and skip all
                        database mutations. Read-only audits and artifacts
                        are still produced. Dry runs never mark call-trace
                        steps as completed.
  -h, --help            Show this help.

Required env:
  OLD_CHAIN_RPC, NEW_CHAIN_RPC, OLD_TOKEN, NEW_TOKEN,
  MIGRATION_DB_CONNECTION_STRING, MIGRATION_DB_PONDER_SUFFIX,
  MIGRATION_DB_APP_SUFFIX, MIGRATION_DB_BOT_SUFFIX,
  CONTRACT_DEPLOYER_PRIVATE_KEY,
  WALLET_DEPLOYER_PRIVATE_KEY, DISTRIBUTOR_PRIVATE_KEY,
  ACCOUNT_FACTORY_ADDRESS, MIGRATION_EXTRA_FUNDED_ADDRESSES

MIGRATION_DB_BOT_SUFFIX is the bot database that holds recovery_balances; the
non-app external holder balances are seeded there for post-migration recovery
claims.

MIGRATION_EXTRA_FUNDED_ADDRESSES is a comma-separated list of addresses
outside the wallets table (service accounts such as the backend faucet)
whose Berachain balances are retained and repopulated on Celo. Set it to
"none" to explicitly fund only wallets-table addresses. These addresses
are funded but not deployed: they must be EOAs (or contracts that exist
on Celo by other means).
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root-env)
      ROOT_ENV="${2:-}"
      shift 2
      ;;
    --artifact-root)
      CLI_ARTIFACT_ROOT="${2:-}"
      shift 2
      ;;
    --id|--run-id)
      CLI_RUN_ID="${2:-}"
      shift 2
      ;;
    --dry-run)
      CLI_DRY_RUN="true"
      shift
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
DECIMAL_SCALE="${MIGRATION_DECIMAL_SCALE:-$DECIMAL_SCALE}"
SMART_WALLET_BATCH_SIZE="${SMART_WALLET_BATCH_SIZE:-$SMART_WALLET_BATCH_SIZE}"
MIGRATION_BROADCAST="${MIGRATION_BROADCAST:-$MIGRATION_BROADCAST}"
if [[ -n "$CLI_ARTIFACT_ROOT" ]]; then
  ARTIFACT_ROOT="$CLI_ARTIFACT_ROOT"
fi
if [[ -n "$CLI_RUN_ID" ]]; then
  RUN_ID="$CLI_RUN_ID"
fi
if [[ "$CLI_DRY_RUN" == "true" ]]; then
  MIGRATION_BROADCAST="false"
fi

ARTIFACT_DIR="$ARTIFACT_ROOT/$RUN_ID"
TRACE_FILE="$ARTIFACT_DIR/call-trace.log"
RUN_START_EPOCH_FILE="$ARTIFACT_DIR/run-start-epoch"
APP_WALLETS_JSON="$ARTIFACT_DIR/app-wallets.json"
WALLET_INTEGRITY_JSON="$ARTIFACT_DIR/wallet-integrity.json"
EXTRA_FUNDED_ADDRESS_FILE="$ARTIFACT_DIR/extra-funded-addresses.txt"
APP_WALLET_ADDRESS_FILE="$ARTIFACT_DIR/app-wallet-addresses.txt"
SMART_WALLET_INPUT_JSON="$ARTIFACT_DIR/smart-wallet-deploy-input.json"
SMART_WALLET_BATCH_DIR="$ARTIFACT_DIR/smart-wallet-batches"
DEPLOYED_SMART_WALLETS_JSON="$ARTIFACT_DIR/deployed-smart-wallets.json"
DEPLOYED_SMART_WALLET_BALANCES_JSON="$ARTIFACT_DIR/deployed-smart-wallet-balances.json"
APP_DISTRIBUTION_JSON="$ARTIFACT_DIR/app-wallet-distribution.json"
EXTERNAL_HOLDERS_JSON="$ARTIFACT_DIR/external-holder-balances.json"
EXTERNAL_WIPE_AUDIT_JSON="$ARTIFACT_DIR/external-holder-balance-wipe-audit.json"
MIGRATION_RESULT_JSON="$ARTIFACT_DIR/migration-result.json"

color_enabled() {
  [[ -t 1 && "${NO_COLOR:-}" == "" ]]
}

if color_enabled; then
  BOLD=$'\033[1m'
  DIM=$'\033[2m'
  GREEN=$'\033[32m'
  RED=$'\033[31m'
  YELLOW=$'\033[33m'
  RESET=$'\033[0m'
else
  BOLD=""
  DIM=""
  GREEN=""
  RED=""
  YELLOW=""
  RESET=""
fi

print_rule() {
  printf "\n%s\n" "${BOLD}============================================================${RESET}"
}

print_phase() {
  print_rule
  printf "%s%s%s\n" "$BOLD" "$1" "$RESET"
  printf "%s\n" "------------------------------------------------------------"
}

progress_step() {
  printf "  %-58s" "$1"
}

progress_ok() {
  printf " %sOK%s\n" "$GREEN" "$RESET"
}

progress_skip() {
  printf " %sSKIP%s\n" "$YELLOW" "$RESET"
}

progress_fail() {
  printf " %sFAIL%s\n" "$RED" "$RESET"
}

progress_info() {
  printf "  %s%s%s\n" "$DIM" "$1" "$RESET"
}

die() {
  printf "%serror:%s %s\n" "$RED" "$RESET" "$*" >&2
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

validate_positive_int() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$label must be a positive integer"
}

shell_quote() {
  printf "%q" "$1"
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

json_array_length() {
  local file="$1"
  local key="$2"
  node - "$file" "$key" <<'NODE'
const fs = require("fs");
const [file, key] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(file, "utf8"));
const value = data[key];
process.stdout.write(String(Array.isArray(value) ? value.length : 0));
NODE
}

private_key_address() {
  local private_key="$1"
  cast wallet address --private-key "$private_key"
}

verify_rpc_get_block() {
  local label="$1"
  local rpc_url="$2"
  local block_number

  progress_step "$label"
  if ! block_number="$(cast block latest --field number --rpc-url "$rpc_url" 2>&1)"; then
    progress_fail
    printf "%s\n" "$block_number" >&2
    die "$label failed; RPC did not return latest block"
  fi
  printf " %s\n" "$block_number"
}

psql_json() {
  local db_url="$1"
  local sql="$2"
  local output="$3"
  psql "$db_url" -X -qAt -v ON_ERROR_STOP=1 -c "$sql" > "$output"
}

psql_scalar() {
  local db_url="$1"
  local sql="$2"
  psql "$db_url" -X -qAt -v ON_ERROR_STOP=1 -c "$sql" | tr -d '[:space:]'
}

psql_exec() {
  local db_url="$1"
  local sql="$2"
  psql "$db_url" -X -q -v ON_ERROR_STOP=1 -c "$sql" >/dev/null
}

cast_scalar() {
  local rpc="$1"
  shift
  cast call --rpc-url "$rpc" "$@" | awk 'NR==1{print $1}'
}

bi_ge() {
  node -e 'process.exit(BigInt(process.argv[1]) >= BigInt(process.argv[2]) ? 0 : 1)' "$1" "$2"
}

bi_max() {
  node -e 'const a = BigInt(process.argv[1]); const b = BigInt(process.argv[2]); process.stdout.write((a > b ? a : b).toString())' "$1" "$2"
}

bi_sub_floor_zero() {
  node -e 'const a = BigInt(process.argv[1]); const b = BigInt(process.argv[2]); process.stdout.write((a > b ? a - b : 0n).toString())' "$1" "$2"
}

trace_step_done() {
  [[ -f "$TRACE_FILE" ]] && grep -q "^ok ${1} " "$TRACE_FILE"
}

trace_mark_done() {
  # Dry runs perform no onchain or DB mutations, so they must not mark steps
  # as completed for a later real run with the same --id.
  [[ "$MIGRATION_BROADCAST" == "true" ]] || return 0
  printf "ok %s %s\n" "$1" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$TRACE_FILE"
}

# run_step STEP_ID LABEL FN [ARGS...]
# Runs FN unless STEP_ID is already recorded as completed in the call trace
# for this run id. Completed steps are skipped so a rerun with the same --id
# resumes exactly where the previous run failed.
run_step() {
  local step="$1"
  local label="$2"
  shift 2
  progress_step "$label"
  if trace_step_done "$step"; then
    progress_skip
    progress_info "Step '$step' already completed in call trace; skipping."
    return 0
  fi
  "$@"
  progress_ok
  trace_mark_done "$step"
}

forge_broadcast_args=()
if [[ "$MIGRATION_BROADCAST" == "true" ]]; then
  forge_broadcast_args=(--broadcast)
elif [[ "$MIGRATION_BROADCAST" != "false" ]]; then
  die "MIGRATION_BROADCAST must be true or false"
fi

for command in node psql pg_dump forge cast; do
  require_cmd "$command"
done

for key in \
  OLD_CHAIN_RPC \
  NEW_CHAIN_RPC \
  OLD_TOKEN \
  NEW_TOKEN \
  MIGRATION_DB_CONNECTION_STRING \
  MIGRATION_DB_PONDER_SUFFIX \
  MIGRATION_DB_APP_SUFFIX \
  MIGRATION_DB_BOT_SUFFIX \
  CONTRACT_DEPLOYER_PRIVATE_KEY \
  WALLET_DEPLOYER_PRIVATE_KEY \
  DISTRIBUTOR_PRIVATE_KEY \
  ACCOUNT_FACTORY_ADDRESS \
  MIGRATION_EXTRA_FUNDED_ADDRESSES; do
  require_env "$key"
done

validate_positive_int "DECIMAL_SCALE" "$DECIMAL_SCALE"
validate_positive_int "SMART_WALLET_BATCH_SIZE" "$SMART_WALLET_BATCH_SIZE"
[[ -d "$CONTRACTS_DIR" ]] || die "missing contracts repo: $CONTRACTS_DIR"
[[ -f "$CONTRACTS_DIR/lib/forge-std/src/Script.sol" ]] || die "contracts dependencies missing. Run: git -C $(shell_quote "$CONTRACTS_DIR") submodule update --init --recursive"

APP_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_APP_SUFFIX")"
PONDER_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_PONDER_SUFFIX")"
BOT_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_BOT_SUFFIX")"
DISTRIBUTOR_ADDRESS="$(private_key_address "$DISTRIBUTOR_PRIVATE_KEY")"
CONTRACT_DEPLOYER_ADDRESS="$(private_key_address "$CONTRACT_DEPLOYER_PRIVATE_KEY")"
WALLET_DEPLOYER_ADDRESS="$(private_key_address "$WALLET_DEPLOYER_PRIVATE_KEY")"

mkdir -p "$ARTIFACT_DIR" "$SMART_WALLET_BATCH_DIR"

# The first invocation for a run id pins the epoch used to filter forge
# broadcast receipts, so a resumed run still recognizes receipts written by
# the original invocation when resolving the completion block.
if [[ -f "$RUN_START_EPOCH_FILE" ]]; then
  RUN_START_EPOCH="$(tr -d '[:space:]' < "$RUN_START_EPOCH_FILE")"
  [[ "$RUN_START_EPOCH" =~ ^[0-9]+$ ]] || die "invalid run start epoch in $RUN_START_EPOCH_FILE"
else
  RUN_START_EPOCH="$(date +%s)"
  printf "%s\n" "$RUN_START_EPOCH" > "$RUN_START_EPOCH_FILE"
fi

app_wallet_address_sql() {
  cat <<'SQL'
WITH wallet_rows AS (
  SELECT
    LOWER(TRIM(eoa_address)) AS eoa_address,
    NULLIF(LOWER(TRIM(COALESCE(smart_address, ''))), '') AS smart_address
  FROM wallets
),
addresses AS (
  SELECT eoa_address AS address
  FROM wallet_rows
  WHERE eoa_address ~ '^0x[0-9a-f]{40}$'
  UNION
  SELECT smart_address AS address
  FROM wallet_rows
  WHERE smart_address ~ '^0x[0-9a-f]{40}$'
)
SELECT address FROM addresses ORDER BY address;
SQL
}

# Prints the configured extra funded addresses (service accounts such as the
# backend faucet) normalized to lowercase, one per line. These addresses are
# treated exactly like wallets-table addresses for balance retention and Celo
# distribution, but are never deployed. "none" means explicitly empty.
extra_funded_addresses() {
  local raw normalized addr
  raw="$MIGRATION_EXTRA_FUNDED_ADDRESSES"
  normalized="$(printf "%s" "$raw" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
  if [[ "$normalized" == "none" ]]; then
    return 0
  fi
  for addr in ${normalized//,/ }; do
    [[ "$addr" =~ ^0x[0-9a-f]{40}$ ]] || die "invalid address in MIGRATION_EXTRA_FUNDED_ADDRESSES: $addr"
    printf "%s\n" "$addr"
  done | sort -u
}

# Canonical funded-address set: wallets-table addresses plus the configured
# extra funded addresses. Used for balance retention, the external wipe
# boundary, and the distribution artifact.
write_funded_address_file() {
  local output="$1"
  {
    psql "$APP_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "$(app_wallet_address_sql)"
    extra_funded_addresses
  } | sort -u > "$output"
}

# Returns 0 when the given DB already carries the given normalization marker.
# Safe to call before the marker table exists.
normalization_marker_present() {
  local db_url="$1"
  local marker_id="$2"
  local marker_table_exists normalized

  marker_table_exists="$(psql_scalar "$db_url" "SELECT COUNT(*) FROM pg_tables WHERE tablename = 'migration_decimal_normalization';")"
  if [[ "$marker_table_exists" == "0" ]]; then
    return 1
  fi
  normalized="$(psql_scalar "$db_url" "SELECT COUNT(*) FROM migration_decimal_normalization WHERE id = '$marker_id';")"
  [[ "$normalized" != "0" ]]
}

# Ponder's realtime reorg triggers log every row INSERT/UPDATE/DELETE into
# _reorg__<table> tables, and Ponder crash recovery replays that entire log in
# reverse on the next same-build start. Our manual normalization and wipe
# writes must not leave entries there: a later (accidental) restart of the
# old Berachain Ponder would otherwise revert the normalized data back to raw
# 18-decimal values. Emits TRUNCATE statements for each reorg table that
# exists, for inclusion in the mutation transaction.
ponder_reorg_cleanup_sql() {
  local table exists sql=""
  for table in transfer_event transfer_account allowance approval_event; do
    exists="$(psql_scalar "$PONDER_DB_URL" "SELECT COUNT(*) FROM pg_tables WHERE tablename = '_reorg__$table';")"
    if [[ "$exists" != "0" ]]; then
      sql+="TRUNCATE _reorg__$table;"$'\n'
    fi
  done
  printf "%s" "$sql"
}

# SQL expression for a transfer_event amount in 6-decimal units, applying the
# decimal scale on the fly when the Ponder DB has not been normalized yet
# (preflight before normalization, or a dry run that skips normalization).
ponder_amount_expr() {
  if normalization_marker_present "$PONDER_DB_URL" "ponder_18_to_6"; then
    printf "amount"
  else
    printf "FLOOR(amount / %s)" "$DECIMAL_SCALE"
  fi
}

# Compute the total app-wallet distribution amount (positive normalized
# balances) without mutating anything, so funding/allowance can be verified
# before the Berachain lock.
preflight_projected_total() {
  local address_file="$ARTIFACT_DIR/preflight-app-addresses.txt"
  local amount_expr

  write_funded_address_file "$address_file"
  amount_expr="$(ponder_amount_expr)"

  {
    printf "%s\n" "CREATE TEMP TABLE preflight_app_addresses(address TEXT PRIMARY KEY);"
    printf "%s\n" "\\copy preflight_app_addresses(address) FROM '$address_file'"
    cat <<SQL
WITH movements AS (
  SELECT LOWER("from") AS address, -($amount_expr) AS delta FROM transfer_event
  UNION ALL
  SELECT LOWER("to") AS address, ($amount_expr) AS delta FROM transfer_event
),
app_balances AS (
  SELECT m.address, SUM(m.delta) AS balance
  FROM movements m
  JOIN preflight_app_addresses app ON app.address = m.address
  GROUP BY m.address
)
SELECT COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text FROM app_balances;
SQL
  } | psql "$PONDER_DB_URL" -X -qAt -v ON_ERROR_STOP=1 | tr -d '[:space:]'
}

# Every wallets-table row must be fundable on Celo: no silently excluded
# addresses. Dies (with row ids in the artifact) on any row the snapshot,
# deployment, or distribution sets would otherwise drop.
preflight_wallet_integrity() {
  local result critical warnings

  psql_json "$APP_DB_URL" "
WITH wallet_rows AS (
  SELECT
    id,
    is_eoa,
    smart_index,
    LOWER(TRIM(COALESCE(eoa_address, ''))) AS eoa_address,
    LOWER(TRIM(COALESCE(smart_address, ''))) AS smart_address
  FROM wallets
),
invalid_eoa AS (
  SELECT id FROM wallet_rows WHERE eoa_address !~ '^0x[0-9a-f]{40}$'
),
invalid_smart_format AS (
  SELECT id FROM wallet_rows
  WHERE smart_address <> '' AND smart_address !~ '^0x[0-9a-f]{40}$'
),
smart_missing_index AS (
  SELECT id FROM wallet_rows
  WHERE smart_address ~ '^0x[0-9a-f]{40}$' AND smart_index IS NULL
),
conflicting_smart_duplicates AS (
  SELECT eoa_address, smart_index, COUNT(DISTINCT smart_address) AS distinct_addresses
  FROM wallet_rows
  WHERE smart_address ~ '^0x[0-9a-f]{40}$' AND smart_index IS NOT NULL
  GROUP BY eoa_address, smart_index
  HAVING COUNT(DISTINCT smart_address) > 1
),
non_eoa_missing_smart AS (
  SELECT id FROM wallet_rows WHERE is_eoa = FALSE AND smart_address = ''
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
  'note', 'Critical rows block the migration: they would be silently dropped from the snapshot, smart wallet deployment, or distribution sets. Fix or remove these wallet rows, then rerun.',
  'invalid_eoa_address_rows', (SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) FROM invalid_eoa),
  'invalid_smart_address_rows', (SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) FROM invalid_smart_format),
  'smart_address_missing_index_rows', (SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) FROM smart_missing_index),
  'conflicting_smart_duplicates', (SELECT COALESCE(jsonb_agg(jsonb_build_object(
    'eoa_address', eoa_address,
    'smart_index', smart_index,
    'distinct_addresses', distinct_addresses
  ) ORDER BY eoa_address, smart_index), '[]'::jsonb) FROM conflicting_smart_duplicates),
  'non_eoa_missing_smart_rows', (SELECT COALESCE(jsonb_agg(id ORDER BY id), '[]'::jsonb) FROM non_eoa_missing_smart)
));" "$WALLET_INTEGRITY_JSON"

  result="$(node - "$WALLET_INTEGRITY_JSON" <<'NODE'
const fs = require("fs");
const data = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const critical =
  data.invalid_eoa_address_rows.length +
  data.invalid_smart_address_rows.length +
  data.smart_address_missing_index_rows.length +
  data.conflicting_smart_duplicates.length;
process.stdout.write(`${critical} ${data.non_eoa_missing_smart_rows.length}`);
NODE
)"
  critical="${result%% *}"
  warnings="${result##* }"

  if [[ "$critical" != "0" ]]; then
    progress_fail
    die "wallets table has $critical row(s) that would be silently excluded from funding. See $WALLET_INTEGRITY_JSON"
  fi
  progress_ok
  if [[ "$warnings" != "0" ]]; then
    progress_info "$warnings non-EOA wallet row(s) have no smart_address recorded; nothing fundable for them. See $WALLET_INTEGRITY_JSON"
  fi
}

preflight_assertions() {
  local old_dec new_dec expected_scale underlying underlying_dec
  local minter_role has_role projected_total total_supply remaining
  local backing_balance backing_allowance native_balance
  local extra_funded_count extra_funded_addr

  progress_step "Wallets table integrity"
  preflight_wallet_integrity

  progress_step "Extra funded addresses"
  extra_funded_addresses > "$EXTRA_FUNDED_ADDRESS_FILE"
  extra_funded_count="$(grep -c . "$EXTRA_FUNDED_ADDRESS_FILE" || true)"
  printf " %s\n" "$extra_funded_count"
  if [[ "$extra_funded_count" != "0" ]]; then
    while IFS= read -r extra_funded_addr; do
      progress_info "Will retain and fund: $extra_funded_addr"
    done < "$EXTRA_FUNDED_ADDRESS_FILE"
  else
    progress_info "MIGRATION_EXTRA_FUNDED_ADDRESSES=none; only wallets-table addresses are funded."
  fi

  progress_step "Old token decimals"
  old_dec="$(cast_scalar "$OLD_CHAIN_RPC" "$OLD_TOKEN" "decimals()(uint8)")"
  printf " %s\n" "$old_dec"
  progress_step "New token decimals"
  new_dec="$(cast_scalar "$NEW_CHAIN_RPC" "$NEW_TOKEN" "decimals()(uint8)")"
  printf " %s\n" "$new_dec"

  progress_step "DECIMAL_SCALE matches token decimals"
  expected_scale="$(node -e '
const oldDec = BigInt(process.argv[1]);
const newDec = BigInt(process.argv[2]);
if (oldDec < newDec) {
  console.error("old token decimals < new token decimals is unsupported");
  process.exit(1);
}
process.stdout.write((10n ** (oldDec - newDec)).toString());
' "$old_dec" "$new_dec")" || die "unsupported token decimal combination: old=$old_dec new=$new_dec"
  [[ "$expected_scale" == "$DECIMAL_SCALE" ]] || die "DECIMAL_SCALE is $DECIMAL_SCALE but token decimals ($old_dec -> $new_dec) require $expected_scale"
  progress_ok

  progress_step "New token underlying"
  underlying="$(cast_scalar "$NEW_CHAIN_RPC" "$NEW_TOKEN" "underlying()(address)")"
  printf " %s\n" "$underlying"
  progress_step "Underlying decimals match new token"
  underlying_dec="$(cast_scalar "$NEW_CHAIN_RPC" "$underlying" "decimals()(uint8)")"
  [[ "$underlying_dec" == "$new_dec" ]] || die "underlying $underlying has $underlying_dec decimals but new token reports $new_dec"
  progress_ok

  progress_step "Distributor has MINTER_ROLE on new token"
  minter_role="$(cast keccak "MINTER")"
  has_role="$(cast_scalar "$NEW_CHAIN_RPC" "$NEW_TOKEN" "hasRole(bytes32,address)(bool)" "$minter_role" "$DISTRIBUTOR_ADDRESS")"
  [[ "$has_role" == "true" ]] || die "distributor $DISTRIBUTOR_ADDRESS is missing MINTER_ROLE on $NEW_TOKEN"
  progress_ok

  progress_step "Deployer has DEFAULT_ADMIN_ROLE on old token"
  has_role="$(cast_scalar "$OLD_CHAIN_RPC" "$OLD_TOKEN" "hasRole(bytes32,address)(bool)" "0x0000000000000000000000000000000000000000000000000000000000000000" "$CONTRACT_DEPLOYER_ADDRESS")"
  [[ "$has_role" == "true" ]] || die "contract deployer $CONTRACT_DEPLOYER_ADDRESS is missing DEFAULT_ADMIN_ROLE on $OLD_TOKEN"
  progress_ok

  progress_step "Projected app distribution total"
  projected_total="$(preflight_projected_total)"
  printf " %s\n" "$projected_total"
  progress_step "New token total supply (already distributed)"
  total_supply="$(cast_scalar "$NEW_CHAIN_RPC" "$NEW_TOKEN" "totalSupply()(uint256)")"
  printf " %s\n" "$total_supply"
  remaining="$(bi_sub_floor_zero "$projected_total" "$total_supply")"
  progress_info "Remaining distribution to fund: $remaining"

  progress_step "Distributor backing balance covers remaining"
  backing_balance="$(cast_scalar "$NEW_CHAIN_RPC" "$underlying" "balanceOf(address)(uint256)" "$DISTRIBUTOR_ADDRESS")"
  bi_ge "$backing_balance" "$remaining" || die "distributor backing balance $backing_balance < remaining distribution $remaining"
  progress_ok
  progress_step "Distributor backing allowance covers remaining"
  backing_allowance="$(cast_scalar "$NEW_CHAIN_RPC" "$underlying" "allowance(address,address)(uint256)" "$DISTRIBUTOR_ADDRESS" "$NEW_TOKEN")"
  bi_ge "$backing_allowance" "$remaining" || die "distributor allowance to $NEW_TOKEN is $backing_allowance < remaining distribution $remaining"
  progress_ok

  progress_step "Contract deployer gas on old chain"
  native_balance="$(cast balance "$CONTRACT_DEPLOYER_ADDRESS" --rpc-url "$OLD_CHAIN_RPC")"
  [[ "$native_balance" != "0" ]] || die "contract deployer $CONTRACT_DEPLOYER_ADDRESS has no gas on the old chain"
  printf " %s wei\n" "$native_balance"
  progress_step "Wallet deployer gas on new chain"
  native_balance="$(cast balance "$WALLET_DEPLOYER_ADDRESS" --rpc-url "$NEW_CHAIN_RPC")"
  [[ "$native_balance" != "0" ]] || die "wallet deployer $WALLET_DEPLOYER_ADDRESS has no gas on the new chain"
  printf " %s wei\n" "$native_balance"
  progress_step "Distributor gas on new chain"
  native_balance="$(cast balance "$DISTRIBUTOR_ADDRESS" --rpc-url "$NEW_CHAIN_RPC")"
  [[ "$native_balance" != "0" ]] || die "distributor $DISTRIBUTOR_ADDRESS has no gas on the new chain"
  printf " %s wei\n" "$native_balance"
}

write_app_wallet_artifacts() {
  local app_wallet_sql smart_input_sql

  app_wallet_sql="
WITH wallet_rows AS (
  SELECT
    id,
    owner,
    name,
    active,
    is_eoa,
    is_hidden,
    is_redeemer,
    is_minter,
    LOWER(TRIM(eoa_address)) AS eoa_address,
    NULLIF(LOWER(TRIM(COALESCE(smart_address, ''))), '') AS smart_address,
    smart_index
  FROM wallets
),
addresses AS (
  SELECT eoa_address AS address
  FROM wallet_rows
  WHERE eoa_address ~ '^0x[0-9a-f]{40}$'
  UNION
  SELECT smart_address AS address
  FROM wallet_rows
  WHERE smart_address ~ '^0x[0-9a-f]{40}$'
),
smart_wallets AS (
  SELECT DISTINCT ON (eoa_address, smart_index)
    eoa_address,
    smart_index,
    smart_address
  FROM wallet_rows
  WHERE smart_index IS NOT NULL
    AND eoa_address ~ '^0x[0-9a-f]{40}$'
    AND smart_address ~ '^0x[0-9a-f]{40}$'
  ORDER BY eoa_address, smart_index, id
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
  'wallet_count', (SELECT COUNT(*) FROM wallet_rows),
  'address_count', (SELECT COUNT(*) FROM addresses),
  'smart_wallet_count', (SELECT COUNT(*) FROM smart_wallets),
  'wallets', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'id', id,
      'owner', owner,
      'name', name,
      'active', active,
      'is_eoa', is_eoa,
      'is_hidden', is_hidden,
      'is_redeemer', is_redeemer,
      'is_minter', is_minter,
      'eoa_address', eoa_address,
      'smart_address', smart_address,
      'smart_index', smart_index
    ) ORDER BY id)
    FROM wallet_rows
  ), '[]'::jsonb),
  'addresses', COALESCE((
    SELECT jsonb_agg(address ORDER BY address)
    FROM addresses
  ), '[]'::jsonb),
  'smart_wallets', COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
      'owner', eoa_address,
      'salt', smart_index,
      'expected_address', smart_address
    ) ORDER BY eoa_address, smart_index)
    FROM smart_wallets
  ), '[]'::jsonb)
));"

  smart_input_sql="
WITH smart_wallets AS (
  SELECT DISTINCT ON (LOWER(TRIM(eoa_address)), smart_index)
    LOWER(TRIM(eoa_address)) AS owner,
    smart_index AS salt,
    LOWER(TRIM(smart_address)) AS expected_address
  FROM wallets
  WHERE smart_index IS NOT NULL
    AND LOWER(TRIM(eoa_address)) ~ '^0x[0-9a-f]{40}$'
    AND LOWER(TRIM(COALESCE(smart_address, ''))) ~ '^0x[0-9a-f]{40}$'
  ORDER BY LOWER(TRIM(eoa_address)), smart_index, id
)
SELECT jsonb_pretty(jsonb_build_object(
  'owners', COALESCE((SELECT jsonb_agg(owner ORDER BY owner, salt) FROM smart_wallets), '[]'::jsonb),
  'salts', COALESCE((SELECT jsonb_agg(salt ORDER BY owner, salt) FROM smart_wallets), '[]'::jsonb),
  'expected_addresses', COALESCE((SELECT jsonb_agg(expected_address ORDER BY owner, salt) FROM smart_wallets), '[]'::jsonb)
));"

  psql_json "$APP_DB_URL" "$app_wallet_sql" "$APP_WALLETS_JSON"
  psql_json "$APP_DB_URL" "$smart_input_sql" "$SMART_WALLET_INPUT_JSON"
  write_funded_address_file "$APP_WALLET_ADDRESS_FILE"
}

normalize_app_db() {
  local before="$ARTIFACT_DIR/app-db-normalization-before.json"
  local after="$ARTIFACT_DIR/app-db-normalization-after.json"

  if normalization_marker_present "$APP_DB_URL" "app_w9_18_to_6"; then
    progress_info "App DB decimal normalization marker already exists; leaving W9 totals unchanged."
    return 0
  fi

  psql_json "$APP_DB_URL" "
SELECT jsonb_pretty(jsonb_build_object(
  'table', 'w9_wallet_earnings',
  'rows', COUNT(*),
  'total_before', COALESCE(SUM(amount_received), 0)::text,
  'non_zero_remainder_rows', COUNT(*) FILTER (WHERE MOD(amount_received, $DECIMAL_SCALE) <> 0),
  'remainder_total', COALESCE(SUM(MOD(amount_received, $DECIMAL_SCALE)), 0)::text
))
FROM w9_wallet_earnings;" "$before"

  if [[ "$MIGRATION_BROADCAST" != "true" ]]; then
    progress_info "Dry run: W9 totals left unchanged; see $before for what would change."
    return 0
  fi

  psql_exec "$APP_DB_URL" "
CREATE TABLE IF NOT EXISTS migration_decimal_normalization (
  id TEXT PRIMARY KEY,
  scale NUMERIC(78, 0) NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

  psql_exec "$APP_DB_URL" "
BEGIN;
UPDATE w9_wallet_earnings
SET amount_received = FLOOR(amount_received / $DECIMAL_SCALE),
    updated_at = NOW()
WHERE amount_received <> FLOOR(amount_received / $DECIMAL_SCALE);
INSERT INTO migration_decimal_normalization (id, scale)
VALUES ('app_w9_18_to_6', $DECIMAL_SCALE);
COMMIT;"

  psql_json "$APP_DB_URL" "
SELECT jsonb_pretty(jsonb_build_object(
  'table', 'w9_wallet_earnings',
  'rows', COUNT(*),
  'total_after', COALESCE(SUM(amount_received), 0)::text
))
FROM w9_wallet_earnings;" "$after"
}

normalize_ponder_db() {
  local before="$ARTIFACT_DIR/ponder-normalization-before.json"
  local after="$ARTIFACT_DIR/ponder-normalization-after.json"

  if normalization_marker_present "$PONDER_DB_URL" "ponder_18_to_6"; then
    progress_info "Ponder DB decimal normalization marker already exists; leaving transaction values unchanged."
    return 0
  fi

  psql_json "$PONDER_DB_URL" "
SELECT jsonb_pretty(jsonb_build_object(
  'scale', '$DECIMAL_SCALE',
  'transfer_event', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_before', COALESCE(SUM(amount), 0)::text,
      'non_zero_remainder_rows', COUNT(*) FILTER (WHERE MOD(amount, $DECIMAL_SCALE) <> 0),
      'remainder_total', COALESCE(SUM(MOD(amount, $DECIMAL_SCALE)), 0)::text
    )
    FROM transfer_event
  ),
  'transfer_account', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_before', COALESCE(SUM(balance), 0)::text,
      'positive_total_before', COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text,
      'non_zero_remainder_rows', COUNT(*) FILTER (WHERE MOD(ABS(balance), $DECIMAL_SCALE) <> 0),
      'remainder_total', COALESCE(SUM(MOD(ABS(balance), $DECIMAL_SCALE)), 0)::text
    )
    FROM transfer_account
  ),
  'allowance', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_before', COALESCE(SUM(amount), 0)::text,
      'non_zero_remainder_rows', COUNT(*) FILTER (WHERE MOD(amount, $DECIMAL_SCALE) <> 0),
      'remainder_total', COALESCE(SUM(MOD(amount, $DECIMAL_SCALE)), 0)::text
    )
    FROM allowance
  ),
  'approval_event', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_before', COALESCE(SUM(amount), 0)::text,
      'non_zero_remainder_rows', COUNT(*) FILTER (WHERE MOD(amount, $DECIMAL_SCALE) <> 0),
      'remainder_total', COALESCE(SUM(MOD(amount, $DECIMAL_SCALE)), 0)::text
    )
    FROM approval_event
  )
));" "$before"

  if [[ "$MIGRATION_BROADCAST" != "true" ]]; then
    progress_info "Dry run: Ponder transaction values left unchanged; see $before for what would change."
    return 0
  fi

  psql_exec "$PONDER_DB_URL" "
CREATE TABLE IF NOT EXISTS migration_decimal_normalization (
  id TEXT PRIMARY KEY,
  scale NUMERIC(78, 0) NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

  psql_exec "$PONDER_DB_URL" "
BEGIN;
UPDATE transfer_event SET amount = FLOOR(amount / $DECIMAL_SCALE);
UPDATE allowance SET amount = FLOOR(amount / $DECIMAL_SCALE);
UPDATE approval_event SET amount = FLOOR(amount / $DECIMAL_SCALE);

CREATE TEMP TABLE recomputed_transfer_account AS
SELECT
  chain_id,
  address,
  SUM(delta) AS balance,
  FALSE AS is_owner
FROM (
  SELECT chain_id, LOWER(\"from\") AS address, -amount AS delta FROM transfer_event
  UNION ALL
  SELECT chain_id, LOWER(\"to\") AS address, amount AS delta FROM transfer_event
) movements
GROUP BY chain_id, address;

TRUNCATE transfer_account;
-- Per-event FLOOR can leave dust-level negative recomputed balances for
-- emptied wallets; those are clamped to zero so the continuity ledger never
-- reports a negative legacy balance.
INSERT INTO transfer_account (chain_id, address, balance, is_owner)
SELECT chain_id, address, GREATEST(balance, 0), is_owner
FROM recomputed_transfer_account;

INSERT INTO migration_decimal_normalization (id, scale)
VALUES ('ponder_18_to_6', $DECIMAL_SCALE);

-- Clear the reorg operation log entries our writes just generated (and any
-- stale unfinalized ones), so a same-build Ponder restart cannot replay raw
-- pre-normalization values over the normalized tables.
$(ponder_reorg_cleanup_sql)
COMMIT;"

  psql_json "$PONDER_DB_URL" "
SELECT jsonb_pretty(jsonb_build_object(
  'scale', '$DECIMAL_SCALE',
  'transfer_event', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_after', COALESCE(SUM(amount), 0)::text
    )
    FROM transfer_event
  ),
  'transfer_account', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_after', COALESCE(SUM(balance), 0)::text,
      'positive_total_after', COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text
    )
    FROM transfer_account
  ),
  'clamped_negative_balances', (
    SELECT jsonb_build_object(
      'note', 'Recomputed balances below zero were clamped to 0 in transfer_account. Stats exclude the zero address mint origin.',
      'rows', COUNT(*),
      'total_clamped_up', COALESCE(SUM(-balance), 0)::text
    )
    FROM (
      SELECT SUM(delta) AS balance
      FROM (
        SELECT chain_id, LOWER(\"from\") AS address, -amount AS delta FROM transfer_event
        UNION ALL
        SELECT chain_id, LOWER(\"to\") AS address, amount AS delta FROM transfer_event
      ) movements
      WHERE address <> '0x0000000000000000000000000000000000000000'
      GROUP BY chain_id, address
      HAVING SUM(delta) < 0
    ) negative_balances
  ),
  'allowance', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_after', COALESCE(SUM(amount), 0)::text
    )
    FROM allowance
  ),
  'approval_event', (
    SELECT jsonb_build_object(
      'rows', COUNT(*),
      'total_after', COALESCE(SUM(amount), 0)::text
    )
    FROM approval_event
  )
));" "$after"
}

write_balance_artifacts_and_wipe_external() {
  local already_wiped amount_expr

  if [[ "$MIGRATION_BROADCAST" == "true" ]]; then
    psql_exec "$PONDER_DB_URL" "
CREATE TABLE IF NOT EXISTS migration_external_balance_wipe (
  id TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  artifact_note TEXT NOT NULL DEFAULT ''
);"

    already_wiped="$(psql_scalar "$PONDER_DB_URL" "SELECT COUNT(*) FROM migration_external_balance_wipe WHERE id = 'external_transfer_account_rows';")"
    if [[ "$already_wiped" != "0" ]]; then
      if [[ -f "$EXTERNAL_HOLDERS_JSON" && -f "$APP_DISTRIBUTION_JSON" && -f "$EXTERNAL_WIPE_AUDIT_JSON" ]]; then
        progress_info "External wipe already applied; keeping existing artifacts for run id $RUN_ID."
        return 0
      fi
      if [[ "${ALLOW_EXTERNAL_BALANCE_WIPE_RERUN:-false}" != "true" ]]; then
        die "external non-app transfer_account rows were already wiped in this Ponder DB, but run id $RUN_ID has no external-holder artifacts. Resume with the original --id, use the original external-holder-balances.json artifact, or set ALLOW_EXTERNAL_BALANCE_WIPE_RERUN=true if you are intentionally rerunning against a restored DB."
      fi
    fi
  fi

  amount_expr="$(ponder_amount_expr)"

  # Balance artifacts are derived from transfer events (clamped per chain and
  # address, exactly like the transfer_account recompute) so they are correct
  # both in real runs and in dry runs where normalization was skipped. The
  # whole block runs in one psql session: the address list lives in a TEMP
  # table, and in real runs the delete plus its wipe marker commit atomically
  # as a single statement.
  {
    printf '%s\n' "CREATE TEMP TABLE migration_app_wallet_addresses(address TEXT PRIMARY KEY);"
    printf '%s\n' "\\copy migration_app_wallet_addresses(address) FROM '$APP_WALLET_ADDRESS_FILE'"
    printf '%s\n' "\\o $EXTERNAL_HOLDERS_JSON"
    cat <<SQL
WITH movements AS (
  SELECT chain_id, LOWER("from") AS address, -($amount_expr) AS delta FROM transfer_event
  UNION ALL
  SELECT chain_id, LOWER("to") AS address, ($amount_expr) AS delta FROM transfer_event
),
chain_balances AS (
  SELECT chain_id, address, GREATEST(SUM(delta), 0) AS balance
  FROM movements
  GROUP BY chain_id, address
),
external AS (
  SELECT cb.address, SUM(cb.balance) AS balance
  FROM chain_balances cb
  WHERE NOT EXISTS (
    SELECT 1 FROM migration_app_wallet_addresses app WHERE app.address = cb.address
  )
  GROUP BY cb.address
  HAVING SUM(cb.balance) > 0
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'note', 'Positive normalized balances derived from Ponder transfer events for holders not present in app.wallets and not in the configured extra funded addresses. In a real run the corresponding transfer_account rows are deleted from Ponder after this artifact is written.',
  'addresses', COALESCE((SELECT jsonb_agg(address ORDER BY address) FROM external), '[]'::jsonb),
  'amounts', COALESCE((SELECT jsonb_agg(balance::text ORDER BY address) FROM external), '[]'::jsonb),
  'holders', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('address', address, 'balance', balance::text) ORDER BY address)
    FROM external
  ), '[]'::jsonb)
));
SQL
    printf '%s\n' "\\o $APP_DISTRIBUTION_JSON"
    cat <<SQL
WITH movements AS (
  SELECT chain_id, LOWER("from") AS address, -($amount_expr) AS delta FROM transfer_event
  UNION ALL
  SELECT chain_id, LOWER("to") AS address, ($amount_expr) AS delta FROM transfer_event
),
chain_balances AS (
  SELECT chain_id, address, GREATEST(SUM(delta), 0) AS balance
  FROM movements
  GROUP BY chain_id, address
),
app_balances AS (
  SELECT cb.address, SUM(cb.balance) AS balance
  FROM chain_balances cb
  JOIN migration_app_wallet_addresses app ON app.address = cb.address
  GROUP BY cb.address
  HAVING SUM(cb.balance) > 0
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'note', 'Desired final Celo SFLUV balances after 6-decimal normalization for addresses present in app.wallets plus the configured extra funded addresses (service accounts such as the backend faucet).',
  'addresses', COALESCE((SELECT jsonb_agg(address ORDER BY address) FROM app_balances), '[]'::jsonb),
  'amounts', COALESCE((SELECT jsonb_agg(balance::text ORDER BY address) FROM app_balances), '[]'::jsonb),
  'holders', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('address', address, 'balance', balance::text) ORDER BY address)
    FROM app_balances
  ), '[]'::jsonb)
));
SQL
    if [[ "$MIGRATION_BROADCAST" == "true" ]]; then
      printf '%s\n' "\\o $EXTERNAL_WIPE_AUDIT_JSON"
      printf '%s\n' "BEGIN;"
      cat <<SQL
WITH deleted AS (
  DELETE FROM transfer_account ta
  WHERE NOT EXISTS (
    SELECT 1 FROM migration_app_wallet_addresses app WHERE app.address = LOWER(ta.address)
  )
  RETURNING balance
),
wipe_marker AS (
  INSERT INTO migration_external_balance_wipe (id, artifact_note)
  VALUES ('external_transfer_account_rows', 'External holder artifact written before deleting non-app transfer_account rows.')
  ON CONFLICT (id) DO UPDATE
  SET applied_at = NOW(),
      artifact_note = EXCLUDED.artifact_note
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
  'deleted_transfer_account_rows', COUNT(*),
  'deleted_positive_rows', COUNT(*) FILTER (WHERE balance > 0),
  'deleted_positive_balance_total', COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text,
  'note', 'Non-app-wallet transfer_account rows were removed intentionally. Do not recompute transfer_account from legacy Berachain transfer_event rows after this point.'
))
FROM deleted;
SQL
      printf '%s\n' "\\o"
      # Clear the reorg log entries the DELETE just generated, in the same
      # transaction, so a same-build Ponder restart cannot re-insert the
      # wiped external rows.
      printf '%s\n' "$(ponder_reorg_cleanup_sql)"
      printf '%s\n' "COMMIT;"
    fi
    printf '%s\n' "\\o"
  } | psql "$PONDER_DB_URL" -X -qAt -v ON_ERROR_STOP=1 >/dev/null

  if [[ "$MIGRATION_BROADCAST" != "true" ]]; then
    progress_info "Dry run: external transfer_account rows left in place; no wipe marker written."
  fi
}

# Seed the bot DB recovery_balances table from the external-holder artifact so
# non-auto-migrated holders (mostly Citizen Wallet users) can claim their
# decimal-adjusted balances after the migration. The external-holder query
# already excludes app wallets and the configured extra funded addresses (the
# faucet), so faucet/auto-migrated balances are never added to the recovery
# list. Idempotent: ON CONFLICT keeps any already-claimed rows untouched.
seed_recovery_balances() {
  if [[ "$MIGRATION_BROADCAST" != "true" ]]; then
    progress_info "Dry run: skipping recovery_balances seeding (no DB writes)."
    return 0
  fi
  [[ -f "$EXTERNAL_HOLDERS_JSON" ]] || die "external holder artifact missing: $EXTERNAL_HOLDERS_JSON"

  local old_chain_id csv
  old_chain_id="$(cast chain-id --rpc-url "$OLD_CHAIN_RPC")"
  [[ "$old_chain_id" =~ ^[0-9]+$ ]] || die "could not resolve old chain id from $OLD_CHAIN_RPC"
  csv="$ARTIFACT_DIR/recovery-balances.csv"

  node - "$EXTERNAL_HOLDERS_JSON" "$old_chain_id" "$csv" <<'NODE'
const fs = require("fs");
const [artifact, chainId, out] = process.argv.slice(2);
const data = JSON.parse(fs.readFileSync(artifact, "utf8"));
const holders = data.holders || [];
const lines = [];
for (const h of holders) {
  const addr = String(h.address || "").toLowerCase().trim();
  const amt = String(h.balance || "0").trim();
  if (!/^0x[0-9a-f]{40}$/.test(addr)) continue;
  if (!/^[0-9]+$/.test(amt) || amt === "0") continue;
  lines.push(`${addr},${chainId},${amt}`);
}
fs.writeFileSync(out, lines.length ? lines.join("\n") + "\n" : "");
NODE

  {
    printf '%s\n' "CREATE TABLE IF NOT EXISTS recovery_balances("
    printf '%s\n' "  address TEXT PRIMARY KEY, chain_id BIGINT NOT NULL, amount NUMERIC(78,0) NOT NULL,"
    printf '%s\n' "  claim_status TEXT NOT NULL DEFAULT 'unclaimed', claimed_by TEXT, claimed_by_user_id TEXT,"
    printf '%s\n' "  claim_tx_hash TEXT, claim_tx_chain_id BIGINT, claimed_at TIMESTAMPTZ,"
    printf '%s\n' "  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(), updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW());"
    printf '%s\n' "CREATE INDEX IF NOT EXISTS recovery_balances_status_idx ON recovery_balances(claim_status);"
    printf '%s\n' "CREATE TEMP TABLE recovery_seed(address TEXT, chain_id BIGINT, amount NUMERIC(78,0));"
    printf '%s\n' "\\copy recovery_seed(address, chain_id, amount) FROM '$csv' WITH (FORMAT csv)"
    printf '%s\n' "INSERT INTO recovery_balances(address, chain_id, amount) SELECT address, chain_id, amount FROM recovery_seed ON CONFLICT (address) DO NOTHING;"
  } | psql "$BOT_DB_URL" -X -q -v ON_ERROR_STOP=1 >/dev/null

  progress_info "Seeded recovery_balances into $MIGRATION_DB_BOT_SUFFIX from $EXTERNAL_HOLDERS_JSON."
}

merge_smart_wallet_batches() {
  node - "$SMART_WALLET_INPUT_JSON" "$SMART_WALLET_BATCH_DIR" "$DEPLOYED_SMART_WALLETS_JSON" <<'NODE'
const fs = require("fs");
const path = require("path");

const [inputPath, batchDir, outputPath] = process.argv.slice(2);
const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
const batchFiles = fs.existsSync(batchDir)
  ? fs.readdirSync(batchDir)
      .filter((name) => /^batch-\d+\.json$/.test(name))
      .sort((a, b) => Number(a.match(/\d+/)[0]) - Number(b.match(/\d+/)[0]))
  : [];

const rows = [];
for (const file of batchFiles) {
  const batch = JSON.parse(fs.readFileSync(path.join(batchDir, file), "utf8"));
  const owners = batch.owners || [];
  const salts = batch.salts || [];
  const addresses = batch.addresses || [];
  const alreadyDeployed = batch.already_deployed || [];
  for (let i = 0; i < addresses.length; i += 1) {
    rows.push({
      owner: owners[i],
      salt: String(salts[i]),
      address: addresses[i],
      already_deployed: alreadyDeployed[i] === true,
    });
  }
}

if (rows.length === 0 && Array.isArray(input.owners) && input.owners.length === 0) {
  // Empty migration is valid.
} else if (rows.length !== (input.owners || []).length) {
  throw new Error(`deployed smart wallet row count mismatch: got ${rows.length}, expected ${(input.owners || []).length}`);
}

fs.writeFileSync(outputPath, `${JSON.stringify({
  generated_at: new Date().toISOString(),
  count: rows.length,
  wallets: rows,
}, null, 2)}\n`);
NODE
}

link_deployed_wallet_balances() {
  node - "$DEPLOYED_SMART_WALLETS_JSON" "$APP_DISTRIBUTION_JSON" "$DEPLOYED_SMART_WALLET_BALANCES_JSON" <<'NODE'
const fs = require("fs");
const [walletPath, distributionPath, outputPath] = process.argv.slice(2);
const deployed = JSON.parse(fs.readFileSync(walletPath, "utf8"));
const distribution = JSON.parse(fs.readFileSync(distributionPath, "utf8"));
const balances = new Map();
(distribution.holders || []).forEach((holder) => {
  balances.set(String(holder.address).toLowerCase(), String(holder.balance));
});
const wallets = (deployed.wallets || []).map((wallet) => ({
  ...wallet,
  balance: balances.get(String(wallet.address).toLowerCase()) || "0",
}));
fs.writeFileSync(outputPath, `${JSON.stringify({
  generated_at: new Date().toISOString(),
  count: wallets.length,
  wallets,
}, null, 2)}\n`);
NODE
}

# Highest block number across forge broadcast receipts written by this run,
# so the Ponder start block is derived from the actual distribution
# transactions rather than a possibly-lagging RPC head.
max_broadcast_block() {
  node - "$CONTRACTS_DIR/broadcast" "$RUN_START_EPOCH" <<'NODE'
const fs = require("fs");
const path = require("path");
const [root, sinceRaw] = process.argv.slice(2);
const since = Number(sinceRaw);
let max = 0n;
for (const script of ["DeploySmartWalletBatch.s.sol", "DistributeBatch.s.sol"]) {
  const scriptDir = path.join(root, script);
  if (!fs.existsSync(scriptDir)) continue;
  for (const chainDir of fs.readdirSync(scriptDir)) {
    const file = path.join(scriptDir, chainDir, "run-latest.json");
    if (!fs.existsSync(file)) continue;
    let data;
    try {
      data = JSON.parse(fs.readFileSync(file, "utf8"));
    } catch {
      continue;
    }
    if (Number(data.timestamp || 0) < since) continue;
    for (const receipt of data.receipts || []) {
      if (receipt.blockNumber === undefined || receipt.blockNumber === null) continue;
      const block = BigInt(receipt.blockNumber);
      if (block > max) max = block;
    }
  }
}
process.stdout.write(max.toString());
NODE
}

write_result_json() {
  local celo_block="$1"
  node - "$MIGRATION_RESULT_JSON" "$ARTIFACT_DIR" "$celo_block" "$OLD_TOKEN" "$NEW_TOKEN" "$APP_DISTRIBUTION_JSON" "$EXTERNAL_HOLDERS_JSON" <<'NODE'
const fs = require("fs");
const [outputPath, artifactDir, celoBlock, oldToken, newToken, appDistributionPath, externalPath] = process.argv.slice(2);
const appDistribution = JSON.parse(fs.readFileSync(appDistributionPath, "utf8"));
const external = JSON.parse(fs.readFileSync(externalPath, "utf8"));
fs.writeFileSync(outputPath, `${JSON.stringify({
  generated_at: new Date().toISOString(),
  artifact_dir: artifactDir,
  old_token: oldToken,
  new_token: newToken,
  celo_distribution_complete_block: Number(celoBlock),
  ponder_start_block: Number(celoBlock) + 1,
  app_distribution_count: (appDistribution.addresses || []).length,
  external_holder_count: (external.addresses || []).length,
}, null, 2)}\n`);
NODE
}

backup_app_db() {
  pg_dump --format=custom --no-owner --no-acl "$APP_DB_URL" -f "$ARTIFACT_DIR/app-db-before.dump"
}

backup_ponder_db() {
  pg_dump --format=custom --no-owner --no-acl "$PONDER_DB_URL" -f "$ARTIFACT_DIR/ponder-db-before.dump"
}

upgrade_bera_lock() {
  (
    cd "$CONTRACTS_DIR"
    SFLUV_V2_PROXY="$OLD_TOKEN" forge script script/UpgradeToBeraWipe.s.sol:UpgradeToBeraWipe \
      --rpc-url "$OLD_CHAIN_RPC" \
      --private-key "$CONTRACT_DEPLOYER_PRIVATE_KEY" \
      "${forge_broadcast_args[@]}"
  )
}

deploy_smart_wallet_batch() {
  local start="$1"
  local batch_file="$SMART_WALLET_BATCH_DIR/batch-$start.json"
  (
    cd "$CONTRACTS_DIR"
    ACCOUNT_FACTORY_ADDRESS="$ACCOUNT_FACTORY_ADDRESS" forge script script/DeploySmartWalletBatch.s.sol:DeploySmartWalletBatch \
      --sig "run(string,uint256,uint256,string)" "$SMART_WALLET_INPUT_JSON" "$start" "$SMART_WALLET_BATCH_SIZE" "$batch_file" \
      --rpc-url "$NEW_CHAIN_RPC" \
      --private-key "$WALLET_DEPLOYER_PRIVATE_KEY" \
      "${forge_broadcast_args[@]}"
  )
}

distribute_app_wallets() {
  (
    cd "$CONTRACTS_DIR"
    SFLUV_V3_PROXY="$NEW_TOKEN" DISTRIBUTOR="$DISTRIBUTOR_ADDRESS" forge script script/DistributeBatch.s.sol:DistributeBatch \
      --sig "run(string)" "$APP_DISTRIBUTION_JSON" \
      --rpc-url "$NEW_CHAIN_RPC" \
      --private-key "$DISTRIBUTOR_PRIVATE_KEY" \
      "${forge_broadcast_args[@]}"
  )
}

completion_write_result() {
  local chain_head broadcast_max celo_block
  chain_head="$(cast block-number --rpc-url "$NEW_CHAIN_RPC")"
  broadcast_max="$(max_broadcast_block)"
  celo_block="$(bi_max "$chain_head" "$broadcast_max")"
  progress_info "Chain head: $chain_head; max broadcast receipt block: $broadcast_max; using: $celo_block"
  write_result_json "$celo_block"
}

print_phase "Preflight"
progress_step "Artifact directory"
printf " %s\n" "$ARTIFACT_DIR"
progress_step "Call trace"
printf " %s\n" "$TRACE_FILE"

verify_rpc_get_block "Old RPC latest block" "$OLD_CHAIN_RPC"
verify_rpc_get_block "New RPC latest block" "$NEW_CHAIN_RPC"

progress_step "Database connection"
psql "$APP_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null
psql "$PONDER_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null
progress_ok

print_phase "Preflight Assertions"
preflight_assertions

print_phase "Database Backups"
run_step "backup_app_db" "Dump app DB" backup_app_db
run_step "backup_ponder_db" "Dump Ponder DB" backup_ponder_db

print_phase "Berachain Migration Lock"
run_step "bera_lock_upgrade" "Upgrade old token to wipe implementation" upgrade_bera_lock

print_phase "Wallet Snapshot"
run_step "wallet_snapshot" "Write app wallet artifacts" write_app_wallet_artifacts
progress_info "Wallet snapshot: $APP_WALLETS_JSON"
progress_info "Smart deploy input: $SMART_WALLET_INPUT_JSON"

print_phase "Decimal Normalization"
run_step "normalize_app_w9" "Normalize app W9 totals" normalize_app_db
run_step "normalize_ponder" "Normalize Ponder transaction values" normalize_ponder_db
progress_info "App business amounts such as workflow bounties and proposer balances are left unchanged; they are treated as already normalized app-level token amounts."

print_phase "Balance Artifacts"
run_step "balance_artifacts_external_wipe" "Write app/external balances and wipe external Ponder balances" write_balance_artifacts_and_wipe_external
progress_info "App distribution: $APP_DISTRIBUTION_JSON"
progress_info "External holders: $EXTERNAL_HOLDERS_JSON"

print_phase "Recovery Balances"
run_step "seed_recovery_balances" "Seed recovery balances for non-migrated holders" seed_recovery_balances
progress_info "Non-app holders are claimable post-migration via the recovery flow; faucet/auto-migrated addresses are excluded by the external-holder query."

print_phase "Celo Smart Wallet Deployment"
SMART_WALLET_COUNT="$(json_array_length "$SMART_WALLET_INPUT_JSON" owners)"
if [[ "$SMART_WALLET_COUNT" -eq 0 ]]; then
  progress_step "Deploy smart wallets"
  progress_skip
  merge_smart_wallet_batches
else
  start=0
  while [[ "$start" -lt "$SMART_WALLET_COUNT" ]]; do
    run_step "smart_wallet_batch_$start" "Deploy smart wallets $start" deploy_smart_wallet_batch "$start"
    start="$((start + SMART_WALLET_BATCH_SIZE))"
  done
  merge_smart_wallet_batches
fi
link_deployed_wallet_balances
progress_info "Deployed smart wallets: $DEPLOYED_SMART_WALLETS_JSON"
progress_info "Deployed smart wallet balances: $DEPLOYED_SMART_WALLET_BALANCES_JSON"

print_phase "Celo Distribution"
APP_DISTRIBUTION_COUNT="$(json_array_length "$APP_DISTRIBUTION_JSON" addresses)"
if [[ "$APP_DISTRIBUTION_COUNT" -eq 0 ]]; then
  progress_step "Distribute app wallet balances"
  progress_skip
else
  run_step "distribute_app_balances" "Distribute app wallet balances" distribute_app_wallets
fi

print_phase "Completion"
run_step "write_migration_result" "Resolve Celo completion block" completion_write_result
CELO_COMPLETE_BLOCK="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).celo_distribution_complete_block' "$MIGRATION_RESULT_JSON")"

cat <<SUMMARY

Migration Artifacts
===================
Directory:                         $ARTIFACT_DIR
App distribution JSON:             $APP_DISTRIBUTION_JSON
External holder balance JSON:      $EXTERNAL_HOLDERS_JSON
Deployed smart wallet JSON:        $DEPLOYED_SMART_WALLETS_JSON
Result JSON:                       $MIGRATION_RESULT_JSON

Ponder Start Block
==================
Celo distribution complete block:  $CELO_COMPLETE_BLOCK
Start new Celo Ponder at block:    $((CELO_COMPLETE_BLOCK + 1))

Deferred Berachain Backing Sweep
================================
After manual verification, run the separate sweep script:
  cd $(shell_quote "$CONTRACTS_DIR")
  SFLUV_V2_PROXY=$(shell_quote "$OLD_TOKEN") TREASURY=<treasury-address> forge script script/SweepBeraBacking.s.sol:SweepBeraBacking --rpc-url $(shell_quote "$OLD_CHAIN_RPC") --private-key \$CONTRACT_DEPLOYER_PRIVATE_KEY --broadcast

SUMMARY
