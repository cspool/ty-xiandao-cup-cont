# Autoresearch Notes

## Nsight Systems Range 与 Kernel Time 的含义

E2 单请求实验把 clock 计时、NVTX CPU range 和 CUPTI kernel activity 分开使用。正式结论必须先确认三类数据的物理含义：

- `request_total_ms` / `generate_total_ms`：端到端 clock 计时。当前 request 返回前执行 `torch.cuda.synchronize()`，优先作为单请求端到端延迟。
- `NVTX CPU range ms`：CPU/Python 进入和离开 request、forward、layer、attn、mlp scope 的时间跨度。它是 timeline 标记，不是该 scope 的 GPU completion latency。
- `CUPTI launch-owned kernel sum ms`：NVTX range 内 CUDA Runtime API 发起、并由 `correlationId` 匹配到的 CUPTI kernel duration 求和。它不是 GPU wall-clock span，也不能在嵌套 range 或并发 kernel 之间直接相加。

### 当前采集与归因链路

当前入口脚本是：

```bash
autoresearch/experiments/e2_single_request_latency/code/run_nsys_layer_profile_single_request.sh
```

核心采集命令等价于：

```bash
nsys profile \
  --trace=cuda,nvtx,cublas,osrt \
  --capture-range=cudaProfilerApi \
  --capture-range-end=stop \
  --stats=true \
  ... \
  profile_visprune_single_request.py \
    --sync-timing off \
    --nvtx on \
    --cuda-profiler-api \
    --layer-profile
```

`cudaProfilerApi` 只采集 measured request；`--sync-timing off` 保留真实异步执行形态；`--layer-profile` 在 request、forward、layer、attn、mlp 等 CPU scope 上打 NVTX range。

后处理脚本是：

```bash
autoresearch/experiments/e2_single_request_latency/code/analyze_layer_nsys.py
```

它读取 `NVTX_EVENTS`、`CUPTI_ACTIVITY_KIND_RUNTIME` 和 `CUPTI_ACTIVITY_KIND_KERNEL`，对每个 range 使用 launch ownership 归因：

```text
owned_runtime_api(range)
  = runtime where range.start <= runtime.start < range.end

owned_cupti_kernel(range)
  = CUPTI kernel where kernel.correlationId == owned_runtime_api.correlationId

kernel_total_ms(range)
  = sum(kernel.end - kernel.start for owned_cupti_kernel(range))
```

因此报告中的 `kernel_total_ms` 只能解释为“该 NVTX CPU range 内 CUDA Runtime API 调用发起的 CUPTI GPU kernel 完整 duration 总和”。它不能解释为“kernel 物理执行时间窗落在这个 NVTX range 内”，也不能解释为“这个 layer 在 GPU 上独占运行了多久”。

### 使用边界

- 端到端性能优先使用 measured request 的 clock/nsys 结果，尤其是 `request_total_ms`。
- layer/component breakdown 使用 Runtime `correlationId` 到 kernel `correlationId` 的 launch ownership；不要再使用 kernel-vs-NVTX overlap。
- `range_ms - kernel_total_ms` 不是严格 CPU overhead，因为二者不是同一个物理量。
- 如果需要分析多个 kernel 的并发关系，使用 Nsight Systems 的 GPU timeline、stream、kernel start/end；Nsight Compute 更适合单个 kernel 的 counters 和 source-level 诊断。
- 多轮相同输入可以降低随机波动，但不能替代归因规则审计。

## SAME_INPUT 与 process-wise workflow skills

这 4 个 skill 覆盖从实验设计到 process-wise 报告的完整链路。当前仓库有现成脚本时优先复用；迁移到没有这些脚本的新场景时，先按对应 skill 的 Portable Tool Contract 生成等价 runner、instrumentation、analyzer 和 report generator，再运行和审计。

推荐顺序：

