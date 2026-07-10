#!/usr/bin/env bash
set -euo pipefail

# Run inside the remote container. This script follows the SCNet debug doc from
# a clean persistent work directory: clone/build vLLM, download testdata, start
# vLLM, then run throughput and accuracy tests. The model is expected to be
# baked into the image at /root/Qwen3.5-27B by default.

WORKDIR="${WORKDIR:-/public/home/tangyu408}"
VLLM_REPO_URL="${VLLM_REPO_URL:-http://developer.sourcefind.cn/codes/OpenDAS/vllm_cscc.git}"
VLLM_BRANCH="${VLLM_BRANCH:-v0.18.1}"
VLLM_DIR="${VLLM_DIR:-$WORKDIR/vllm_cscc}"
MODEL_ID="${MODEL_ID:-Qwen/Qwen3.5-27B}"
MODEL_DIR="${MODEL_DIR:-$WORKDIR/Qwen3.5-27B}"
ROOT_MODEL_DIR="${ROOT_MODEL_DIR:-/root/Qwen3.5-27B}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-0}"
COPY_MODEL_TO_ROOT="${COPY_MODEL_TO_ROOT:-0}"
LINK_IMAGE_MODEL="${LINK_IMAGE_MODEL:-1}"
TESTDATA_URL="${TESTDATA_URL:-https://zzefile.scnet.cn:65011/efile/s/d/c2N5MTE1OTkxMDU1OQ==/a927e65672549b46}"
TESTDATA_ARCHIVE="${TESTDATA_ARCHIVE:-$WORKDIR/testdata.tar.gz}"
TESTDATA_DIR="${TESTDATA_DIR:-$WORKDIR/testdata}"
CACHE_DIR="${CACHE_DIR:-$WORKDIR/.cache}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-$CACHE_DIR/pip}"
export MODELSCOPE_CACHE="${MODELSCOPE_CACHE:-$CACHE_DIR/modelscope}"
export TMPDIR="${TMPDIR:-$WORKDIR/tmp}"
export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="127.0.0.1,localhost,${no_proxy:-}"
VLLM_PORT="${VLLM_PORT:-8001}"
WAIT_ATTEMPTS="${WAIT_ATTEMPTS:-120}"
WAIT_SECONDS="${WAIT_SECONDS:-5}"
RUN_THROUGHPUT="${RUN_THROUGHPUT:-1}"
RUN_ACCURACY="${RUN_ACCURACY:-1}"
THROUGHPUT_ARGS="${THROUGHPUT_ARGS:-}"
ACCURACY_ARGS="${ACCURACY_ARGS:-}"
KEEP_SERVER="${KEEP_SERVER:-0}"

RUN_ID="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="${LOG_DIR:-$WORKDIR/xiandao_logs/$RUN_ID}"
SERVER_LOG="$LOG_DIR/vllm_server.log"
SERVER_PID_FILE="$LOG_DIR/vllm_server.pid"
STARTED_SERVER=0
SERVER_PID=""

log() {
  printf '[full-setup] %s\n' "$*"
}

