# hipprof 远程容器已验证使用指南

本文档把 `异构计算平台性能分析介绍.md` 中的 hipprof 功能整理成当前远程容器里已经验证通过的可执行步骤。验证环境和完整产物位于：

```text
/data3/Projects/scnet_ssh/remote-home/testdata/hipprof_verify
```

复现脚本：

```text
remote-home/testdata/hipprof_verify/run_hipprof_verification.sh
```

验证报告：

```text
remote-home/testdata/hipprof_verify/verification_summary.md
```

## 1. 验证环境

当前验证环境：

- 容器 hostname：`worker-0`
- 用户：`root`
- HIP version：`6.2.0-0`
- `HIP_PATH`：`/opt/dtk/hip`
- `ROCM_PATH`：`/opt/dtk`
- GPU 可见：`rocm-smi` 可看到 1 张 HCU，程序输出设备名为 `BW`
- MPI：Open MPI `5.0.3`

`hipprof` 在容器内存在：

```bash
command -v hipprof
# /opt/dtk/bin/hipprof
```

但是直接执行 `hipprof` 会缺少 `libLLVM-17git.so`。已验证的环境修正如下：

```bash
export LD_LIBRARY_PATH=/opt/dtk-26.04-DCC2602-0317/dcc/lib:/opt/dtk-26.04-DCC2602-0317/roctracer/lib:/opt/dtk-26.04-DCC2602-0317/lib:${LD_LIBRARY_PATH:-}
```

检查命令：

```bash
hipprof -h
hipcc --version
hipconfig --full
rocm-smi
```

## 2. 最小测试程序

验证目录中包含 3 个最小程序：

```text
remote-home/testdata/hipprof_verify/vector_add_hipprof.cpp
remote-home/testdata/hipprof_verify/vector_add_roctx.cpp
remote-home/testdata/hipprof_verify/mpi_pingpong.cpp
```

用途：

| 程序 | 用途 |
| --- | --- |
| `vector_add_hipprof` | 纯 HIP vector add，用于 `--hip-trace`、`--pmc`、`--pmc-read`、`--pmc-write` |
| `vector_add_roctx` | 带 `roctxMark`、`roctxRangeStart`、`roctxRangePush`，用于 `--hiptx-trace` |
| `mpi_pingpong` | 2 rank MPI send/recv/barrier，用于 `--mpi-trace` |

编译命令：

```bash
cd remote-home/testdata/hipprof_verify

hipcc vector_add_hipprof.cpp -o vector_add_hipprof

hipcc -I/opt/dtk-26.04-DCC2602-0317/roctracer/include \
  vector_add_roctx.cpp \
  -L/opt/dtk-26.04-DCC2602-0317/roctracer/lib \
  -lroctx64 \
  -o vector_add_roctx

mpicxx mpi_pingpong.cpp -o mpi_pingpong
```

运行 smoke test：

```bash
./vector_add_hipprof
./vector_add_roctx
mpirun --allow-run-as-root --mca coll ^hcoll -np 2 ./mpi_pingpong
```

预期输出包含：

```text
PASSED vector_add_hipprof
PASSED vector_add_roctx
PASSED mpi_pingpong
```

## 3. HIP API 和 Kernel Trace

用途：统计 HIP API、memcpy、kernel launch、kernel 执行时间，并生成 Chrome trace JSON、CSV 和数据库。

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_hiptrace
mkdir -p results_hiptrace
cd results_hiptrace

hipprof --hip-trace --output-type 0 -o vector_add_trace \
  ../vector_add_hipprof > hipprof_hip_trace.log 2>&1
```

已验证输出：

```text
vector_add_trace.db
vector_add_trace.json
vector_add_trace.hiptrace.csv
vector_add_trace.hipkernel.csv
hipprof_hip_trace.log
```

关键内容：

- `vector_add_trace.hiptrace.csv` 中包含 `hipMalloc`、`hipMemcpy`、`hipLaunchKernel`、`hipFree`、`hipDeviceSynchronize`。
- `vector_add_trace.hipkernel.csv` 中包含 `vector_add_kernel(float const*, float const*, float*, int)`。
- `vector_add_trace.json` 可用 Chrome `chrome://tracing` 打开。

