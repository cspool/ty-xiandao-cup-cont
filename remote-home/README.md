# 长上下文 Profile 与 Patch Trace 阅读指南

## 单卡吞吐优化计划

vLLM CSCC/DCU 单卡长上下文吞吐优化计划已经单独整理到：

- `docs/vllm_cscc_single_card_throughput_optimization_plan.md`

不执行实验的 benchmark 环境骨架位于：

- `testdata/optimization_env/`

该环境只包含参数矩阵、命令生成、结果汇总模板和 speculative decoding 禁用检查；不包含 trace、patch trace 或 FX trace 初始化。

本文档汇总 `testdata` 下原有三种吞吐测试上下文长度的 torch profile 结果、patch trace 结果和分析结论。当前只包含：

- `4-8K`
- `8-16K`
- `16-32K`

没有保留额外上下文长度的结果。

## 结果目录

Torch profiler 结果：

- 汇总：`testdata/profile_runs/torch_profile_20260707_codex/profile_summary.md`
- 插桩目标计划：`testdata/profile_runs/torch_profile_20260707_codex/trace_patch_target_plan.md`
- 每组 profiler 表：`testdata/profile_runs/torch_profile_20260707_codex/contexts/<context>/raw_traces/profiler_out_0.txt`
- 每组 torch trace：`testdata/profile_runs/torch_profile_20260707_codex/contexts/<context>/raw_traces/rank0.*.pt.trace.json.gz`

Patch trace 结果：

- 汇总：`testdata/profile_runs/patch_trace_20260707_codex/patch_trace_summary.md`
- 机器可读汇总：`testdata/profile_runs/patch_trace_20260707_codex/patch_trace_summary.json`
- 每组 JSONL trace：`testdata/profile_runs/patch_trace_20260707_codex/contexts/<context>/patch_trace/events.*.jsonl`
- 每组 benchmark 结果：`testdata/profile_runs/patch_trace_20260707_codex/contexts/<context>/result.json`

相关脚本：

- 重新跑 torch profile：`testdata/run_torch_profile_contexts.sh`
- 重新跑 patch trace：`testdata/run_patch_trace_contexts.sh`
- 重新汇总 patch trace：`testdata/summarize_patch_trace.py`
- runtime monkey patch：`testdata/trace_patch/vllm_trace_patch.py`

## Profile 阅读方法

先读 `profile_summary.md`，确认三组输入/输出 token 和 TTFT/TPOT/E2E。再进入对应 context 的 `profiler_out_0.txt` 看 Self CUDA 排序。

关键事件含义：

- `execute_context_1(<N>)_generation_0(0)`：prefill/chunked prefill，`<N>` 是本次调度的上下文 token 数。
- `execute_context_0(0)_generation_1(1)`：decode step。
- `vllm::unified_attention_with_output` 和 `kernel_unified_attention_2d/3d`：attention kernel 的 profiler 视角。
- `Cijk_*`、`aten::mm`、`CompiledFxGraph`：底层算子或编译图，不适合作为算法 trace 的 patch 点。

注意：profiler 事件名中的 context token 数比 benchmark 的 `Input tokens` 多约 11 个 token，运行时应以 scheduler/model runner 的 `num_scheduled_tokens` 为准。差异来自 chat template 或 special token 包装。

## Patch Trace 阅读方法

先读 `patch_trace_summary.md`。它已经验证：

- `completed=1`
- `failed=0`
- 必需事件类型齐全
- `missing_join_keys={}`
- `patch_errors=0`
- prefill/decode 事件计数符合预期

如果要看完整过程，读取 `events.*.jsonl`。每行是一个结构化事件，按 `ts_ns` 排序即可还原执行过程。最大的一份通常是 EngineCore 进程的事件文件。

主要事件类型：