1. `$visipruner-same-input-workflow`
   用于从 0 设计 SAME_INPUT-style 固定输入、固定 token 设置的 layer-wise 延迟实验，而不是只重新跑已有实验。它负责明确 variant、输入、采样边界、NVTX/layer event schema，并生成或复用 `profile_visprune_single_request.py`、`run_clock_layer_profile_single_request.sh`、`run_nsys_layer_profile_single_request.sh` 等等价采集工具。主要产物是 clock JSON/ranges、layer-events CSV、Nsight `.sqlite` 和实验运行记录。

2. `$visipruner-sampled-latency-attribution`
   用于实现或审计 Nsight/CUPTI 采样数据到 layer/component latency 的严格归因。它约束 analyzer 必须读取 NVTX、CUPTI runtime、CUPTI kernel，并使用 Runtime `correlationId` -> kernel `correlationId`；这是流程中最需要人工 review 的检查点。主要产物是 `*_layer_kernel_breakdown.csv/json`，以及对 overlap 归因、错误相减和并发误读的审计结论。

3. `$visipruner-same-input-evidence`
   用于把 clock、layer-events 和 nsys attribution 汇总为 SAME_INPUT 证据包。它生成每个 variant 的 layer performance report、三方对齐表和 audit JSON；当前对应 `SAME_INPUT_*_LAYER_PERFORMANCE_REPORT.md`、`SAME_INPUT_THREE_WAY_LAYER_PERFORMANCE_TABLE.md` 和 `output/same_input_three_way_audit.json`。

4. `$visipruner-process-performance-breakdown`
   用于把 SAME_INPUT 的 layer/component latency 投影到 FX process reconstruction，形成算法 process-wise 归因报告。当前默认命令是：

```bash
python autoresearch/experiments/e2_single_request_latency/code/generate_process_performance_breakdown.py
```

它默认生成每个 variant 的 `SAME_INPUT_*_PROCESS_WISE_PERFORMANCE_REPORT.md`，其中包含 `Layer/component Source Latency` 和 `FX Process Latency Attribution` 两张汇总表；如需全局聚合报告再显式加 `--write-aggregate-report`。迁移时要保留 `--match-mode exact` 的严格匹配语义，除非报告中明确标注 nearest-shape fallback。

协作方式：第 1 步产出可复现实验与原始采样，第 2 步做严格归因 review，第 3 步形成 layer-wise 证据，第 4 步形成 process-wise 解释。除第 2 步外，其余步骤主要按 schema、coverage、row count 和 audit JSON 自动检查；只有 coverage 异常、脚本缺失或迁移语义不清时再人工 review。

## E2 单层推理过程 UML 时序图

下面用 `e2_single_request_latency` 中的一次真实 Nsight 记录建模一个 layer 的
推理过程。选择的对象是：

```text
run tag        nsys_e2_visipruner_full_eager_32tok
config         visipruner-full
backend        eager VisiPruner, use_flash_attn=False
layer event    event_id=0, visprune.layer00.prefill
shape          q_len=624, kv_len=624
workload       eager_visipruner_prefill_shallow_layer0_mass_fold
operator path  eager QK^T/softmax/AV attention; shallow post-softmax edits;
               o_proj GEMM; MLP GEMMs
```

证据来自：

- `autoresearch/experiments/e2_single_request_latency/output/nsys_e2_visipruner_full_eager_32tok.json`
- `autoresearch/experiments/e2_single_request_latency/output/nsys_e2_visipruner_full_eager_32tok_layer_events.csv`
- `autoresearch/experiments/e2_single_request_latency/output/nsys_e2_visipruner_full_eager_32tok_layer_kernel_breakdown.csv`
- `autoresearch/experiments/e2_single_request_latency/output/nsys_e2_visipruner_full_eager_32tok.sqlite`
- `autoresearch/experiments/e2_single_request_latency/code/profile_visprune_single_request.py`

该 layer 的关键观测值：

