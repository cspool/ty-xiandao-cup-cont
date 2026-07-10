"""Bootstrap selected-layer process latency profiling for vLLM.

This module is imported automatically when this directory is on PYTHONPATH.
Instrumentation is opt-in via VLLM_PROCESS_LATENCY_ENABLE=1.
"""

import os
import sys


if os.environ.get("VLLM_PROCESS_LATENCY_ENABLE") == "1":
    try:
        import vllm_process_latency_patch

        vllm_process_latency_patch.apply_patches()
    except BaseException as exc:  # pragma: no cover - profiling must not break boot.
        sys.stderr.write(f"[vllm-process-latency] failed to apply patches: {exc!r}\n")