- `scheduler_step`：scheduler 每步选择了哪些 request、调度多少 token、phase 是 `prefill_chunk` 还是 `decode`。
- `model_execute_begin` / `model_execute_end`：一次 model forward 的边界。
- `batch_constructed`：runtime batch 的 request、token 数、computed token 状态。
- `attention_batch_metadata`：attention metadata 构造结果。
- `attention_forward_begin` / `attention_forward_end`：attention backend 调用边界，带 `layer_name`。
- `kv_get_computed_blocks` / `kv_allocate_slots` / `kv_take_new_block_ids`：KV cache/block 分配过程。
- `sampler_call` / `sample_tokens`：采样边界。
- `scheduler_update_output`：输出 token、finish reason、停止信息。

核心 join key：

- `request_id`：连接 scheduler、KV、输出。
- `engine_step_id`：连接 scheduler step、model execute、scheduler update。
- `forward_id`：连接 model execute、batch、attention、sampler。
- `layer_name`：连接 attention 事件到具体层。

常用检查命令：

```bash
python3 testdata/summarize_patch_trace.py testdata/profile_runs/patch_trace_20260707_codex
```

```bash
python3 - <<'PY'
import json
from pathlib import Path

summary = Path("testdata/profile_runs/patch_trace_20260707_codex/patch_trace_summary.json")
for item in json.loads(summary.read_text()):
    print(item["label"], item["prefill_chunk_tokens"], item["decode_step_count"],
          item["validation"])
PY
```

## Profile 结论

| Context | Profile 指标 | 主要耗时证据 |
| --- | --- | --- |
| `4-8K` | input 7574，output 88，TTFT 4350.36 ms，TPOT 69.76 ms，E2E 10419.54 ms | decode 事件 `execute_context_0(0)_generation_1(1)` 为 6.142s/88 次；prefill 为 4096 + 3489 两块；attention 为 2.736s/32 次。 |
| `8-16K` | input 13962，output 92，TTFT 12303.98 ms，TPOT 71.01 ms，E2E 18765.48 ms | prefill 4096 块 3 次加 1685 remainder；attention 为 9.372s/64 次；decode 为 6.539s/92 次。 |
| `16-32K` | input 20574，output 23，TTFT 24631.13 ms，TPOT 71.79 ms，E2E 26210.50 ms | prefill 4096 块 5 次加 105 remainder；attention 为 20.299s/96 次；decode 只有 1.663s/23 次。 |

总体上，随着上下文变长，prefill 和 attention 的占比快速上升；`16-32K` 已经明显是 prefill/attention 主导。TPOT 在三组中都约 70 ms，说明单请求 decode 每步成本相对稳定，差异主要来自 TTFT/prefill。

`ChunkGatedDeltaRuleFunction` 和 `vllm::gdn_attention_core` 在 profile 中可见，但占比远低于 attention 主路径。除非目标是解释 Qwen3.5 hybrid/GDN 内部状态，否则不应优先 patch 这些底层函数。

## Patch Trace 结论

| Context | Patch trace 结构 | Benchmark 结果 | 停止原因 |
| --- | --- | --- | --- |
| `4-8K` | prefill chunks `[4096, 3489]`，decode steps `88` | completed 1，failed 0，output 88 | `finish_reason=stop` |
| `8-16K` | prefill chunks `[4096, 4096, 4096, 1685]`，decode steps `92` | completed 1，failed 0，output 92 | `finish_reason=stop` |
| `16-32K` | prefill chunks `[4096, 4096, 4096, 4096, 4096, 105]`，decode steps `23` | completed 1，failed 0，output 23 | `finish_reason=stop` |

Patch trace 直接证明了 profiler 中的 prefill chunk 结构来自 scheduler 的 `num_scheduled_tokens`。`max_num_batched_tokens=4096` 是完整 chunk 的上限，最后一个 chunk 是剩余 token。

Patch trace 也证明了输出长度不是 benchmark 的 `custom-output-len=1024` 达到上限导致，而是请求在生成 88/92/23 个 token 后以 `stop` 结束。

