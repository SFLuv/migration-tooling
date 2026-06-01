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
  --run-id ID           Artifact subdirectory name. Default: UTC timestamp.
  --dry-run             Run forge scripts without --broadcast.
  -h, --help            Show this help.

Required env:
  OLD_CHAIN_RPC, NEW_CHAIN_RPC, OLD_TOKEN, NEW_TOKEN,
  MIGRATION_DB_CONNECTION_STRING, MIGRATION_DB_PONDER_SUFFIX,
  MIGRATION_DB_APP_SUFFIX, CONTRACT_DEPLOYER_PRIVATE_KEY,
  WALLET_DEPLOYER_PRIVATE_KEY, DISTRIBUTOR_PRIVATE_KEY,
  ACCOUNT_FACTORY_ADDRESS
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
    --run-id)
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
APP_WALLETS_JSON="$ARTIFACT_DIR/app-wallets.json"
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
  CONTRACT_DEPLOYER_PRIVATE_KEY \
  WALLET_DEPLOYER_PRIVATE_KEY \
  DISTRIBUTOR_PRIVATE_KEY \
  ACCOUNT_FACTORY_ADDRESS; do
  require_env "$key"
done

validate_positive_int "DECIMAL_SCALE" "$DECIMAL_SCALE"
validate_positive_int "SMART_WALLET_BATCH_SIZE" "$SMART_WALLET_BATCH_SIZE"
[[ -d "$CONTRACTS_DIR" ]] || die "missing contracts repo: $CONTRACTS_DIR"
[[ -f "$CONTRACTS_DIR/lib/forge-std/src/Script.sol" ]] || die "contracts dependencies missing. Run: git -C $(shell_quote "$CONTRACTS_DIR") submodule update --init --recursive"

APP_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_APP_SUFFIX")"
PONDER_DB_URL="$(db_url_for "$MIGRATION_DB_CONNECTION_STRING" "$MIGRATION_DB_PONDER_SUFFIX")"
DISTRIBUTOR_ADDRESS="$(private_key_address "$DISTRIBUTOR_PRIVATE_KEY")"

mkdir -p "$ARTIFACT_DIR" "$SMART_WALLET_BATCH_DIR"

