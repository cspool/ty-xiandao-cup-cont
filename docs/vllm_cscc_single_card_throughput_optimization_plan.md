# vllm_cscc 单卡单请求吞吐优化计划与阶段性结论

本文档是优化工作的入口文档，只保留优化路线、当前阶段性结论和后续执行计划。完整实验数据与执行约束拆分到独立文档，通过索引项引用。

配套文档：

- [阶段性实验完整结果](./vllm_cscc_stage_experiment_results.md)
- [优化执行和测试约束](./vllm_cscc_optimization_constraints.md)

## 阶段性结论

当前计分有效优化候选是 `H6.1c ROCm AITER Unified Attention backend gating`。后续执行采用增量优化策略：已证明可运行、未破坏正确性且没有明确降速的源码优化可以作为工作基线继续叠加；但最终结论仍按证据区分“可计分收益”和“工程工作基线”。

| 项目 | official baseline | H6.1c | 结论 |
| --- | ---: | ---: | --- |
| 吞吐公式分 | `60.00 / 100` | `69.57 / 100` | `+9.57` 分 |
| 20/50/30 加权吞吐提升 | `0.00%` | `+21.87%` | 有效 |
| 精度系数 | `1.0` | `1.0` | 未观察到精度下降 |
| 综合基准/阶段分 | `60.00 / 100` | `69.57 / 100` | H6.1c 当前保留 |

H6.1c 的收益主要来自长上下文 prefill/TTFT 下降，TPOT 只小幅改善。D1/D2 两个 decode 小样本候选未形成新增有效收益：packed decode 检查跳过只有噪声级变化，AITER decode 强制 2D 分支明确降速。下一阶段若继续，应基于已验证可行的优化栈做增量优化，而不是回退到 official baseline 或丢弃已有可行改动。

当前增量工作基线：

- 计分有效基础：`H6.1c`。
- 可保留的工程基础：`H4.1/H4.2` 的 GDN prefill metadata/no-initial-state 快路径，以及 `D1` 的 GDN decode packed validate 跳过。它们未形成可单独计分的显著收益，但小样本未观察到降速或功能错误，可作为后续源码栈的一部分继续叠加。
- 必须排除：`D2` AITER decode 强制 2D 分支、`H4.3` L2 norm 变体。`H4.4` `wy_fast` tile 变体虽小样本为正，但当前源码已回退；若纳入增量基础，需要单独重放并完成同口径确认。

历史通过多请求并发、修改测试脚本、修改数据集、serve 参数扫描、chunk budget 扫描、prefix cache 或未重新编译 wheel 得到的结果，全部不进入结论。

阶段性结论只引用后两个文档中的索引，不在主计划重复展开完整实验日志或约束细节。

