"""Process-level HIPTX profiling patches for selected Qwen3.5 vLLM layers.

The patch instruments the same twelve process groups used by
selected_layer_fx_process_visualization.md. It is intended for profiling runs
only: selected target layers are executed through Python-visible native
RMSNorm/RoPE boundaries so the reconstructed FX process groups can be timed
separately with hipprof --hiptx-trace.
"""

from __future__ import annotations

import atexit
import csv
import ctypes
import functools
import json
import os
import sys
import threading
import time
import traceback
from collections import Counter
from collections.abc import Mapping
from contextlib import contextmanager
from pathlib import Path
from typing import Any

import torch


_PATCHED = False
_STATE = threading.local()
_LOCK = threading.RLock()
_EVENT_INDEX = 0
_LAYER_EVENT_COUNT = 0
_CAPTURED_EVENTS: set[tuple[int, int]] = set()
_CAPTURED_BY_LAYER: Counter[int] = Counter()
_PATCH_ERRORS: list[dict[str, Any]] = []


PROCESS_GROUPS = [
    (1, "runtime_inputs", "Runtime FX Inputs"),
    (2, "pre_attention_residual_rmsnorm", "Pre-Attention Residual Add And Input RMSNorm"),
    (3, "qkv_projection_and_split", "Fused Q/Gate/K/V Projection And Head Reshape"),
    (4, "q_head_rmsnorm", "Q Head RMSNorm"),
    (5, "k_head_rmsnorm", "K Head RMSNorm"),
    (6, "mrope_table_lookup", "MROPE Cos/Sin Table Lookup And Axis Remap"),
    (7, "q_rope_apply", "Q RoPE Application"),
    (8, "k_rope_apply", "K RoPE Application"),
    (9, "vllm_attention_and_kv_cache", "vLLM Attention And KV Cache Update"),
    (10, "attention_gate_projection_residual", "Attention Gate, Output Projection, And Residual"),
    (11, "post_attention_rmsnorm", "Post-Attention RMSNorm"),
    (12, "mlp_and_layer_output", "MLP And Layer Output Tuple"),
]

PROCESS_BY_ORDER = {order: (process_id, title) for order, process_id, title in PROCESS_GROUPS}

LATENCY_FIELDS = [
    "event_id",
    "context",
    "pid",
    "engine_step_id",
    "forward_id",
    "phase",
    "total_num_scheduled_tokens",
    "layer_id",
    "layer_type",
    "q_len",
    "process_order",
    "process_id",
    "process_title",
    "hiptx_label",
    "status",
    "error",
    "start_ns",
    "end_ns",
    "duration_ns",
    "hidden_shape",
]

LAYER_EVENT_FIELDS = [
    "event_id",
    "context",
    "pid",
    "engine_step_id",
    "forward_id",
    "phase",
    "total_num_scheduled_tokens",
    "layer_id",
    "layer_type",
    "q_len",
    "matched",
    "instrumented",
    "status",
    "error",
    "duration_ns",
]


def _enabled() -> bool:
    return os.environ.get("VLLM_PROCESS_LATENCY_ENABLE") == "1"


def _trace_dir() -> Path:
    return Path(os.environ.get("VLLM_PROCESS_LATENCY_DIR") or os.getcwd())


def _context() -> str | None:
    return os.environ.get("VLLM_PROCESS_LATENCY_CONTEXT")


def _arm_file() -> str | None:
    return os.environ.get("VLLM_PROCESS_LATENCY_ARM_FILE")


def _is_armed() -> bool:
    arm = _arm_file()
    return not arm or os.path.exists(arm)


def _sync_enabled() -> bool:
    return os.environ.get("VLLM_PROCESS_LATENCY_SYNC", "1") == "1"


def _latency_events_path() -> Path:
    return _trace_dir() / "process_latency_events.csv"


def _layer_events_path() -> Path:
    return _trace_dir() / "process_latency_layer_events.csv"


def _events_jsonl_path() -> Path:
    return _trace_dir() / f"events.{os.getpid()}.jsonl"


def _metadata_path() -> Path:
    return _trace_dir() / "run_metadata.json"


def _now_ns() -> int:
    return time.monotonic_ns()


