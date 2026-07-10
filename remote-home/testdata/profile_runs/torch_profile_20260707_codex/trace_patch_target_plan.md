# 三种长上下文 profile 的 trace patch 目标计划

## 范围与清理结论

本次只保留原有三种吞吐测试上下文长度：

| Context | Dataset | Input tokens | Output tokens | TTFT ms | TPOT ms | E2E ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 4-8K | `4-8K_throughput.jsonl:1` | 7574 | 88 | 4350.36 | 69.76 | 10419.54 |
| 8-16K | `8-16K_throughput.jsonl:1` | 13962 | 92 | 12303.98 | 71.01 | 18765.48 |
| 16-32K | `16-32K_throughput.jsonl:1` | 20574 | 23 | 24631.13 | 71.79 | 26210.50 |

代码入口已收敛到 `remote-home/testdata/run_torch_profile_contexts.sh`，默认 `CONTEXTS=4-8K,8-16K,16-32K`，`profile_plan.tsv` 也只包含这三行。当前结果目录只包含 `contexts/{4-8K,8-16K,16-32K}` 和 `bench_results/{4-8K,8-16K,16-32K}`。

## Profile 证据

`4-8K`：
- `execute_context_0(0)_generation_1(1)`：6.142s，88 次，decode 阶段占比最高。
- `execute_context_1(4096)_generation_0(0)`：1.604s，1 次；`execute_context_1(3489)_generation_0(0)`：2.703s，1 次。
- `vllm::unified_attention_with_output`：2.736s，32 次。
- `ChunkGatedDeltaRuleFunction`：185.358ms，96 次。

`8-16K`：
- `execute_context_1(4096)_generation_0(0)`：9.708s，3 次；`execute_context_1(1685)_generation_0(0)`：2.533s，1 次。
- `vllm::unified_attention_with_output`：9.372s，64 次。
- `execute_context_0(0)_generation_1(1)`：6.539s，92 次。
- `ChunkGatedDeltaRuleFunction`：342.764ms，192 次。

`16-32K`：
- `execute_context_1(4096)_generation_0(0)`：24.218s，5 次；`execute_context_1(105)_generation_0(0)`：341.650ms，1 次。
- `vllm::unified_attention_with_output`：20.299s，96 次。
- `execute_context_0(0)_generation_1(1)`：1.663s，23 次。
- `ChunkGatedDeltaRuleFunction`：507.333ms，288 次。

注意：profile 事件名里的上下文 token 数比 bench `Input tokens` 多约 11 个 token，运行时以 scheduler/model runner 的 `num_scheduled_tokens` 为准；差异通常来自 chat template 或 special token 包装。

## 过程问题

`4-8K` 需要回答：
- 2 个 chunked prefill 步是如何形成的，为什么后一个 3489-token chunk 比 4096-token chunk 更慢。
- 88 次 decode 中 GEMM 与 attention 的占比如何随 seq_len 增长。
- 请求为何在 88 个输出 token 后结束。

`8-16K` 需要回答：
- 3 个完整 4096-token prefill chunk 与 1 个 remainder chunk 的 scheduler 决策。
- attention 时间为何已经接近总 CUDA 时间的一半。
- 92 次 decode 的每步 batch、seq_len 与 KV cache 状态是否稳定。

`16-32K` 需要回答：
- 5 个完整 4096-token prefill chunk 与 1 个 105-token remainder chunk 的形成原因。
- `unified_attention_with_output`/`kernel_unified_attention_2d` 为什么成为主瓶颈。
- decode 只有 23 次时，停止原因来自 EOS、max token 还是服务侧输出限制。

## Patch 目标

