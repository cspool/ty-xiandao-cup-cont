#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  local_start_chisel.sh [--platform-url URL] [--auth USER:PASS] [options]

Run on the local machine. Starts the local chisel client and opens
localhost:2222 as an SSH endpoint to the remote container.

Options:
  --config PATH          Config env file (default: ./config.env or CHISEL_HTTP_SSH_CONFIG)
  --platform-url URL      Platform HTTP service URL ending in / (required unless set in config)
  --auth USER:PASS       Chisel auth credential matching server (required unless set in config)
  --local-bind HOST      Local bind host (default: 127.0.0.1)
  --local-port PORT      Local SSH tunnel port (default: 2222)
  --remote-ssh-host HOST Remote SSH host as seen from container chisel server (default: 127.0.0.1)
  --remote-ssh-port PORT Remote SSH port as seen from container chisel server (default: 22)
  --chisel-bin PATH      Local chisel binary (default: ~/.local/bin/chisel)
  -h, --help             Show this help

Example:
  bash local_start_chisel.sh
  bash local_start_chisel.sh --config ./config.env
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib_chisel_config.sh"
CONFIG_FILE="$(chisel_config_file_from_args "$SCRIPT_DIR" "$@")"
chisel_load_config "$CONFIG_FILE"

PLATFORM_URL="${PLATFORM_URL:-}"
AUTH="$(chisel_auth_from_config)"
CHISEL_BIN="${CHISEL_BIN:-$HOME/.local/bin/chisel}"
LOCAL_BIND="${LOCAL_BIND:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-2222}"
REMOTE_SSH_HOST="${REMOTE_SSH_HOST:-127.0.0.1}"
REMOTE_SSH_PORT="${REMOTE_SSH_PORT:-22}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --platform-url) PLATFORM_URL="${2:?Missing value for --platform-url}"; shift 2 ;;
    --auth) AUTH="${2:?Missing value for --auth}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?Missing value for --config}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#--config=}"; shift ;;
    --local-bind) LOCAL_BIND="${2:?Missing value for --local-bind}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:?Missing value for --local-port}"; shift 2 ;;
    --remote-ssh-host) REMOTE_SSH_HOST="${2:?Missing value for --remote-ssh-host}"; shift 2 ;;
    --remote-ssh-port) REMOTE_SSH_PORT="${2:?Missing value for --remote-ssh-port}"; shift 2 ;;
    --chisel-bin) CHISEL_BIN="${2:?Missing value for --chisel-bin}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$PLATFORM_URL" ]; then
  echo "ERROR: --platform-url URL is required unless PLATFORM_URL is set in config." >&2
  usage
  exit 2
fi

if [ -z "$AUTH" ]; then
  echo "ERROR: --auth USER:PASS is required unless CHISEL_AUTH or CHISEL_AUTH_USER/PASS is set in config." >&2
  usage
  exit 2
fi

log() {
  printf '[local-start] %s\n' "$*"
}

if [ ! -x "$CHISEL_BIN" ]; then
  log "ERROR: chisel not found at $CHISEL_BIN. Run local_config_chisel.sh first."
  exit 1
fi

case "$PLATFORM_URL" in
  */) ;;
  *) PLATFORM_URL="${PLATFORM_URL}/" ;;
esac

if command -v ss >/dev/null 2>&1; then
  if ss -tln | awk '{print $4}' | grep -Eq "(^|:)$LOCAL_PORT$"; then
    log "WARNING: local port $LOCAL_PORT already appears to be listening."
  fi
fi

log "Starting chisel client."
log "Local SSH endpoint: $LOCAL_BIND:$LOCAL_PORT -> remote $REMOTE_SSH_HOST:$REMOTE_SSH_PORT"

exec "$CHISEL_BIN" client \
  --auth "$AUTH" \
  -v \
  "$PLATFORM_URL" \
  "$LOCAL_BIND:$LOCAL_PORT:$REMOTE_SSH_HOST:$REMOTE_SSH_PORT"
