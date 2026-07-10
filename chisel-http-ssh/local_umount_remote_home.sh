#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  local_umount_remote_home.sh [options]

Unmount the sshfs mount created by local_mount_remote_home.sh.

Options:
  --config PATH       Config env file (default: ./config.env or CHISEL_HTTP_SSH_CONFIG)
  --mount-point PATH  Local mount point (default: ./remote-home)
  --lazy              Lazy unmount
  -h, --help          Show this help

Example:
  bash local_umount_remote_home.sh
EOF
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib_chisel_config.sh"
CONFIG_FILE="$(chisel_config_file_from_args "$SCRIPT_DIR" "$@")"
chisel_load_config "$CONFIG_FILE"

MOUNT_POINT="${MOUNT_POINT:-remote-home}"
LAZY="0"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --mount-point) MOUNT_POINT="${2:?Missing value for --mount-point}"; shift 2 ;;
    --config) CONFIG_FILE="${2:?Missing value for --config}"; shift 2 ;;
    --config=*) CONFIG_FILE="${1#--config=}"; shift ;;
    --lazy) LAZY="1"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

case "$MOUNT_POINT" in
  /*) ;;
  *) MOUNT_POINT="$PWD/$MOUNT_POINT" ;;
esac

log() {
  printf '[local-umount] %s\n' "$*"
}

is_mounted() {
  mountpoint -q "$1" 2>/dev/null || findmnt -M "$1" >/dev/null 2>&1
}

if ! is_mounted "$MOUNT_POINT"; then
  log "Not mounted: $MOUNT_POINT"
  exit 0
fi

if command -v fusermount3 >/dev/null 2>&1; then
  if [ "$LAZY" = "1" ]; then
    fusermount3 -uz "$MOUNT_POINT"
  else
    fusermount3 -u "$MOUNT_POINT"
  fi
elif command -v fusermount >/dev/null 2>&1; then
  if [ "$LAZY" = "1" ]; then
    fusermount -uz "$MOUNT_POINT"
  else
    fusermount -u "$MOUNT_POINT"
  fi
else
  if [ "$LAZY" = "1" ]; then
    umount -l "$MOUNT_POINT"
  else
    umount "$MOUNT_POINT"
  fi
fi

log "Unmounted: $MOUNT_POINT"