| 结论 ID | 结论 | 依据索引 | 后续动作 |
| --- | --- | --- | --- |
| S0 | official baseline 已完成吞吐和精度闭环，可作为固定比较基线。 | [R0](./vllm_cscc_stage_experiment_results.md#r0-official-baseline-full-all-基准), [C0](./vllm_cscc_optimization_constraints.md#c0-赛题口径), [C1](./vllm_cscc_optimization_constraints.md#c1-固定实验契约), [C3](./vllm_cscc_optimization_constraints.md#c3-测量协议) | 后续候选统一对齐 R0 的 full `all` 口径。 |
| S1 | H6.1c 是当前可计分的有效源码优化候选。 | [R1](./vllm_cscc_stage_experiment_results.md#r1-h61c-rocm-aiter-unified-attention), [R2](./vllm_cscc_stage_experiment_results.md#r2-h61c-accuracy-对照), [C4](./vllm_cscc_optimization_constraints.md#c4-正确性门槛) | 作为计分基础和最终对照继续保留。 |
| S2 | H5.1 的 upstream ROCm FlashAttention 强制优先改变了输出行为，不能计入收益。 | [R3](./vllm_cscc_stage_experiment_results.md#r3-h51-上游-rocm-flashattention-强制优先), [C4](./vllm_cscc_optimization_constraints.md#c4-正确性门槛) | 只有先修复输出、停止原因和精度后才能重开。 |
| S3 | 早期单条 profile 只能指导定位，不能作为验收结论。 | [R4](./vllm_cscc_stage_experiment_results.md#r4-早期单条-profile), [C3](./vllm_cscc_optimization_constraints.md#c3-测量协议), [C5](./vllm_cscc_optimization_constraints.md#c5-profiler-规范) | profiler 结果必须回到固定 full `all` 和 accuracy 闭环验证。 |
| S4 | 下一阶段优化重点转向单请求 decode、GDN/linear attention 和数学等价算子融合。 | [R1](./vllm_cscc_stage_experiment_results.md#r1-h61c-rocm-aiter-unified-attention), [C2](./vllm_cscc_optimization_constraints.md#c2-允许与禁止), [C5](./vllm_cscc_optimization_constraints.md#c5-profiler-规范), [C6](./vllm_cscc_optimization_constraints.md#c6-源码边界) | 先做无扰动 HIP timeline，再按 H1/H4/H9 等假设实施。 |
| S5 | H4.1/H4.2 可作为增量工作基线保留，但不单独计入有效性能突破；H4.3/H4.4 不默认保留。 | [R5](./vllm_cscc_stage_experiment_results.md#r5-h41-gdn-prefill-state-初始化快路径), [R6](./vllm_cscc_stage_experiment_results.md#r6-h42-gdn-prefill-no-initial-state-specialization), [R7](./vllm_cscc_stage_experiment_results.md#r7-h43-fla-l2-norm-kernel-变体), [R8](./vllm_cscc_stage_experiment_results.md#r8-h44-gdn-prefill-wy_fast-tile-变体) | 后续在当前优化栈上叠加；若重开 GDN prefill，必须先有 profiler 归因。 |
| S6 | D1 可作为增量工作基线保留；D2 明确降速并已回滚。 | [R9](./vllm_cscc_stage_experiment_results.md#r9-d1-gdn-decode-packed-validate-跳过), [R10](./vllm_cscc_stage_experiment_results.md#r10-d2-aiter-unified-attention-decode-2d-分支强制) | 等 review 后再继续；下一轮必须先做 decode kernel timeline/launch gap 归因。 |
| S7 | 后续实验采用“累计优化栈 + 单候选增量归因”的双对照。 | [C3](./vllm_cscc_optimization_constraints.md#c3-测量协议), [C7](./vllm_cscc_optimization_constraints.md#c7-evidence-card-模板) | 每轮同时报告相对 official baseline、H6.1c 和上一轮工作基线的变化。 |

## 文档索引

完整实验结果索引：

| 索引 | 引用 | 用途 |
| --- | --- | --- |
| R0 | [Official baseline full all 基准](./vllm_cscc_stage_experiment_results.md#r0-official-baseline-full-all-基准) | baseline 吞吐、accuracy 与综合基准 |
| R1 | [H6.1c ROCm AITER Unified Attention](./vllm_cscc_stage_experiment_results.md#r1-h61c-rocm-aiter-unified-attention) | 当前有效优化的构建、吞吐与 SLA |
| R2 | [H6.1c accuracy 对照](./vllm_cscc_stage_experiment_results.md#r2-h61c-accuracy-对照) | 精度系数和正确性阶段结论 |
| R3 | [H5.1 上游 ROCm FlashAttention 强制优先](./vllm_cscc_stage_experiment_results.md#r3-h51-上游-rocm-flashattention-强制优先) | 已排除的无效候选 |
| R4 | [早期单条 profile](./vllm_cscc_stage_experiment_results.md#r4-早期单条-profile) | 仅作定位起点的历史 profile |
| R5 | [H4.1 GDN prefill state 初始化快路径](./vllm_cscc_stage_experiment_results.md#r5-h41-gdn-prefill-state-初始化快路径) | GDN prefill 小样本未达标候选 |
| R6 | [H4.2 GDN prefill no-initial-state specialization](./vllm_cscc_stage_experiment_results.md#r6-h42-gdn-prefill-no-initial-state-specialization) | GDN prefill 小样本未达标候选 |
| R7 | [H4.3 FLA L2 norm kernel 变体](./vllm_cscc_stage_experiment_results.md#r7-h43-fla-l2-norm-kernel-变体) | 输出变化且吞吐下降的回滚候选 |
| R8 | [H4.4 GDN prefill `wy_fast` tile 变体](./vllm_cscc_stage_experiment_results.md#r8-h44-gdn-prefill-wy_fast-tile-变体) | GDN prefill 小样本微弱收益、未达标候选 |
| R9 | [D1 GDN decode packed validate 跳过](./vllm_cscc_stage_experiment_results.md#r9-d1-gdn-decode-packed-validate-跳过) | Decode wrapper 检查开销不是主瓶颈 |
| R10 | [D2 AITER unified attention decode 2D 分支强制](./vllm_cscc_stage_experiment_results.md#r10-d2-aiter-unified-attention-decode-2d-分支强制) | AITER single-query 3D 分支优于强制 2D，候选回滚 |

执行和测试约束索引：

| 索引 | 引用 | 用途 |
| --- | --- | --- |
| C0 | [赛题口径](./vllm_cscc_optimization_constraints.md#c0-赛题口径) | 指标、SLA、评分公式、精度约束 |
| C1 | [固定实验契约](./vllm_cscc_optimization_constraints.md#c1-固定实验契约) | 固定脚本、固定参数、no-proxy 和 accuracy 命令 |
| C2 | [允许与禁止](./vllm_cscc_optimization_constraints.md#c2-允许与禁止) | 可改源码范围与禁止策略 |
| C3 | [测量协议](./vllm_cscc_optimization_constraints.md#c3-测量协议) | wheel 构建、服务启动、吞吐和精度闭环 |
| C4 | [正确性门槛](./vllm_cscc_optimization_constraints.md#c4-正确性门槛) | 输出、finish reason、hash 与 OpenCompass 门槛 |
| C5 | [Profiler 规范](./vllm_cscc_optimization_constraints.md#c5-profiler-规范) | HIP timeline、counter 与瓶颈分类要求 |
| C6 | [源码边界](./vllm_cscc_optimization_constraints.md#c6-源码边界) | 只读锁定文件与可优化源码地图 |
| C7 | [Evidence Card 模板](./vllm_cscc_optimization_constraints.md#c7-evidence-card-模板) | 候选进入结论前必须补齐的证据 |

## 优化计划

### 目标和边界

目标是在单卡、单请求并发、固定测试脚本的条件下提升 Qwen3.5-27B vLLM CSCC/DCU 在线服务的 `output_throughput`。

不可改变的边界：

- 不修改 `run_throughput.sh`、`run_accuracy.sh`、模型权重、tokenizer、chat template 或评测解析口径。
- 不通过多请求并发、serve 参数调优、修改 batch scheduler、prefix cache、speculative decoding、持久化量化或模型结构变化获得收益。
- 允许的主路径是修改 `remote-home/vllm_cscc` 源码，重新编译 wheel，使用固定启动和固定测试脚本验证。

所有候选必须按 C3 完成源码变更、wheel 构建、服务启动、吞吐 `all`、accuracy `all` 和证据记录闭环。

### Workload 与硬件判断

单请求长上下文包含 prefill 与 decode 两段。

Prefill 阶段处理 prompt/context 并生成 KV cache，是 8K-32K 档 TTFT 的主要候选来源。vLLM 的 `chunked prefill` 是同一请求内部的 context 切分，不改变请求数、不改变上下文语义、不拆数据集。chunked prefill 可以作为路径分析对象，但不能扫描或调整 `MAX_NUM_BATCHED_TOKENS`，也不能修改 batch scheduler 代码来改变 chunk 调度策略。

Decode 阶段每次生成一个或少量 token，是 TPOT P99 的核心来源。decode 优化应优先围绕 Attention、Linear、GDN state update、KV 读取、kernel launch 和 HBM 字节流展开。

模型与硬件先验：

- Qwen3.5-27B 使用 `bfloat16`。
- full-attention `head_dim=256`。
- `layer_types` 共 64 层，其中每 4 层 1 个 `full_attention`，约 16 个 full-attention 层和 48 个 `linear_attention`/GDN 层。
- DCU 目标卡按讲义归纳为海光 DCU `gfx936`，`wavefront=64`。
- 微基准给出的可持续量级：HBM 峰值约 `1206 GB/s`，bf16 算力峰值约 `395 TFLOPS`。
- Roofline 拐点约 `327 FLOP/byte`。算术强度低于该拐点时优先按 memory-bound 分析，高于该拐点时优先按 compute-bound 分析。

这些先验只用于决定先测哪里；进入结论必须以 C5 的 profiler 证据和固定脚本结果为准。

### Backend 证据矩阵

| 路径 | 预期源码 | 必需证据 | 边界 | 决策 |
| --- | --- | --- | --- | --- |
| full-attention prefill | `selector.py`、`flash_attn.py`、`rocm_aiter_fa.py`、`triton_prefill_attention.py` | selector 日志、kernel timeline、chunk `q_len` | 不改 batch scheduler 或 chunk 参数 | 证实热点后优化 wrapper/Triton/HIP kernel |
| full-attention decode | `paged_attn.py`、`triton_decode_attention.py`、`csrc/rocm/attention.cu` | paged decode kernel 名称与耗时 | gfx936 custom paged attention 只支持 head 64/128 | 未命中时降低 `attention.cu` 优先级 |
| KV cache allocation/block manager | `kv_cache_manager.py`、`single_type_kv_cache_manager.py`、`block_pool.py`、`kv_cache_utils.py` | block 分配/释放次数、碎片率、HBM 占用、cache miss | 不改锁定参数或 scheduler 策略 | 若开销高，优化内部实现 |
| KV cache write/update | `triton_reshape_and_cache_flash.py`、`cache_kernels.cu`、`cache_kernels_fused.cu` | reshape/cache kernel 次数、字节流、slot mapping shape | 不改变 KV 语义或输出口径 | 若 memory-bound，减少 HBM 往返 |
| Q/K norm + RoPE | `qk_norm_rope_fusion.py`、`fused_qknorm_rope_kernel.cu`、`torch_bindings.cpp` | custom op 命中、kernel 数下降、数值对比 | 不生成可复用模型图或改变模型结构 | 只在 full-attention 路径成立时优化 |
| GDN/linear attention prefill | `gdn_attn.py`、`qwen3_next.py`、`layers/fla/ops/` | GDN kernel timeline、48 层占比、state/update shape | `--gdn-prefill-backend` 只是已有开关，不能单独计收益 | 若占比高，减少中间张量和 launch |
| GDN/linear attention decode | `layers/fla/ops/`、`gdn_attn.py` | per-token state update kernel 与 HBM 读写 | 不改变 recurrent state 语义 | 若 TPOT 热，优化 state update |
| Decode 算子融合 | `gdn_attn.py`、`layers/fla/ops/`、`qwen3_next.py`、`linear.py`、`gpu_model_runner.py` | decode token 级 kernel 序列、launch gap、相邻 elementwise/norm/reshape/copy 证据 | 不改采样、stop、输出 token、batch scheduler 或请求间状态复用 | 只融合数学等价子路径 |
| Linear/GEMM/GEMV | `linear.py`、`kernels/linear/`、`_aiter_ops.py`、`platforms/rocm.py` | rocBLAS/hipBLASLt/AITER/Triton 命中证据 | 不做持久化权重量化或权重重排压缩 | 只修正真实 fallback |
| 非持久化运行时量化 | `quantization/kv_cache.py`、`torch_utils.py`、attention/linear kernels | KV/activation 动态 scale、临时 dtype、精度审计 | 禁止生成量化权重文件、压缩缓存或持久化转换 | 只有精度系数通过时保留 |
| 非 batch-scheduler runtime overhead | `gpu_model_runner.py`、`gpu_input_batch.py`、`workspace.py` | Python timeline、launch gap、metadata 构造次数 | 禁止修改 batch scheduler 相关代码 | 仅缓存/消除执行路径重复 work |

### 假设 Backlog

优先级由当前增量工作基线上的 profiler 结果决定。每个候选一次只验证一个假设，避免把 backend 切换、fusion、调度变更和环境开关混成不可归因数字。新增候选不从 official baseline 重新开始，而是在已有可行优化栈上叠加；归因时同时记录相对上一轮工作基线和相对 H6.1c 的差异。

| ID | 触发条件 | 源码路径 | 预期瓶颈 | 最小改动 | 验证信号 | 失败判据 |
| --- | --- | --- | --- | --- | --- | --- |
| H0 路径表征 | 尚未证明固定脚本实际命中哪些 backend | `selector.py`、`registry.py`、`model_runner.py`、相关 backend | 结论风险来自路径假设错误 | 增加一次性日志或轻量插桩 | backend 矩阵填完整 | 日志影响吞吐或无法关联到 EngineCore |
| H1 Decode 专项：Attention/GDN/算子融合 | H6.1c 后 TPOT 只小幅改善 | `paged_attn.py`、`triton_decode_attention.py`、`gdn_attn.py`、`layers/fla/ops/`、`linear.py`、`qwen3_next.py` | HBM 带宽、GEMV、GDN state update、launch-bound | 数学等价融合、减少读写字节、修正 backend fallback | TPOT P99/Mean TPOT 下降，output throughput 提升 | 输出 token、finish reason、OpenCompass 精度或 SLA 失败 |
| H1.1 full-attention decode | attention decode 占 TPOT 主体 | `paged_attn.py`、`triton_decode_attention.py`、`rocm_aiter_unified_attn.py`、`attention.cu` | KV 读取、block table address、softmax/reduction、非合并访存 | shape/capability gating、减少 wrapper/copy、优化 block table 访问 | attention decode kernel 时间下降 | head_dim=256 路径不命中目标 kernel，或输出异常 |
| H1.2 GDN/linear attention decode | 48 个 GDN/linear 层 state update 累计占比高 | `gdn_attn.py`、`layers/fla/ops/`、`qwen3_next.py` | recurrent state 读写、gate/update 中间张量、reshape/copy、launch-bound | 融合 gate/state/update/norm 等价子路径 | GDN decode kernel 数、HBM bytes、TPOT 下降 | state 语义改变或精度下降 |
| H1.3 decode 算子融合 | 单 token decode 小 kernel 多且 gap 明显 | `qwen3_next.py`、`linear.py`、`gpu_model_runner.py`、`workspace.py`、fusion/custom op | launch-bound、metadata 重建、中间 tensor HBM 往返 | 融合相邻无副作用算子，缓存固定 shape 元数据 | kernel 数和 EngineCore gap 下降 | 触碰 scheduler、改变采样/stop 或引入持久化缓存 |
| H2 KV cache allocation/block manager | 显存碎片、block 管理或 cache 分配开销可观 | `kv_cache_manager.py`、`single_type_kv_cache_manager.py`、`block_pool.py`、`kv_cache_utils.py` | 块管理开销、碎片率、无效 block 访问 | 优化内部块管理和 layout | HBM 占用/碎片下降，TTFT/TPOT 不退 | 改变上下文容量、scheduler 或请求语义 |
| H3 KV cache write/update | cache reshape/write 在 prefill 或 decode 中高占比 | `triton_reshape_and_cache_flash.py`、`cache_kernels.cu`、`cache_kernels_fused.cu` | 非合并访存、重复地址计算、额外 copy | 合并 slot mapping/address 计算，向量化 K/V store | cache kernel 时间和 HBM bytes 下降 | 破坏 KV 正确性或输出哈希 |
| H4 GDN/linear attention prefill | 48 个 GDN/linear 层合计占 TTFT 主体 | `gdn_attn.py`、`qwen3_next.py`、`layers/fla/ops/` | 中间张量 materialization、HBM 往返、小 kernel launch | 融合安全的 gate/state/norm 子路径 | GDN kernel 数和字节下降，TTFT P99 不退 | GDN 占比低，或精度下降 |
| H5 full-attention prefill backend | full-attention chunk kernel 是 TTFT 热点 | `flash_attn.py`、`rocm_aiter_fa.py`、`triton_prefill_attention.py`、`prefix_prefill.py` | IO-bound attention、fallback、wrapper/copy | 对实际命中 path 做 shape 特化或减少 wrapper/copy | TTFT P99 下降，output throughput 提升 | head_dim=256 路径未命中目标 kernel |
| H6 GEMM/GEMV backend gating | profiler 显示 Triton/eager fallback 或 AITER 未命中 | `_aiter_ops.py`、`platforms/rocm.py`、`linear.py`、`kernels/linear/` | backend 选择错误、API 能力检测不足、权重带宽受限 | 基于实际 API 和 dtype/shape 做 capability gating | backend 稳定命中，TPOT 或 TTFT 改善 | 伪装设备能力、fallback 抖动或权重持久化变更 |
| H7 非持久化运行时量化 | KV/activation 带宽是主瓶颈且精度有余量 | `quantization/kv_cache.py`、`torch_utils.py`、attention/linear kernels | KV 或 activation 字节流过大 | 动态 scale、临时低精度、kernel 内部转换 | output throughput 提升，OpenCompass 通过 | 生成持久化量化产物或精度下降不可接受 |
| H8 非 batch-scheduler runtime overhead | HIP timeline 存在 Python gap、launch gap 或 metadata 重建 | `gpu_model_runner.py`、`gpu_input_batch.py`、`workspace.py` | Python overhead、metadata 重建、workspace resize | 缓存固定 shape 元数据，减少重复对象构造 | EngineCore gap 下降，TTFT/E2E 改善 | 修改 scheduler 代码或锁定参数 |
| H9 Q/K norm + RoPE fusion | full-attention 层中 norm/rope 小 kernel 多 | `qk_norm_rope_fusion.py`、`fused_qknorm_rope_kernel.cu`、`torch_bindings.cpp` | launch-bound 与中间张量写回 | 源码级 custom op/fusion | kernel 数下降，数值/精度通过 | 被判定为模型图重构或数值不稳定 |

### 下一阶段执行计划

1. 等 review 后继续；当前轮次因 D2 未提升已收束，不再追加测试。
2. 使用增量工作基线继续：`H6.1c + H4.1/H4.2 + D1`。先重新编译该工作栈 wheel，并用固定小样本确认其吞吐接近已记录结果，作为下一轮候选的直接对照。
3. 在该工作栈上做一轮低侵入 decode 归因：按 token 级 kernel 序列区分 full-attention decode、48 层 GDN/linear attention decode、Linear/GEMV、KV cache read/write、采样前后 runtime gap。
4. 若 full-attention decode 占比高，执行 H1.1：保留 AITER single-query 3D 分支，重点查看 `block_table`/KV 访问、descale tensor 构造和 wrapper copy，避免再做 D2 式 2D 强制分支。
5. 若 GDN/linear attention decode 占比高，执行 H1.2：围绕 recurrent state update 的 HBM 读写和小 kernel launch 做数学等价融合；D1 已排除纯 Python validate 检查作为主瓶颈，但 D1 可保留在工作栈中。
6. 若 kernel 数多但单 kernel 时间短，执行 H1.3：只融合相邻无副作用的 elementwise/norm/reshape/copy 子路径，禁止触碰 batch scheduler、采样、stop 逻辑和请求间状态复用。
7. H7 运行时量化继续暂缓，除非归因证明 KV/activation 字节流是主瓶颈且能先完成局部数值对照和 accuracy 闭环。
8. 每个候选都必须重新编译 wheel，使用固定启动脚本和固定吞吐脚本验证；小样本未达到新增目标时不进入 full `all`/accuracy 晋级。

### 研究循环

Inner loop：

1. 选择最高优先级的未验证假设。
2. 写实验协议：触发条件、源码路径、预测、失败判据。
3. 做最小源码改动。
4. 重新编译并安装 wheel。
5. 用固定启动和固定吞吐脚本运行。
6. 记录 evidence card，必须列出“累计优化栈”和“本轮新增 diff”。
7. 若失败，写明它排除了什么；若成功，再进入消融。

Outer loop：

1. 每 3-5 个候选或遇到矛盾结果时，重新综合 backend 矩阵和瓶颈归因。
2. 调整 H1-H9 及 H1.x decode 子项优先级。
3. 删除没有路径证据、SLA 证据或精度证据的候选。
4. 只有完整 evidence card 支持的结果才能进入最终结论。
