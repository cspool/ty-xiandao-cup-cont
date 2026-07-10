#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  remote_start_chisel.sh --auth USER:PASS [options]

Run inside the remote container. Starts sshd on port 22 and chisel server on
the HTTP service port.

Options:
  --auth USER:PASS        Chisel server auth credential (required)
  --remote-home PATH      Remote home/work path (default: /public/home/tangyu408)
  --chisel-port PORT      Container HTTP service port for chisel (default: 8080)
  --sshd-port PORT        Container sshd port (default: 22)
  --detach                Run chisel server in background
  --log-file PATH         Background log path (default: REMOTE_HOME/chisel-server.log)
  --keep-code-server      Do not stop code-server before binding chisel port
  --restart-sshd          Kill existing sshd before starting
  --restart-chisel        Kill existing chisel before binding chisel port (default)
  --no-restart-chisel     Do not kill existing chisel; fail if chisel port is in use
  -h, --help              Show this help

Example:
  bash remote_start_chisel.sh --auth 'user:strong-password'
EOF
}

AUTH=""
REMOTE_HOME="/public/home/tangyu408"
CHISEL_PORT="8080"
SSHD_PORT="22"
DETACH="0"
STOP_CODE_SERVER="1"
RESTART_SSHD="0"
RESTART_CHISEL="1"
LOG_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --auth) AUTH="${2:?Missing value for --auth}"; shift 2 ;;
    --remote-home) REMOTE_HOME="${2:?Missing value for --remote-home}"; shift 2 ;;
    --chisel-port) CHISEL_PORT="${2:?Missing value for --chisel-port}"; shift 2 ;;
    --sshd-port) SSHD_PORT="${2:?Missing value for --sshd-port}"; shift 2 ;;
    --detach) DETACH="1"; shift ;;
    --log-file) LOG_FILE="${2:?Missing value for --log-file}"; shift 2 ;;
    --keep-code-server) STOP_CODE_SERVER="0"; shift ;;
    --restart-sshd) RESTART_SSHD="1"; shift ;;
    --restart-chisel) RESTART_CHISEL="1"; shift ;;
    --no-restart-chisel) RESTART_CHISEL="0"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -z "$AUTH" ]; then
  echo "ERROR: --auth USER:PASS is required." >&2
  usage
  exit 2
fi

BIN_DIR="$REMOTE_HOME/.local/bin"
CHISEL_BIN="$BIN_DIR/chisel"
LOG_FILE="${LOG_FILE:-$REMOTE_HOME/chisel-server.log}"

log() {
  printf '[remote-start] %s\n' "$*"
}

if [ "$(id -u)" -ne 0 ]; then
  log "ERROR: run as root inside the container."
  exit 1
fi

if [ ! -x "$CHISEL_BIN" ]; then
  log "ERROR: chisel not found at $CHISEL_BIN. Run remote_config_chisel.sh first."
  exit 1
fi

port_listening() {
  port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -tln | awk '{print $4}' | grep -Eq "(^|:)$port$"
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tln | awk '{print $4}' | grep -Eq "(^|:)$port$"
  else
    return 1
  fi
}

port_listener_details() {
  port="$1"
  if command -v ss >/dev/null 2>&1; then
    ss -H -tlnp "sport = :$port" 2>/dev/null || ss -tlnp 2>/dev/null | awk -v port="$port" '$4 ~ "(^|:)" port "$" { print }'
  elif command -v netstat >/dev/null 2>&1; then
    netstat -tlnp 2>/dev/null | awk -v port="$port" '$4 ~ "(^|:)" port "$" { print }'
  fi
}

log_port_listener() {
  port="$1"
  details="$(port_listener_details "$port" || true)"
  if [ -n "$details" ]; then
    printf '%s\n' "$details" | while IFS= read -r line; do
      log "listener: $line"
    done
  fi
}

mkdir -p /run/sshd

if [ "$RESTART_SSHD" = "1" ]; then
  log "Restarting sshd..."
  pkill -x sshd 2>/dev/null || true
fi

if port_listening "$SSHD_PORT"; then
  log "sshd already appears to be listening on port $SSHD_PORT"
else
  log "Starting sshd on port $SSHD_PORT"
  /usr/sbin/sshd \
    -o PermitRootLogin=yes \
    -o PubkeyAuthentication=yes \
    -o PasswordAuthentication=no \
    -p "$SSHD_PORT"
fi

if [ "$STOP_CODE_SERVER" = "1" ]; then
  pkill -f code-server 2>/dev/null || true
fi

if [ "$RESTART_CHISEL" = "1" ]; then
  if pgrep -x chisel >/dev/null 2>&1; then
    log "Stopping existing chisel processes before binding port $CHISEL_PORT..."
    pkill -x chisel 2>/dev/null || true
    sleep 1
  fi
fi

if port_listening "$CHISEL_PORT"; then
  if [ "$RESTART_CHISEL" = "1" ]; then
    log "ERROR: port $CHISEL_PORT is still in use after stopping chisel."
    log_port_listener "$CHISEL_PORT"
    exit 1
  else
    log "ERROR: port $CHISEL_PORT is already in use."
    log_port_listener "$CHISEL_PORT"
    log "If this is the chisel server you already started, leave it running and start local_start_chisel.sh locally."
    log "If it is stale or the auth changed, rerun without --no-restart-chisel."
    exit 1
  fi
fi

cmd=(
  "$CHISEL_BIN" server
  --host 0.0.0.0
  --port "$CHISEL_PORT"
  --auth "$AUTH"
  -v
)

if [ "$DETACH" = "1" ]; then
  log "Starting chisel server in background. Log: $LOG_FILE"
  nohup "${cmd[@]}" > "$LOG_FILE" 2>&1 &
  log "chisel server pid: $!"
else
  log "Starting chisel server in foreground on 0.0.0.0:$CHISEL_PORT"
  exec "${cmd[@]}"
fi
