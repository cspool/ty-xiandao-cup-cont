#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  local_remote_exec.sh [options] -- COMMAND [ARGS...]
  local_remote_exec.sh [options] --shell 'COMMAND STRING'

Run on the local machine. Executes a command inside the remote container over
SSH, mapping the current sshfs-mounted local directory back to the matching
remote directory.

Options:
  --host-alias NAME      SSH config host alias (default: worker-0-chisel)
  --remote-path PATH     Remote path mounted locally (default: /public/home/tangyu408)
  --mount-point PATH     Local sshfs mount point (default: inferred from .codex helper)
  --cwd PATH             Local cwd to map to the remote path (default: current directory)
  --shell COMMAND        Run COMMAND through remote bash -lc
  --print-cwd            Print the mapped remote cwd and exit
  --ssh-option OPTION    Extra ssh option; can be repeated
  -h, --help             Show this help

Examples:
  ./.codex/remote_exec -- pwd
  ./.codex/remote_exec --shell 'pwd && python -V'
EOF
}

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
env_file="$script_dir/remote_exec.env"

if [ -f "$env_file" ]; then
  # shellcheck disable=SC1090
  . "$env_file"
fi

HOST_ALIAS="${REMOTE_EXEC_HOST_ALIAS:-worker-0-chisel}"
REMOTE_PATH="${REMOTE_EXEC_REMOTE_PATH:-/public/home/tangyu408}"
MOUNT_POINT="${REMOTE_EXEC_MOUNT_POINT:-}"
CWD="$PWD"
MODE="argv"
SHELL_COMMAND=""
PRINT_CWD="0"
SSH_OPTIONS=()
REMOTE_ARGS=()

if [ -z "$MOUNT_POINT" ]; then
  if [ "$(basename -- "$script_dir")" = ".codex" ]; then
    MOUNT_POINT="$(dirname -- "$script_dir")"
  else
    MOUNT_POINT="$PWD"
  fi
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --host-alias) HOST_ALIAS="${2:?Missing value for --host-alias}"; shift 2 ;;
    --remote-path) REMOTE_PATH="${2:?Missing value for --remote-path}"; shift 2 ;;
    --mount-point) MOUNT_POINT="${2:?Missing value for --mount-point}"; shift 2 ;;
    --cwd) CWD="${2:?Missing value for --cwd}"; shift 2 ;;
    --shell) MODE="shell"; SHELL_COMMAND="${2:?Missing value for --shell}"; shift 2 ;;
    --print-cwd) PRINT_CWD="1"; shift ;;
    --ssh-option) SSH_OPTIONS+=("${2:?Missing value for --ssh-option}"); shift 2 ;;
    --) shift; REMOTE_ARGS=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) REMOTE_ARGS+=("$1"); shift ;;
  esac
done

abs_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

shell_quote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

MOUNT_POINT="$(abs_path "$MOUNT_POINT")"
CWD="$(abs_path "$CWD")"
REMOTE_PATH="${REMOTE_PATH%/}"

case "$CWD" in
  "$MOUNT_POINT")
    REMOTE_CWD="$REMOTE_PATH"
    ;;
  "$MOUNT_POINT"/*)
    suffix="${CWD#"$MOUNT_POINT"/}"
    REMOTE_CWD="$REMOTE_PATH/$suffix"
    ;;
  *)
    REMOTE_CWD="$REMOTE_PATH"
    printf '[remote-exec] WARNING: cwd is outside mount point; using %s\n' "$REMOTE_CWD" >&2
    ;;
esac

if [ "$PRINT_CWD" = "1" ]; then
  printf '%s\n' "$REMOTE_CWD"
  exit 0
fi

if ! command -v ssh >/dev/null 2>&1; then
  printf '[remote-exec] ERROR: ssh is required on the local machine.\n' >&2
  exit 1
fi

remote_cd="$(shell_quote "$REMOTE_CWD")"

if [ "$MODE" = "shell" ]; then
  remote_shell="$(shell_quote "$SHELL_COMMAND")"
  exec ssh "${SSH_OPTIONS[@]}" "$HOST_ALIAS" "cd $remote_cd && exec bash -lc $remote_shell"
fi

if [ "${#REMOTE_ARGS[@]}" -eq 0 ]; then
  exec ssh -t "${SSH_OPTIONS[@]}" "$HOST_ALIAS" "cd $remote_cd && exec bash -l"
fi

remote_command="exec"
for arg in "${REMOTE_ARGS[@]}"; do
  remote_command="$remote_command $(shell_quote "$arg")"
done

exec ssh "${SSH_OPTIONS[@]}" "$HOST_ALIAS" "cd $remote_cd && $remote_command"