def _safe_int(value: Any) -> int | None:
    try:
        if value is None:
            return None
        return int(value)
    except Exception:
        return None


def _shape(value: Any) -> list[int] | None:
    if not torch.is_tensor(value):
        return None
    try:
        return [int(item) for item in value.shape]
    except Exception:
        return None


def _shape_json(value: Any) -> str:
    return json.dumps(_shape(value), separators=(",", ":"))


def _jsonable(value: Any) -> Any:
    if value is None or isinstance(value, (str, int, float, bool)):
        return value
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, torch.dtype):
        return str(value)
    if isinstance(value, torch.device):
        return str(value)
    if torch.is_tensor(value):
        return {
            "type": "Tensor",
            "shape": _shape(value),
            "dtype": str(value.dtype),
            "device": str(value.device),
        }
    if isinstance(value, Mapping):
        return {str(key): _jsonable(item) for key, item in value.items()}
    if isinstance(value, (list, tuple, set)):
        return [_jsonable(item) for item in value]
    return repr(value)


def _compact_json(value: Any) -> str:
    return json.dumps(_jsonable(value), ensure_ascii=False, sort_keys=True)


def _append_csv(path: Path, fields: list[str], row: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    exists = path.exists() and path.stat().st_size > 0
    normalized = {field: row.get(field, "") for field in fields}
    with path.open("a", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        if not exists:
            writer.writeheader()
        writer.writerow(normalized)


def _write_event(event_type: str, **payload: Any) -> None:
    global _EVENT_INDEX
    if not _enabled():
        return
    try:
        _trace_dir().mkdir(parents=True, exist_ok=True)
        with _LOCK:
            _EVENT_INDEX += 1
            event = {
                "event_index": _EVENT_INDEX,
                "event_type": event_type,
                "ts_ns": _now_ns(),
                "pid": os.getpid(),
                "ppid": os.getppid(),
                "context": _context(),
                "argv0": os.path.basename(sys.argv[0]) if sys.argv else None,
                **payload,
            }
            with _events_jsonl_path().open("a", encoding="utf-8") as handle:
                handle.write(_compact_json(event) + "\n")
    except BaseException as exc:  # pragma: no cover - tracing is best effort.
        try:
            sys.stderr.write(f"[vllm-process-latency] event write failed: {exc!r}\n")
        except Exception:
            pass


class _Roctx:
    def __init__(self) -> None:
        self.lib = None
        self.error: str | None = None
        self._range_push = None
        self._range_pop = None
        self._mark = None
        candidates = [
            "libroctx64.so",
            "/opt/dtk-26.04-DCC2602-0317/roctracer/lib/libroctx64.so",
            "/opt/dtk-26.04-DCC2602-0317/lib/libroctx64.so",
            "/opt/dtk/roctracer/lib/libroctx64.so",
            "/opt/dtk/lib/libroctx64.so",
        ]
        for candidate in candidates:
            try:
                self.lib = ctypes.CDLL(candidate)
                break
            except OSError as exc:
                self.error = repr(exc)
        if self.lib is not None:
            try:
                self._range_push = getattr(self.lib, "roctxRangePushA", None) or getattr(self.lib, "roctxRangePush")
                self._range_pop = getattr(self.lib, "roctxRangePop")
                self._mark = getattr(self.lib, "roctxMarkA", None) or getattr(self.lib, "roctxMark")
                self._range_push.argtypes = [ctypes.c_char_p]
                self._range_push.restype = ctypes.c_int
                self._range_pop.argtypes = []
                self._range_pop.restype = ctypes.c_int
                self._mark.argtypes = [ctypes.c_char_p]
                self._mark.restype = None
            except Exception as exc:
                self.error = repr(exc)
                self.lib = None

    def push(self, label: str) -> None:
        if self.lib is None or self._range_push is None:
            return
        self._range_push(label.encode("utf-8", errors="replace"))

    def pop(self) -> None:
        if self.lib is None or self._range_pop is None:
            return
        self._range_pop()

    def mark(self, label: str) -> None:
        if self.lib is None or self._mark is None:
            return
        self._mark(label.encode("utf-8", errors="replace"))


_ROCTX = _Roctx()


def _sync_device() -> None:
    if not _sync_enabled():
        return
    try:
        if torch.cuda.is_available():
            torch.cuda.synchronize()
    except Exception:
        pass


def _parse_csv_targets(value: str) -> tuple[set[int], set[tuple[int, int]]]:
    any_layers: set[int] = set()
    event_keys: set[tuple[int, int]] = set()
    for raw in (value or "").split(","):
        item = raw.strip()
        if not item:
            continue
        if item.startswith("input") and "_layer" in item:
            left, right = item.split("_layer", 1)
            event_keys.add((int(left.removeprefix("input")), int(right)))
            continue
        if ":" in item:
            forward, layer = item.split(":", 1)
            event_keys.add((int(forward), int(layer)))
            continue
        any_layers.add(int(item))
    return any_layers, event_keys


def _target_sets() -> tuple[set[int], set[tuple[int, int]]]:
    return _parse_csv_targets(os.environ.get("VLLM_PROCESS_LATENCY_TARGETS", ""))


def _phase_set() -> set[str]:
    value = os.environ.get("VLLM_PROCESS_LATENCY_PHASES", "prefill_chunk")
    phases = {item.strip() for item in value.split(",") if item.strip()}
    return phases or {"prefill_chunk"}


def _max_samples_per_layer() -> int:
    return int(os.environ.get("VLLM_PROCESS_LATENCY_MAX_SAMPLES_PER_LAYER", "0") or "0")


def _current_step_id() -> int | None:
    return getattr(_STATE, "engine_step_id", None)


def _current_forward_id() -> int | None:
    return getattr(_STATE, "forward_id", None)


def _current_phase() -> str | None:
    return getattr(_STATE, "phase", None)


def _current_total_scheduled_tokens() -> int | None:
    return getattr(_STATE, "total_num_scheduled_tokens", None)


def _set_forward_context(
    *,
    engine_step_id: int | None,
    forward_id: int | None,
    phase: str | None,
    total_num_scheduled_tokens: int | None,
) -> tuple[int | None, int | None, str | None, int | None]:
    previous = (
        _current_step_id(),
        _current_forward_id(),
        _current_phase(),
        _current_total_scheduled_tokens(),
    )
    _STATE.engine_step_id = engine_step_id
    _STATE.forward_id = forward_id
    _STATE.phase = phase
    _STATE.total_num_scheduled_tokens = total_num_scheduled_tokens
    return previous


def _restore_forward_context(previous: tuple[int | None, int | None, str | None, int | None]) -> None:
    (
        _STATE.engine_step_id,
        _STATE.forward_id,
        _STATE.phase,
        _STATE.total_num_scheduled_tokens,
    ) = previous


def _next_id(obj: Any, attr: str) -> int:
    value = int(getattr(obj, attr, 0)) + 1
    setattr(obj, attr, value)
    return value


def _phase_from_scheduler_output(output: Any) -> str:
    total = _safe_int(getattr(output, "total_num_scheduled_tokens", None))
    if total is None:
        token_map = getattr(output, "num_scheduled_tokens", {}) or {}
        try:
            total = sum(int(value) for value in token_map.values())
        except Exception:
            total = None
    if total is None:
        return "unknown"
    if total == 0:
        return "empty"
    if total == 1:
        return "decode"
    return "prefill_chunk"


def _wrap_method(cls: Any, name: str, wrapper_factory: Any) -> None:
    original = getattr(cls, name, None)
    if original is None or getattr(original, "_vllm_process_latency_patched", False):
        return
    wrapped = wrapper_factory(original)
    wrapped._vllm_process_latency_patched = True
    setattr(cls, name, wrapped)


def _should_profile(forward_id: int, layer_id: int, phase: str) -> bool:
    if phase not in _phase_set() and "*" not in _phase_set():
        return False
    any_layers, event_keys = _target_sets()
    if not any_layers and not event_keys:
        return False
    if event_keys:
        matched = (forward_id, layer_id) in event_keys
    else:
        matched = layer_id in any_layers
    if not matched:
        return False
    max_per_layer = _max_samples_per_layer()
    if max_per_layer > 0 and _CAPTURED_BY_LAYER[layer_id] >= max_per_layer:
        return False
    return (forward_id, layer_id) not in _CAPTURED_EVENTS


def _make_label(meta: Mapping[str, Any], process_order: int) -> str:
    process_id, title = PROCESS_BY_ORDER[process_order]
    parts = [
        "vllm_process_latency",
        f"ctx={meta.get('context')}",
        f"event={meta.get('event_id')}",
        f"layer={meta.get('layer_id')}",
        f"q_len={meta.get('q_len')}",
        f"process={process_order:02d}",
        f"id={process_id}",
        f"name={process_id}",
    ]
    return "|".join(parts)


@contextmanager
def _profile_range(meta: Mapping[str, Any], process_order: int, hidden: Any = None):
    process_id, title = PROCESS_BY_ORDER[process_order]
    label = _make_label(meta, process_order)
    start_ns = 0
    error = ""
    status = "ok"
    try:
        _sync_device()
        start_ns = _now_ns()
        _ROCTX.push(label)
        yield
        _sync_device()
    except BaseException as exc:
        status = "error"
        error = repr(exc)
        raise
    finally:
        try:
            _ROCTX.pop()
        except Exception:
            pass
        end_ns = _now_ns()
        row = {
            **meta,
            "process_order": process_order,
            "process_id": process_id,
            "process_title": title,
            "hiptx_label": label,
            "status": status,
            "error": error,
            "start_ns": start_ns,
            "end_ns": end_ns,
            "duration_ns": end_ns - start_ns if start_ns else "",
            "hidden_shape": _shape_json(hidden),
        }
        with _LOCK:
            _append_csv(_latency_events_path(), LATENCY_FIELDS, row)


def _rmsnorm_native(module: Any, x: torch.Tensor, residual: torch.Tensor | None = None):
    if hasattr(module, "forward_native"):
        return module.forward_native(x, residual)
    return module.forward(x, residual)


def _is_gemma_rmsnorm(module: Any) -> bool:
    return module.__class__.__name__ == "GemmaRMSNorm"


def _rmsnorm_weight(module: Any) -> torch.Tensor | None:
    weight = getattr(module, "weight", None)
    if weight is None:
        return None
    return weight.data if hasattr(weight, "data") else weight


def _rmsnorm_hidden_size(module: Any) -> int:
    hidden_size = getattr(module, "hidden_size", None)
    if hidden_size is not None:
        return int(hidden_size)
    weight = _rmsnorm_weight(module)
    if weight is not None:
        return int(weight.shape[-1])
    raise ValueError(f"cannot infer hidden_size for {module!r}")


def _residual_add_for_post_norm(
    module: Any,
    x: torch.Tensor,
    residual: torch.Tensor,
) -> tuple[torch.Tensor, torch.Tensor, torch.dtype]:
    orig_dtype = x.dtype
    if _is_gemma_rmsnorm(module):
        summed = x.float() + residual.float() if orig_dtype == torch.float16 else x + residual
        return summed.float(), summed, orig_dtype
    summed = x.to(torch.float32) + residual
    return summed, summed.to(orig_dtype), orig_dtype


def _rmsnorm_from_sum(module: Any, norm_input: torch.Tensor, orig_dtype: torch.dtype) -> torch.Tensor:
    hidden_size = _rmsnorm_hidden_size(module)
    if norm_input.shape[-1] != hidden_size:
        raise ValueError(f"Expected hidden_size={hidden_size}, got {norm_input.shape[-1]}")
    eps = getattr(module, "variance_epsilon", getattr(module, "eps", 1e-6))
    if _is_gemma_rmsnorm(module):
        variance = norm_input.pow(2).mean(dim=-1, keepdim=True)
        out = norm_input * torch.rsqrt(variance + eps)
        weight = _rmsnorm_weight(module)
        if weight is not None:
            out = out * (1.0 + weight.float())
        return out.to(orig_dtype)

    variance_size_override = getattr(module, "variance_size_override", None)
    x_var = norm_input if variance_size_override is None else norm_input[..., :variance_size_override]
    variance = x_var.pow(2).mean(dim=-1, keepdim=True)
    out = norm_input * torch.rsqrt(variance + eps)
    out = out.to(orig_dtype)
    weight = _rmsnorm_weight(module)
    if weight is not None and getattr(module, "has_weight", True):
        out = out * weight
    return out


def _mrope_lookup(rotary_emb: Any, positions: torch.Tensor, query: torch.Tensor):
    cos_sin_cache = rotary_emb._match_cos_sin_cache_dtype(query)
    num_tokens = positions.shape[-1]
    cos_sin = cos_sin_cache[positions]
    cos, sin = cos_sin.chunk(2, dim=-1)
    if positions.ndim == 2:
        assert rotary_emb.mrope_section
        if rotary_emb.mrope_interleaved:
            try:
                from vllm.model_executor.layers.rotary_embedding import apply_interleaved_rope
            except ImportError:
                from vllm.model_executor.layers.rotary_embedding.mrope import apply_interleaved_rope
            cos = apply_interleaved_rope(cos, rotary_emb.mrope_section)
            sin = apply_interleaved_rope(sin, rotary_emb.mrope_section)
        else:
            cos = torch.cat(
                [item[i] for i, item in enumerate(cos.split(rotary_emb.mrope_section, dim=-1))],
                dim=-1,
            )
            sin = torch.cat(
                [item[i] for i, item in enumerate(sin.split(rotary_emb.mrope_section, dim=-1))],
                dim=-1,
            )
    return num_tokens, cos, sin


def _apply_one_rope(rotary_emb: Any, x: torch.Tensor, num_tokens: int, cos: torch.Tensor, sin: torch.Tensor) -> torch.Tensor:
    x_shape = x.shape
    x = x.view(num_tokens, -1, rotary_emb.head_size)
    x_rot = x[..., : rotary_emb.rotary_dim]
    x_pass = x[..., rotary_emb.rotary_dim :]
    x_rot = rotary_emb.apply_rotary_emb.forward_native(x_rot, cos, sin)
    return torch.cat((x_rot, x_pass), dim=-1).reshape(x_shape)


def _apply_attn_layer_scale(layer: Any, hidden_states: torch.Tensor) -> torch.Tensor:
    if not getattr(layer, "layer_scale", False):
        return hidden_states
    if len(hidden_states.shape) == 2:
        return hidden_states * (layer.attn_layer_scale.to(hidden_states.dtype)[0] + 1)
    return hidden_states * (layer.attn_layer_scale.to(hidden_states.dtype) + 1)


def _apply_ffn_layer_scale(layer: Any, hidden_states: torch.Tensor) -> torch.Tensor:
    if not getattr(layer, "layer_scale", False):
        return hidden_states
    if len(hidden_states.shape) == 2:
        return hidden_states * (layer.ffn_layer_scale.to(hidden_states.dtype)[0] + 1)
    return hidden_states * (layer.ffn_layer_scale.to(hidden_states.dtype) + 1)


def _instrumented_forward(
    *,
    layer: Any,
    hidden_states: torch.Tensor,
    residual: torch.Tensor | None,
    positions: torch.Tensor | None,
    meta: Mapping[str, Any],
) -> tuple[torch.Tensor, torch.Tensor]:
    with _profile_range(meta, 1, hidden_states):
        pass

    with _profile_range(meta, 2, hidden_states):
        if residual is None:
            residual = hidden_states
            hidden_states = _rmsnorm_native(layer.input_layernorm, hidden_states)
        else:
            hidden_states, residual = _rmsnorm_native(layer.input_layernorm, hidden_states, residual)

    if getattr(layer, "layer_type", None) != "full_attention":
        raise RuntimeError(f"unsupported instrumented layer_type={getattr(layer, 'layer_type', None)!r}")
    if positions is None:
        raise RuntimeError("positions is required for instrumented full_attention")

    attn = layer.self_attn

    with _profile_range(meta, 3, hidden_states):
        qkv, _ = attn.qkv_proj(hidden_states)
        if attn.attn_output_gate:
            q_gate, k, v = qkv.split([attn.q_size * 2, attn.kv_size, attn.kv_size], dim=-1)
            orig_shape = q_gate.shape[:-1]
            q_gate = q_gate.view(*orig_shape, attn.num_heads, -1)
            q, gate = torch.chunk(q_gate, 2, dim=-1)
            q = q.reshape(*orig_shape, -1)
            gate = gate.reshape(*orig_shape, -1)
        else:
            q, k, v = qkv.split([attn.q_size, attn.kv_size, attn.kv_size], dim=-1)
            gate = None

    with _profile_range(meta, 4, q):
        q = _rmsnorm_native(attn.q_norm, q.view(-1, attn.num_heads, attn.head_dim)).view(
            -1, attn.num_heads * attn.head_dim
        )

    with _profile_range(meta, 5, k):
        k = _rmsnorm_native(attn.k_norm, k.view(-1, attn.num_kv_heads, attn.head_dim)).view(
            -1, attn.num_kv_heads * attn.head_dim
        )

    with _profile_range(meta, 6, positions):
        num_tokens, cos, sin = _mrope_lookup(attn.rotary_emb, positions, q)

    with _profile_range(meta, 7, q):
        q = _apply_one_rope(attn.rotary_emb, q, num_tokens, cos, sin)

    with _profile_range(meta, 8, k):
        k = _apply_one_rope(attn.rotary_emb, k, num_tokens, cos, sin)

    with _profile_range(meta, 9, q):
        attn_output = attn.attn(q, k, v)

    with _profile_range(meta, 10, attn_output):
        if attn.attn_output_gate:
            assert gate is not None
            attn_output = attn_output * torch.sigmoid(gate)
        attn_output, _ = attn.o_proj(attn_output)
        attn_output = _apply_attn_layer_scale(layer, attn_output)
        assert residual is not None
        post_norm_input, residual, orig_dtype = _residual_add_for_post_norm(
            layer.post_attention_layernorm,
            attn_output,
            residual,
        )

    with _profile_range(meta, 11, residual):
        hidden_states = _rmsnorm_from_sum(layer.post_attention_layernorm, post_norm_input, orig_dtype)

    with _profile_range(meta, 12, hidden_states):
        hidden_states = layer.mlp(hidden_states)
        hidden_states = _apply_ffn_layer_scale(layer, hidden_states)

    return hidden_states, residual


def _write_run_metadata() -> None:
    if not _enabled():
        return
    any_layers, event_keys = _target_sets()
    metadata = {
        "analysis_type": "vllm_qwen35_selected_layer_process_latency_hiptx",
        "strategy": "selected target layers execute Python-visible native process boundaries and emit ROCTX/HIPTX ranges",
        "evidence_boundary": {
            "runtime": "ranges are emitted during vLLM eager generate() target-layer execution",
            "process_index": "process ids/titles mirror selected_layer_fx_process_visualization.md",
            "instrumentation": "target layers use native RMSNorm/RoPE boundaries and per-process synchronize to keep HIP kernels inside ranges",
        },
        "context": _context(),
        "pid": os.getpid(),
        "targets": os.environ.get("VLLM_PROCESS_LATENCY_TARGETS", ""),
        "target_any_forward_layers": sorted(any_layers),
        "target_event_keys": [f"input{forward}_layer{layer}" for forward, layer in sorted(event_keys)],
        "target_phases": sorted(_phase_set()),
        "sync_enabled": _sync_enabled(),
        "roctx_loaded": _ROCTX.lib is not None,
        "roctx_error": _ROCTX.error,
        "process_groups": [
            {"order": order, "process_id": process_id, "title": title}
            for order, process_id, title in PROCESS_GROUPS
        ],
        "observed_layer_event_count": _LAYER_EVENT_COUNT,
        "captured_events": [f"input{forward}_layer{layer}" for forward, layer in sorted(_CAPTURED_EVENTS)],
        "captured_by_layer": {str(key): value for key, value in sorted(_CAPTURED_BY_LAYER.items())},
        "patch_errors": _PATCH_ERRORS,
        "outputs": {
            "process_latency_events": str(_latency_events_path()),
            "process_latency_layer_events": str(_layer_events_path()),
            "run_metadata": str(_metadata_path()),
        },
    }
    try:
        _trace_dir().mkdir(parents=True, exist_ok=True)
        tmp_path = _metadata_path().with_name(f"{_metadata_path().name}.{os.getpid()}.tmp")
        tmp_path.write_text(
            json.dumps(_jsonable(metadata), indent=2, ensure_ascii=False, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        tmp_path.replace(_metadata_path())
    except BaseException as exc:
        _write_event("patch_error", where="write_run_metadata", error=repr(exc))


def _patch_engine() -> None:
    from vllm.v1.engine.core import EngineCore

    def step_wrapper(original: Any) -> Any:
        @functools.wraps(original)
        def wrapped(self: Any, *args: Any, **kwargs: Any) -> Any:
            step_id = _next_id(self, "_process_latency_engine_step_id")
            previous = _set_forward_context(
                engine_step_id=step_id,
                forward_id=_current_forward_id(),
                phase=_current_phase(),
                total_num_scheduled_tokens=_current_total_scheduled_tokens(),
            )
            try:
                return original(self, *args, **kwargs)
            finally:
                _restore_forward_context(previous)

        return wrapped

    _wrap_method(EngineCore, "step", step_wrapper)
    _wrap_method(EngineCore, "step_with_batch_queue", step_wrapper)


def _patch_scheduler() -> None:
    from vllm.v1.core.sched.scheduler import Scheduler

    def schedule_wrapper(original: Any) -> Any:
        @functools.wraps(original)
        def wrapped(self: Any, *args: Any, **kwargs: Any) -> Any:
            output = original(self, *args, **kwargs)
            step_id = _current_step_id()
            if step_id is None:
                step_id = _next_id(self, "_process_latency_scheduler_step_id")
            setattr(output, "_process_latency_engine_step_id", step_id)
            setattr(output, "_process_latency_phase", _phase_from_scheduler_output(output))
            return output

        return wrapped

    _wrap_method(Scheduler, "schedule", schedule_wrapper)


def _patch_model_runner() -> None:
    try:
        from vllm.v1.worker.gpu.model_runner import GPUModelRunner
    except Exception:
        return

    def execute_wrapper(original: Any) -> Any:
        @functools.wraps(original)
        def wrapped(self: Any, scheduler_output: Any, *args: Any, **kwargs: Any) -> Any:
            forward_id = _next_id(self, "_process_latency_forward_id")
            step_id = getattr(scheduler_output, "_process_latency_engine_step_id", _current_step_id())
            phase = getattr(scheduler_output, "_process_latency_phase", _phase_from_scheduler_output(scheduler_output))
            total = _safe_int(getattr(scheduler_output, "total_num_scheduled_tokens", None))
            previous = _set_forward_context(
                engine_step_id=step_id,
                forward_id=forward_id,
                phase=phase,
                total_num_scheduled_tokens=total,
            )
            try:
                return original(self, scheduler_output, *args, **kwargs)
            finally:
                _restore_forward_context(previous)

        return wrapped

    _wrap_method(GPUModelRunner, "execute_model", execute_wrapper)


def _patch_v1_model_runner() -> None:
    try:
        from vllm.v1.worker.gpu_model_runner import GPUModelRunner
    except Exception:
        return

    def execute_wrapper(original: Any) -> Any:
        @functools.wraps(original)
        def wrapped(self: Any, scheduler_output: Any, *args: Any, **kwargs: Any) -> Any:
            forward_id = _next_id(self, "_process_latency_forward_id")
            step_id = getattr(scheduler_output, "_process_latency_engine_step_id", _current_step_id())
            phase = getattr(scheduler_output, "_process_latency_phase", _phase_from_scheduler_output(scheduler_output))
            total = _safe_int(getattr(scheduler_output, "total_num_scheduled_tokens", None))
            previous = _set_forward_context(
                engine_step_id=step_id,
                forward_id=forward_id,
                phase=phase,
                total_num_scheduled_tokens=total,
            )
            try:
                return original(self, scheduler_output, *args, **kwargs)
            finally:
                _restore_forward_context(previous)

        return wrapped

    _wrap_method(GPUModelRunner, "execute_model", execute_wrapper)


def _patch_qwen35_decoder_layer() -> None:
    from vllm.model_executor.models.qwen3_5 import Qwen3_5DecoderLayer

    def forward_wrapper(original: Any) -> Any:
        @functools.wraps(original)
        def wrapped(self: Any, *args: Any, **kwargs: Any) -> Any:
            if not _is_armed():
                return original(self, *args, **kwargs)

            hidden_states = kwargs.get("hidden_states")
            if hidden_states is None and args:
                hidden_states = args[0]
            residual = kwargs.get("residual")
            if residual is None and len(args) > 1:
                residual = args[1]
            positions = kwargs.get("positions")
            if positions is None and len(args) > 2:
                positions = args[2]

            layer_id = _safe_int(getattr(self, "layer_idx", None))
            forward_id = _safe_int(_current_forward_id()) or -1
            phase = _current_phase() or "unknown"
            q_len = None
            if torch.is_tensor(hidden_states) and hidden_states.dim() >= 1:
                q_len = int(hidden_states.shape[0])
                if phase == "unknown":
                    phase = "prefill_chunk" if q_len > 1 else "decode"
            event_id = f"input{forward_id}_layer{layer_id}"
            matched = layer_id is not None and _should_profile(forward_id, layer_id, phase)
            meta = {
                "event_id": event_id,
                "context": _context(),
                "pid": os.getpid(),
                "engine_step_id": _current_step_id(),
                "forward_id": forward_id,
                "phase": phase,
                "total_num_scheduled_tokens": _current_total_scheduled_tokens(),
                "layer_id": layer_id,
                "layer_type": getattr(self, "layer_type", None),
                "q_len": q_len,
            }

            t0 = _now_ns()
            status = "ok"
            error = ""
            instrumented = False
            try:
                if matched:
                    _CAPTURED_EVENTS.add((forward_id, layer_id))
                    _CAPTURED_BY_LAYER[layer_id] += 1
                    instrumented = True
                    output = _instrumented_forward(
                        layer=self,
                        hidden_states=hidden_states,
                        residual=residual,
                        positions=positions,
                        meta=meta,
                    )
                else:
                    output = original(self, *args, **kwargs)
                return output
            except BaseException as exc:
                status = "error"
                error = repr(exc)
                _write_event(
                    "instrumented_forward_error",
                    **meta,
                    error=error,
                    traceback=traceback.format_exc(),
                )
                if os.environ.get("VLLM_PROCESS_LATENCY_STRICT") == "1":
                    raise
                return original(self, *args, **kwargs)
            finally:
                global _LAYER_EVENT_COUNT
                row = {
                    **meta,
                    "matched": bool(matched),
                    "instrumented": bool(instrumented),
                    "status": status,
                    "error": error,
                    "duration_ns": _now_ns() - t0,
                }
                with _LOCK:
                    _LAYER_EVENT_COUNT += 1
                    _append_csv(_layer_events_path(), LAYER_EVENT_FIELDS, row)
                    _write_run_metadata()

        return wrapped

    _wrap_method(Qwen3_5DecoderLayer, "forward", forward_wrapper)


def apply_patches() -> None:
    global _PATCHED
    if _PATCHED or not _enabled():
        return
    _PATCHED = True

    _trace_dir().mkdir(parents=True, exist_ok=True)
    for patch_fn in (
        _patch_engine,
        _patch_scheduler,
        _patch_model_runner,
        _patch_v1_model_runner,
        _patch_qwen35_decoder_layer,
    ):
        try:
            patch_fn()
        except BaseException:
            error = {"patch": patch_fn.__name__, "traceback": traceback.format_exc()}
            _PATCH_ERRORS.append(error)
            _write_event("patch_error", **error)

    _write_event(
        "patch_loaded",
        patches=[
            "engine",
            "scheduler",
            "model_runner",
            "v1_model_runner",
            "qwen35_decoder_layer",
        ],
        targets=os.environ.get("VLLM_PROCESS_LATENCY_TARGETS", ""),
        phases=sorted(_phase_set()),
        process_groups=[{"order": order, "process_id": process_id} for order, process_id, _ in PROCESS_GROUPS],
        sync_enabled=_sync_enabled(),
        roctx_loaded=_ROCTX.lib is not None,
        roctx_error=_ROCTX.error,
        errors=_PATCH_ERRORS,
    )
    _write_run_metadata()
    atexit.register(_write_run_metadata)