## 4. 从 DB 重生成 Timeline

用途：不重新运行程序，直接用已有 `.db` 重生成 timeline。文档中的 `--group-stream` 已验证可用。

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify/results_hiptrace

hipprof --db vector_add_trace.db \
  --group-stream \
  --output-type 0 \
  -o vector_add_grouped \
  > hipprof_db_group_stream.log 2>&1
```

已验证输出：

```text
vector_add_grouped_stream.json
vector_add_grouped-vector_add_trace.db.hiptrace.csv
vector_add_grouped-vector_add_trace.db.hipkernel.csv
```

## 5. hiptx / roctx 标记 Trace

用途：把程序中的 `roctxMark`、`roctxRangeStart`、`roctxRangePush` 标记写入 timeline，用于把用户代码区域和 HIP API/kernel 对齐。

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_hiptx
mkdir -p results_hiptx
cd results_hiptx

hipprof --hip-trace --hiptx-trace --output-type 0 -o vector_add_hiptx \
  ../vector_add_roctx > hipprof_hiptx.log 2>&1
```

已验证输出：

```text
vector_add_hiptx.db
vector_add_hiptx.json
vector_add_hiptx.hiptrace.csv
vector_add_hiptx.hipkernel.csv
```

已在 JSON 中验证到以下 roctx 字符串：

```text
before h2d memcpy
vector_add_roctx_kernel range
vector_add_roctx_kernel push
after vector_add_roctx_kernel
```

快速检查：

```bash
grep -n 'vector_add_roctx\|before h2d\|after vector' vector_add_hiptx.json
```

## 6. PMC 硬件计数器分析

用途：对 kernel 输出硬件计数器类指标，如 kernel time、Gflops、L1/L2 cache 指标。

### 6.1 通用 PMC

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_pmc
mkdir -p results_pmc
cd results_pmc

hipprof --pmc ../vector_add_hipprof > hipprof_pmc.log 2>&1
```

已验证输出：

```text
pmc_results_<pid>.txt
hipprof_pmc.log
```

文件中包含：

```text
kernel time
performance
L1 cache unit is active
L1 cache unit is stalled
L2 cache hit rate
```

### 6.2 PMC Read 组

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_pmc_read
mkdir -p results_pmc_read
cd results_pmc_read

hipprof --pmc-read ../vector_add_hipprof > hipprof_pmc_read.log 2>&1
```

已验证输出：

```text
pmc_results_<pid>.txt
```

文件中包含 L2 read 请求和 read size 指标，例如：

```text
number of L2 cache read requests
size of L2 cache read
```

### 6.3 PMC Write 组

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_pmc_write
mkdir -p results_pmc_write
cd results_pmc_write

hipprof --pmc-write ../vector_add_hipprof > hipprof_pmc_write.log 2>&1
```

已验证输出：

```text
pmc_results_<pid>.txt
```

文件中包含 L2 write 请求和 write size 指标，例如：

```text
number of L2 cache write requests
size of L2 cache write
```

## 7. MPI Trace

用途：跟踪 MPI API，并导出 Chrome trace JSON。

当前容器内存在：

```text
/opt/mpi/bin/mpirun
/opt/mpi/bin/mpicxx
/opt/dtk-26.04-DCC2602-0317/lib/mpitracer.so
/opt/mpi/lib/libmpi.so.40
```

已验证可用方式：由 `hipprof` 包裹 `mpirun`，再由 `mpirun` 将 `mpitracer.so` 注入 MPI rank。

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_mpi_wrap_preload
mkdir -p results_mpi_wrap_preload
cd results_mpi_wrap_preload

hipprof --mpi-trace --output-type 0 -o mpi_wrap_preload \
  mpirun --allow-run-as-root --mca coll ^hcoll -np 2 \
    -x LD_LIBRARY_PATH \
    -x LD_PRELOAD=/opt/dtk-26.04-DCC2602-0317/lib/mpitracer.so:/opt/mpi/lib/libmpi.so.40 \
    ../mpi_pingpong > hipprof_mpi_wrap_preload.log 2>&1
```

已验证输出：

