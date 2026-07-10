# vllm_cscc 阶段性实验完整结果

本文档保存阶段性实验的完整结果、路径、指标和结论。主计划只引用这里的索引，不重复展开明细。

## 索引

| ID | 主题 | 结论 |
| --- | --- | --- |
| R0 | Official baseline full all 基准 | 吞吐公式基准分 `60.00/100`，baseline 精度系数 `1.0` |
| R1 | H6.1c ROCm AITER Unified Attention | 当前唯一有效优化；完整 `all` 加权吞吐提升 `+21.87%`，综合分约 `69.57/100` |
| R2 | H6.1c accuracy 对照 | 相对 official baseline 未观察到精度下降 |
| R3 | H5.1 上游 ROCm FlashAttention 强制优先 | 输出行为异常，实验无效并排除 |
| R4 | 早期单条 profile | 只作为定位起点，不作为验收结论 |
| R5 | H4.1 GDN prefill state 初始化快路径 | 小样本相对 H6.1c 加权 `+0.05%`，未达新增 `+20%` 目标 |
| R6 | H4.2 GDN prefill no-initial-state specialization | 小样本相对 H6.1c 加权 `+0.047%`，未达新增 `+20%` 目标 |
| R7 | H4.3 FLA L2 norm kernel 变体 | 小样本加权 `-2.87%`，且输出 token 数变化；回滚 |
| R8 | H4.4 GDN prefill `wy_fast` tile 变体 | 小样本相对 H6.1c 加权 `+0.134%`，未达新增 `+20%` 目标；不晋级 |
| R9 | D1 GDN decode packed validate 跳过 | 小样本相对 H6.1c 加权 `+0.049%`，噪声级；不作为有效收益 |
| R10 | D2 AITER unified attention decode 2D 分支强制 | 小样本相对 H6.1c 加权 `-15.56%`，明确降速；回滚 |

## R0 Official baseline full all 基准

baseline wheel 状态：

- `pip show vllm`：`0.18.1+das.dtk2604`，安装位置 `/usr/local/lib/python3.10/dist-packages`。
- installed marker：`vllm/platforms/rocm.py` 中 `ROCM_AITER_UNIFIED_ATTN` 计数为 `3`；`rocm_aiter_unified_attn.py` 仍包含 `output_scale=`，符合保存的 official baseline wheel 形态。

吞吐基准：

- 路径：`/public/home/tangyu408/testdata/goal_runs/20260710_040000_official_baseline_full_all/throughput_all`
- 命令：固定 `run_throughput.sh all`，未传第二参数。
- 三档均 `completed=50`、`failed=0`。

| 档位 | output throughput | TTFT P99 | TPOT P99 | 单档公式基准分 |
| --- | ---: | ---: | ---: | ---: |
| `4-8K` | `12.2076` | `4792.48 ms` | `68.96 ms` | `12.00 / 20` |
| `8-16K` | `8.8108` | `24886.19 ms` | `70.37 ms` | `30.00 / 50` |
| `16-32K` | `5.3902` | `28740.84 ms` | `71.82 ms` | `18.00 / 30` |

baseline 相对自身提升率为 `0`，因此吞吐公式基准分为 `60.00/100`。

准确率基准：

- 路径：`/public/home/tangyu408/testdata/goal_runs/20260710_061800_official_baseline_full_accuracy_all_dtk_env`
- 命令：固定 `run_accuracy.sh all`，未传第二参数。
- 输出目录：`/public/home/tangyu408/testdata/accuracy_debug/output/local_accuracy_qwen35/20260710_141706`
- 口径：以 `run_accuracy.sh` 最终表为准；OpenCompass 原始 summary 中 RULER 聚合任务可能未按脚本重算，不能替代最终表。

