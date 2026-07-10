#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

MODEL_DIR="${MODEL_DIR:-../Qwen3.5-27B}"
PORT="${PORT:-8003}"
FX_TRACE_RUN_DIR="${FX_TRACE_RUN_DIR:-./profile_runs/selected_layer_fx_20260707_codex}"
LATENCY_DIR="${LATENCY_DIR:-$FX_TRACE_RUN_DIR/process_latency}"
KEEP_SERVER="${KEEP_SERVER:-0}"
STOP_EXISTING="${STOP_EXISTING:-1}"
OUTPUT_LEN="${OUTPUT_LEN:-1024}"
NUM_WARMUPS="${NUM_WARMUPS:-0}"
CONTEXTS="${CONTEXTS:-4-8K,8-16K,16-32K}"
PROCESS_PATCH_PYTHONPATH="$SCRIPT_DIR/process_latency_patch"
PROCESS_PHASES="${PROCESS_PHASES:-prefill_chunk}"
PROCESS_SYNC="${PROCESS_SYNC:-1}"
PROCESS_STRICT="${PROCESS_STRICT:-1}"
DISABLE_FRONTEND_MULTIPROCESSING="${DISABLE_FRONTEND_MULTIPROCESSING:-1}"
PROCESS_RATIONALE="${PROCESS_RATIONALE:-process-latency targets mirror selected_layer_fx_20260707_codex selected FX events}"
ACTIVE_SERVER_PID_FILE=""

export NO_PROXY="127.0.0.1,localhost,${NO_PROXY:-}"
export no_proxy="127.0.0.1,localhost,${no_proxy:-}"
export VLLM_RPC_TIMEOUT="${VLLM_RPC_TIMEOUT:-1800000}"
export LD_LIBRARY_PATH="/opt/dtk-26.04-DCC2602-0317/dcc/lib:/opt/dtk-26.04-DCC2602-0317/roctracer/lib:/opt/dtk-26.04-DCC2602-0317/lib:${LD_LIBRARY_PATH:-}"

mkdir -p "$LATENCY_DIR"

log() {
  printf '[process-latency] %s\n' "$*"
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
  pids="$(pgrep -f "vllm serve .*--port $PORT" || true)"
  if [ -n "$pids" ]; then
    log "Stopping existing vLLM serve processes: $pids"
    kill $pids || true
    sleep 5
  fi
  pids="$(pgrep -f 'VLLM::EngineCore' || true)"
  if [ -n "$pids" ]; then
    log "Stopping existing EngineCore processes: $pids"
    kill $pids || true
    sleep 3
    pids="$(pgrep -f 'VLLM::EngineCore' || true)"
    if [ -n "$pids" ]; then
      kill -9 $pids || true
    fi
  fi
}

targets_for_context() {
  local label="$1"
  case "$label" in
    4-8K)
      printf '%s\n' "${PROCESS_TARGETS_4_8K:-1:3,1:31,1:59}"
      ;;
    8-16K)
      printf '%s\n' "${PROCESS_TARGETS_8_16K:-1:3,4:31,3:59}"
      ;;
    16-32K)
      printf '%s\n' "${PROCESS_TARGETS_16_32K:-1:3,2:31,4:59}"
      ;;
    *)
      printf '%s\n' "${PROCESS_TARGETS:-1:3}"
      ;;
  esac
}

start_profiled_server() {
  local label="$1"
  local trace_dir="$2"
  local hipprof_dir="$3"
  local targets="$4"
  local server_log="$5"
  local server_pid_file="$6"
  local arm_file="$trace_dir/profile_enabled"
  local hipprof_prefix="$hipprof_dir/vllm_process_latency"
  local extra_args=()

  mkdir -p "$trace_dir" "$hipprof_dir"
  rm -f "$trace_dir"/process_latency_events.csv \
    "$trace_dir"/process_latency_layer_events.csv \
    "$trace_dir"/run_metadata.json \
    "$trace_dir"/events.*.jsonl \
    "$hipprof_dir"/vllm_process_latency*
  rm -f "$arm_file"
  if [ "$DISABLE_FRONTEND_MULTIPROCESSING" = "1" ]; then
    extra_args+=(--disable-frontend-multiprocessing)
  fi

  log "Starting hipprof-wrapped vLLM server context=$label targets=$targets log=$server_log"
  VLLM_PROCESS_LATENCY_ENABLE=1 \
  VLLM_PROCESS_LATENCY_CONTEXT="$label" \
  VLLM_PROCESS_LATENCY_DIR="$trace_dir" \
  VLLM_PROCESS_LATENCY_ARM_FILE="$arm_file" \
  VLLM_PROCESS_LATENCY_TARGETS="$targets" \
  VLLM_PROCESS_LATENCY_PHASES="$PROCESS_PHASES" \
  VLLM_PROCESS_LATENCY_SYNC="$PROCESS_SYNC" \
  VLLM_PROCESS_LATENCY_STRICT="$PROCESS_STRICT" \
  VLLM_PROCESS_LATENCY_RATIONALE="$PROCESS_RATIONALE" \
  VLLM_ENABLE_V1_MULTIPROCESSING=0 \
  PYTHONPATH="$PROCESS_PATCH_PYTHONPATH:${PYTHONPATH:-}" \
  nohup hipprof --hip-trace --hiptx-trace --output-type 0 -o "$hipprof_prefix" \
    vllm serve "$MODEL_DIR" \
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
      --enforce-eager \
      "${extra_args[@]}" \
      >"$server_log" 2>&1 &
  printf '%s\n' "$!" > "$server_pid_file"
  ACTIVE_SERVER_PID_FILE="$server_pid_file"
}

