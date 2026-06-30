#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/repos/app"
BACKEND_DIR="$APP_DIR/backend"
FRONTEND_DIR="$APP_DIR/frontend"
PONDER_DIR="$APP_DIR/ponder"
CONTRACTS_DIR="$ROOT_DIR/repos/contracts"

SESSION_NAME="${SESSION_NAME:-sfluv-migration-test}"
ROOT_ENV="${ROOT_ENV:-$ROOT_DIR/.env}"
DEFAULT_BERA_RPC="https://rpc.berachain.com"
DEFAULT_CELO_RPC="https://forno.celo.org"
BERA_RPC="${BERACHAIN_RPC_URL:-${BERA_RPC_URL:-${ANVIL_BERA_FORK_URL:-$DEFAULT_BERA_RPC}}}"
CELO_RPC="${CELO_RPC_URL:-${ANVIL_CELO_FORK_URL:-$DEFAULT_CELO_RPC}}"
BERA_PORT="${BERA_ANVIL_PORT:-8545}"
CELO_PORT="${CELO_ANVIL_PORT:-8546}"
BERA_FORK_BLOCK="${BERA_FORK_BLOCK:-}"
CELO_FORK_BLOCK="${CELO_FORK_BLOCK:-}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
PONDER_PORT="${PONDER_PORT:-42069}"
PONDER_HOST="${PONDER_HOST:-localhost}"
PONDER_COMMAND="${PONDER_COMMAND:-start}"
PONDER_START_BLOCK="${PONDER_START_BLOCK:-}"
PONDER_WAIT_SECONDS="${PONDER_WAIT_SECONDS:-600}"
BOOT_WAIT_SECONDS="${BOOT_WAIT_SECONDS:-180}"
BACKEND_ENV="${BACKEND_ENV:-$BACKEND_DIR/.env}"
FRONTEND_SCRIPT="${FRONTEND_SCRIPT:-dev-http}"
NOTIFICATION_TEST_MODE="${NOTIFICATION_TEST_MODE:-false}"
PRODUCTION_APP_DB_NAME="${PRODUCTION_APP_DB_NAME:-app}"
PRODUCTION_BOT_DB_NAME="${PRODUCTION_BOT_DB_NAME:-bot}"
PRODUCTION_PONDER_DB_NAME="${PRODUCTION_PONDER_DB_NAME:-ponder}"
MIGRATION_APP_DB_NAME="${MIGRATION_APP_DB_NAME:-migration_app}"
MIGRATION_BOT_DB_NAME="${MIGRATION_BOT_DB_NAME:-migration_bot}"
MIGRATION_PONDER_DB_NAME="${MIGRATION_PONDER_DB_NAME:-migration_ponder}"
LOCAL_POSTGRES_BASE_URL="${LOCAL_POSTGRES_BASE_URL:-}"
LOCAL_POSTGRES_USER="${LOCAL_POSTGRES_USER:-}"
LOCAL_POSTGRES_PASSWORD="${LOCAL_POSTGRES_PASSWORD:-}"
LOCAL_POSTGRES_CONNECTION_STRING="${LOCAL_POSTGRES_CONNECTION_STRING:-}"
LOCAL_POSTGRES_MAINTENANCE_DB="${LOCAL_POSTGRES_MAINTENANCE_DB:-postgres}"
ALLOW_NON_LOCAL_POSTGRES="${ALLOW_NON_LOCAL_POSTGRES:-false}"
ATTACH="false"
REPLACE_SESSION="false"
CHECK_PORTS="true"
CLEANUP_DONE="false"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

TEST HARNESS ONLY. This script clones production state into local databases and
stands up local anvil forks of Berachain and Celo so the migration can be
rehearsed end-to-end against a disposable copy. It is NOT part of the real
production migration: the live run uses the migrator web app (see
migrator/README.md) against real chains and the real databases, and this script
is never executed during it. (Among other things, it deals fake backing and
storage-pranks AccessControl roles to the anvil key — strictly local-test setup.)

Starts a tmux session with five panes:
  1. Berachain anvil fork
  2. Celo anvil fork
  3. Ponder pointed at the local Berachain fork
  4. Backend using a generated local Berachain config
  5. Frontend

After the anvil forks boot, the migration AccessControl roles on OLD_TOKEN
(Berachain) and NEW_TOKEN (Celo) are granted to the default anvil account so the
migration can run with the anvil key instead of real admin keys. Set TEST_ADMIN
to empower a different address; the step is skipped if OLD_TOKEN/NEW_TOKEN are
unset. The test chains are OLD_CHAIN_RPC / NEW_CHAIN_RPC (default: the local
forks this script starts).

Options:
  --bera-rpc URL                 Berachain RPC URL to fork. Default: $DEFAULT_BERA_RPC.
                                  Env: BERACHAIN_RPC_URL, BERA_RPC_URL, or ANVIL_BERA_FORK_URL.
  --celo-rpc URL                 Celo RPC URL to fork. Default: $DEFAULT_CELO_RPC.
                                  Env: CELO_RPC_URL or ANVIL_CELO_FORK_URL.
  --bera-port PORT               Local Berachain anvil port. Default: 8545.
  --celo-port PORT               Local Celo anvil port. Default: 8546.
  --bera-fork-block BLOCK        Optional fixed Berachain fork block. Default: current state.
  --celo-fork-block BLOCK        Optional fixed Celo fork block. Default: current state.
  --backend-port PORT            Backend port. Default: 8080.
  --frontend-port PORT           Frontend port. Default: 3000.
  --ponder-port PORT             Ponder port. Default: 42069.
  --ponder-host HOST             Host backend/probes use to reach Ponder. Default: localhost.
  --ponder-command COMMAND       Ponder CLI command. Default: start.
                                  Use dev for hot-reload local development.
  --ponder-start-block BLOCK     Optional Ponder start block. Default: Ponder config default.
  --ponder-wait-seconds SECONDS  Seconds backend waits for Ponder port. Default: 600.
  --boot-wait-seconds SECONDS    Seconds to wait for each service port after tmux startup.
                                  Default: 180.
  --root-env PATH                Root env file with PRODUCTION_POSTGRES_CONNECTION_STRING and
                                  LOCAL_POSTGRES_CONNECTION_STRING.
                                  Default: .env.
  --production-app-db NAME       Production app database name. Default: app.
  --production-bot-db NAME       Production bot database name. Default: bot.
  --production-ponder-db NAME    Production Ponder database name. Default: ponder.
  --local-postgres-base-url HOST Local Postgres host:port. Fallback when
                                  LOCAL_POSTGRES_CONNECTION_STRING is unset.
  --local-postgres-user USER     Local Postgres user. Fallback when
                                  LOCAL_POSTGRES_CONNECTION_STRING is unset.
  --backend-env PATH             Backend env file. Default: repos/app/backend/.env.
  --frontend-script NAME         pnpm script for frontend. Default: dev-http.
  --notification-test-mode BOOL  Backend notification sink env. Default: false.
  --session NAME                 tmux session name. Default: sfluv-migration-test.
  --replace                      Accepted for compatibility; startup preflight already replaces this session.
  --attach                       Attach to the full tmux session after successful boot verification.
  --no-attach                    Monitor without attaching/switching to the session. This is the default.
  --no-port-check                Skip local port preflight checks.
  -h, --help                     Show this help.