| 数据集 | metric | baseline accuracy |
| --- | --- | ---: |
| `hotpotqa` | `score` | `77.96` |
| `gov_report` | `score` | `32.96` |
| `retrieval_multi_point` | `accuracy` | `100.00` |
| `aggregation_keyword_aggregation` | `accuracy` | `100.00` |

baseline 精度系数按定义为 `1.0`。若综合分按“吞吐公式分乘精度系数”计算，则 official baseline 综合基准分为 `60.00/100`。

## R1 H6.1c ROCm AITER Unified Attention

实验时间：`2026-07-09`。

源码变更：

- `vllm/platforms/rocm.py`：当 `aiter.ops.triton.unified_attention` 可导入时，将 `ROCM_AITER_UNIFIED_ATTN` 放在默认 `TRITON_ATTN` 前。
- `vllm/v1/attention/backends/rocm_aiter_unified_attn.py`：适配当前容器内 AITER unified attention 函数签名，移除不支持的 `sinks` 与 `output_scale` 关键字，并将 `supports_sink()` 置为 `False`。
- `setup.py`、`vllm/version.py`：保留 wheel 构建所需的版本生成修正。

路径证据：

- 服务日志确认命中 `Using ROCM_AITER_UNIFIED_ATTN attention backend out of potential backends: ['ROCM_AITER_UNIFIED_ATTN', 'TRITON_ATTN']`。
- 固定 `start_vllm.sh` 未修改。
- no-proxy API 快速检查返回正常中文短答，`finish_reason=stop`，未出现 H5.1 的重复输出失控现象。

构建与结果路径：

- build/install：`/public/home/tangyu408/testdata/goal_runs/20260709_225549_candidate_aiter_unified_no_output_scale_build`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260709_225731_candidate_aiter_unified_no_output_scale_serve`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260709_230206_candidate_aiter_unified_no_output_scale_all3`
- 完整 throughput：`/public/home/tangyu408/testdata/goal_runs/20260709_234926_h6_1c_full_throughput_all`

小样本吞吐：

| 档位 | baseline output throughput | H6.1c output throughput | 相对提升 | baseline total output tokens | H6.1c total output tokens | TTFT P99 对比 | TPOT P99 对比 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `4-8K` | `7.4017` | `9.5594` | `+29.15%` | `172` | `241` | `4344.36 -> 3187.06 ms` | `68.78 -> 68.36 ms` |
| `8-16K` | `7.9994` | `9.7455` | `+21.83%` | `600` | `610` | `13227.32 -> 7869.08 ms` | `70.03 -> 69.14 ms` |
| `16-32K` | `3.6039` | `5.2747` | `+46.36%` | `388` | `364` | `28405.19 -> 15154.81 ms` | `71.68 -> 70.31 ms` |

小样本 20/50/30 加权相对提升约 `+30.65%`。该结果只作为筛选信号，不能替代完整 `all`。

完整 `all` 吞吐：

- official baseline full all：`/public/home/tangyu408/testdata/goal_runs/20260710_040000_official_baseline_full_all/throughput_all`
- H6.1c full all：`/public/home/tangyu408/testdata/goal_runs/20260709_234926_h6_1c_full_throughput_all`
- 两组均使用固定 `start_vllm.sh` 与固定 `run_throughput.sh all`，未传第二参数，`MAX_CONCURRENCY=1`，三档均 `completed=50`、`failed=0`。

| 档位 | official baseline output throughput | H6.1c output throughput | 相对提升 | TTFT P99 对比 | TPOT P99 对比 | SLA |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| `4-8K` | `12.2076` | `12.7816` | `+4.70%` | `4792.48 -> 3459.79 ms` | `68.96 -> 68.44 ms` | 通过 |
| `8-16K` | `8.8108` | `10.5395` | `+19.62%` | `24886.19 -> 10020.25 ms` | `70.37 -> 69.39 ms` | 通过 |
| `16-32K` | `5.3902` | `7.3887` | `+37.08%` | `28740.84 -> 15255.00 ms` | `71.82 -> 70.40 ms` | 通过 |

