# Torch Profile Summary

Run directory: `/public/home/tangyu408/testdata/profile_runs/torch_profile_20260707_codex`

Method: each original throughput context in `testdata/run_throughput.sh` was profiled once with `vllm bench serve --profile`, `backend=openai-chat`, `max-concurrency=1`, `request-rate=1`, `custom-output-len=1024`, `num-warmups=2`, and `num-prompts=1`.

Only the original three throughput datasets are included: `4-8K_throughput.jsonl`, `8-16K_throughput.jsonl`, and `16-32K_throughput.jsonl`.

| Context | Source row | Input tokens | Output tokens | TTFT ms | TPOT ms | E2E ms | Rank trace |
| --- | --- | ---: | ---: | ---: | ---: | ---: | --- |
| 4-8K | 4-8K_throughput.jsonl:1 | 7574 | 88 | 4350.36 | 69.76 | 10419.54 | `contexts/4-8K/raw_traces/rank0.1783404848326291555.pt.trace.json.gz` |
| 8-16K | 8-16K_throughput.jsonl:1 | 13962 | 92 | 12303.98 | 71.01 | 18765.48 | `contexts/8-16K/raw_traces/rank0.1783405117004262948.pt.trace.json.gz` |
| 16-32K | 16-32K_throughput.jsonl:1 | 20574 | 23 | 24631.13 | 71.79 | 26210.50 | `contexts/16-32K/raw_traces/rank0.1783405413530600899.pt.trace.json.gz` |

Profiler tables:
- `contexts/4-8K/raw_traces/profiler_out_0.txt`
- `contexts/8-16K/raw_traces/profiler_out_0.txt`
- `contexts/16-32K/raw_traces/profiler_out_0.txt`

Frontend traces:
- `contexts/4-8K/raw_traces/worker-0_22188.async_llm.1783404847726850887.pt.trace.json.gz`
- `contexts/8-16K/raw_traces/worker-0_23677.async_llm.1783405116227717459.pt.trace.json.gz`
- `contexts/16-32K/raw_traces/worker-0_25166.async_llm.1783405412930180258.pt.trace.json.gz`

Trace files are gzip-compressed torch profiler traces and can be opened directly in Perfetto/TensorBoard-compatible trace viewers.