die() {
  printf '[full-setup] ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

cleanup() {
  if [ "$KEEP_SERVER" != "1" ] && [ "$STARTED_SERVER" = "1" ] && [ -n "$SERVER_PID" ]; then
    if kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      log "Stopping vLLM server pid $SERVER_PID. Set KEEP_SERVER=1 to leave it running."
      kill "$SERVER_PID" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup EXIT

latest_vllm_wheel() {
  local wheel
  wheel="$(ls -t "$VLLM_DIR"/dist/vllm-*.whl 2>/dev/null | head -n 1 || true)"
  [ -n "$wheel" ] || die "no vLLM wheel found under $VLLM_DIR/dist"
  printf '%s\n' "$wheel"
}

clone_and_build_vllm() {
  if [ ! -d "$VLLM_DIR/.git" ]; then
    log "Cloning vLLM source to $VLLM_DIR"
    git clone -b "$VLLM_BRANCH" --depth 1 "$VLLM_REPO_URL" "$VLLM_DIR"
  else
    log "vLLM source already exists: $VLLM_DIR"
  fi

  log "Building vLLM wheel"
  cd "$VLLM_DIR"
  python setup.py bdist_wheel

  local wheel
  wheel="$(latest_vllm_wheel)"
  log "Installing vLLM wheel: $wheel"
  python -m pip install "$wheel" --no-deps
}

download_model_to_workdir() {
  if [ -f "$MODEL_DIR/config.json" ]; then
    log "Model already exists: $MODEL_DIR"
    return
  fi

  if [ "$DOWNLOAD_MODEL" != "1" ]; then
    die "model not found at $ROOT_MODEL_DIR or $MODEL_DIR, and DOWNLOAD_MODEL=0. Check the image model path or set DOWNLOAD_MODEL=1 to download into $MODEL_DIR."
  fi

  if ! command -v modelscope >/dev/null 2>&1; then
    log "Installing modelscope"
    python -m pip install modelscope
  fi

  log "Downloading model $MODEL_ID to $MODEL_DIR"
  cd "$WORKDIR"
  modelscope download --model "$MODEL_ID" --local_dir "$MODEL_DIR"
}

copy_model_to_root() {
  case "$ROOT_MODEL_DIR" in
    /root/*) ;;
    *) die "ROOT_MODEL_DIR must stay under /root for safety: $ROOT_MODEL_DIR" ;;
  esac

  if [ -f "$ROOT_MODEL_DIR/config.json" ]; then
    log "Root model copy already exists: $ROOT_MODEL_DIR"
    return
  fi

  [ -d "$MODEL_DIR" ] || die "model directory not found: $MODEL_DIR"
  log "Copying model to $ROOT_MODEL_DIR"
  mkdir -p "$(dirname "$ROOT_MODEL_DIR")"
  cp -a "$MODEL_DIR" "$ROOT_MODEL_DIR"
}

link_image_model_into_workdir() {
  [ "$LINK_IMAGE_MODEL" = "1" ] || return
  [ -f "$ROOT_MODEL_DIR/config.json" ] || return

  if [ -e "$MODEL_DIR" ] || [ -L "$MODEL_DIR" ]; then
    [ -f "$MODEL_DIR/config.json" ] || die "$MODEL_DIR exists but is not a usable model directory"
    log "Workdir model path is available: $MODEL_DIR"
    return
  fi

  log "Linking image model for testdata scripts: $MODEL_DIR -> $ROOT_MODEL_DIR"
  mkdir -p "$(dirname "$MODEL_DIR")"
  ln -s "$ROOT_MODEL_DIR" "$MODEL_DIR"
}

prepare_model() {
  case "$ROOT_MODEL_DIR" in
    /root/*) ;;
    *) die "ROOT_MODEL_DIR must stay under /root for safety: $ROOT_MODEL_DIR" ;;
  esac

  if [ -f "$ROOT_MODEL_DIR/config.json" ]; then
    log "Using image model: $ROOT_MODEL_DIR"
    link_image_model_into_workdir
    return
  fi

  download_model_to_workdir
  if [ "$COPY_MODEL_TO_ROOT" = "1" ]; then
    copy_model_to_root
  else
    log "Using workdir model without copying to /root: $MODEL_DIR"
  fi
}

download_testdata() {
  if [ -f "$TESTDATA_DIR/start_vllm.sh" ] \
    && [ -f "$TESTDATA_DIR/run_throughput.sh" ] \
    && [ -f "$TESTDATA_DIR/run_accuracy.sh" ]; then
    log "Testdata already exists: $TESTDATA_DIR"
  else
    log "Downloading testdata archive"
    cd "$WORKDIR"
    curl -f -L -C - -o "$TESTDATA_ARCHIVE" "$TESTDATA_URL"

    log "Extracting testdata to $TESTDATA_DIR"
    mkdir -p "$TESTDATA_DIR"
    tar -xzf "$TESTDATA_ARCHIVE" -C "$TESTDATA_DIR" --strip-components=1
  fi

  for required in start_vllm.sh run_throughput.sh run_accuracy.sh; do
    [ -f "$TESTDATA_DIR/$required" ] || die "missing $TESTDATA_DIR/$required"
  done
  chmod +x "$TESTDATA_DIR"/*.sh
}

vllm_ready() {
  curl --noproxy '*' -fsS "http://127.0.0.1:$VLLM_PORT/v1/models" >/dev/null 2>&1
}

start_vllm_server() {
  if vllm_ready; then
    log "vLLM server is already running on 127.0.0.1:$VLLM_PORT"
    return
  fi

  log "Starting vLLM server in background; log: $SERVER_LOG"
  cd "$TESTDATA_DIR"
  nohup ./start_vllm.sh >"$SERVER_LOG" 2>&1 &
  SERVER_PID="$!"
  STARTED_SERVER=1
  printf '%s\n' "$SERVER_PID" > "$SERVER_PID_FILE"
}

wait_for_vllm_server() {
  log "Waiting for vLLM server on 127.0.0.1:$VLLM_PORT"
  for attempt in $(seq 1 "$WAIT_ATTEMPTS"); do
    if vllm_ready; then
      log "vLLM server is ready"
      return
    fi
    if [ "$STARTED_SERVER" = "1" ] && ! kill -0 "$SERVER_PID" >/dev/null 2>&1; then
      tail -n 80 "$SERVER_LOG" >&2 || true
      die "vLLM server process exited before becoming ready"
    fi
    log "Still waiting ($attempt/$WAIT_ATTEMPTS)"
    sleep "$WAIT_SECONDS"
  done
  tail -n 80 "$SERVER_LOG" >&2 || true
  die "vLLM server did not become ready in time"
}

smoke_test() {
  log "Running one chat completion smoke test"
  curl --noproxy '*' -fsS "http://127.0.0.1:$VLLM_PORT/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen3.5-27B","messages":[{"role":"user","content":"Reply with one short sentence."}],"temperature":0.0,"max_tokens":64}' \
    >/dev/null
}

run_benchmarks() {
  cd "$TESTDATA_DIR"

  if [ "$RUN_THROUGHPUT" = "1" ]; then
    log "Running throughput test"
    if [ -n "$THROUGHPUT_ARGS" ]; then
      # Intentionally split THROUGHPUT_ARGS, e.g. THROUGHPUT_ARGS="all 10".
      ./run_throughput.sh $THROUGHPUT_ARGS | tee "$LOG_DIR/throughput.log"
    else
      ./run_throughput.sh | tee "$LOG_DIR/throughput.log"
    fi
  fi

  if [ "$RUN_ACCURACY" = "1" ]; then
    log "Running accuracy test"
    if [ -n "$ACCURACY_ARGS" ]; then
      # Intentionally split ACCURACY_ARGS, e.g. ACCURACY_ARGS="hotpotqa 10".
      ./run_accuracy.sh $ACCURACY_ARGS | tee "$LOG_DIR/accuracy.log"
    else
      ./run_accuracy.sh | tee "$LOG_DIR/accuracy.log"
    fi
  fi
}

main() {
  need_cmd git
  need_cmd python
  need_cmd curl
  need_cmd tar
  need_cmd tee
  mkdir -p "$WORKDIR" "$LOG_DIR" "$PIP_CACHE_DIR" "$MODELSCOPE_CACHE" "$TMPDIR"

  clone_and_build_vllm
  prepare_model
  download_testdata
  start_vllm_server
  wait_for_vllm_server
  smoke_test
  run_benchmarks

  log "Done. Logs are under $LOG_DIR"
}

main "$@"
