# Selected-layer FX Process Latency

索引文档：`/data3/Projects/scnet_ssh/remote-home/testdata/profile_runs/selected_layer_fx_20260707_codex/selected_layer_fx_process_visualization.md`

## 采集方式

- 对 12 个 FX process group 使用同一套 `order/process_id/title` 索引。
- 远程容器中已运行 `hipprof --hip-trace --hiptx-trace` 包裹 vLLM server，并保留每个 context 的 hipprof DB/log。
- range 来自 `process_latency_patch` 的 Python 接口注入，不修改已安装 vLLM wheel 文件。
- 为了让 kernel 落在对应 range 内，目标 layer profiling 时默认在每个 process 前后做 device synchronize；因此这里是 profiling-instrumented latency，不是吞吐 benchmark 的无扰动端到端延迟。
- 目标 layer 的 RMSNorm/RoPE 使用 Python-visible native 边界，以便和 FX process 6/7/8/10/11 分组一致。
- 当前 vLLM server 路径仍会把模型执行放到 EngineCore worker；已尝试 `--disable-frontend-multiprocessing` 和 `VLLM_ENABLE_V1_MULTIPROCESSING=0`，hipprof DB 重建仍报告 `has not valid trace data`，因此本文表格使用 patch 写出的同步 device range latency，HIPTX 列保留为诊断字段。

## 覆盖范围

| context | events | q_len | HIPTX ranges | patch ranges |
| --- | --- | --- | ---: | ---: |
| 4-8K | input1_layer3, input1_layer31, input1_layer59 | 4096 | 0/36 | 36/36 |
| 8-16K | input1_layer3, input3_layer59, input4_layer31 | 1685, 4096 | 0/36 | 36/36 |
| 16-32K | input1_layer3, input2_layer31, input4_layer59 | 4096 | 0/36 | 36/36 |

## Context Median Latency

单位：ms。优先使用 hipprof HIPTX range；括号内是 patch 同步 CPU duration 的 median，作为 hipprof 缺失时的兜底读数。

| # | process | 4-8K | 8-16K | 16-32K |
| ---: | --- | ---: | ---: | ---: |
| 1 | `runtime_inputs` | (0.047) | (0.055) | (0.105) |
| 2 | `pre_attention_residual_rmsnorm` | (0.384) | (0.360) | (0.599) |
| 3 | `qkv_projection_and_split` | (2.339) | (2.326) | (2.445) |
| 4 | `q_head_rmsnorm` | (0.447) | (0.462) | (0.478) |
| 5 | `k_head_rmsnorm` | (0.273) | (0.283) | (0.276) |
| 6 | `mrope_table_lookup` | (0.479) | (0.519) | (0.503) |
| 7 | `q_rope_apply` | (0.655) | (0.675) | (0.705) |
| 8 | `k_rope_apply` | (0.319) | (0.322) | (0.320) |
| 9 | `vllm_attention_and_kv_cache` | (48.881) | (135.900) | (151.938) |
| 10 | `attention_gate_projection_residual` | (1.368) | (1.337) | (1.397) |
| 11 | `post_attention_rmsnorm` | (0.802) | (0.756) | (0.757) |
| 12 | `mlp_and_layer_output` | (7.588) | (7.933) | (7.979) |

## Event-level 明细

完整 event/process 明细见 `process_latency_summary.csv`；下面只列每个 event 是否完整。

| context | event | q_len | HIPTX processes | patch processes |
| --- | --- | ---: | ---: | ---: |
| 16-32K | `input1_layer3` | 4096 | 0/12 | 12/12 |
| 16-32K | `input2_layer31` | 4096 | 0/12 | 12/12 |
| 16-32K | `input4_layer59` | 4096 | 0/12 | 12/12 |
| 4-8K | `input1_layer3` | 4096 | 0/12 | 12/12 |
| 4-8K | `input1_layer31` | 4096 | 0/12 | 12/12 |
| 4-8K | `input1_layer59` | 4096 | 0/12 | 12/12 |
| 8-16K | `input1_layer3` | 4096 | 0/12 | 12/12 |
| 8-16K | `input3_layer59` | 4096 | 0/12 | 12/12 |
| 8-16K | `input4_layer31` | 1685 | 0/12 | 12/12 |

## 产物

- `process_latency_summary.csv`: 9 个 event × 12 个 process 的汇总表。
- `process_latency_context_summary.csv`: 每个 context 内跨 3 个 event 的 process median。
- `process_latency_hiptx_ranges.csv`: 从 hipprof JSON 抽出的原始 HIPTX range；当前为空，因为 hipprof DB 未捕获到有效 worker trace。
- `process_latency_patch_ranges.csv`: patch 写出的同步 CPU range。
- `contexts/<context>/hipprof/vllm_process_latency.db` 和 `hipprof_db_timeline.log`: hipprof 原始 DB 与 DB 重建日志。
- `contexts/<context>/trace/process_latency_events.csv`: 目标 layer process range 原始记录。

## 结论

这份结果可以按 process 对比三种上下文范围中的目标层计算耗时。当前所有单元均为括号读数，含义是 patch 已记录同步 device range duration；hipprof 已执行但没有捕获到 EngineCore worker 的有效 HIPTX timeline，不能作为本次 per-process latency 的数值来源。