| 优先级 | 边界 | 目标代码 | 记录字段 | 作用 |
| --- | --- | --- | --- | --- |
| P0 | engine iteration | `vllm/v1/engine/core.py:EngineCore.step()` 和 `step_with_batch_queue()` | `engine_step_id`、rank、timestamp、`total_num_scheduled_tokens`、`model_executed`、输出 req 数 | 串起 schedule、execute、sample、update 的主时间线。 |
| P0 | scheduler output | `vllm/v1/core/sched/scheduler.py:Scheduler.schedule()`；输出结构在 `vllm/v1/core/sched/output.py:SchedulerOutput` | `request_id`、`num_scheduled_tokens`、`scheduled_new_reqs`、`scheduled_cached_reqs`、waiting/running 数、`num_common_prefix_blocks`、`new_block_ids_to_zero` | 解释每个 4096/remainder prefill chunk 和每步 decode。 |
| P0 | model execution | `vllm/v1/worker/gpu/model_runner.py:GPUModelRunner.execute_model()` | `forward_id`、`engine_step_id`、`req_ids`、`num_reqs`、`num_toks`、`max_query_len`、`batch_desc.cg_mode`、`num_tokens_after_padding` | 对齐 profiler 中的 `execute_context_*` 事件。 |
| P0 | batch construction | `GPUModelRunner.prepare_inputs()` 和 `prepare_attn()` | `req_ids`、`num_scheduled_tokens`、`query_start_loc` 摘要、`seq_lens` 摘要、`num_tokens_after_padding`、block table 形状、slot mapping 形状 | 证明 runtime batch 形态，而不是从 kernel 名字反推。 |
| P0 | attention semantic boundary | `vllm/model_executor/layers/attention/attention.py:Attention.forward()`、`unified_attention_with_output()`；后端 `rocm_attn.py:RocmAttentionImpl.forward()` 或 `triton_attn.py:TritonAttentionImpl.forward()` | `forward_id`、`layer_name`、`layer_idx`、`num_actual_tokens`、`max_query_len`、`max_seq_len`、`query_start_loc`/`seq_lens` 摘要、backend 名称 | 解释 `unified_attention_with_output` 与 2D/3D kernel 的上层语义来源。 |
| P1 | KV cache/block allocation | `vllm/v1/core/kv_cache_manager.py:KVCacheManager.get_computed_blocks()`、`allocate_slots()`、`take_new_block_ids()` | `request_id`、`num_new_tokens`、prefix hit tokens、`num_blocks_to_allocate`、free blocks、new block ids 数、cache usage | 解释 chunk 之间的 block 分配、prefix cache 命中和 cache 压力。 |
| P1 | sampling/output | `vllm/v1/worker/gpu/model_runner.py:sample()`、`sample_tokens()`；`vllm/v1/worker/gpu/sample/sampler.py:Sampler.__call__()` | `request_id`、`num_sampled`、sampled token 小摘要、finish reason、generated token count | 解释 88/92/23 个输出 token 和 decode 终止。 |
| P2 | Qwen3.5 hybrid layer | `vllm/model_executor/models/qwen3_5.py:Qwen3_5DecoderLayer`、`Qwen3_5GatedDeltaNet.forward()` | `layer_idx`、`layer_type`、`num_tokens`、GDN state/shape 摘要 | 只在需要解释 `ChunkGatedDeltaRuleFunction` 或 `gdn_attention_core` 残余时间时启用。 |

## Join keys

所有事件都应带这些 join key：
- `request_id`：跨 scheduler、batch、sampling/output 串联单请求。
- `engine_step_id`：跨 `EngineCore.step()`、scheduler output、model execute 串联每次迭代。
- `forward_id`：跨 model runner、attention、KV cache update 串联一次 forward。
- `rank`/`local_rank`：为多卡或未来 TP/DP 扩展保留。
- `phase`：由 `num_scheduled_tokens` 与请求状态推导，取 `prefill_chunk`、`decode`、`mixed`。
- `layer_idx`/`layer_name`：仅 attention/GDN/layer 级事件使用。

## 各上下文的最小 patch 集

`4-8K`：
- 必需：engine iteration、scheduler output、model execution、attention、sampling/output。
- 可选：KV cache/block allocation，用于确认两个 prefill chunk 的 block 形态。
- 不建议默认打开 Qwen3.5 GDN 层级插桩，因为 GDN 自身只占约 1.8%。

`8-16K`：
- 必需：scheduler output、model execution、batch construction、attention、KV cache/block allocation、sampling/output。
- 重点验证 3 个 4096-token chunk 和 1 个 remainder chunk 的 schedule 记录是否与 profiler 一致。

`16-32K`：
- 必需：scheduler output、model execution、batch construction、attention、KV cache/block allocation。
- sampling/output 只需记录终止原因和 23 个输出 token；它不是主耗时来源。
- Qwen3.5 GDN 层级插桩仍为可选，主要用于解释非 attention 的剩余时间。

## 不建议 patch 的对象

- 不 patch `Cijk_*` GEMM kernel、`aten::mm`、`kernel_unified_attention_2d/3d` 的内部实现。它们是 profiler 的低层耗时对象，但缺少 request/step/layer 语义 join key。
- 不 patch `CompiledFxGraph` 内部。应在 `GPUModelRunner.execute_model()` 和 attention custom op 边界记录上下文。
- 不记录完整 logits、hidden states、KV cache tensor、block table 全量内容。只记录 shape、计数、短摘要和必要 ID。
- 不对所有 layer 全量同步打印。若打开 layer 级插桩，应按 layer type 或 layer_idx 采样，避免改变吞吐测试行为。

## 验证准则

1. 关闭插桩与开启插桩的请求结果应在 `temperature=0` 下保持相同终止行为，benchmark 仍为 `completed=1 failed=0`。
2. 事件计数应匹配 profiler 证据：
   - `4-8K`：2 个 prefill chunk，88 个 decode step。
   - `8-16K`：4 个 prefill chunk，92 个 decode step。
   - `16-32K`：6 个 prefill chunk，其中 5 个完整 4096-token chunk 和 1 个 remainder chunk，23 个 decode step。
3. 每个 attention 事件都能通过 `forward_id + layer_name` 回连 model execute，并通过 `engine_step_id + request_id` 回连 scheduler output。
4. KV cache 事件能解释每个 prefill chunk 的 block 分配数量，且不触发大 tensor CPU 拷贝。
5. trace 事件写入应采用轻量结构化日志或 profiler record scope，不在热路径打印大文本。
