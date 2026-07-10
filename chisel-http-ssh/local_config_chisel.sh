#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  local_config_chisel.sh [options]

Run on the local machine. Installs chisel locally, prints the local SSH public
key, and optionally writes an SSH config entry for VS Code Remote-SSH.

Options:
  --config PATH           Config env file (default: ./config.env or CHISEL_HTTP_SSH_CONFIG)
  --ssh-key PATH           SSH private key path (default: ~/.ssh/id_ed25519)
  --generate-key           Generate SSH key if missing
  --host-alias NAME        SSH config host alias (default: worker-0-chisel)
  --local-bind HOST        Local bind host (default: 127.0.0.1)
  --local-port PORT        Local SSH tunnel port (default: 2222)
  --ssh-user USER          Remote SSH user (default: root)
  --no-ssh-config          Do not write ~/.ssh/config
  --chisel-version VERSION Chisel version (default: 1.11.7)
  -h, --help               Show this help

Example:
  bash local_config_chisel.sh --generate-key
  bash local_config_chisel.sh --config ./config.env --generate-key
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib_chisel_config.sh"
CONFIG_FILE="$(chisel_config_file_from_args "$SCRIPT_DIR" "$@")"
chisel_load_config "$CONFIG_FILE"

CHISEL_VERSION="${CHISEL_VERSION:-1.11.7}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"
GENERATE_KEY="0"
WRITE_SSH_CONFIG="1"
SSH_CONFIG="$HOME/.ssh/config"
SSH_HOST_ALIAS="${SSH_HOST_ALIAS:-${HOST_ALIAS:-worker-0-chisel}}"
LOCAL_BIND="${LOCAL_BIND:-127.0.0.1}"
LOCAL_PORT="${LOCAL_PORT:-2222}"
SSH_USER="${SSH_USER:-root}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ssh-key) SSH_KEY="${2:?Missing value for --ssh-key}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?Missing value for --config}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#--config=}"; shift ;;
    --generate-key) GENERATE_KEY="1"; shift ;;
    --host-alias) SSH_HOST_ALIAS="${2:?Missing value for --host-alias}"; shift 2 ;;
    --local-bind) LOCAL_BIND="${2:?Missing value for --local-bind}"; shift 2 ;;
    --local-port) LOCAL_PORT="${2:?Missing value for --local-port}"; shift 2 ;;
    --ssh-user) SSH_USER="${2:?Missing value for --ssh-user}"; shift 2 ;;
    --no-ssh-config) WRITE_SSH_CONFIG="0"; shift ;;
    --chisel-version) CHISEL_VERSION="${2:?Missing value for --chisel-version}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

BIN_DIR="$HOME/.local/bin"
WORK_DIR="$HOME/.local/chisel"

log() {
  printf '[local-config] %s\n' "$*"
}

mkdir -p "$BIN_DIR" "$WORK_DIR" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if ! command -v curl >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1; then
  log "ERROR: curl and gzip are required on the local machine."
  exit 1
fi

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) PKG="chisel_${CHISEL_VERSION}_linux_amd64.gz" ;;
  aarch64|arm64) PKG="chisel_${CHISEL_VERSION}_linux_arm64.gz" ;;
  *) log "ERROR: unsupported architecture: $ARCH"; exit 1 ;;
esac

if [ ! -x "$BIN_DIR/chisel" ]; then
  log "Downloading chisel $CHISEL_VERSION for $ARCH..."
  curl -L -o "$WORK_DIR/$PKG" "https://github.com/jpillora/chisel/releases/download/v${CHISEL_VERSION}/$PKG"
  gunzip -c "$WORK_DIR/$PKG" > "$BIN_DIR/chisel"
  chmod +x "$BIN_DIR/chisel"
else
  log "chisel already exists at $BIN_DIR/chisel"
fi

"$BIN_DIR/chisel" --version || true

if [ ! -f "$SSH_KEY" ]; then
  if [ "$GENERATE_KEY" = "1" ]; then
    log "Generating SSH key at $SSH_KEY"
    ssh-keygen -t ed25519 -N "" -f "$SSH_KEY"
  else
    log "WARNING: SSH key not found at $SSH_KEY"
    log "Set --generate-key to create one, or pass --ssh-key /path/to/key."
  fi
fi

if [ -f "$SSH_KEY.pub" ]; then
  log "Copy this public key into remote_config_chisel.sh --local-pubkey:"
  printf '%s\n' "-----BEGIN LOCAL PUBLIC KEY-----"
  cat "$SSH_KEY.pub"
  printf '%s\n' "-----END LOCAL PUBLIC KEY-----"
else
  log "WARNING: public key not found at $SSH_KEY.pub"
fi

if [ "$WRITE_SSH_CONFIG" = "1" ]; then
  touch "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"
  backup="$SSH_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp "$SSH_CONFIG" "$backup"

  tmp="$(mktemp)"
  awk -v alias="$SSH_HOST_ALIAS" '
    $0 == "# BEGIN CHISEL " alias { skip = 1; next }
    $0 == "# END CHISEL " alias { skip = 0; next }
    !skip { print }
  ' "$SSH_CONFIG" > "$tmp"

  {
    printf '\n# BEGIN CHISEL %s\n' "$SSH_HOST_ALIAS"
    printf 'Host %s\n' "$SSH_HOST_ALIAS"
    printf '  HostName %s\n' "$LOCAL_BIND"
    printf '  Port %s\n' "$LOCAL_PORT"
    printf '  User %s\n' "$SSH_USER"
    printf '  IdentityFile %s\n' "$SSH_KEY"
    printf '# END CHISEL %s\n' "$SSH_HOST_ALIAS"
  } >> "$tmp"

  mv "$tmp" "$SSH_CONFIG"
  chmod 600 "$SSH_CONFIG"

  log "Updated SSH config: $SSH_CONFIG"
  log "Backup saved: $backup"
  if ! ssh -F "$SSH_CONFIG" -G "$SSH_HOST_ALIAS" >/dev/null 2>&1; then
    log "WARNING: ssh reports a config error. Inspect $SSH_CONFIG and $backup."
    log "You can still test with: ssh -F /dev/null -i '$SSH_KEY' $SSH_USER@$LOCAL_BIND -p $LOCAL_PORT"
  fi
fi

log "Local configuration complete."
log "Next: fill config.env, then run local_start_chisel.sh."