write_app_wallet_artifacts() {
  local app_wallet_sql smart_input_sql address_sql

  app_wallet_sql="
WITH wallet_rows AS (
  SELECT
    id,
    owner,
    name,
    is_eoa,
    is_hidden,
    is_redeemer,
    is_minter,
    LOWER(TRIM(eoa_address)) AS eoa_address,
    NULLIF(LOWER(TRIM(COALESCE(smart_address, ''))), '') AS smart_address,
    smart_index
  FROM wallets
  WHERE active = TRUE
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
  WHERE is_eoa = FALSE
    AND smart_index IS NOT NULL
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
  WHERE active = TRUE
    AND is_eoa = FALSE
    AND smart_index IS NOT NULL
    AND LOWER(TRIM(eoa_address)) ~ '^0x[0-9a-f]{40}$'
    AND LOWER(TRIM(COALESCE(smart_address, ''))) ~ '^0x[0-9a-f]{40}$'
  ORDER BY LOWER(TRIM(eoa_address)), smart_index, id
)
SELECT jsonb_pretty(jsonb_build_object(
  'owners', COALESCE((SELECT jsonb_agg(owner ORDER BY owner, salt) FROM smart_wallets), '[]'::jsonb),
  'salts', COALESCE((SELECT jsonb_agg(salt ORDER BY owner, salt) FROM smart_wallets), '[]'::jsonb),
  'expected_addresses', COALESCE((SELECT jsonb_agg(expected_address ORDER BY owner, salt) FROM smart_wallets), '[]'::jsonb)
));"

  address_sql="
WITH wallet_rows AS (
  SELECT
    LOWER(TRIM(eoa_address)) AS eoa_address,
    NULLIF(LOWER(TRIM(COALESCE(smart_address, ''))), '') AS smart_address
  FROM wallets
  WHERE active = TRUE
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
SELECT address FROM addresses ORDER BY address;"

  psql_json "$APP_DB_URL" "$app_wallet_sql" "$APP_WALLETS_JSON"
  psql_json "$APP_DB_URL" "$smart_input_sql" "$SMART_WALLET_INPUT_JSON"
  psql "$APP_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "$address_sql" > "$APP_WALLET_ADDRESS_FILE"
}

normalize_app_db() {
  local before="$ARTIFACT_DIR/app-db-normalization-before.json"
  local after="$ARTIFACT_DIR/app-db-normalization-after.json"
  local normalized

  psql_exec "$APP_DB_URL" "
CREATE TABLE IF NOT EXISTS migration_decimal_normalization (
  id TEXT PRIMARY KEY,
  scale NUMERIC(78, 0) NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

  normalized="$(psql_scalar "$APP_DB_URL" "SELECT COUNT(*) FROM migration_decimal_normalization WHERE id = 'app_w9_18_to_6';")"
  if [[ "$normalized" != "0" ]]; then
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
  local normalized

  psql_exec "$PONDER_DB_URL" "
CREATE TABLE IF NOT EXISTS migration_decimal_normalization (
  id TEXT PRIMARY KEY,
  scale NUMERIC(78, 0) NOT NULL,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);"

  normalized="$(psql_scalar "$PONDER_DB_URL" "SELECT COUNT(*) FROM migration_decimal_normalization WHERE id = 'ponder_18_to_6';")"
  if [[ "$normalized" != "0" ]]; then
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
INSERT INTO transfer_account (chain_id, address, balance, is_owner)
SELECT chain_id, address, balance, is_owner
FROM recomputed_transfer_account;

INSERT INTO migration_decimal_normalization (id, scale)
VALUES ('ponder_18_to_6', $DECIMAL_SCALE);
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
  local address_table="migration_app_wallet_addresses_$$"
  local already_wiped

  psql_exec "$PONDER_DB_URL" "
CREATE TABLE IF NOT EXISTS migration_external_balance_wipe (
  id TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  artifact_note TEXT NOT NULL DEFAULT ''
);"

  already_wiped="$(psql_scalar "$PONDER_DB_URL" "SELECT COUNT(*) FROM migration_external_balance_wipe WHERE id = 'external_transfer_account_rows';")"
  if [[ "$already_wiped" != "0" && "${ALLOW_EXTERNAL_BALANCE_WIPE_RERUN:-false}" != "true" ]]; then
    die "external non-app transfer_account rows were already wiped in this Ponder DB. Use the original external-holder-balances.json artifact, or set ALLOW_EXTERNAL_BALANCE_WIPE_RERUN=true if you are intentionally rerunning against a restored DB."
  fi

  psql_exec "$PONDER_DB_URL" "DROP TABLE IF EXISTS $address_table; CREATE TABLE $address_table(address TEXT PRIMARY KEY);"
  psql "$PONDER_DB_URL" -X -q -v ON_ERROR_STOP=1 -c "\\copy $address_table(address) FROM '$APP_WALLET_ADDRESS_FILE'" >/dev/null

  psql_json "$PONDER_DB_URL" "
WITH external AS (
  SELECT LOWER(address) AS address, SUM(balance) AS balance
  FROM transfer_account ta
  WHERE NOT EXISTS (
    SELECT 1 FROM $address_table app WHERE app.address = LOWER(ta.address)
  )
  GROUP BY LOWER(address)
  HAVING SUM(balance) > 0
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
  'note', 'Positive normalized Ponder balances for holders not present in app.wallets. These transfer_account rows are deleted from Ponder after this artifact is written.',
  'addresses', COALESCE((SELECT jsonb_agg(address ORDER BY address) FROM external), '[]'::jsonb),
  'amounts', COALESCE((SELECT jsonb_agg(balance::text ORDER BY address) FROM external), '[]'::jsonb),
  'holders', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('address', address, 'balance', balance::text) ORDER BY address)
    FROM external
  ), '[]'::jsonb)
));" "$EXTERNAL_HOLDERS_JSON"

  psql_json "$PONDER_DB_URL" "