## Selected-Layer FX Trace 阅读方法

Selected-layer FX trace 的目标不是重新做吞吐测试，而是在 layerwise patch 证据上挑出少量值得深入的 decoder layers，用固定 runtime 输入生成可读的 FX DAG。远端执行使用源码编译得到的 vLLM；本次 patch 直接适配当前源码中的 `Qwen3_5DecoderLayer.forward(self, hidden_states, residual, positions=None, **kwargs)`，不是按发行 wheel 的实现假设。

结果目录：

- 汇总：`testdata/profile_runs/selected_layer_fx_20260707_codex/selected_layer_fx_trace_summary.md`
- 机器可读汇总：`testdata/profile_runs/selected_layer_fx_20260707_codex/selected_layer_fx_trace_summary.json`
- 每组 metadata：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/run_metadata.json`
- 每组 manifest：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/fx_layer_trace_manifest.csv`
- 每组 layer event 记录：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/fx_layer_events.csv`
- 每个 FX 事件目录：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/traces/<event_id>/`

相关脚本：

- selected-layer FX patch：`testdata/fx_trace_patch/vllm_selected_layer_fx_patch.py`
- sitecustomize 入口：`testdata/fx_trace_patch/sitecustomize.py`
- 运行三组上下文：`testdata/run_selected_layer_fx_trace_contexts.sh`
- 汇总和校验：`testdata/summarize_selected_layer_fx_trace.py`

阅读顺序：

1. 先读 `selected_layer_fx_trace_summary.md`，确认每组 `FX OK=3`、`FX Errors=0`、`Missing artifacts=0`。
2. 再读对应 context 的 `run_metadata.json`，重点看 `target_event_keys`、`captured_events`、`fx_sample_count`、`fx_trace_count`、`fx_trace_error_count`。
3. 用 `fx_layer_trace_manifest.csv` 定位每个事件的 `trace_dir`、`forward_id`、`layer_id`、`q_len`、`node_count` 和 `status`。
4. 进入单个 `trace_dir` 读 `fx_graph.py` 或 `fx_graph.txt` 看图结构；读 `fx_nodes.json` 做程序化分析；`fx_graph_module.pt` 和 `fx_graph_module/` 是可加载的 GraphModule 形式。
5. 单事件的 `fx_trace_metadata.json` 记录固定输入 shape、layer 类型、原始 forward、输入绑定和 trace 选项。

每个成功事件目录都应包含：

- `fx_graph.py`
- `fx_graph.txt`
- `fx_nodes.json`
- `fx_graph_module.pt`
- `fx_graph_module/`
- `fx_trace_metadata.json`

注意边界：runtime 真实生成仍走 eager layer forward；FX DAG 是在 layer forward 返回后，用 clone 出来的固定输入在 `make_fx` 中 replay 得到的离线图证据。为兼容当前源码编译 vLLM 和 ROCm kernel，trace 时做了 native rotary、plain parameter、unquantized GEMM fallback、RMSNorm unwrap 等临时适配。GraphModule 默认剥离真实 tensor data 后保存为 meta 权重，避免每个事件落盘数百 MB 权重；因此它适合读图结构，不适合当作带真实权重的可执行模型。

## Selected-Layer FX Trace 结论

Layer 选择来自 `patch_trace_20260707_codex` 的 layerwise patch 结果：

- `layer 3`：三组上下文中最稳定、最显著的 full-attention outlier。
- `layer 31`：长上下文下更突出的中后段 outlier。
- `layer 59`：稳定的 late-layer full-attention 代表。

实际捕获事件如下：

| Context | Target events | q_len | Result |
| --- | --- | --- | --- |
| `4-8K` | `input1_layer3`, `input1_layer31`, `input1_layer59` | 4096, 4096, 4096 | 3/3 OK，每图 155 nodes |
| `8-16K` | `input1_layer3`, `input4_layer31`, `input3_layer59` | 4096, 1685, 4096 | 3/3 OK，每图 155 nodes |
| `16-32K` | `input1_layer3`, `input2_layer31`, `input4_layer59` | 4096, 4096, 4096 | 3/3 OK，每图 155 nodes |

