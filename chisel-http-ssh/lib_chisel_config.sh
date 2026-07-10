#!/usr/bin/env bash

chisel_config_file_from_args() {
  local script_dir="$1"
  shift

  local config_file="${CHISEL_HTTP_SSH_CONFIG:-$script_dir/config.env}"

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --config)
        config_file="${2:?Missing value for --config}"
        shift 2
        ;;
      --config=*)
        config_file="${1#--config=}"
        shift
        ;;
      --)
        break
        ;;
      *)
        shift
        ;;
    esac
  done

  printf '%s\n' "$config_file"
}

chisel_load_config() {
  local config_file="$1"

  if [ -f "$config_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$config_file"
    set +a
  fi
}

chisel_auth_from_config() {
  if [ -n "${CHISEL_AUTH:-}" ]; then
    printf '%s\n' "$CHISEL_AUTH"
    return 0
  fi

  if [ -n "${CHISEL_AUTH_USER:-}" ] && [ -n "${CHISEL_AUTH_PASS:-}" ]; then
    printf '%s:%s\n' "$CHISEL_AUTH_USER" "$CHISEL_AUTH_PASS"
    return 0
  fi

  printf '\n'
}