完整 `all` 的 20/50/30 加权相对提升为 `+21.87%`，按赛题单档公式汇总得分约 `69.57/100`。相比小样本 `+30.65%`，全量结果下修 `8.78` 个百分点；后续结论以完整 `all` 为准。

## R2 H6.1c accuracy 对照

H6.1c accuracy 路径：

- `/public/home/tangyu408/testdata/goal_runs/20260710_030800_h6_1c_full_accuracy_all_dtk_env`
- output dir：`/public/home/tangyu408/testdata/accuracy_debug/output/local_accuracy_qwen35/20260710_110647`

| 数据集 | baseline | H6.1c | 观察到的下降 |
| --- | ---: | ---: | ---: |
| `hotpotqa` | `77.96` | `77.96` | `0.00` |
| `gov_report` | `32.96` | `32.97` | `0.00` |
| `retrieval_multi_point` | `100.00` | `100.00` | `0.00` |
| `aggregation_keyword_aggregation` | `100.00` | `100.00` | `0.00` |

结论：以固定脚本最终表为口径，H6.1c 相对 official baseline 未观察到精度下降。若精度系数按无下降计为 `1.0`，H6.1c 综合分约为 `69.57/100`。

正确性补充：

- 小样本 `generated_texts` 与 baseline 逐请求文本哈希比对：`9` 条中 `5` 条完全一致，`4` 条不一致。
- 不一致样本没有出现重复 token 或明显失控输出，但存在措辞、长度和局部内容差异；最终正确性结论以 OpenCompass/accuracy 固定脚本结果为准。

## R3 H5.1 上游 ROCm FlashAttention 强制优先

实验时间：`2026-07-09`。

源码变更：

- `vllm/platforms/rocm.py`：在 ROCm backend priority 中将 upstream `flash_attn` 放在 `TRITON_ATTN` 前。
- `vllm/model_executor/models/config.py`：为 upstream ROCm FlashAttention 将 hybrid attention/mamba cache block 对齐到 `64`，实际 attention block size 从 `784` 变为 `832`。
- `vllm/v1/attention/backends/flash_attn.py`：增加 ROCm upstream `flash_attn_varlen_func` 调用路径，并把 `cu_seqlens_k` 从 forward 中的临时构造移动到 metadata build 阶段，以避免 HIP graph capture 中的 GPU 写入。

有效路径证据：

- 服务日志确认命中 `Using FLASH_ATTN attention backend out of potential backends: ['FLASH_ATTN', 'TRITON_ATTN']`。
- 服务日志确认 `Setting attention block size to 832 tokens`，并成功完成启动。
- 固定 `start_vllm.sh` 未修改；固定 `run_throughput.sh all 3` 运行完成。

构建与结果路径：