```text
mpi_wrap_preload.db
mpi_wrap_preload.json
hipprof_mpi_wrap_preload.log
```

已验证 JSON 中包含：

```text
MPI_Send
MPI_Recv
MPI_Barrier
```

注意：直接使用 `mpirun ... hipprof --mpi-trace ...` 并把 `LD_PRELOAD` 注入到 `hipprof` 自身时，在当前容器触发过段错误。上面的 `hipprof --mpi-trace mpirun ... -x LD_PRELOAD=...` 是已验证稳定的方式。

## 8. DB Merge

用途：合并多个 `.db`，用于多进程、多节点或多次运行结果汇总。

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_db_merge
mkdir -p results_db_merge

cp results_hiptrace/vector_add_trace.db results_db_merge/hip_a.db
cp results_hiptx/vector_add_hiptx.db results_db_merge/hip_b.db

cd results_db_merge
hipprof --db-merge . --output-type 0 -o merged_trace \
  > hipprof_db_merge.log 2>&1
```

已验证输出：

```text
merged_trace.db
merged_trace.json
merged_trace.hiptrace.csv
merged_trace.hipkernel.csv
```

已验证合并后的 kernel CSV 同时包含：

```text
vector_add_kernel
vector_add_roctx_kernel
```

## 9. buffer-size 和 index-range

### 9.1 buffer-size

用途：缩小 profiler 缓冲区，适合 server 类程序或希望更快落盘的场景。

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify
rm -rf results_options
mkdir -p results_options
cd results_options

hipprof --hip-trace --buffer-size 1 --output-type 0 -o buffer_size_trace \
  ../vector_add_hipprof > hipprof_buffer_size.log 2>&1
```

已验证输出：

```text
buffer_size_trace.db
buffer_size_trace.json
buffer_size_trace.hiptrace.csv
buffer_size_trace.hipkernel.csv
```

### 9.2 index-range

用途：基于已有 db 只导出指定 API index 范围，不重新运行程序。

已验证命令：

```bash
cd remote-home/testdata/hipprof_verify/results_options

hipprof --db ../results_hiptrace/vector_add_trace.db \
  --index-range 0:5 \
  --output-type 0 \
  -o index_range_trace > hipprof_index_range.log 2>&1
```

已验证输出：

```text
index_range_trace.json
index_range_trace-vector_add_trace.db.hiptrace.csv
```

该 CSV 只包含前 5 条范围内的 HIP API 统计。

## 10. 一键复现

运行完整验证：

```bash
cd remote-home/testdata/hipprof_verify
bash run_hipprof_verification.sh
```

脚本会重新编译样例、运行所有已验证命令，并做内容校验。当前通过项为：

```text
hip_trace_has_kernel=True
hiptx_has_roctx_mark=True
mpi_trace_has_mpi_send=True
pmc_has_kernel_time=True
db_merge_has_two_kernels=True
```

## 11. 产物阅读建议

- 先看 `verification_summary.md`，确认哪些功能已验证通过。
- 查看 `environment.log`，确认容器、HIP、DTK、GPU 环境。
- 查看 `results_hiptrace/*.csv`，快速读 HIP API/kernel 统计。
- 查看 `results_hiptrace/*.json` 或 `results_hiptx/*.json`，用 Chrome `chrome://tracing` 打开 timeline。
- 查看 `results_pmc*/pmc_results_*.txt`，读 PMC 硬件计数器指标。
- 查看 `results_mpi_wrap_preload/mpi_wrap_preload.json`，确认 MPI timeline 中的 `MPI_Send`、`MPI_Recv`、`MPI_Barrier`。

## 12. 已知限制

- 当前验证是单容器、单节点、单 GPU 环境；文档中双节点 MPI 场景未在本次验证范围内。
- `hipprof` 需要补充 `LD_LIBRARY_PATH` 才能找到 `libLLVM-17git.so`。
- MPI trace 需要 `mpitracer.so` 和 `libmpi.so.40` 通过 `LD_PRELOAD` 注入到 MPI rank。
- 不建议把 `LD_PRELOAD` 注入到 `hipprof` 自身；当前容器中这种方式触发过段错误。