| 观测项 | 值 |
|---|---:|
| `visprune.layer00.prefill` NVTX CPU range | 2.930888 ms |
| `visprune.layer00.prefill.attn` NVTX CPU range | 2.079071 ms |
| `visprune.layer00.prefill.mlp` NVTX CPU range | 0.249649 ms |
| NVTX CPU range 内 CUDA Runtime API 调用数 | 53 |
| NVTX CPU range 内 CUPTI launch-owned kernel 数 | 53 |
| CUPTI launch-owned `kernel_total_ms` | 2.077156 ms |
| dominant kernel family | `gemm_tensorcore` |
| `gemm_tensorcore_ms` | 1.695774 ms |
| `elementwise_norm_activation_ms` | 0.237252 ms |
| `copy_gather_cat_ms` | 0.077825 ms |
| `softmax_ms` | 0.050721 ms |
| `selection_reduce_scan_ms` | 0.015584 ms |
| attention component CUPTI launch-owned `kernel_total_ms` | 0.827311 ms |
| MLP component CUPTI launch-owned `kernel_total_ms` | 1.153428 ms |

### 采样与归因机制

这个图说明当前 nsys 采样方式如何把 CPU range、CUDA Runtime、GPU kernel 和
OSRT 事件放到同一条 timeline 上。注意这里的归因规则是 “runtime API start
落在 NVTX range 内，并且 runtime/kernel correlationId 相同”，不是 kernel
执行时间窗和 NVTX range 的 overlap。

<pre>
Diagram: E2_NSIGHT_SAMPLING_AND_LAUNCH_OWNERSHIP
Time/order axis: left -> right.  The diagram is not PlantUML syntax.
Formula:
  owned_runtime(range) = runtime.start inside NVTX_RANGE
  owned_cupti_kernel(range) = kernel.correlationId == runtime.correlationId
  kernel_total_ms           = sum full duration(owned_cupti_kernel)

participant / event source          observed request order
                                     0                                                                  export
                                     ▲                                                                    ▲
CPU_PROCESS / Python+PyTorch    ──▶  |==================== PYTORCH_LAYER_FORWARD_LOOP ====================|
                                     meaning: 真实 Python 进程；执行 eager LLaVA/VisiPrune，打 NVTX range，并提交 CUDA 工作。
                                     action: push NVTX; run eager ATen ops; call CUDA runtime; request-level sync
                                                    │ runtime calls                     │ OS calls
                                                    ▼                                   ▼
NVTX_EVENTS                       ──▶        |==================== NVTX_LAYER_RANGE ====================|
                                             meaning: Nsight NVTX 事件表；记录 range_push/range_pop 的 start/end/text。
                                             action: start/end timestamps define where runtime API starts are accepted.
                                             ▲                                                   ▲
                                             │ range_push                                        │ range_pop

CUPTI_RUNTIME                     ──▶             ┌──CALL c1──┐ ┌──CALL c2──┐       ┌──CALL c3──┐
                                                  meaning: CUPTI Runtime 表；记录 CPU 发出的 launch/copy/sync/alloc API 调用。
                                                  action: if CALL.start is inside NVTX range, keep CALL.correlationId.
                                                  │launch    │ │memcpy    │  ...  │launch    │
                                                  └──────────┘ └──────────┘       └──────────┘
                                                     │            │                │
                                                     │corr=c1     │corr=c2         │corr=c3
                                                     ▼            ▼                ▼
CUDA_DRIVER_STREAM_QUEUE          ──▶               enqueue on stream 7 ─────────────────────────▶
                                                  meaning: CUDA driver/stream 排队视角；提交的工作在 stream 7 上等待 GPU 调度。
                                                               │
                                                               ▼
CUPTI_KERNELS                     ──▶                  ┌─KERNEL c1─┐ ┌─KERNEL c2─┐ ┌─KERNEL c3─┐
                                                       meaning: CUPTI kernel activity；记录真实 GPU kernel 的 start/end/name/correlationId。
                                                       action: full kernel duration is counted when correlationId matches an owned runtime call.
                                                       │ GEMM      │ │ softmax   │ │ tail GEMM │
                                                       └───────────┘ └───────────┘ └───────────┘
                                                                                     ▲
                                                                                     │ tail can finish after NVTX range