USAGE
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

shell_quote() {
  printf "%q" "$1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bera-rpc)
      BERA_RPC="${2:-}"
      shift 2
      ;;
    --celo-rpc)
      CELO_RPC="${2:-}"
      shift 2
      ;;
    --bera-port)
      BERA_PORT="${2:-}"
      shift 2
      ;;
    --celo-port)
      CELO_PORT="${2:-}"
      shift 2
      ;;
    --bera-fork-block)
      BERA_FORK_BLOCK="${2:-}"
      shift 2
      ;;
    --celo-fork-block)
      CELO_FORK_BLOCK="${2:-}"
      shift 2
      ;;
    --backend-port)
      BACKEND_PORT="${2:-}"
      shift 2
      ;;
    --frontend-port)
      FRONTEND_PORT="${2:-}"
      shift 2
      ;;
    --ponder-port)
      PONDER_PORT="${2:-}"
      shift 2
      ;;
    --ponder-host)
      PONDER_HOST="${2:-}"
      shift 2
      ;;
    --ponder-command)
      PONDER_COMMAND="${2:-}"
      shift 2
      ;;
    --ponder-start-block)
      PONDER_START_BLOCK="${2:-}"
      shift 2
      ;;
    --ponder-wait-seconds)
      PONDER_WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --boot-wait-seconds)
      BOOT_WAIT_SECONDS="${2:-}"
      shift 2
      ;;
    --root-env)
      ROOT_ENV="${2:-}"
      shift 2
      ;;
    --production-app-db)
      PRODUCTION_APP_DB_NAME="${2:-}"
      shift 2
      ;;
    --production-bot-db)
      PRODUCTION_BOT_DB_NAME="${2:-}"
      shift 2
      ;;
    --production-ponder-db)
      PRODUCTION_PONDER_DB_NAME="${2:-}"
      shift 2
      ;;
    --local-postgres-base-url)
      LOCAL_POSTGRES_BASE_URL="${2:-}"
      shift 2
      ;;
    --local-postgres-user)
      LOCAL_POSTGRES_USER="${2:-}"
      shift 2
      ;;
    --backend-env)
      BACKEND_ENV="${2:-}"
      shift 2
      ;;
    --frontend-script)
      FRONTEND_SCRIPT="${2:-}"
      shift 2
      ;;
    --notification-test-mode)
      NOTIFICATION_TEST_MODE="${2:-}"
      shift 2
      ;;
    --session)
      SESSION_NAME="${2:-}"
      shift 2
      ;;
    --replace)
      REPLACE_SESSION="true"
      shift
      ;;
    --attach)
      ATTACH="true"
      shift
      ;;
    --no-attach)
      ATTACH="false"
      shift
      ;;
    --no-port-check)
      CHECK_PORTS="false"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
done

BERA_RPC="${BERA_RPC:-$DEFAULT_BERA_RPC}"
CELO_RPC="${CELO_RPC:-$DEFAULT_CELO_RPC}"
[[ -f "$BACKEND_ENV" ]] || die "missing backend env file: $BACKEND_ENV"
[[ -f "$BACKEND_DIR/community-config.json" ]] || die "missing backend community config"
[[ -f "$PONDER_DIR/package.json" ]] || die "missing ponder package: $PONDER_DIR/package.json"
[[ -n "$PONDER_HOST" ]] || die "Ponder host must not be empty"
[[ -n "$PONDER_COMMAND" ]] || die "Ponder command must not be empty"
case "$PONDER_COMMAND" in
  dev|start)
    ;;
  *)
    die "unsupported Ponder command '$PONDER_COMMAND'. Use 'start' or 'dev'."
    ;;
esac

require_cmd tmux
require_cmd anvil
require_cmd forge
require_cmd cast
require_cmd nc
require_cmd node
require_cmd go
require_cmd pnpm
require_cmd psql
require_cmd pg_dump

BERA_LOCAL_RPC="http://127.0.0.1:$BERA_PORT"
CELO_LOCAL_RPC="http://127.0.0.1:$CELO_PORT"
BERA_LOCAL_WS="ws://127.0.0.1:$BERA_PORT"
BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"
FRONTEND_URL="http://127.0.0.1:$FRONTEND_PORT"
PONDER_URL="http://$PONDER_HOST:$PONDER_PORT"
LOCAL_CONFIG_DIR="$BACKEND_DIR/.migration-local"
LOCAL_CONFIG="$LOCAL_CONFIG_DIR/community-config.berachain-local.json"
NOTIFICATION_DIR="$BACKEND_DIR/test-notifications"

trim_value() {
  local value="$1"
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf "%s" "$value"
}

env_file_value() {
  local key="$1"
  local file="${2:-$BACKEND_ENV}"
  local line value
  [[ -f "$file" ]] || return 0
  line="$(awk -v key="$key" '$0 ~ "^[[:space:]]*(export[[:space:]]+)?" key "=" { line=$0 } END { print line }' "$file")"
  [[ -n "$line" ]] || return 0
  line="$(trim_value "$line")"
  line="${line#export }"
  value="${line#*=}"
  value="$(trim_value "$value")"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  else
    value="${value%%[[:space:]]#*}"
    value="$(trim_value "$value")"
  fi
  printf "%s" "$value"
}

env_or_file_value() {
  local key="$1"
  local fallback="${2:-}"
  local value="${!key-}"
  if [[ -z "$value" ]]; then
    value="$(env_file_value "$key")"
  fi
  printf "%s" "${value:-$fallback}"
}

env_or_file_value_from() {
  local key="$1"
  local file="$2"
  local fallback="${3:-}"
  local value="${!key-}"
  if [[ -z "$value" ]]; then
    value="$(env_file_value "$key" "$file")"
  fi
  printf "%s" "${value:-$fallback}"
}

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
  printf "  %-52s" "$1"
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

