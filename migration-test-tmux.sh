#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT_DIR/repos/app"
BACKEND_DIR="$APP_DIR/backend"
FRONTEND_DIR="$APP_DIR/frontend"

SESSION_NAME="${SESSION_NAME:-sfluv-migration-test}"
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
BACKEND_ENV="${BACKEND_ENV:-$BACKEND_DIR/.env}"
FRONTEND_SCRIPT="${FRONTEND_SCRIPT:-dev-http}"
NOTIFICATION_TEST_MODE="${NOTIFICATION_TEST_MODE:-false}"
ATTACH="true"
REPLACE_SESSION="false"
CHECK_PORTS="true"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Starts a tmux session with four panes:
  1. Berachain anvil fork
  2. Celo anvil fork
  3. Backend using a generated local Berachain config
  4. Frontend

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
  --backend-env PATH             Backend env file. Default: repos/app/backend/.env.
  --frontend-script NAME         pnpm script for frontend. Default: dev-http.
  --notification-test-mode BOOL  Backend notification sink env. Default: false.
  --session NAME                 tmux session name. Default: sfluv-migration-test.
  --replace                      Kill an existing session with the same name first.
  --no-attach                    Start panes but do not attach/switch to the session.
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

require_cmd tmux
require_cmd anvil
require_cmd node
require_cmd go
require_cmd pnpm

if [[ "$CHECK_PORTS" == "true" ]] && command -v lsof >/dev/null 2>&1; then
  for port in "$BERA_PORT" "$CELO_PORT" "$BACKEND_PORT" "$FRONTEND_PORT"; do
    if lsof -ti :"$port" -sTCP:LISTEN >/dev/null 2>&1; then
      die "port $port is already in use. Stop that process or rerun with --no-port-check."
    fi
  done
fi

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
  if [[ "$REPLACE_SESSION" == "true" ]]; then
    tmux kill-session -t "$SESSION_NAME"
  else
    die "tmux session '$SESSION_NAME' already exists. Use --replace or --session NAME."
  fi
fi

BERA_LOCAL_RPC="http://127.0.0.1:$BERA_PORT"
BERA_LOCAL_WS="ws://127.0.0.1:$BERA_PORT"
BACKEND_URL="http://127.0.0.1:$BACKEND_PORT"
FRONTEND_URL="http://127.0.0.1:$FRONTEND_PORT"
LOCAL_CONFIG_DIR="$BACKEND_DIR/.migration-local"
LOCAL_CONFIG="$LOCAL_CONFIG_DIR/community-config.berachain-local.json"
NOTIFICATION_DIR="$BACKEND_DIR/test-notifications"

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

Panes
-----
Berachain anvil
  Target:  $SESSION_NAME:0.0
  RPC:     $BERA_LOCAL_RPC
  Access:  $(pane_attach_command "$SESSION_NAME:0.0")

Celo anvil
  Target:  $SESSION_NAME:0.1
  RPC:     http://127.0.0.1:$CELO_PORT
  Access:  $(pane_attach_command "$SESSION_NAME:0.1")

Backend
  Target:  $SESSION_NAME:0.2
  URL:     $BACKEND_URL
  Access:  $(pane_attach_command "$SESSION_NAME:0.2")

Frontend
  Target:  $SESSION_NAME:0.3
  URL:     $FRONTEND_URL
  Access:  $(pane_attach_command "$SESSION_NAME:0.3")

Full session
  Access:  tmux attach -t $(shell_quote "$SESSION_NAME")

SUMMARY
}

BERA_BODY="printf '%s\n' $(shell_quote "Berachain anvil fork -> $BERA_LOCAL_RPC")
anvil --host 127.0.0.1 --port $(shell_quote "$BERA_PORT") --fork-url $(shell_quote "$BERA_RPC")$(fork_block_arg "$BERA_FORK_BLOCK")"

CELO_BODY="printf '%s\n' $(shell_quote "Celo anvil fork -> http://127.0.0.1:$CELO_PORT")
anvil --host 127.0.0.1 --port $(shell_quote "$CELO_PORT") --fork-url $(shell_quote "$CELO_RPC")$(fork_block_arg "$CELO_FORK_BLOCK")"

BACKEND_BODY="printf '%s\n' $(shell_quote "Backend -> $BACKEND_URL")
printf '%s\n' $(shell_quote "Local client config -> $LOCAL_CONFIG")
printf '%s\n' $(shell_quote "Notification test mode -> $NOTIFICATION_TEST_MODE")
ENV_FILE=$(shell_quote "$BACKEND_ENV") \
PORT=$(shell_quote "$BACKEND_PORT") \
APP_BASE_URL=$(shell_quote "$FRONTEND_URL") \
PUBLIC_BACKEND_URL=$(shell_quote "$BACKEND_URL") \
CLIENT_CONFIG_LOCAL_ONLY=true \
CLIENT_CONFIG_FALLBACK_PATH=$(shell_quote "$LOCAL_CONFIG") \
NOTIFICATION_TEST_MODE=$(shell_quote "$NOTIFICATION_TEST_MODE") \
NOTIFICATION_TEST_OUTPUT_DIR=$(shell_quote "$NOTIFICATION_DIR") \
go run ./cmd/server"

FRONTEND_BODY="printf '%s\n' $(shell_quote "Frontend -> $FRONTEND_URL")
NEXT_PUBLIC_BACKEND_URL=$(shell_quote "$BACKEND_URL") \
NEXT_PUBLIC_BACKEND_BASE_URL=$(shell_quote "$BACKEND_URL") \
NEXT_PUBLIC_APP_BASE_URL=$(shell_quote "$FRONTEND_URL") \
pnpm run $(shell_quote "$FRONTEND_SCRIPT") -- --hostname 0.0.0.0 --port $(shell_quote "$FRONTEND_PORT")"

tmux new-session -d -s "$SESSION_NAME" -n migration -c "$APP_DIR" "$(pane_shell "$BERA_BODY")"
tmux select-pane -t "$SESSION_NAME:0.0" -T "bera-anvil"
tmux split-window -h -t "$SESSION_NAME:0.0" -c "$APP_DIR" "$(pane_shell "$CELO_BODY")"
tmux select-pane -t "$SESSION_NAME:0.1" -T "celo-anvil"
tmux split-window -v -t "$SESSION_NAME:0.0" -c "$BACKEND_DIR" "$(pane_shell "$BACKEND_BODY")"
tmux select-pane -t "$SESSION_NAME:0.2" -T "backend"
tmux split-window -v -t "$SESSION_NAME:0.1" -c "$FRONTEND_DIR" "$(pane_shell "$FRONTEND_BODY")"
tmux select-pane -t "$SESSION_NAME:0.3" -T "frontend"
tmux set-option -t "$SESSION_NAME" pane-border-status top >/dev/null
tmux set-option -t "$SESSION_NAME" pane-border-format "#{pane_title}" >/dev/null
tmux select-layout -t "$SESSION_NAME:0" tiled >/dev/null
tmux select-pane -t "$SESSION_NAME:0.0"

print_pane_summary

if [[ "$ATTACH" == "true" ]]; then
  if [[ -n "${TMUX:-}" ]]; then
    tmux switch-client -t "$SESSION_NAME"
  else
    tmux attach -t "$SESSION_NAME"
  fi
else
  echo "Attach later with: tmux attach -t $SESSION_NAME"
fi
