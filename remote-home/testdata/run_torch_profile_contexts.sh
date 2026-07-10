#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODEL_DIR="${MODEL_DIR:-../Qwen3.5-27B}"
PORT="${PORT:-8001}"
PROFILE_RUN_DIR="${PROFILE_RUN_DIR:-./profile_runs/$(date +%Y%m%d_%H%M%S)}"
BENCH_DIR="$PROFILE_RUN_DIR/bench_results"
KEEP_SERVER="${KEEP_SERVER:-0}"
STOP_EXISTING="${STOP_EXISTING:-1}"
OUTPUT_LEN="${OUTPUT_LEN:-1024}"
NUM_WARMUPS="${NUM_WARMUPS:-2}"
PROFILE_CONFIG_EXTRA="${PROFILE_CONFIG_EXTRA:-}"
CONTEXTS="${CONTEXTS:-4-8K,8-16K,16-32K}"
ACTIVE_SERVER_PID_FILE=""

export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="127.0.0.1,localhost,${no_proxy:-}"
export VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-1800000}"

mkdir -p "$PROFILE_RUN_DIR" "$BENCH_DIR"

log() {
  printf '[torch-profile] %s\n' "$*"
}

vllm_ready() {
  curl --noproxy 127.0.0.1,localhost -fsS \
    "http://127.0.0.1:$PORT/v1/models" >/dev/null 2>&1
}

stop_existing_vllm() {
  if [ "$STOP_EXISTING" != "1" ]; then
    return
  fi
  local pids
  pids="$(pgrep -f 'vllm serve' || true)"
  if [ -n "$pids" ]; then
    log "Stopping existing vLLM serve processes: $pids"
    kill $pids || true
    sleep 5
  fi
}

start_profile_server() {
  local raw_profile_dir="$1"
  local server_log="$2"
  local server_pid_file="$3"
  local profiler_config
  mkdir -p "$raw_profile_dir"
  profiler_config="$(
    python3 - "$raw_profile_dir" "$PROFILE_CONFIG_EXTRA" <<'PY'
import json
import sys

cfg = {
    "profiler": "torch",
    "torch_profiler_dir": sys.argv[1],
    "torch_profiler_use_gzip": True,
    "torch_profiler_dump_cuda_time_total": True,
}
if sys.argv[2]:
    cfg.update(json.loads(sys.argv[2]))
print(json.dumps(cfg, separators=(",", ":")))
PY
  )"

  log "Starting vLLM profile server; log=$server_log"
  nohup vllm serve "$MODEL_DIR" \
    --served-model-name Qwen3.5-27B \
    --port "$PORT" \
    --trust-remote-code \
    --dtype bfloat16 \
    --tensor-parallel-size 1 \
    --max-num-seqs 128 \
    --max-num-batched-tokens 4096 \
    --gpu-memory-utilization 0.95 \
    --default-chat-template-kwargs '{"enable_thinking": false}' \
    --reasoning-parser qwen3 \
    --enable-auto-tool-choice \
    --tool-call-parser qwen3_coder \
    --profiler-config "$profiler_config" \
    >"$server_log" 2>&1 &
  printf '%s\n' "$!" > "$server_pid_file"
  ACTIVE_SERVER_PID_FILE="$server_pid_file"
}

wait_for_server() {
  local server_log="$1"
  local server_pid_file="$2"
  log "Waiting for vLLM on 127.0.0.1:$PORT"
  for attempt in $(seq 1 180); do
    if vllm_ready; then
      log "vLLM server is ready"
      return
    fi
    if [ -f "$server_pid_file" ] && ! kill -0 "$(cat "$server_pid_file")" 2>/dev/null; then
      tail -n 120 "$server_log" >&2 || true
      exit 1
    fi
    log "Still waiting ($attempt/180)"
    sleep 5
  done
  tail -n 120 "$server_log" >&2 || true
  exit 1
}

cleanup() {
  if [ "$KEEP_SERVER" != "1" ] && [ -n "$ACTIVE_SERVER_PID_FILE" ] && [ -f "$ACTIVE_SERVER_PID_FILE" ]; then
    local pid
    pid="$(cat "$ACTIVE_SERVER_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping profile server pid $pid"
      kill "$pid" || true
    fi
    ACTIVE_SERVER_PID_FILE=""
  fi
}
trap cleanup EXIT

stop_profile_server() {
  cleanup
  sleep 3
}

run_one_profile() {
  local label="$1"
  local dataset_path="$2"
  local context_dir="$PROFILE_RUN_DIR/contexts/$label"
  local result_dir="$BENCH_DIR/$label"
  local raw_profile_dir="$context_dir/raw_traces"
  local server_log="$context_dir/vllm_profile_server.log"
  local server_pid_file="$context_dir/vllm_profile_server.pid"

  mkdir -p "$context_dir" "$result_dir" "$raw_profile_dir"
  start_profile_server "$raw_profile_dir" "$server_log" "$server_pid_file"
  wait_for_server "$server_log" "$server_pid_file"
  log "Profiling context=$label dataset=$dataset_path"

  vllm bench serve \
    --backend openai-chat \
    --host 127.0.0.1 \
    --port "$PORT" \
    --endpoint /v1/chat/completions \
    --model Qwen3.5-27B \
    --tokenizer "$MODEL_DIR" \
    --dataset-name custom \
    --dataset-path "$dataset_path" \
    --num-prompts 1 \
    --no-oversample \
    --max-concurrency 1 \
    --request-rate 1 \
    --temperature 0 \
    --disable-shuffle \
    --custom-output-len "$OUTPUT_LEN" \
    --num-warmups "$NUM_WARMUPS" \
    --save-detailed \
    --extra-body '{"temperature":0.0}' \
    --percentile-metrics ttft,tpot,itl,e2el \
    --metric-percentiles 50,95,99 \
    --profile \
    --save-result \
    --result-dir "$result_dir" \
    --result-filename result.json \
    | tee "$context_dir/bench.log"

  python3 - "$result_dir/result.json" <<'PY'
import json
import sys

result_path = sys.argv[1]
with open(result_path, encoding="utf-8") as f:
    result = json.load(f)
if result.get("completed") != 1 or result.get("failed") != 0:
    raise SystemExit(
        f"invalid benchmark result: completed={result.get('completed')} "
        f"failed={result.get('failed')}"
    )
PY

  cp -a "$result_dir/result.json" "$context_dir/result.json"
  stop_profile_server
  log "Context $label artifacts saved under $context_dir"
}

context_enabled() {
  local label="$1"
  case ",$CONTEXTS," in
    *",$label,"*) return 0 ;;
    *) return 1 ;;
  esac
}

main() {
  stop_existing_vllm
  cat > "$PROFILE_RUN_DIR/profile_plan.tsv" <<'EOF'
4-8K	./4-8K_throughput.jsonl
8-16K	./8-16K_throughput.jsonl
16-32K	./16-32K_throughput.jsonl
EOF

  while IFS="$(printf '\t')" read -r label dataset_path; do
    if ! context_enabled "$label"; then
      log "Skipping context=$label because CONTEXTS=$CONTEXTS"
      continue
    fi
    run_one_profile "$label" "$dataset_path"
  done < "$PROFILE_RUN_DIR/profile_plan.tsv"

  log "All profiles complete: $PROFILE_RUN_DIR"
  find "$PROFILE_RUN_DIR/contexts" -maxdepth 4 -type f -printf '%p %s\n' \
    | sort \
    | tee "$PROFILE_RUN_DIR/artifacts.txt"
}

main "$@"