truncate_text() {
  local text="$1"
  local max_len="$2"
  if ((max_len <= 0)); then
    printf ""
    return
  fi
  if ((${#text} <= max_len)); then
    printf "%s" "$text"
    return
  fi
  if ((max_len <= 3)); then
    printf "%s" "${text:0:max_len}"
    return
  fi
  printf "%s..." "${text:0:max_len-3}"
}

server_port_entries() {
  printf "%s\n" \
    "Berachain anvil:$BERA_PORT" \
    "Celo anvil:$CELO_PORT" \
    "Ponder:$PONDER_PORT" \
    "Backend:$BACKEND_PORT" \
    "Frontend:$FRONTEND_PORT"
}

check_required_ports_available() {
  local phase_label="${1:-Required server ports available}"
  local entries=()
  local entry label port other_entry other_label other_port
  local status=0
  local report=""
  local listeners=""

  progress_step "$phase_label"

  if [[ "$CHECK_PORTS" != "true" ]]; then
    progress_skip
    return 0
  fi

  if ! command -v lsof >/dev/null 2>&1; then
    progress_fail
    printf "\nPort checks require lsof. Install lsof or rerun with --no-port-check.\n" >&2
    return 1
  fi

  while IFS= read -r entry; do
    entries+=("$entry")
  done < <(server_port_entries)

  for entry in "${entries[@]}"; do
    label="${entry%%:*}"
    port="${entry#*:}"
    if [[ ! "$port" =~ ^[0-9]+$ ]] || ((port < 1 || port > 65535)); then
      report+="  - $label: configured port '$port' is not a valid TCP port."$'\n'
      status=1
    fi
  done

  for ((i = 0; i < ${#entries[@]}; i++)); do
    label="${entries[$i]%%:*}"
    port="${entries[$i]#*:}"
    for ((j = i + 1; j < ${#entries[@]}; j++)); do
      other_entry="${entries[$j]}"
      other_label="${other_entry%%:*}"
      other_port="${other_entry#*:}"
      if [[ "$port" == "$other_port" ]]; then
        report+="  - $label and $other_label are both configured for port $port."$'\n'
        status=1
      fi
    done
  done

  for entry in "${entries[@]}"; do
    label="${entry%%:*}"
    port="${entry#*:}"
    [[ "$port" =~ ^[0-9]+$ ]] || continue
    listeners="$({ lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null || true; } | awk 'NR > 1 { item = $1 "/" $2; if (!seen[item]++) { if (out != "") out = out ","; out = out item } } END { print out }')"
    if [[ -n "$listeners" ]]; then
      report+="  - $label requires port $port, currently used by $listeners."$'\n'
      status=1
    fi
  done

  if [[ "$status" -eq 0 ]]; then
    progress_ok
    return 0
  fi

  progress_fail
  printf "\nStartup blocked. Make these configured ports available, then rerun the script:\n%s" "$report" >&2
  return 1
}

port_is_open() {
  local host="$1"
  local port="$2"
  nc -z -w 1 "$host" "$port" >/dev/null 2>&1
}

print_pane_tail() {
  local label="$1"
  local pane="$2"

  if [[ -z "$pane" ]] || ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    return 0
  fi

  printf "\n%s pane output tail:\n" "$label" >&2
  tmux capture-pane -p -t "$pane" -S -40 2>/dev/null | sed 's/^/    /' >&2 || true
}

check_pnpm_bin_available() {
  local label="$1"
  local dir="$2"
  local bin="$3"
  local install_command

  progress_step "$label"

  if [[ -x "$dir/node_modules/.bin/$bin" ]]; then
    progress_ok
    return 0
  fi

  install_command="cd $(shell_quote "$dir") && pnpm install"
  progress_fail
  printf "\nMissing local pnpm dependency binary: %s/node_modules/.bin/%s\n" "$dir" "$bin" >&2
  printf "Install dependencies before rerunning:\n  %s\n" "$install_command" >&2
  return 1
}

pane_exit_line() {
  local pane="$1"
  tmux capture-pane -p -t "$pane" -S -80 2>/dev/null | awk '/pane exited with status/ { line = $0 } END { print line }'
}

wait_for_service_port() {
  local label="$1"
  local host="$2"
  local port="$3"
  local pane="$4"
  local timeout="${5:-$BOOT_WAIT_SECONDS}"
  local start elapsed last_notice exit_line

  progress_step "Verify $label port $port"
  printf " START\n"
  start="$(date +%s)"
  last_notice=-1

  while true; do
    if port_is_open "$host" "$port"; then
      progress_step "Verify $label port $port"
      progress_ok
      return 0
    fi

    elapsed="$(( $(date +%s) - start ))"

    exit_line="$(pane_exit_line "$pane" || true)"
    if [[ -n "$exit_line" ]]; then
      progress_step "Verify $label port $port"
      progress_fail
      printf "\n%s pane exited before opening %s:%s.\n" "$label" "$host" "$port" >&2
      print_pane_tail "$label" "$pane"
      return 1
    fi

    if ((elapsed >= timeout)); then
      progress_step "Verify $label port $port"
      progress_fail
      printf "\n%s did not become reachable on %s:%s within %ss.\n" "$label" "$host" "$port" "$timeout" >&2
      print_pane_tail "$label" "$pane"
      return 1
    fi

    if ((last_notice < 0 || elapsed >= last_notice + 10)); then
      progress_info "Verify $label port $port: waiting ${elapsed}s/${timeout}s"
      last_notice="$elapsed"
    fi

    sleep 1
  done
}

validate_local_db_name() {
  local name="$1"
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || die "unsafe local database name: $name"
}

validate_positive_int() {
  local label="$1"
  local value="$2"
  [[ "$value" =~ ^[0-9]+$ && "$value" -gt 0 ]] || die "$label must be a positive integer"
}

assert_local_postgres_base_url() {
  case "$LOCAL_POSTGRES_BASE_URL" in
    localhost|localhost:*|127.0.0.1|127.0.0.1:*|\[::1\]|\[::1\]:*)
      return 0
      ;;
  esac

  if [[ "$ALLOW_NON_LOCAL_POSTGRES" == "true" ]]; then
    return 0
  fi

  die "refusing to manage non-local Postgres host '$LOCAL_POSTGRES_BASE_URL'. Set ALLOW_NON_LOCAL_POSTGRES=true to override."
}

postgres_url_for_db() {
  local db_name="$1"
  node - "$LOCAL_POSTGRES_BASE_URL" "$LOCAL_POSTGRES_USER" "$LOCAL_POSTGRES_PASSWORD" "$db_name" <<'NODE'
const [hostPort, user, password, dbName] = process.argv.slice(2);
const url = new URL(`postgres://${hostPort}`);
url.username = user;
url.password = password;
url.pathname = `/${dbName}`;
process.stdout.write(url.toString());
NODE
}

postgres_connection_url_for_db() {
  local connection_string="$1"
  local db_name="$2"
  node - "$connection_string" "$db_name" <<'NODE'
const [rawConnectionString, dbName] = process.argv.slice(2);
const url = new URL(rawConnectionString);
if (url.protocol !== "postgres:" && url.protocol !== "postgresql:") {
  throw new Error(`unsupported postgres URL protocol: ${url.protocol}`);
}
url.pathname = `/${dbName}`;
process.stdout.write(url.toString());
NODE
}

postgres_connection_component() {
  local connection_string="$1"
  local component="$2"
  node - "$connection_string" "$component" <<'NODE'
const [rawConnectionString, component] = process.argv.slice(2);
const url = new URL(rawConnectionString);
if (url.protocol !== "postgres:" && url.protocol !== "postgresql:") {
  throw new Error(`unsupported postgres URL protocol: ${url.protocol}`);
}
if (component === "host") {
  process.stdout.write(url.host);
} else if (component === "username") {
  process.stdout.write(decodeURIComponent(url.username));
} else if (component === "password") {
  process.stdout.write(decodeURIComponent(url.password));
} else {
  throw new Error(`unsupported postgres URL component: ${component}`);
}
NODE
}

local_postgres_url_for_db() {
  local db_name="$1"
  if [[ -n "$LOCAL_POSTGRES_CONNECTION_STRING" ]]; then
    postgres_connection_url_for_db "$LOCAL_POSTGRES_CONNECTION_STRING" "$db_name"
    return
  fi
  postgres_url_for_db "$db_name"
}

production_url_for_db() {
  local db_name="$1"
  postgres_connection_url_for_db "$PRODUCTION_POSTGRES_CONNECTION_STRING" "$db_name"
}

source_database_table_count() {
  local source_url="$1"
  psql "$source_url" -X -qAt -c "
    SELECT count(*)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r', 'p')
      AND n.nspname NOT IN ('pg_catalog', 'information_schema');
  " 2>/dev/null | tr -d '[:space:]'
}

psql_maintenance() {
  local sql="$1"
  psql "$LOCAL_POSTGRES_MAINTENANCE_URL" -X -v ON_ERROR_STOP=1 -qAt -c "$sql"
}

database_exists() {
  local db_name="$1"
  local result
  if ! result="$(psql_maintenance "SELECT 1 FROM pg_database WHERE datname = '$db_name';" | tr -d '[:space:]')"; then
    return 2
  fi
  [[ "$result" == "1" ]] && return 0
  return 1
}

stop_tmux_session() {
  progress_step "Stop tmux session"
  if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    progress_skip
    return 0
  fi

  tmux kill-session -t "$SESSION_NAME" >/dev/null 2>&1 || {
    progress_fail
    return 1
  }

  for _ in {1..40}; do
    if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
      progress_ok
      return 0
    fi
    sleep 0.25
  done

  progress_fail
  return 1
}

drop_local_database() {
  local db_name="$1"
  progress_step "Drop database $db_name"
  psql_maintenance "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$db_name' AND pid <> pg_backend_pid();" >/dev/null
  psql_maintenance "DROP DATABASE IF EXISTS \"$db_name\";" >/dev/null
  if database_exists "$db_name"; then
    progress_fail
    return 1
  elif [[ "$?" -eq 2 ]]; then
    progress_fail
    return 1
  fi
  progress_ok
}

create_local_database() {
  local db_name="$1"
  progress_step "Create database $db_name"
  psql_maintenance "CREATE DATABASE \"$db_name\";" >/dev/null
  if database_exists "$db_name"; then
    progress_ok
    return 0
  elif [[ "$?" -eq 2 ]]; then
    progress_fail
    return 1
  fi
  progress_fail
  return 1
}

clone_database() {
  local label="$1"
  local source_url="$2"
  local target_url="$3"
  local log_file log_dir pid status elapsed latest table_count table_done last_reported_table reported_once report_every
  local status_label checkpoint
  local start_time

  status_label="Clone $label production data"
  progress_step "$status_label"
  printf " START\n"

  log_dir="${TMPDIR:-/tmp}"
  log_dir="${log_dir%/}"
  log_file="$(mktemp "$log_dir/sfluv-db-clone.XXXXXX")"
  table_count="$(source_database_table_count "$source_url" || true)"
  start_time="$(date +%s)"
  last_reported_table=-1
  reported_once=false
  report_every=5

  (
    set -o pipefail
    pg_dump --verbose --format=plain --no-owner --no-acl "$source_url" 2>>"$log_file" \
      | sed '/^SET transaction_timeout = 0;$/d' \
      | psql "$target_url" -X -v ON_ERROR_STOP=1 -q -o /dev/null 2>>"$log_file"
  ) &
  pid=$!

  while kill -0 "$pid" 2>/dev/null; do
    elapsed="$(( $(date +%s) - start_time ))s"
    latest="$(awk 'NF { line = $0 } END { print line }' "$log_file" 2>/dev/null || true)"
    latest="${latest#pg_dump: }"
    latest="${latest#pg_dump: detail: }"
    table_done="$(grep -c 'dumping contents of table' "$log_file" 2>/dev/null || true)"

    checkpoint=false
    if [[ "$table_count" =~ ^[0-9]+$ && "$table_count" -gt 0 ]]; then
      if ((last_reported_table < 0 || table_done >= last_reported_table + report_every || table_done >= table_count)); then
        checkpoint=true
        last_reported_table="$table_done"
      fi
      latest="$table_done/$table_count tables dumped${latest:+ - $latest}"
    elif [[ "$reported_once" != "true" ]]; then
      checkpoint=true
    fi

    if [[ "$checkpoint" == "true" ]]; then
      progress_info "$status_label: $elapsed - $(truncate_text "$latest" 96)"
      reported_once=true
    fi
    sleep 2
  done

  if wait "$pid"; then
    progress_step "$status_label"
    progress_ok
    rm -f "$log_file"
    return 0
  fi

  status=$?
  progress_step "$status_label"
  progress_fail
  if [[ -s "$log_file" ]]; then
    sed 's/^/    /' "$log_file" >&2
  fi
  rm -f "$log_file"
  return "$status"
}

cleanup_managed_state() {
  local phase_name="$1"
  local status=0

  print_phase "$phase_name"
  stop_tmux_session || status=1
  drop_local_database "$MIGRATION_APP_DB_NAME" || status=1
  drop_local_database "$MIGRATION_BOT_DB_NAME" || status=1
  drop_local_database "$MIGRATION_PONDER_DB_NAME" || status=1

  return "$status"
}

managed_state_needs_cleanup() {
  local db_name db_status

  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    return 0
  fi

  for db_name in "$MIGRATION_APP_DB_NAME" "$MIGRATION_BOT_DB_NAME" "$MIGRATION_PONDER_DB_NAME"; do
    if database_exists "$db_name"; then
      return 0
    else
      db_status=$?
      if [[ "$db_status" -eq 2 ]]; then
        return 2
      fi
    fi
  done

  return 1
}

verify_clean_start_state() {
  local status=0

  print_phase "Startup Verification"
  progress_step "No tmux session remains"
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    progress_fail
    status=1
  else
    progress_ok
  fi

  for db_name in "$MIGRATION_APP_DB_NAME" "$MIGRATION_BOT_DB_NAME" "$MIGRATION_PONDER_DB_NAME"; do
    progress_step "Database $db_name absent"
    if database_exists "$db_name"; then
      progress_fail
      status=1
    elif [[ "$?" -eq 2 ]]; then
      progress_fail
      status=1
    else
      progress_ok
    fi
  done

  return "$status"
}

shutdown_environment() {
  if [[ "$CLEANUP_DONE" == "true" ]]; then
    return 0
  fi

  local status=0
  cleanup_managed_state "Shutdown" || status=1
  CLEANUP_DONE="true"

  if [[ "$status" -eq 0 ]]; then
    print_rule
    printf "%sShutdown complete.%s\n" "$GREEN" "$RESET"
  else
    print_rule
    printf "%sShutdown finished with errors. Check the FAIL rows above.%s\n" "$RED" "$RESET"
  fi

  return "$status"
}

handle_signal() {
  printf "\n"
  shutdown_environment
  exit 130
}

handle_exit() {
  local status=$?
  if [[ "$CLEANUP_DONE" != "true" ]]; then
    shutdown_environment || true
  fi
  exit "$status"
}

PRODUCTION_POSTGRES_CONNECTION_STRING="$(env_or_file_value_from PRODUCTION_POSTGRES_CONNECTION_STRING "$ROOT_ENV")"
[[ -n "$PRODUCTION_POSTGRES_CONNECTION_STRING" ]] || die "PRODUCTION_POSTGRES_CONNECTION_STRING is required in the environment or $ROOT_ENV"

LOCAL_POSTGRES_CONNECTION_STRING="$(env_or_file_value_from LOCAL_POSTGRES_CONNECTION_STRING "$ROOT_ENV" "$LOCAL_POSTGRES_CONNECTION_STRING")"
if [[ -n "$LOCAL_POSTGRES_CONNECTION_STRING" ]]; then
  LOCAL_POSTGRES_BASE_URL="${LOCAL_POSTGRES_BASE_URL:-$(postgres_connection_component "$LOCAL_POSTGRES_CONNECTION_STRING" host)}"
  LOCAL_POSTGRES_USER="${LOCAL_POSTGRES_USER:-$(postgres_connection_component "$LOCAL_POSTGRES_CONNECTION_STRING" username)}"
  LOCAL_POSTGRES_PASSWORD="${LOCAL_POSTGRES_PASSWORD:-$(postgres_connection_component "$LOCAL_POSTGRES_CONNECTION_STRING" password)}"
fi

LOCAL_POSTGRES_USER="${LOCAL_POSTGRES_USER:-$(env_or_file_value DB_USER postgres)}"
LOCAL_POSTGRES_PASSWORD="${LOCAL_POSTGRES_PASSWORD:-$(env_or_file_value DB_PASSWORD)}"
if [[ -z "$LOCAL_POSTGRES_BASE_URL" ]]; then
  LOCAL_POSTGRES_BASE_URL="$(env_or_file_value DB_BASE_URL)"
fi
if [[ -z "$LOCAL_POSTGRES_BASE_URL" ]]; then
  LOCAL_POSTGRES_BASE_URL="$(env_or_file_value DB_URL localhost:5432)"
fi

validate_local_db_name "$MIGRATION_APP_DB_NAME"
validate_local_db_name "$MIGRATION_BOT_DB_NAME"
validate_local_db_name "$MIGRATION_PONDER_DB_NAME"
validate_local_db_name "$LOCAL_POSTGRES_MAINTENANCE_DB"
validate_positive_int "PONDER_WAIT_SECONDS" "$PONDER_WAIT_SECONDS"
validate_positive_int "BOOT_WAIT_SECONDS" "$BOOT_WAIT_SECONDS"
assert_local_postgres_base_url

LOCAL_POSTGRES_MAINTENANCE_URL="$(local_postgres_url_for_db "$LOCAL_POSTGRES_MAINTENANCE_DB")"
LOCAL_APP_DATABASE_URL="$(local_postgres_url_for_db "$MIGRATION_APP_DB_NAME")"
LOCAL_BOT_DATABASE_URL="$(local_postgres_url_for_db "$MIGRATION_BOT_DB_NAME")"
LOCAL_PONDER_DATABASE_URL="$(local_postgres_url_for_db "$MIGRATION_PONDER_DB_NAME")"
PRODUCTION_APP_DATABASE_URL="$(production_url_for_db "$PRODUCTION_APP_DB_NAME")"
PRODUCTION_BOT_DATABASE_URL="$(production_url_for_db "$PRODUCTION_BOT_DB_NAME")"
PRODUCTION_PONDER_DATABASE_URL="$(production_url_for_db "$PRODUCTION_PONDER_DB_NAME")"

LOCAL_PONDER_ADMIN_KEY="${LOCAL_PONDER_ADMIN_KEY:-$(env_or_file_value PONDER_KEY)}"
if [[ -z "$LOCAL_PONDER_ADMIN_KEY" ]]; then
  LOCAL_PONDER_ADMIN_KEY="$(env_or_file_value ADMIN_KEY x)"
fi
PAID_ADMIN_ADDRESSES_VALUE="$(env_or_file_value PAID_ADMIN_ADDRESSES)"
W9_TRANSACTION_URL="$BACKEND_URL/w9/transaction"
PONDER_CALLBACK_URL="$BACKEND_URL/ponder/callback"

# Migration test-role setup: empower the default anvil account on both local
# forks so the migration can run with the anvil key instead of real admin keys.
# Tokens come from the migration env; the test chains are the local anvil forks
# (OLD_CHAIN_RPC / NEW_CHAIN_RPC, defaulting to the forks this script started).
MIGRATION_OLD_TOKEN="$(env_or_file_value_from OLD_TOKEN "$ROOT_ENV")"
MIGRATION_NEW_TOKEN="$(env_or_file_value_from NEW_TOKEN "$ROOT_ENV")"
MIGRATION_OLD_RPC="$(env_or_file_value_from OLD_CHAIN_RPC "$ROOT_ENV" "$BERA_LOCAL_RPC")"
MIGRATION_NEW_RPC="$(env_or_file_value_from NEW_CHAIN_RPC "$ROOT_ENV" "$CELO_LOCAL_RPC")"
# Test admin (receives the roles) and the key that signs the grant transactions.
# Both default to anvil account #0, whose key is a well-known public test key.
TEST_CHAIN_ADMIN="$(env_or_file_value_from TEST_ADMIN "$ROOT_ENV" "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266")"
TEST_CHAIN_ADMIN_KEY="$(env_or_file_value_from TEST_ADMIN_KEY "$ROOT_ENV" "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80")"
# OpenZeppelin v5 AccessControl (ERC-7201) storage location; used to seed
# DEFAULT_ADMIN_ROLE for the test admin by writing the fork's hasRole slot.
ACL_STORAGE_LOCATION="0x02dd7bc7dec4dceedda775e58dd541e08a116c6c53815c0bd028192f7b626800"
ACL_DEFAULT_ADMIN_ROLE="0x0000000000000000000000000000000000000000000000000000000000000000"
ACL_TRUE_WORD="0x0000000000000000000000000000000000000000000000000000000000000001"
# Backing-token balance to deal to the test admin on each side (~3.4e38 base
# units; comfortably covers any distribution). Written to the ERC20 balance slot.
BACKING_MINT_WORD="0x00000000000000000000000000000000ffffffffffffffffffffffffffffffff"

trap handle_signal INT TERM
trap handle_exit EXIT

if managed_state_needs_cleanup; then
  cleanup_managed_state "Startup Preflight Cleanup" || die "startup preflight cleanup failed"
elif [[ "$?" -eq 2 ]]; then
  die "startup preflight cleanup check failed"
fi
verify_clean_start_state || die "startup verification failed"

print_phase "Dependency Preflight"
check_pnpm_bin_available "Ponder CLI installed" "$PONDER_DIR" "ponder" || die "dependency preflight failed"
check_pnpm_bin_available "Frontend Next CLI installed" "$FRONTEND_DIR" "next" || die "dependency preflight failed"

print_phase "Port Preflight"
check_required_ports_available "Configured server ports available" || die "server ports are unavailable"

print_phase "Database Clone"
create_local_database "$MIGRATION_APP_DB_NAME"
clone_database "app -> $MIGRATION_APP_DB_NAME" "$PRODUCTION_APP_DATABASE_URL" "$LOCAL_APP_DATABASE_URL"
create_local_database "$MIGRATION_BOT_DB_NAME"
clone_database "bot -> $MIGRATION_BOT_DB_NAME" "$PRODUCTION_BOT_DATABASE_URL" "$LOCAL_BOT_DATABASE_URL"
create_local_database "$MIGRATION_PONDER_DB_NAME"
clone_database "Ponder -> $MIGRATION_PONDER_DB_NAME" "$PRODUCTION_PONDER_DATABASE_URL" "$LOCAL_PONDER_DATABASE_URL"

print_phase "Local Config"
progress_step "Write backend local chain config"
mkdir -p "$LOCAL_CONFIG_DIR"
node - "$BACKEND_DIR/community-config.json" "$LOCAL_CONFIG" "$BERA_LOCAL_RPC" "$BERA_LOCAL_WS" <<'NODE'
const fs = require("fs");
const [source, target, rpcUrl, wsUrl] = process.argv.slice(2);
const config = JSON.parse(fs.readFileSync(source, "utf8"));
const chainId = String(config.community?.primary_token?.chain_id || 80094);
config.chains = config.chains || {};
config.chains[chainId] = config.chains[chainId] || { id: Number(chainId), node: {} };
config.chains[chainId].id = Number(chainId);
config.chains[chainId].node = config.chains[chainId].node || {};
config.chains[chainId].node.url = rpcUrl;
config.chains[chainId].node.ws_url = wsUrl;
config.config_location = `file:${target}`;
fs.writeFileSync(target, `${JSON.stringify(config, null, 2)}\n`);
NODE
progress_ok

pane_shell() {
  local body="$1"
  local script
  script="set -euo pipefail
trap 'status=\$?; echo; echo \"pane exited with status \$status. Press Enter to close.\"; read -r _' EXIT
$body"
  printf "bash -lc %q" "$script"
}

fork_block_arg() {
  local block="$1"
  if [[ -n "$block" ]]; then
    printf " --fork-block-number %s" "$(shell_quote "$block")"
  fi
}

pane_attach_command() {
  local pane_target="$1"
  printf "tmux select-pane -t %q \\; attach-session -t %q" "$pane_target" "$SESSION_NAME"
}

print_pane_summary() {
  cat <<SUMMARY

Migration Test Tmux Session
===========================
Session:              $SESSION_NAME
Backend local config: $LOCAL_CONFIG
Notification files:   $NOTIFICATION_DIR
Local databases:      $MIGRATION_APP_DB_NAME, $MIGRATION_BOT_DB_NAME, $MIGRATION_PONDER_DB_NAME

Panes
-----
Berachain anvil
  Target:  $BERA_PANE
  RPC:     $BERA_LOCAL_RPC
  Access:  $(pane_attach_command "$BERA_PANE")

Celo anvil
  Target:  $CELO_PANE
  RPC:     http://127.0.0.1:$CELO_PORT
  Access:  $(pane_attach_command "$CELO_PANE")

Ponder
  Target:  $PONDER_PANE
  URL:     $PONDER_URL
  RPC:     $BERA_LOCAL_RPC
  Command: pnpm exec ponder $PONDER_COMMAND -H 0.0.0.0 -p $PONDER_PORT
  Access:  $(pane_attach_command "$PONDER_PANE")

Backend
  Target:  $BACKEND_PANE
  URL:     $BACKEND_URL
  Access:  $(pane_attach_command "$BACKEND_PANE")

Frontend
  Target:  $FRONTEND_PANE
  URL:     $FRONTEND_URL
  Access:  $(pane_attach_command "$FRONTEND_PANE")

Full session
  Access:  tmux attach -t $(shell_quote "$SESSION_NAME")

SUMMARY
}

BERA_BODY="printf '%s\n' $(shell_quote "Berachain anvil fork -> $BERA_LOCAL_RPC")
anvil --host 127.0.0.1 --port $(shell_quote "$BERA_PORT") --fork-url $(shell_quote "$BERA_RPC")$(fork_block_arg "$BERA_FORK_BLOCK")"

CELO_BODY="printf '%s\n' $(shell_quote "Celo anvil fork -> http://127.0.0.1:$CELO_PORT")
anvil --host 127.0.0.1 --port $(shell_quote "$CELO_PORT") --fork-url $(shell_quote "$CELO_RPC")$(fork_block_arg "$CELO_FORK_BLOCK")"

PONDER_BODY="printf '%s\n' $(shell_quote "Ponder -> $PONDER_URL")
printf '%s\n' $(shell_quote "Ponder RPC -> $BERA_LOCAL_RPC")
set -a
if [[ -f .env ]]; then
  . ./.env
fi
set +a
export DATABASE_URL=$(shell_quote "$LOCAL_PONDER_DATABASE_URL")
export PONDER_RPC_URL_1=$(shell_quote "$BERA_LOCAL_RPC")
export PONDER_CHAIN_ID=80094
export CHAIN_ID=80094
export PONDER_START_BLOCK=$(shell_quote "$PONDER_START_BLOCK")
export ADMIN_KEY=$(shell_quote "$LOCAL_PONDER_ADMIN_KEY")
export PAID_ADMIN_ADDRESSES=$(shell_quote "$PAID_ADMIN_ADDRESSES_VALUE")
export W9_TRANSACTION_URL=$(shell_quote "$W9_TRANSACTION_URL")
export PORT=$(shell_quote "$PONDER_PORT")
export PONDER_PORT=$(shell_quote "$PONDER_PORT")
pnpm exec ponder $(shell_quote "$PONDER_COMMAND") -H 0.0.0.0 -p $(shell_quote "$PONDER_PORT")"

BACKEND_BODY="printf '%s\n' $(shell_quote "Backend -> $BACKEND_URL")
printf '%s\n' $(shell_quote "Local client config -> $LOCAL_CONFIG")
printf '%s\n' $(shell_quote "Notification test mode -> $NOTIFICATION_TEST_MODE")
printf '%s\n' $(shell_quote "Waiting for Ponder -> $PONDER_URL")
ponder_ready=false
for ((i = 1; i <= $(shell_quote "$PONDER_WAIT_SECONDS"); i++)); do
  if nc -z -w 1 $(shell_quote "$PONDER_HOST") $(shell_quote "$PONDER_PORT") >/dev/null 2>&1; then
    ponder_ready=true
    break
  fi
  if (( i % 15 == 0 )); then
    printf '%s\n' \"Still waiting for Ponder (\${i}s/${PONDER_WAIT_SECONDS}s) — it may be running historical sync; check the Ponder pane.\"
  fi
  sleep 1
done
if [[ \$ponder_ready != true ]]; then
  printf '%s\n' $(shell_quote "Ponder did not become reachable at $PONDER_URL within $PONDER_WAIT_SECONDS seconds. If it is still doing historical sync, re-run with a larger --ponder-wait-seconds.") >&2
  exit 1
fi
ENV_FILE=$(shell_quote "$BACKEND_ENV") \
PORT=$(shell_quote "$BACKEND_PORT") \
DB_BASE_URL=$(shell_quote "$LOCAL_POSTGRES_BASE_URL") \
DB_URL=$(shell_quote "$LOCAL_POSTGRES_BASE_URL") \
DB_USER=$(shell_quote "$LOCAL_POSTGRES_USER") \
DB_PASSWORD=$(shell_quote "$LOCAL_POSTGRES_PASSWORD") \
APP_DB_NAME=$(shell_quote "$MIGRATION_APP_DB_NAME") \
BOT_DB_NAME=$(shell_quote "$MIGRATION_BOT_DB_NAME") \
PONDER_DB_NAME=$(shell_quote "$MIGRATION_PONDER_DB_NAME") \
APP_BASE_URL=$(shell_quote "$FRONTEND_URL") \
PUBLIC_BACKEND_URL=$(shell_quote "$BACKEND_URL") \
CLIENT_CONFIG_LOCAL_ONLY=true \
CLIENT_CONFIG_FALLBACK_PATH=$(shell_quote "$LOCAL_CONFIG") \
PONDER_SERVER_BASE_URL=$(shell_quote "$PONDER_URL") \
PONDER_CALLBACK_URL=$(shell_quote "$PONDER_CALLBACK_URL") \
PONDER_KEY=$(shell_quote "$LOCAL_PONDER_ADMIN_KEY") \
ADMIN_KEY=$(shell_quote "$LOCAL_PONDER_ADMIN_KEY") \
NOTIFICATION_TEST_MODE=$(shell_quote "$NOTIFICATION_TEST_MODE") \
NOTIFICATION_TEST_OUTPUT_DIR=$(shell_quote "$NOTIFICATION_DIR") \
go run ./cmd/server"

FRONTEND_BODY="printf '%s\n' $(shell_quote "Frontend -> $FRONTEND_URL")
NEXT_PUBLIC_BACKEND_URL=$(shell_quote "$BACKEND_URL") \
NEXT_PUBLIC_BACKEND_BASE_URL=$(shell_quote "$BACKEND_URL") \
NEXT_PUBLIC_APP_BASE_URL=$(shell_quote "$FRONTEND_URL") \
pnpm run $(shell_quote "$FRONTEND_SCRIPT") -H 0.0.0.0 -p $(shell_quote "$FRONTEND_PORT")"

# Give an account a large ERC20 balance on the fork by finding and writing its
# balanceOf storage slot (the StdStorage probe: write a sentinel to each
# candidate mapping slot until balanceOf reflects it). Works for standard
# mapping(address=>uint) layouts (e.g. USDC, OZ ERC20); returns 1 if not found.
deal_erc20_balance() {
  local rpc="$1"
  local token="$2"
  local account="$3"
  local amount_word="$4"
  local sentinel="0x0000000000000000000000000000000000000000000000000000000000000539" # 1337
  local i slot orig newbal
  for i in $(seq 0 40); do
    slot="$(cast keccak "$(cast abi-encode 'f(address,uint256)' "$account" "$i")")"
    orig="$(cast storage "$token" "$slot" --rpc-url "$rpc" 2>/dev/null)" || return 1
    cast rpc --rpc-url "$rpc" anvil_setStorageAt "$token" "$slot" "$sentinel" >/dev/null 2>&1 || return 1
    newbal="$(cast call "$token" 'balanceOf(address)(uint256)' "$account" --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')"
    if [[ "$newbal" == "1337" ]]; then
      cast rpc --rpc-url "$rpc" anvil_setStorageAt "$token" "$slot" "$amount_word" >/dev/null 2>&1 || return 1
      return 0
    fi
    cast rpc --rpc-url "$rpc" anvil_setStorageAt "$token" "$slot" "$orig" >/dev/null 2>&1 || true
  done
  return 1
}

# Mint backing for the test admin on a chain: resolve the proxy's underlying()
# and deal it a large balance. The setup script already set the proxy allowance.
fund_backing_on_chain() {
  local label="$1"
  local rpc="$2"
  local token="$3"
  local backing

  progress_step "Fund backing token: $label"
  backing="$(cast call "$token" 'underlying()(address)' --rpc-url "$rpc" 2>/dev/null | awk '{print $1}')"
  if [[ ! "$backing" =~ ^0x[0-9a-fA-F]{40}$ ]] || [[ "$backing" == "0x0000000000000000000000000000000000000000" ]]; then
    progress_skip
    progress_info "Could not resolve underlying() on $token; skipping backing funding."
    return 0
  fi
  if deal_erc20_balance "$rpc" "$backing" "$TEST_CHAIN_ADMIN" "$BACKING_MINT_WORD"; then
    progress_ok
    progress_info "Minted backing $backing to $TEST_CHAIN_ADMIN (proxy allowance set by setup script)."
  else
    progress_skip
    progress_info "Could not locate balance slot for backing $backing; mint it manually if distribution needs it."
  fi
}

# Storage slot of AccessControlStorage._roles[role].hasRole[account] for the
# OpenZeppelin v5 (ERC-7201) layout, computed with cast.
acl_has_role_slot() {
  local role="$1"
  local account="$2"
  local role_slot
  role_slot="$(cast keccak "$(cast abi-encode 'f(bytes32,bytes32)' "$role" "$ACL_STORAGE_LOCATION")")"
  cast keccak "$(cast abi-encode 'f(address,bytes32)' "$account" "$role_slot")"
}

grant_roles_on_chain() {
  local label="$1"
  local rpc="$2"
  local token="$3"
  local log_file admin_slot

  progress_step "Grant migration roles: $label"
  log_file="$(mktemp "${TMPDIR:-/tmp}/sfluv-role-setup.XXXXXX")"
  admin_slot="$(acl_has_role_slot "$ACL_DEFAULT_ADMIN_ROLE" "$TEST_CHAIN_ADMIN")"

  # 1. Seed DEFAULT_ADMIN_ROLE for the test admin by writing the fork's hasRole
  #    slot directly (no key/owner needed). 2. As that account, grant the
  #    remaining migration roles with real transactions.
  if ( set -e
        cast rpc --rpc-url "$rpc" anvil_setStorageAt "$token" "$admin_slot" "$ACL_TRUE_WORD" >/dev/null
        cd "$CONTRACTS_DIR"
        SFLUV_PROXY="$token" TEST_ADMIN="$TEST_CHAIN_ADMIN" \
          forge script script/SetupMigrationTestEnv.s.sol:SetupMigrationTestEnv \
            --rpc-url "$rpc" --broadcast --private-key "$TEST_CHAIN_ADMIN_KEY" ) \
        >"$log_file" 2>&1; then
    progress_ok
    progress_info "Granted DEFAULT_ADMIN/MINTER/REDEEMER/MIGRATOR to $TEST_CHAIN_ADMIN on $token"
    rm -f "$log_file"
    return 0
  fi
  progress_fail
  sed 's/^/    /' "$log_file" >&2 || true
  rm -f "$log_file"
  die "failed to grant migration roles on $label"
}

# Empower the default anvil account on both local forks so the migration can be
# exercised with the well-known anvil key instead of real admin keys. Skipped
# when the migration token addresses are not configured.
grant_migration_test_roles() {
  if [[ ! -d "$CONTRACTS_DIR" ]]; then
    progress_step "Grant migration roles"
    progress_skip
    progress_info "Contracts repo not found at $CONTRACTS_DIR; skipping migration role setup."
    return 0
  fi
  if [[ -z "$MIGRATION_OLD_TOKEN" && -z "$MIGRATION_NEW_TOKEN" ]]; then
    progress_step "Grant migration roles"
    progress_skip
    progress_info "OLD_TOKEN/NEW_TOKEN not set in $ROOT_ENV; skipping migration role setup."
    return 0
  fi

  if [[ -n "$MIGRATION_OLD_TOKEN" ]]; then
    grant_roles_on_chain "Berachain" "$MIGRATION_OLD_RPC" "$MIGRATION_OLD_TOKEN"
    fund_backing_on_chain "Berachain" "$MIGRATION_OLD_RPC" "$MIGRATION_OLD_TOKEN"
  else
    progress_step "Grant migration roles: Berachain"
    progress_skip
    progress_info "OLD_TOKEN not set; skipping Berachain role setup."
  fi
  if [[ -n "$MIGRATION_NEW_TOKEN" ]]; then
    grant_roles_on_chain "Celo" "$MIGRATION_NEW_RPC" "$MIGRATION_NEW_TOKEN"
    fund_backing_on_chain "Celo" "$MIGRATION_NEW_RPC" "$MIGRATION_NEW_TOKEN"
  else
    progress_step "Grant migration roles: Celo"
    progress_skip
    progress_info "NEW_TOKEN not set; skipping Celo role setup."
  fi
}

print_phase "Chain Startup"
check_required_ports_available "Final server port check" || die "server ports are unavailable"
progress_step "Start Berachain anvil pane"
tmux new-session -d -s "$SESSION_NAME" -n migration -c "$APP_DIR" "$(pane_shell "$BERA_BODY")"
BERA_PANE="$(tmux display-message -p -t "$SESSION_NAME:0.0" "#{pane_id}")"
tmux select-pane -t "$BERA_PANE" -T "bera-anvil"
progress_ok

progress_step "Start Celo anvil pane"
CELO_PANE="$(tmux split-window -h -t "$BERA_PANE" -c "$APP_DIR" -P -F "#{pane_id}" "$(pane_shell "$CELO_BODY")")"
tmux select-pane -t "$CELO_PANE" -T "celo-anvil"
progress_ok

print_phase "Chain Boot Verification"
wait_for_service_port "Berachain anvil" "127.0.0.1" "$BERA_PORT" "$BERA_PANE" "$BOOT_WAIT_SECONDS" || die "Berachain anvil failed to boot"
wait_for_service_port "Celo anvil" "127.0.0.1" "$CELO_PORT" "$CELO_PANE" "$BOOT_WAIT_SECONDS" || die "Celo anvil failed to boot"

print_phase "Migration Test Roles"
grant_migration_test_roles

print_phase "Ponder Startup"
progress_step "Start Ponder pane"
PONDER_PANE="$(tmux split-window -v -t "$BERA_PANE" -c "$PONDER_DIR" -P -F "#{pane_id}" "$(pane_shell "$PONDER_BODY")")"
tmux select-pane -t "$PONDER_PANE" -T "ponder"
progress_ok

print_phase "Ponder Boot Verification"
wait_for_service_port "Ponder" "$PONDER_HOST" "$PONDER_PORT" "$PONDER_PANE" "$BOOT_WAIT_SECONDS" || die "Ponder failed to boot"

print_phase "App Startup"
progress_step "Start backend pane"
BACKEND_PANE="$(tmux split-window -v -t "$PONDER_PANE" -c "$BACKEND_DIR" -P -F "#{pane_id}" "$(pane_shell "$BACKEND_BODY")")"
tmux select-pane -t "$BACKEND_PANE" -T "backend"
progress_ok

progress_step "Start frontend pane"
FRONTEND_PANE="$(tmux split-window -v -t "$CELO_PANE" -c "$FRONTEND_DIR" -P -F "#{pane_id}" "$(pane_shell "$FRONTEND_BODY")")"
tmux select-pane -t "$FRONTEND_PANE" -T "frontend"
progress_ok

progress_step "Arrange tmux layout"
tmux set-option -t "$SESSION_NAME" pane-border-status top >/dev/null
tmux set-option -t "$SESSION_NAME" pane-border-format "#{pane_title}" >/dev/null
tmux select-layout -t "$SESSION_NAME:0" tiled >/dev/null
tmux select-pane -t "$BERA_PANE"
progress_ok

print_phase "App Boot Verification"
wait_for_service_port "Backend" "127.0.0.1" "$BACKEND_PORT" "$BACKEND_PANE" "$BOOT_WAIT_SECONDS" || die "backend failed to boot"
wait_for_service_port "Frontend" "127.0.0.1" "$FRONTEND_PORT" "$FRONTEND_PANE" "$BOOT_WAIT_SECONDS" || die "frontend failed to boot"

print_pane_summary

print_phase "Environment Running"
progress_info "Controller is active. Press Ctrl-C in this terminal to stop servers and delete migration databases."

if [[ "$ATTACH" == "true" ]]; then
  progress_info "Attaching to tmux. Detaching returns to the controller; Ctrl-C stops the environment."
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION_NAME" || true
  else
    tmux attach -t "$SESSION_NAME" || true
  fi
else
  progress_info "Attach from another terminal with: tmux attach -t $(shell_quote "$SESSION_NAME")"
fi

progress_info "Monitoring tmux session '$SESSION_NAME'. Press Ctrl-C here to shut everything down."
while tmux has-session -t "$SESSION_NAME" 2>/dev/null; do
  sleep 2
done

progress_info "Tmux session ended; cleaning up migration databases."
shutdown_environment
trap - EXIT
