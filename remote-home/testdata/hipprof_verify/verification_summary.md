# hipprof Verification Summary

验证目标：在远程容器中验证 `docs/异构计算平台性能分析介绍/异构计算平台性能分析介绍.md` 中介绍的性能分析工具 `hipprof` 及其主要功能是否可用。

验证时间：2026-07-07

验证位置：

- 远程容器 hostname：`worker-0`
- 工作目录：`remote-home/testdata/hipprof_verify`
- 复现脚本：`run_hipprof_verification.sh`
- 环境记录：`environment.log`
- 产物清单：`artifacts.txt`

## 结论

文档中的 `hipprof` 主要能力在当前远程容器内可以成功使用：

| 功能 | 文档对应命令/能力 | 验证状态 | 证据 |
| --- | --- | --- | --- |
| 帮助信息 | `hipprof -h` | 通过 | `hipprof_help.txt` |
| HIP API/kernel trace | `hipprof --hip-trace ./app` | 通过 | `results_hiptrace/vector_add_trace.{db,json,hiptrace.csv,hipkernel.csv}` |
| 从 db 重生成 timeline | `hipprof --db <db> --group-stream` | 通过 | `results_hiptrace/vector_add_grouped_stream.json` |
| hiptx/roctx 标记 | `hipprof --hip-trace --hiptx-trace ./app` | 通过 | `results_hiptx/vector_add_hiptx.json` 中包含 `before h2d memcpy`、`vector_add_roctx_kernel range` |
| PMC | `hipprof --pmc ./app` | 通过 | `results_pmc/pmc_results_*.txt` 中包含 `kernel time`、`performance`、L1/L2 指标 |
| PMC read 组 | `hipprof --pmc-read ./app` | 通过 | `results_pmc_read/pmc_results_*.txt` |
| PMC write 组 | `hipprof --pmc-write ./app` | 通过 | `results_pmc_write/pmc_results_*.txt` |
| MPI trace | `hipprof --mpi-trace` + `mpitracer.so` | 通过 | `results_mpi_wrap_preload/mpi_wrap_preload.json` 中包含 `MPI_Send`、`MPI_Recv`、`MPI_Barrier` |
| 多 db 合并 | `hipprof --db-merge .` | 通过 | `results_db_merge/merged_trace.{db,json,hiptrace.csv,hipkernel.csv}` |
| buffer 调整 | `--buffer-size 1` | 通过 | `results_options/buffer_size_trace.{db,json,hiptrace.csv,hipkernel.csv}` |
| index 范围导出 | `--db <db> --index-range 0:5` | 通过 | `results_options/index_range_trace.json` |

## 必要环境修正

容器内 `hipprof` 直接执行会缺少 `libLLVM-17git.so`：

```text
hipprof: error while loading shared libraries: libLLVM-17git.so: cannot open shared object file
```

该库实际位于：

```text
/opt/dtk-26.04-DCC2602-0317/dcc/lib/libLLVM-17git.so
```

验证脚本使用以下环境变量修正：

```bash
export LD_LIBRARY_PATH=/opt/dtk-26.04-DCC2602-0317/dcc/lib:/opt/dtk-26.04-DCC2602-0317/roctracer/lib:/opt/dtk-26.04-DCC2602-0317/lib:${LD_LIBRARY_PATH:-}
```

MPI trace 还需要将 `mpitracer.so` 注入 MPI rank：

```bash
LD_PRELOAD=/opt/dtk-26.04-DCC2602-0317/lib/mpitracer.so:/opt/mpi/lib/libmpi.so.40
```

直接使用 `mpirun ... hipprof --mpi-trace ...` 并把 `LD_PRELOAD` 注入到 `hipprof` 自身时发生过段错误。已验证可用方式是由 `hipprof` 包裹 `mpirun`，再由 `mpirun -x LD_PRELOAD=...` 注入到 MPI rank：

```bash
hipprof --mpi-trace --output-type 0 -o mpi_wrap_preload \
  mpirun --allow-run-as-root --mca coll ^hcoll -np 2 \
    -x LD_LIBRARY_PATH \
    -x LD_PRELOAD=/opt/dtk-26.04-DCC2602-0317/lib/mpitracer.so:/opt/mpi/lib/libmpi.so.40 \
    ../mpi_pingpong
```

## 验证程序

编译出的最小测试程序：

- `vector_add_hipprof.cpp` / `vector_add_hipprof`：纯 HIP vector add，用于 `--hip-trace`、`--pmc`、`--pmc-read`、`--pmc-write`。
- `vector_add_roctx.cpp` / `vector_add_roctx`：带 `roctxMark`、`roctxRangeStart`、`roctxRangePush` 的 HIP vector add，用于 `--hiptx-trace`。
- `mpi_pingpong.cpp` / `mpi_pingpong`：2 rank MPI send/recv/barrier，用于 `--mpi-trace`。

## 关键证据

`--hip-trace` 输出中记录到 HIP API 和 kernel：

```text
hipMalloc, hipMemcpy, hipLaunchKernel, hipFree, hipDeviceSynchronize
vector_add_kernel(float const*, float const*, float*, int)
```

`--hiptx-trace` 输出中记录到 roctx 标记：

```text
before h2d memcpy
vector_add_roctx_kernel range
vector_add_roctx_kernel push
after vector_add_roctx_kernel
```

PMC 输出中记录到硬件计数器类指标：

```text
kernel time
performance
L1 cache unit is active
L1 cache unit is stalled
L2 cache hit rate
```

MPI trace JSON 中记录到 MPI API：

```text
MPI_Send
MPI_Recv
MPI_Barrier
```

## 复现

在远程容器内执行：

```bash
cd remote-home/testdata/hipprof_verify
bash run_hipprof_verification.sh
```

脚本最后会做内容校验，当前通过项为：

```text
hip_trace_has_kernel=True
hiptx_has_roctx_mark=True
mpi_trace_has_mpi_send=True
pmc_has_kernel_time=True
db_merge_has_two_kernels=True
```