- build/install：`/public/home/tangyu408/testdata/goal_runs/20260709_220658_candidate_flashattn_rocm_cuseq_build`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260709_220921_candidate_flashattn_rocm_cuseq_serve`
- throughput：`/public/home/tangyu408/testdata/goal_runs/20260709_221245_candidate_flashattn_rocm_cuseq_all3`

小样本吞吐现象：

| 档位 | baseline output throughput | H5.1 output throughput | baseline total output tokens | H5.1 total output tokens | 结论 |
| --- | ---: | ---: | ---: | ---: | --- |
| `4-8K` | `7.4017` | `14.5549` | `172` | `3072` | 输出长度异常 |
| `8-16K` | `7.9994` | `14.3017` | `600` | `3072` | 输出长度异常 |
| `16-32K` | `3.6039` | `13.9549` | `388` | `3072` | 输出长度异常 |

失败判据：

- 三个档位均输出满 `3 * 1024 = 3072` tokens，而有效 baseline 的输出 token 数分别为 `172/600/388`。
- no-proxy API 快速检查中，简单中文问答输出大量重复感叹号，说明 deterministic 输出已明显偏离。
- 因输出行为和停止行为改变，该候选的 `output_throughput` 提升不能进入有效优化结论。

后续规则：

- H5 的 upstream ROCm FlashAttention 路径只有在先修复输出正确性、finish reason、stop reason 和输出哈希后才能重新进入候选。
- 任何依赖“输出提前停止变成输出满长”得到的吞吐提升都必须判为无效。

## R4 早期单条 profile

已有单条 profile 只作为定位起点，不作为验收结果。

| Context | Input tokens | Output tokens | Output throughput | TTFT ms | TPOT ms | E2E ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `4-8K` | `7574` | `88` | `7.70` | `4350.36` | `69.76` | `10419.54` |
| `8-16K` | `13962` | `92` | `4.65` | `12303.98` | `71.01` | `18765.48` |
| `16-32K` | `20574` | `23` | `0.85` | `24631.13` | `71.79` | `26210.50` |

这些 profile 的实际输出 token 数远小于 `custom-output-len=1024`，说明输出提前停止会显著影响官方主指标。正式比较必须逐请求检查输出 token 数、finish reason、stop reason 和输出哈希，并用 OpenCompass 做精度验收。

## R5 H4.1 GDN prefill state 初始化快路径

实验时间：`2026-07-10`。

源码变更：

- `vllm/v1/attention/backends/gdn_attn.py`：在 GDN prefill metadata 中增加 `has_initial_state_any` 和 `has_initial_state_all`，用已有 CPU metadata 判断 non-spec prefill 是否全部没有历史 recurrent state，避免在模型 forward 热路径做 GPU->CPU 同步。
- `vllm/model_executor/models/qwen3_next.py`：当 `has_initial_state_any is False` 时，用 `ssm_state.new_zeros(...)` 直接构造初始 state；当 `has_initial_state_all is True` 时跳过 mask 清零。

构建与运行证据：

- build：`/public/home/tangyu408/testdata/goal_runs/20260710_151814_candidate_gdn_prefill_statefast_build`
- wheel：`/public/home/tangyu408/vllm_cscc/dist/vllm-0.18.1+das.dtk2604-cp310-cp310-linux_x86_64.whl`
- wheel sha256：`fea33d9a835c0310af1dfdc0edb560d20a4777358561cfb5f0b0464cd16c76bd`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260710_152203_candidate_gdn_prefill_statefast_serve2`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260710_152634_candidate_gdn_prefill_statefast_all3`
- 固定脚本 hash：`run_throughput.sh = adf0cf91266745b37df916926c7d495ec79f00a11be653c219d1d5df4d93c681`，`start_vllm.sh = 7c3e8c5ecdf02109e02af8c3b5ba05050b26339c7f50869b5288eea359364fad`
- 小样本运行命令：`./run_throughput.sh all 3`；脚本耗时 `322s`，包装命令补足到 `10min+` 后读取结果。

小样本对比 H6.1c 小样本最佳：

| 档位 | H6.1c output throughput | H4.1 output throughput | 相对 H6.1c |
| --- | ---: | ---: | ---: |
| `4-8K` | `9.5594` | `9.5629` | `+0.04%` |
| `8-16K` | `9.7455` | `9.7511` | `+0.06%` |
| `16-32K` | `5.2747` | `5.2771` | `+0.04%` |

20/50/30 加权 throughput 为 `8.3712`，相对 H6.1c 小样本最佳 `8.3670` 提升 `+0.05%`，距离新增 `+20%` 目标 `10.0405` 明显不足。

结论：H4.1 是正确性风险较低的源码快路径，但 gather/mask 清零不是当前 GDN prefill 的主要瓶颈；不进入有效收益结论。下一步应继续查看 FLA chunk kernel 是否支持 `initial_state=None` 的零初始状态路径，或转向 GDN prefill 主体 kernel 的 launch/HBM 归因。

## R6 H4.2 GDN prefill no-initial-state specialization

实验时间：`2026-07-10`。

源码变更：

- 在 H4.1 基础上，`qwen3_next.py` 的 FLA/Triton GDN prefill backend 增加 `supports_none_initial_state` 标记。
- 当 metadata 判定 non-spec prefill 全部没有历史 recurrent state 时，传 `initial_state=None`，使 `chunk_gated_delta_rule_fwd_h` 走 Triton `USE_INITIAL_STATE=False` specialization，跳过初始 state tensor 分配和 kernel 内 state load。
- `_warmup_prefill_kernels()` 增加 `(initial_state=None, output_final_state=True)` warmup case，覆盖 no-initial-state specialization。

构建与运行证据：

- build：`/public/home/tangyu408/testdata/goal_runs/20260710_154128_candidate_gdn_prefill_none_state_build`
- wheel sha256：`95b68517ca7425db15d85e51dd479ae1e7abb8286aac4f44c0402c059ebe7c4f`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260710_154410_candidate_gdn_prefill_none_state_serve`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260710_154849_candidate_gdn_prefill_none_state_all3`
- 小样本运行命令：`./run_throughput.sh all 3`；脚本耗时 `322s`，包装命令补足到 `10min+` 后读取结果。

小样本对比 H6.1c 小样本最佳：

| 档位 | H6.1c output throughput | H4.2 output throughput | 相对 H6.1c |
| --- | ---: | ---: | ---: |
| `4-8K` | `9.5594` | `9.5611` | `+0.02%` |
| `8-16K` | `9.7455` | `9.7504` | `+0.05%` |
| `16-32K` | `5.2747` | `5.2785` | `+0.07%` |

20/50/30 加权 throughput 为 `8.3710`，相对 H6.1c 小样本最佳 `8.3670` 提升 `+0.047%`；相对 H4.1 加权结果 `8.3712` 略低 `-0.003%`。距离新增 `+20%` 目标 `10.0405` 明显不足。

结论：no-initial-state specialization 能命中并保持 `failed=0`，但初始 state load/清零路径不是主要瓶颈。后续 GDN prefill 优化应转向 `chunk_local_cumsum`、`chunk_scaled_dot_kkt_fwd`、`solve_tril`、`recompute_w_u_fwd`、`chunk_gated_delta_rule_fwd_h`、`chunk_fwd_o` 等主体 kernel 的 launch/HBM 归因。

## R7 H4.3 FLA L2 norm kernel 变体

实验时间：`2026-07-10`。

源码变更：

- `vllm/model_executor/layers/fla/ops/l2norm.py`：将 `USE_DEFAULT_FLA_NORM` 的源码默认值从 `0` 改为 `1`，使 GDN/KDA prefill 的 q/k L2 norm 走现有 autotuned FLA norm kernel 分支，而非当前默认 `l2norm_fwd_kernel2`。

构建与运行证据：

- build：`/public/home/tangyu408/testdata/goal_runs/20260710_160215_candidate_gdn_prefill_default_fla_norm_build`
- wheel sha256：`5e6bf105a1c372a0b972b8430aa5139e7e3ecd4dc9126b0ba119ad535ec8bed1`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260710_160502_candidate_gdn_prefill_default_fla_norm_serve`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260710_160907_candidate_gdn_prefill_default_fla_norm_all3`
- 小样本运行命令：`./run_throughput.sh all 3`；脚本耗时 `318s`，包装命令补足到 `10min+` 后读取结果。

小样本对比 H6.1c 小样本最佳：

| 档位 | H6.1c output throughput | H4.3 output throughput | 相对 H6.1c | H6.1c total output tokens | H4.3 total output tokens |
| --- | ---: | ---: | ---: | ---: | ---: |
| `4-8K` | `9.5594` | `8.3836` | `-12.30%` | `241` | `172` |
| `8-16K` | `9.7455` | `9.7450` | `-0.005%` | `610` | `610` |
| `16-32K` | `5.2747` | `5.2598` | `-0.28%` | `364` | `362` |

20/50/30 加权 throughput 为 `8.1272`，相对 H6.1c 小样本最佳 `8.3670` 下降 `-2.87%`。

结论：该 kernel 变体没有吞吐收益，并且 4-8K 与 16-32K 输出 token 数发生变化，不能进入有效收益结论。该变更应回滚；后续若重新研究 L2 norm，只能在先完成逐请求输出/精度审计的前提下进入候选。

## R8 H4.4 GDN prefill `wy_fast` tile 变体

实验时间：`2026-07-10`。

源码变更：

- `vllm/model_executor/layers/fla/ops/wy_fast.py`：将 `recompute_w_u_fwd()` 中的 `BK/BV` 从 `64/64` 调整为 `128/128`。
- 该变更只改变 `A @ v` 和 `A @ k` 的列向量分块大小，数学表达不变。目标是让 Qwen3.5-27B 的 GDN `K/V=128` 场景把两个分块循环各从 2 次降到 1 次。

构建与运行证据：

- build：`/public/home/tangyu408/testdata/goal_runs/20260710_163212_candidate_gdn_prefill_wy128_build`
- wheel sha256：`c31633e1cc7ee6356e0052c4bc2e2d28fb3770092a96d730ca8f8e556288213f`
- wheel copy：`/public/home/tangyu408/testdata/goal_runs/20260710_163212_candidate_gdn_prefill_wy128_build/vllm_h4_4_wy128.whl`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260710_163535_candidate_gdn_prefill_wy128_serve`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260710_163851_candidate_gdn_prefill_wy128_all3`
- 小样本运行命令：`./run_throughput.sh all 3`；脚本耗时 `339s`，包装命令补足到 `600s` 后读取结果。

小样本对比 H6.1c 小样本最佳：

| 档位 | H6.1c output throughput | H4.4 output throughput | 相对 H6.1c | H4.4 total output tokens | completed | failed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `4-8K` | `9.5594` | `9.5727` | `+0.1389%` | `241` | `3` | `0` |
| `8-16K` | `9.7455` | `9.7569` | `+0.1167%` | `610` | `3` | `0` |
| `16-32K` | `5.2747` | `5.2843` | `+0.1820%` | `364` | `3` | `0` |

20/50/30 加权 throughput 为 `8.3783`，相对 H6.1c 小样本最佳 `8.3670` 提升 `+0.134%`；新增 `+20%` 目标线为 `10.0405`。

结论：H4.4 没有形成有效性能突破。输出 token 数与 H6.1c 小样本一致，`failed=0`，说明该 tile 变体未暴露明显功能错误；但收益只有噪声级别，不值得进入 full `all` 和 accuracy 晋级。该变更不作为当前有效候选保留，后续 GDN prefill 优化应转向 profiler 证明的主体瓶颈，而不是继续盲扫 `BK/BV`。

## R9 D1 GDN decode packed validate 跳过

实验时间：`2026-07-10`。

源码变更：

- `vllm/model_executor/layers/fla/ops/fused_recurrent.py`：为 `fused_recurrent_gated_delta_rule_packed_decode()` 增加 `validate: bool = True`，用显式参数控制 Python 侧 shape/dtype/device 检查。
- `vllm/model_executor/models/qwen3_next.py`：在 Qwen3Next packed non-spec decode 快路径中传入 `validate=False`，避免每 token decode 重复执行已由上层保证的不变量检查。

正确性快检：

- same-input GPU 对照：`validate=True` 与 `validate=False` 的 `max_out_diff=0.0`，`max_state_diff=0.0`。
- 该快检只能证明局部 kernel wrapper 数值一致；进入有效收益仍必须依赖固定脚本吞吐和后续 accuracy。

构建与运行证据：

- build：`/public/home/tangyu408/testdata/goal_runs/20260710_170553_candidate_decode_packed_validate_skip_build`
- wheel sha256：`7a995a16f92a0ef29568c63781a6fb32b924f80157a0bd74a0e9069999acea08`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260710_170728_candidate_decode_packed_validate_skip_serve`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260710_171056_candidate_decode_packed_validate_skip_all3`
- 小样本运行命令：`./run_throughput.sh all 3`；脚本结束后补足总等待到 `600s`。

小样本对比 H6.1c 小样本最佳：

| 档位 | H6.1c output throughput | D1 output throughput | 相对 H6.1c | total output tokens | completed | failed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `4-8K` | `9.5594` | `9.5615` | `+0.0216%` | `241` | `3` | `0` |
| `8-16K` | `9.7455` | `9.7503` | `+0.0494%` | `610` | `3` | `0` |
| `16-32K` | `5.2747` | `5.2791` | `+0.0823%` | `364` | `3` | `0` |

20/50/30 加权 throughput 为 `8.3712`，相对 H6.1c 小样本最佳 `8.3670` 提升 `+0.0493%`；decode 目标新增 `+10%` 门槛为 `9.2038`。

结论：D1 逻辑正确性风险低，但收益只有噪声级，说明 Python 侧 packed decode 参数检查不是当前单请求 decode 的主要瓶颈。该结果不进入有效性能提升结论；后续 decode 优化不能继续围绕类似 wrapper 检查做微调。

## R10 D2 AITER unified attention decode 2D 分支强制

实验时间：`2026-07-10`。

源码变更：

- `vllm/v1/attention/backends/rocm_aiter_unified_attn.py`：尝试在 `max_query_len == 1` 的 decode 场景中把传给 AITER `unified_attention()` 的 `max_seqlen_q` 从 `1` 改为 `2`，使 AITER Python 分支选择 2D kernel，避开其 single-query segmented 3D 分支的临时 tensor 分配。
- 该变更只作为 D2 候选测试；测试后已回滚源码，不作为后续基础。

构建与运行证据：

- build：`/public/home/tangyu408/testdata/goal_runs/20260710_173124_candidate_decode_aiter_2d_build`
- wheel sha256：`09df2ec5d2280af5ad9bc58c186763209ae0e5f848dbc95bf2577fce23a3472f`
- serve：`/public/home/tangyu408/testdata/goal_runs/20260710_173257_candidate_decode_aiter_2d_serve`
- 小样本 throughput：`/public/home/tangyu408/testdata/goal_runs/20260710_173600_candidate_decode_aiter_2d_all3`
- 小样本运行命令：`./run_throughput.sh all 3`；完整运行并等待超过 `10min` 后记录。

小样本对比 H6.1c 小样本最佳：

| 档位 | H6.1c output throughput | D2 output throughput | 相对 H6.1c | total output tokens | completed | failed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `4-8K` | `9.5594` | `8.5380` | `-10.6847%` | `241` | `3` | `0` |
| `8-16K` | `9.7455` | `8.0793` | `-17.0975%` | `612` | `3` | `0` |
| `16-32K` | `5.2747` | `4.3933` | `-16.7102%` | `378` | `3` | `0` |

20/50/30 加权 throughput 为 `7.0652`，相对 H6.1c 小样本最佳 `8.3670` 下降 `-15.5589%`，相对 D1 下降 `-15.6005%`。decode 目标新增 `+10%` 门槛为 `9.2038`，未达标。

结论：AITER 的 single-query segmented 3D decode 分支虽然存在临时分配，但在当前 gfx936/Qwen3.5-27B 形状下明显快于强制 2D 分支。该实验排除“仅通过 Python branch selector 强制 2D decode 获益”的方向；后续若继续 attention decode，必须基于 kernel timeline 和 counter 找到真实瓶颈，而不是继续替换 AITER 分支。