OSRT_API                          ──▶                         ┌─IOCTL/POLL/THREAD_EVENT─┐
                                                              meaning: OS runtime 采样；展示 driver ioctl、poll 和线程事件。
                                                              └─────────────────────────┘

NSIGHT_CUPTI_COLLECTOR            ──▶  records NVTX_EVENTS + CUPTI_RUNTIME + CUPTI_KERNEL + OSRT_API independently
                                       meaning: nsys 采集器；采集 cuda,nvtx,cublas,osrt 并导出 SQLite 证据表。
                                                                  │
                                                                  ▼
POSTPROCESS_ANALYZER              ──▶  |==================== SQLITE_RANGE_JOIN_AND_AGGREGATE ====================|
                                       meaning: analyze_layer_nsys.py；用 Runtime correlationId -> Kernel correlationId 计算 launch ownership。
                                       action: read SQLite; keep runtime.start inside range; aggregate matched full kernel durations by family.
                                                                  │
                                                                  ▼
OUTPUT_FILES                       ──▶  layer_events.csv + layer_kernel_breakdown.csv/json
                                       meaning: 后处理输出；本节观测值和 CUPTI launch-owned summary 的来源。

Representative elements:
RUNTIME_CALL = cudaLaunchKernel / cudaMemcpyAsync / cudaStreamSynchronize
KERNEL       = gemm_tensorcore / softmax / copy_gather_cat / selection_reduce_scan
OSRT_EVENT   = ioctl / poll / pthread_cond_signal
</pre>

### layer00.prefill 推理过程

这个图把上面的采样机制落到一个具体 layer。时间均以
`visprune.layer00.prefill` 的 NVTX start 为 `+0.000 ms`。

<pre>
Diagram: E2_LAYER00_PREFILL_SEQUENCE
Run: nsys_e2_visipruner_full_eager_32tok
Time axis: milliseconds from NVTX start of visprune.layer00.prefill.  Horizontal scale is compressed.

time(ms)              0.000        0.300        0.600        0.900        1.200        1.500        1.800        2.100        2.400        2.700        2.930  3.106
                      ▲            ▲            ▲            ▲            ▲            ▲            ▲            ▲            ▲            ▲            ▲      ▲

CPU_LAYER_RANGE       0.000000..2.930888  ──▶  |============================ LAYER00_PREFILL_CPU_RANGE ============================|
                                                meaning: layer.forward 的 CPU/NVTX scope；不是该 layer 的完整 GPU 执行耗时。
                                                note: q_len=624, kv_len=624, eager_visipruner_prefill_shallow_layer0_mass_fold

CPU_ATTN_RANGE        0.309738..2.388809  ──▶       |======================= ATTN_CPU_RANGE =======================|
                                                    meaning: layer.self_attn.forward 的 CPU/NVTX scope；GPU kernel 可能滞后执行。
                                                    note: eager QK^T, softmax, AV, shallow post-softmax edit, o_proj enqueue

CPU_MLP_RANGE         2.649489..2.899138  ──▶                                                                 |====== MLP_CPU_RANGE ======|
                                                                                                             meaning: layer.mlp.forward 的 CPU/NVTX scope。
                                                                                                             note: MLP GEMM enqueue; full GPU GEMM interval can extend past the scope.

RUNTIME_LAUNCHES      selected launch intervals ──▶      [73181] [73200] [73219]        [73452]    [73495]  [73563][73580][73599] [73623]     [73676]       [73805]
                                                         meaning: CUPTI Runtime API 调用；CPU 请求 CUDA launch/copy/sync，不代表 kernel 已完成。
                                                         0.404   0.476   0.522          1.455      1.811    1.989  2.043  2.095   2.173       2.355         2.721
                                                         │       │       │              │          │        │      │      │       │           │             │
                                                         ▼       ▼       ▼              ▼          ▼        ▼      ▼      ▼       ▼           ▼             ▼