wait_for_server() {
  local server_log="$1"
  local server_pid_file="$2"
  log "Waiting for vLLM on 127.0.0.1:$PORT"
  for attempt in $(seq 1 300); do
    if vllm_ready; then
      log "vLLM server is ready"
      return
    fi
    if [ -f "$server_pid_file" ] && ! kill -0 "$(cat "$server_pid_file")" 2>/dev/null; then
      tail -n 200 "$server_log" >&2 || true
      exit 1
    fi
    log "Still waiting ($attempt/300)"
    sleep 5
  done
  tail -n 200 "$server_log" >&2 || true
  exit 1
}

cleanup() {
  if [ "$KEEP_SERVER" != "1" ] && [ -n "$ACTIVE_SERVER_PID_FILE" ] && [ -f "$ACTIVE_SERVER_PID_FILE" ]; then
    local pid
    pid="$(cat "$ACTIVE_SERVER_PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      log "Stopping profiled server wrapper pid $pid"
      pkill -P "$pid" || true
      kill "$pid" || true
      wait "$pid" || true
    fi
    ACTIVE_SERVER_PID_FILE=""
  fi
}
trap cleanup EXIT

stop_profiled_server() {
  cleanup
  local pids
  pids="$(pgrep -f "vllm serve .*--port $PORT" || true)"
  if [ -n "$pids" ]; then
    log "Stopping remaining vLLM serve processes on port $PORT: $pids"
    kill $pids || true
    sleep 3
    pids="$(pgrep -f "vllm serve .*--port $PORT" || true)"
    if [ -n "$pids" ]; then
      kill -9 $pids || true
    fi
  fi
  pids="$(pgrep -f 'VLLM::EngineCore' || true)"
  if [ -n "$pids" ]; then
    log "Stopping remaining EngineCore processes: $pids"
    kill $pids || true
    sleep 3
    pids="$(pgrep -f 'VLLM::EngineCore' || true)"
    if [ -n "$pids" ]; then
      kill -9 $pids || true
    fi
  fi
  # hipprof writes DB/JSON after target process exit.
  sleep 10
}

regenerate_hipprof_outputs() {
  local hipprof_dir="$1"
  local db_path="$hipprof_dir/vllm_process_latency.db"
  if [ ! -f "$db_path" ]; then
    log "No hipprof DB found at $db_path"
    return
  fi
  log "Regenerating hipprof JSON/CSV from $db_path"
  (
    cd "$hipprof_dir"
    hipprof --db vllm_process_latency.db --output-type 0 -o vllm_process_latency_timeline \
      > hipprof_db_timeline.log 2>&1 || true
  )
}

run_one_context() {
  local label="$1"
  local dataset_path="$2"
  local context_dir="$LATENCY_DIR/contexts/$label"
  local trace_dir="$context_dir/trace"
  local hipprof_dir="$context_dir/hipprof"
  local result_dir="$context_dir/bench"
  local arm_file="$trace_dir/profile_enabled"
  local targets
  local server_log="$context_dir/vllm_process_latency_server.log"
  local server_pid_file="$context_dir/vllm_process_latency_server.pid"

  targets="$(targets_for_context "$label")"
  mkdir -p "$context_dir" "$trace_dir" "$hipprof_dir" "$result_dir"
  start_profiled_server "$label" "$trace_dir" "$hipprof_dir" "$targets" "$server_log" "$server_pid_file"
  wait_for_server "$server_log" "$server_pid_file"

  log "Running process-latency benchmark context=$label dataset=$dataset_path"
  : > "$arm_file"
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
    --save-result \
    --result-dir "$result_dir" \
    --result-filename result.json \
    | tee "$context_dir/bench.log"
  rm -f "$arm_file"

  python3 - "$result_dir/result.json" <<'PY'
import json
import sys

result_path = sys.argv[1]
with open(result_path, encoding="utf-8") as handle:
    result = json.load(handle)
if result.get("completed") != 1 or result.get("failed") != 0:
    raise SystemExit(
        f"invalid benchmark result: completed={result.get('completed')} "
        f"failed={result.get('failed')}"
    )
PY

  stop_profiled_server
  regenerate_hipprof_outputs "$hipprof_dir"
  log "Context $label process latency artifacts saved under $context_dir"
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
  cat > "$LATENCY_DIR/profile_plan.tsv" <<'EOF'
4-8K	./4-8K_throughput.jsonl
8-16K	./8-16K_throughput.jsonl
16-32K	./16-32K_throughput.jsonl
EOF

  while IFS="$(printf '\t')" read -r label dataset_path; do
    if ! context_enabled "$label"; then
      log "Skipping context=$label because CONTEXTS=$CONTEXTS"
      continue
    fi
    run_one_context "$label" "$dataset_path"
  done < "$LATENCY_DIR/profile_plan.tsv"

  python3 "$SCRIPT_DIR/summarize_process_latency_hipprof.py" "$FX_TRACE_RUN_DIR"

  log "All process latency profiling complete: $LATENCY_DIR"
  find "$LATENCY_DIR" -maxdepth 5 -type f -printf '%p %s\n' \
    | sort \
    | tee "$LATENCY_DIR/artifacts.txt"
}

main "$@"