三组上下文共 9 个 selected-layer FX trace，全部成功，`fx_trace_error_count=0`，必需 artifact 无缺失。图节点数一致说明这三个 full-attention decoder layer 在这些固定输入下走的是同一类结构路径；不同 context 的差异主要体现在 prefill chunk 序列、目标事件位置和输入长度，而不是 layer 内部图结构发生分支变化。

这组 FX 结果应和 patch trace 分工阅读：patch trace 解释 request/scheduler/attention/KV 的运行时过程，FX trace 解释被选中 decoder layer 在固定输入下的图结构。不要把 FX DAG 当作完整 runtime op 覆盖，也不要用 eager+FX 的 benchmark 时间替代前面 profile/patch trace 的吞吐结论。

## Selected-Layer FX Process 重建与可视化

Process 重建使用上面的 9 个 selected-layer FX trace，不重新跑 vLLM。重建脚本只生成证据文件：process 分组、node 表、node ranges、targets、users、shape/dtype metadata；解释和图放在单独的手工可视化文档中。

结果目录：

- 汇总：`testdata/profile_runs/selected_layer_fx_20260707_codex/selected_layer_fx_process_summary.md`
- 机器可读汇总：`testdata/profile_runs/selected_layer_fx_20260707_codex/selected_layer_fx_process_summary.json`
- 手工可视化：`testdata/profile_runs/selected_layer_fx_20260707_codex/selected_layer_fx_process_visualization.md`
- 每个 event 的重建：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/traces/<event_id>/fx_process_reconstruction.md`
- 每个 event 的机器可读重建：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/traces/<event_id>/fx_process_reconstruction.json`
- 每个 event 的 node 表：`testdata/profile_runs/selected_layer_fx_20260707_codex/contexts/<context>/fx_trace/traces/<event_id>/fx_process_nodes.csv`

相关脚本：

- process 重建：`testdata/reconstruct_selected_layer_fx_processes.py`

阅读顺序：

1. 先读 `selected_layer_fx_process_summary.md`，确认 9 个 event 都完成、`All nodes assigned=True`、`No duplicate assignments=True`。
2. 读 `selected_layer_fx_process_visualization.md`，它按共同的 155-node DAG 手工解释 12 个 process，并画 tensor-axis/rectangle-axis 图。注意其中 `S` 表示当前 prefill chunk 长度：8 个 event 是 `4096`，`8-16K/input4_layer31` 是 `1685`。
3. 进入具体 event 目录读 `fx_process_reconstruction.md`，查看该 event 的 process table、node ranges、target set 和每个 node 的 shape/users。
4. 需要程序化分析时用 `fx_process_reconstruction.json` 和 `fx_process_nodes.csv`。

12 个 process 分组：

- `runtime_inputs`
- `pre_attention_residual_rmsnorm`
- `qkv_projection_and_split`
- `q_head_rmsnorm`
- `k_head_rmsnorm`
- `mrope_table_lookup`
- `q_rope_apply`
- `k_rope_apply`
- `vllm_attention_and_kv_cache`
- `attention_gate_projection_residual`
- `post_attention_rmsnorm`
- `mlp_and_layer_output`

重建结论：9 个 event 全部是 `155` 个 FX nodes、`12` 个 process、节点覆盖 `155/155`、无重复分配。`layer 3/31/59` 在这些 full-attention prefill chunk 上的 layer 内部固定输入 DAG 结构一致；差异主要是 context、forward id、layer id 和 `S`。当前 FX 图中 `vllm.unified_attention_with_output` 是 custom op 边界，不能从 FX nodes 展开 QK score、mask、softmax 或 weighted-V kernel 细节。