GPU_STREAM7_KERNELS   kernel intervals      ──▶  |EARLY_NORM_COPY_REDUCE 0.048263..0.278859|
                                                 meaning: stream 7 上的真实 GPU kernel 区间；单个 duration 是 kernel 级证据。
                                                 |QKV_GEMM_CLUSTER       0.413837..0.816084|
                                                 |ROPE_ELEMWISE_COPY     0.932662..1.720708|
                                                 |SOFTMAX                1.822054..1.872775|
                                                 |SHALLOW_EDIT           1.873415..2.206669|
                                                 |O_PROJ_GEMM            2.363696..2.497490|
                                                 |POST_ATTN_NORM         2.498066..2.620532|
                                                 |MLP_GEMM_WITH_TAIL     2.730966..3.106333| ──▶ tail after layer end
LAUNCH_OWNERSHIP_RULE counted kernels       ──▶  runtime.start in 0.000000..2.930888 and matched kernel.correlationId are counted in full
                                                meaning: 后处理使用的归因规则；tail kernel 也完整计入，因为它由 range 内 runtime call 发起。

OSRT_API              OS events             ──▶                                             |IOCTL_BURST 1.277173..1.788821, ioctl x9|
                                             meaning: Nsight OS runtime 事件；解释 driver/system 活动，不是 VisiPrune 算法步骤。
                                             |POLL_BACKGROUND -3.327193..96.799379, crosses layer time window|

NSIGHT_CUPTI          collected records     ──▶  NVTX range + 53 owned runtime API calls + 53 owned GPU kernels
                                                meaning: 选中 layer 时间窗内的 nsys/CUPTI 采集结果。

POSTPROCESS_OUTPUT    CUPTI launch-owned summary ──▶  range_ms=2.930888; kernel_total_ms=2.077156; dominant_family=gemm_tensorcore
                                                meaning: analyze_layer_nsys.py 生成的 layer_events 与 layer_kernel_breakdown 摘要。


Kernel-family CUPTI launch-owned contribution from LAYER00_PREFILL_CPU_RANGE
Contribution axis: 0.000000 ms                                                                  2.077156 ms
                   ▲                                                                                ▲
filled bar width is proportional to kernel_total_ms=2.077156 ms
gemm_tensorcore             1.695774 ms 81.6% ──▶ |=================================================           |
elementwise_norm_activation 0.237252 ms 11.4% ──▶ |=======                                                     |
copy_gather_cat             0.077825 ms  3.7% ──▶ |==                                                          |
softmax                     0.050721 ms  2.4% ──▶ |=                                                           |
selection_reduce_scan       0.015584 ms  0.8% ──▶ |                                                            |

Representative correlation map:
73181  runtime 0.404209..0.415187  -> GPU GEMM 0.413837..0.547376
73495  runtime 1.811016..1.823188  -> GPU SOFTMAX 1.822054..1.872775
73676  runtime 2.355081..2.363461  -> GPU O_PROJ_GEMM 2.363696..2.497490
73805  runtime 2.720738..2.730981  -> GPU MLP_GEMM 2.730966..3.106333, counted in full by correlationId ownership
</pre>

### 读图边界

这个单层图可以说明：

- CPU 进入/退出 layer、attn、mlp Python/module scope 的时间窗；
- CUDA Runtime/Driver 如何在这些 CPU scope 内 enqueue kernel、memcpy、sync 和 allocator 工作；
- GPU kernel 的真实执行窗口可能滞后于 CPU launch；
- OSRT 中可以看到 driver `ioctl`、后台 `poll` 和少量线程事件；
- 当前 `kernel_total_ms` 如何通过 Runtime correlationId -> Kernel correlationId 计算 launch ownership。

这个单层图不能说明：

- `layer00.prefill` 的 CUPTI launch-owned kernel duration 之和就是 GPU wall-clock layer latency；
- `range_ms - kernel_total_ms` 是严格的 launch overhead 或 CPU-only overhead；
- 嵌套的 layer、attn、mlp breakdown 可以直接相加；
- 没有线程/stack 约束时，时间窗内所有 runtime call 都一定来自同一条 Python 调用栈。
