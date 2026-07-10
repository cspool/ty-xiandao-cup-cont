#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  local_mount_remote_home.sh [options]

Run on the local machine after local_start_chisel.sh is connected. Mounts the
remote container home into ./remote-home with sshfs.

Options:
  --config PATH           Config env file (default: ./config.env or CHISEL_HTTP_SSH_CONFIG)
  --host-alias NAME        SSH config host alias (default: worker-0-chisel)
  --remote-path PATH       Remote path to mount (default: /public/home/tangyu408)
  --mount-point PATH       Local mount point (default: ./remote-home)
  --no-owner-map           Keep remote uid/gid display instead of mapping to the local user
  --sshfs-option OPTION    Extra sshfs -o option; can be repeated
  -h, --help               Show this help

Example:
  bash local_mount_remote_home.sh
  bash local_mount_remote_home.sh --mount-point /data3/Projects/scnet_ssh/remote-home
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib_chisel_config.sh"
CONFIG_FILE="$(chisel_config_file_from_args "$SCRIPT_DIR" "$@")"
chisel_load_config "$CONFIG_FILE"

HOST_ALIAS="${HOST_ALIAS:-worker-0-chisel}"
REMOTE_PATH="${REMOTE_PATH:-${REMOTE_HOME:-/public/home/tangyu408}}"
MOUNT_POINT="${MOUNT_POINT:-remote-home}"
OWNER_MAP="1"
EXTRA_SSHFS_OPTIONS=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host-alias) HOST_ALIAS="${2:?Missing value for --host-alias}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?Missing value for --config}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#--config=}"; shift ;;
    --remote-path) REMOTE_PATH="${2:?Missing value for --remote-path}"; shift 2 ;;
    --mount-point) MOUNT_POINT="${2:?Missing value for --mount-point}"; shift 2 ;;
    --no-owner-map) OWNER_MAP="0"; shift ;;
    --sshfs-option) EXTRA_SSHFS_OPTIONS+=("${2:?Missing value for --sshfs-option}"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$MOUNT_POINT" in
  /*) ;;
  *) MOUNT_POINT="$PWD/$MOUNT_POINT" ;;
esac

log() {
  printf '[local-mount] %s\n' "$*"
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

is_mounted() {
  mountpoint -q "$1" 2>/dev/null || findmnt -M "$1" >/dev/null 2>&1
}

if ! command -v ssh >/dev/null 2>&1; then
  log "ERROR: ssh is required."
  exit 1
fi

if ! command -v sshfs >/dev/null 2>&1; then
  log "ERROR: sshfs is required. Install it locally, for example: sudo apt-get install -y sshfs"
  exit 1
fi

mkdir -p "$MOUNT_POINT"

if is_mounted "$MOUNT_POINT"; then
  log "Already mounted: $MOUNT_POINT"
  exit 0
fi

REMOTE_PATH_Q="$(shell_quote "$REMOTE_PATH")"
log "Checking SSH alias and remote path..."
ssh -o BatchMode=yes "$HOST_ALIAS" "test -d $REMOTE_PATH_Q"

SSHFS_ARGS=(
  -o reconnect
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=3
  -o follow_symlinks
)

if [ "$OWNER_MAP" = "1" ]; then
  SSHFS_ARGS+=(
    -o idmap=user
    -o "uid=$(id -u)"
    -o "gid=$(id -g)"
    -o umask=022
  )
fi

for opt in "${EXTRA_SSHFS_OPTIONS[@]}"; do
  SSHFS_ARGS+=(-o "$opt")
done

log "Mounting $HOST_ALIAS:$REMOTE_PATH -> $MOUNT_POINT"
sshfs "${SSHFS_ARGS[@]}" "$HOST_ALIAS:$REMOTE_PATH" "$MOUNT_POINT"

log "Mounted. Test with: ls -la '$MOUNT_POINT'"
