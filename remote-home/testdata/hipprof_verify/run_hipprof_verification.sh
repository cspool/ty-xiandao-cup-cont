#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DTK_EXTRA_LIB="/opt/dtk-26.04-DCC2602-0317/dcc/lib"
ROCTRACER_ROOT="/opt/dtk-26.04-DCC2602-0317/roctracer"
ROCTX_LIB="$ROCTRACER_ROOT/lib"
DTK_LIB="/opt/dtk-26.04-DCC2602-0317/lib"
MPITRACER="$DTK_LIB/mpitracer.so"
MPI_LIB="/opt/mpi/lib/libmpi.so.40"

export LD_LIBRARY_PATH="$DTK_EXTRA_LIB:$ROCTX_LIB:$DTK_LIB:${LD_LIBRARY_PATH:-}"

log() {
  printf '[hipprof-verify] %s\n' "$*"
}

log "Collecting environment information"
{
  hostname
  id
  hipconfig --full
  rocm-smi
} > environment.log 2>&1 || true
hipprof -h > hipprof_help.txt 2>&1

log "Building HIP and MPI smoke programs"
hipcc vector_add_hipprof.cpp -o vector_add_hipprof
hipcc -I"$ROCTRACER_ROOT/include" vector_add_roctx.cpp \
  -L"$ROCTX_LIB" -lroctx64 -o vector_add_roctx
mpicxx mpi_pingpong.cpp -o mpi_pingpong

log "Running smoke programs"
./vector_add_hipprof > vector_add_hipprof_run.log 2>&1
./vector_add_roctx > vector_add_roctx_run.log 2>&1
mpirun --allow-run-as-root --mca coll ^hcoll -np 2 ./mpi_pingpong \
  > mpi_pingpong_run.log 2>&1

log "Verifying hipprof --hip-trace"
rm -rf results_hiptrace
mkdir -p results_hiptrace
(
  cd results_hiptrace
  hipprof --hip-trace --output-type 0 -o vector_add_trace \
    ../vector_add_hipprof > hipprof_hip_trace.log 2>&1
  hipprof --db vector_add_trace.db --group-stream --output-type 0 \
    -o vector_add_grouped > hipprof_db_group_stream.log 2>&1
)

log "Verifying hipprof --hiptx-trace"
rm -rf results_hiptx
mkdir -p results_hiptx
(
  cd results_hiptx
  hipprof --hip-trace --hiptx-trace --output-type 0 -o vector_add_hiptx \
    ../vector_add_roctx > hipprof_hiptx.log 2>&1
)

log "Verifying hipprof PMC modes"
rm -rf results_pmc results_pmc_read results_pmc_write
mkdir -p results_pmc results_pmc_read results_pmc_write
(
  cd results_pmc
  hipprof --pmc ../vector_add_hipprof > hipprof_pmc.log 2>&1
)
(
  cd results_pmc_read
  hipprof --pmc-read ../vector_add_hipprof > hipprof_pmc_read.log 2>&1
)
(
  cd results_pmc_write
  hipprof --pmc-write ../vector_add_hipprof > hipprof_pmc_write.log 2>&1
)

log "Verifying hipprof --mpi-trace"
rm -rf results_mpi_wrap_preload
mkdir -p results_mpi_wrap_preload
(
  cd results_mpi_wrap_preload
  hipprof --mpi-trace --output-type 0 -o mpi_wrap_preload \
    mpirun --allow-run-as-root --mca coll ^hcoll -np 2 \
      -x LD_LIBRARY_PATH -x LD_PRELOAD="$MPITRACER:$MPI_LIB" \
      ../mpi_pingpong > hipprof_mpi_wrap_preload.log 2>&1
)

log "Verifying hipprof --db-merge"
rm -rf results_db_merge
mkdir -p results_db_merge
cp results_hiptrace/vector_add_trace.db results_db_merge/hip_a.db
cp results_hiptx/vector_add_hiptx.db results_db_merge/hip_b.db
(
  cd results_db_merge
  hipprof --db-merge . --output-type 0 -o merged_trace \
    > hipprof_db_merge.log 2>&1
)

log "Verifying hipprof --buffer-size and --index-range"
rm -rf results_options
mkdir -p results_options
(
  cd results_options
  hipprof --hip-trace --buffer-size 1 --output-type 0 -o buffer_size_trace \
    ../vector_add_hipprof > hipprof_buffer_size.log 2>&1
  hipprof --db ../results_hiptrace/vector_add_trace.db --index-range 0:5 \
    --output-type 0 -o index_range_trace > hipprof_index_range.log 2>&1
)

log "Checking required artifacts"
python3 - <<'PY'
from pathlib import Path

required = [
    "hipprof_help.txt",
    "vector_add_hipprof",
    "vector_add_roctx",
    "mpi_pingpong",
    "results_hiptrace/vector_add_trace.db",
    "results_hiptrace/vector_add_trace.json",
    "results_hiptrace/vector_add_trace.hiptrace.csv",
    "results_hiptrace/vector_add_trace.hipkernel.csv",
    "results_hiptrace/vector_add_grouped_stream.json",
    "results_hiptx/vector_add_hiptx.json",
    "results_pmc/pmc_results_",
    "results_pmc_read/pmc_results_",
    "results_pmc_write/pmc_results_",
    "results_mpi_wrap_preload/mpi_wrap_preload.json",
    "results_db_merge/merged_trace.json",
    "results_options/buffer_size_trace.json",
    "results_options/index_range_trace.json",
]
root = Path(".")
missing = []
for item in required:
    if item.endswith("_"):
        if not list(root.glob(item + "*")):
            missing.append(item + "*")
    elif not (root / item).exists():
        missing.append(item)
if missing:
    raise SystemExit("missing required artifacts: " + ", ".join(missing))

checks = {
    "hip_trace_has_kernel": "vector_add_kernel" in Path("results_hiptrace/vector_add_trace.hipkernel.csv").read_text(),
    "hiptx_has_roctx_mark": "vector_add_roctx_kernel range" in Path("results_hiptx/vector_add_hiptx.json").read_text(),
    "mpi_trace_has_mpi_send": "MPI_Send" in Path("results_mpi_wrap_preload/mpi_wrap_preload.json").read_text(),
    "pmc_has_kernel_time": "kernel time" in next(Path("results_pmc").glob("pmc_results_*")).read_text(),
    "db_merge_has_two_kernels": "vector_add_roctx_kernel" in Path("results_db_merge/merged_trace.hipkernel.csv").read_text()
        and "vector_add_kernel" in Path("results_db_merge/merged_trace.hipkernel.csv").read_text(),
}
bad = [key for key, value in checks.items() if not value]
if bad:
    raise SystemExit("failed content checks: " + ", ".join(bad))
for key, value in checks.items():
    print(f"{key}={value}")
PY

find . -maxdepth 2 -type f -printf '%p %s\n' | sort > artifacts.txt
log "Verification complete"