## Selected-Layer FX Process Latency

Process latency 使用 `selected_layer_fx_process_visualization.md` 中的 12 个 process 作为索引，对三种上下文范围的 9 个 selected-layer event 记录每个 process 的同步 device range duration。

结果目录：

- 阅读文档：`testdata/profile_runs/selected_layer_fx_20260707_codex/process_latency/selected_layer_fx_process_latency.md`
- event/process 汇总：`testdata/profile_runs/selected_layer_fx_20260707_codex/process_latency/process_latency_summary.csv`
- context median 汇总：`testdata/profile_runs/selected_layer_fx_20260707_codex/process_latency/process_latency_context_summary.csv`
- 原始 range：`testdata/profile_runs/selected_layer_fx_20260707_codex/process_latency/contexts/<context>/trace/process_latency_events.csv`

覆盖结论：`4-8K`、`8-16K`、`16-32K` 均为 `36/36` 个 patch range，合计 `108/108` 个 process latency；`8-16K/input4_layer31` 保留 `q_len=1685` 的短 chunk 结果。`hipprof --hip-trace --hiptx-trace` 已运行并保留 DB/log，但当前 vLLM server 的 EngineCore worker 没有被 hipprof timeline 捕获，DB 重建日志为 `has not valid trace data`；因此当前 latency 表中的数值来自 patch 记录的同步 device range duration，不来自 HIPTX timeline。

## 为什么不 Patch 底层 Kernel

本次 patch 的目标是恢复算法级执行过程，而不是复制 profiler 的底层耗时表。因此 patch 放在这些语义边界：

- engine iteration
- scheduler decision
- model execution
- batch construction
- attention backend boundary
- KV cache/block allocation
- sampler/output update

不 patch：

- `Cijk_*` GEMM kernel
- `kernel_unified_attention_2d/3d`
- `aten::mm`
- `CompiledFxGraph` 内部
- logits、hidden states、KV cache tensor 的完整内容

原因是这些底层对象没有稳定的 `request_id`、`engine_step_id`、`forward_id` 等 join key，难以解释 request-level 的调度和 phase 转换。

## 复现说明

重新跑三组 patch trace：

```bash
cd testdata
PATCH_TRACE_RUN_DIR=./profile_runs/patch_trace_YYYYMMDD_name ./run_patch_trace_contexts.sh
```

只跑某一组：

```bash
cd testdata
PATCH_TRACE_RUN_DIR=./profile_runs/patch_trace_smoke CONTEXTS=4-8K ./run_patch_trace_contexts.sh
```

重新生成汇总：

```bash
python3 testdata/summarize_patch_trace.py testdata/profile_runs/patch_trace_20260707_codex
```

重新跑三组 selected-layer FX trace：

```bash
cd testdata
FX_TRACE_RUN_DIR=./profile_runs/selected_layer_fx_YYYYMMDD_name ./run_selected_layer_fx_trace_contexts.sh
```

只跑某一组 selected-layer FX trace：

```bash
cd testdata
FX_TRACE_RUN_DIR=./profile_runs/selected_layer_fx_smoke CONTEXTS=4-8K ./run_selected_layer_fx_trace_contexts.sh
```

重新生成 selected-layer FX trace 汇总：

```bash
python3 testdata/summarize_selected_layer_fx_trace.py testdata/profile_runs/selected_layer_fx_20260707_codex
```

重新生成 selected-layer FX process 重建：

```bash
python3 testdata/reconstruct_selected_layer_fx_processes.py testdata/profile_runs/selected_layer_fx_20260707_codex
```

`run_*_contexts.sh` 会分别启动新的 vLLM server，跑完当前 context 后停止 server，避免 profile/trace 状态在不同上下文之间串扰。`summarize_*` 和 `reconstruct_selected_layer_fx_processes.py` 只读取已有结果，不重新启动 vLLM。