WITH app_balances AS (
  SELECT LOWER(ta.address) AS address, SUM(ta.balance) AS balance
  FROM transfer_account ta
  JOIN $address_table app ON app.address = LOWER(ta.address)
  GROUP BY LOWER(ta.address)
  HAVING SUM(ta.balance) > 0
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
  'note', 'Desired final Celo SFLUV balances for addresses present in app.wallets after 6-decimal normalization.',
  'addresses', COALESCE((SELECT jsonb_agg(address ORDER BY address) FROM app_balances), '[]'::jsonb),
  'amounts', COALESCE((SELECT jsonb_agg(balance::text ORDER BY address) FROM app_balances), '[]'::jsonb),
  'holders', COALESCE((
    SELECT jsonb_agg(jsonb_build_object('address', address, 'balance', balance::text) ORDER BY address)
    FROM app_balances
  ), '[]'::jsonb)
));" "$APP_DISTRIBUTION_JSON"

  psql_json "$PONDER_DB_URL" "
WITH deleted AS (
  DELETE FROM transfer_account ta
  WHERE NOT EXISTS (
    SELECT 1 FROM $address_table app WHERE app.address = LOWER(ta.address)
  )
  RETURNING balance
)
SELECT jsonb_pretty(jsonb_build_object(
  'generated_at', TO_CHAR(NOW() AT TIME ZONE 'UTC', 'YYYY-MM-DD\"T\"HH24:MI:SS\"Z\"'),
  'deleted_transfer_account_rows', COUNT(*),
  'deleted_positive_rows', COUNT(*) FILTER (WHERE balance > 0),
  'deleted_positive_balance_total', COALESCE(SUM(balance) FILTER (WHERE balance > 0), 0)::text,
  'note', 'Non-app-wallet transfer_account rows were removed intentionally. Do not recompute transfer_account from legacy Berachain transfer_event rows after this point.'
))
FROM deleted;" "$EXTERNAL_WIPE_AUDIT_JSON"

  psql_exec "$PONDER_DB_URL" "
INSERT INTO migration_external_balance_wipe (id, artifact_note)
VALUES ('external_transfer_account_rows', 'External holder artifact written before deleting non-app transfer_account rows.')
ON CONFLICT (id) DO UPDATE
SET applied_at = NOW(),
    artifact_note = EXCLUDED.artifact_note;"

  psql_exec "$PONDER_DB_URL" "DROP TABLE IF EXISTS $address_table;"
}

