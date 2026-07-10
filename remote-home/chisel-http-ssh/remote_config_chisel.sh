#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  remote_config_chisel.sh [options]

Run inside the remote container through e-shell.

Options:
  --local-pubkey KEY       Local SSH public key text to append to /root/.ssh/authorized_keys
  --local-pubkey-file PATH File containing local SSH public key
  --remote-home PATH       Remote home/work path (default: /public/home/tangyu408)
  --chisel-version VERSION Chisel version (default: 1.11.7)
  -h, --help               Show this help

Example:
  bash remote_config_chisel.sh \
    --local-pubkey 'ssh-ed25519 AAAA... descfly@ubuntu'
EOF
}

CHISEL_VERSION="1.11.7"
REMOTE_HOME="/public/home/tangyu408"
LOCAL_PUBKEY=""
LOCAL_PUBKEY_FILE=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local-pubkey) LOCAL_PUBKEY="${2:?Missing value for --local-pubkey}"; shift 2 ;;
    --local-pubkey-file) LOCAL_PUBKEY_FILE="${2:?Missing value for --local-pubkey-file}"; shift 2 ;;
    --remote-home) REMOTE_HOME="${2:?Missing value for --remote-home}"; shift 2 ;;
    --chisel-version) CHISEL_VERSION="${2:?Missing value for --chisel-version}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

BIN_DIR="$REMOTE_HOME/.local/bin"
WORK_DIR="$REMOTE_HOME/.local/chisel"

log() {
  printf '[remote-config] %s\n' "$*"
}

if [ "$(id -u)" -ne 0 ]; then
  log "ERROR: run as root inside the container."
  exit 1
fi

if [ -z "$LOCAL_PUBKEY" ] && [ -n "$LOCAL_PUBKEY_FILE" ]; then
  LOCAL_PUBKEY="$(cat "$LOCAL_PUBKEY_FILE")"
fi

mkdir -p "$BIN_DIR" "$WORK_DIR"

if ! command -v curl >/dev/null 2>&1 || ! command -v gzip >/dev/null 2>&1 || ! command -v sshd >/dev/null 2>&1; then
  if command -v apt-get >/dev/null 2>&1; then
    log "Installing missing packages with apt-get..."
    apt-get update
    apt-get install -y curl gzip ca-certificates openssh-server openssh-client
  else
    log "ERROR: missing curl/gzip/sshd and apt-get is unavailable."
    exit 1
  fi
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

mkdir -p /run/sshd /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys

if [ -n "$LOCAL_PUBKEY" ]; then
  if grep -qxF "$LOCAL_PUBKEY" /root/.ssh/authorized_keys; then
    log "Local public key is already present in /root/.ssh/authorized_keys"
  else
    log "Appending local public key to /root/.ssh/authorized_keys"
    printf '%s\n' "$LOCAL_PUBKEY" >> /root/.ssh/authorized_keys
  fi
else
  log "WARNING: no local public key was provided."
  log "You can append it later with: cat >> /root/.ssh/authorized_keys"
fi

chmod 600 /root/.ssh/authorized_keys
[ -f /root/.ssh/config ] && chmod 600 /root/.ssh/config
find /root/.ssh -type f -name 'id_*' ! -name '*.pub' -exec chmod 600 {} + 2>/dev/null || true
find /root/.ssh -type f -name '*.pub' -exec chmod 644 {} + 2>/dev/null || true
chown -R root:root /root/.ssh

if command -v ssh-keygen >/dev/null 2>&1; then
  ssh-keygen -A
fi

/usr/sbin/sshd -t

log "Remote configuration complete."
log "Next: run remote_start_chisel.sh --auth '<user>:<password>'."