merge_smart_wallet_batches() {
  node - "$SMART_WALLET_INPUT_JSON" "$SMART_WALLET_BATCH_DIR" "$DEPLOYED_SMART_WALLETS_JSON" <<'NODE'
const fs = require("fs");
const path = require("path");

const [inputPath, batchDir, outputPath] = process.argv.slice(2);
const input = JSON.parse(fs.readFileSync(inputPath, "utf8"));
const batchFiles = fs.existsSync(batchDir)
  ? fs.readdirSync(batchDir).filter((name) => /^batch-\d+\.json$/.test(name)).sort()
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

print_phase "Preflight"
progress_step "Artifact directory"
printf " %s\n" "$ARTIFACT_DIR"

verify_rpc_get_block "Old RPC latest block" "$OLD_CHAIN_RPC"
verify_rpc_get_block "New RPC latest block" "$NEW_CHAIN_RPC"

progress_step "Database connection"
psql "$APP_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null
psql "$PONDER_DB_URL" -X -qAt -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null
progress_ok

print_phase "Database Backups"
progress_step "Dump app DB"
pg_dump --format=custom --no-owner --no-acl "$APP_DB_URL" -f "$ARTIFACT_DIR/app-db-before.dump"
progress_ok
progress_step "Dump Ponder DB"
pg_dump --format=custom --no-owner --no-acl "$PONDER_DB_URL" -f "$ARTIFACT_DIR/ponder-db-before.dump"
progress_ok

print_phase "Berachain Migration Lock"
progress_step "Upgrade old token to wipe implementation"
(
  cd "$CONTRACTS_DIR"
  SFLUV_V2_PROXY="$OLD_TOKEN" forge script script/UpgradeToBeraWipe.s.sol:UpgradeToBeraWipe \
    --rpc-url "$OLD_CHAIN_RPC" \
    --private-key "$CONTRACT_DEPLOYER_PRIVATE_KEY" \
    "${forge_broadcast_args[@]}"
)
progress_ok

print_phase "Wallet Snapshot"
progress_step "Write app wallet artifacts"
write_app_wallet_artifacts
progress_ok
progress_info "Wallet snapshot: $APP_WALLETS_JSON"
progress_info "Smart deploy input: $SMART_WALLET_INPUT_JSON"

print_phase "Decimal Normalization"
progress_step "Normalize app W9 totals"
normalize_app_db
progress_ok
progress_step "Normalize Ponder transaction values"
normalize_ponder_db
progress_ok
progress_info "App business amounts such as workflow bounties and proposer balances are left unchanged; they are treated as already normalized app-level token amounts."

print_phase "Balance Artifacts"
progress_step "Write app/external balances and wipe external Ponder balances"
write_balance_artifacts_and_wipe_external
progress_ok
progress_info "App distribution: $APP_DISTRIBUTION_JSON"
progress_info "External holders: $EXTERNAL_HOLDERS_JSON"

print_phase "Celo Smart Wallet Deployment"
SMART_WALLET_COUNT="$(json_array_length "$SMART_WALLET_INPUT_JSON" owners)"
if [[ "$SMART_WALLET_COUNT" -eq 0 ]]; then
  progress_step "Deploy smart wallets"
  progress_skip
  merge_smart_wallet_batches
else
  start=0
  while [[ "$start" -lt "$SMART_WALLET_COUNT" ]]; do
    batch_file="$SMART_WALLET_BATCH_DIR/batch-$start.json"
    progress_step "Deploy smart wallets $start"
    (
      cd "$CONTRACTS_DIR"
      ACCOUNT_FACTORY_ADDRESS="$ACCOUNT_FACTORY_ADDRESS" forge script script/DeploySmartWalletBatch.s.sol:DeploySmartWalletBatch \
        --sig "run(string,uint256,uint256,string)" "$SMART_WALLET_INPUT_JSON" "$start" "$SMART_WALLET_BATCH_SIZE" "$batch_file" \
        --rpc-url "$NEW_CHAIN_RPC" \
        --private-key "$WALLET_DEPLOYER_PRIVATE_KEY" \
        "${forge_broadcast_args[@]}"
    )
    progress_ok
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
  progress_step "Distribute app wallet balances"
  (
    cd "$CONTRACTS_DIR"
    SFLUV_V3_PROXY="$NEW_TOKEN" DISTRIBUTOR="$DISTRIBUTOR_ADDRESS" forge script script/DistributeBatch.s.sol:DistributeBatch \
      --sig "run(string)" "$APP_DISTRIBUTION_JSON" \
      --rpc-url "$NEW_CHAIN_RPC" \
      --private-key "$DISTRIBUTOR_PRIVATE_KEY" \
      "${forge_broadcast_args[@]}"
  )
  progress_ok
fi

print_phase "Completion"
progress_step "Read Celo block"
CELO_COMPLETE_BLOCK="$(cast block-number --rpc-url "$NEW_CHAIN_RPC")"
printf " %s\n" "$CELO_COMPLETE_BLOCK"
write_result_json "$CELO_COMPLETE_BLOCK"

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
