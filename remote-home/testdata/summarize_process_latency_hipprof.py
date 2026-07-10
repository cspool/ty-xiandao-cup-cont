#!/usr/bin/env python3
"""Summarize selected-layer process latency HIPTX traces.

Inputs:
- selected-layer FX run directory, e.g. profile_runs/selected_layer_fx_20260707_codex
- process_latency/ contexts produced by run_selected_layer_process_latency_hipprof.sh

Outputs are written under <run_dir>/process_latency.
"""

from __future__ import annotations

import csv
import json
import re
import statistics
import sys
from collections import defaultdict
from pathlib import Path
from typing import Any


PROCESS_LABEL = "vllm_process_latency|"


def read_json(path: Path) -> Any:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def parse_label(label: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for part in label.split("|")[1:]:
        if "=" not in part:
            continue
        key, value = part.split("=", 1)
        result[key] = value
    return result


def numeric(value: Any) -> float | None:
    try:
        if value in ("", None):
            return None
        return float(value)
    except Exception:
        return None


def int_or_none(value: Any) -> int | None:
    try:
        if value in ("", None):
            return None
        return int(value)
    except Exception:
        return None


def median(values: list[float]) -> float | None:
    values = [item for item in values if item is not None]
    if not values:
        return None
    return float(statistics.median(values))


def mean(values: list[float]) -> float | None:
    values = [item for item in values if item is not None]
    if not values:
        return None
    return float(sum(values) / len(values))


def fmt_ms(value: float | None) -> str:
    if value is None:
        return ""
    return f"{value:.3f}"


def context_from_path(path: Path, latency_dir: Path) -> str:
    rel = path.relative_to(latency_dir)
    parts = rel.parts
    if parts and parts[0] == "contexts" and len(parts) > 1:
        return parts[1]
    if parts:
        return parts[0]
    return ""


def iter_hiptx_events(json_path: Path):
    """Yield HIPTX events without loading large Chrome traces fully."""
    with json_path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if PROCESS_LABEL not in line:
                continue
            text = line.strip()
            if text.startswith('{"traceEvents":['):
                text = text[len('{"traceEvents":[') :]
            if text.startswith(","):
                text = text[1:]
            if text.endswith("]}"):
                text = text[:-2]
            if text.endswith(","):
                text = text[:-1]
            try:
                event = json.loads(text)
            except Exception:
                # Fallback for compact one-line JSON files.
                try:
                    data = json.loads(json_path.read_text(encoding="utf-8", errors="replace"))
                except Exception:
                    return
                for item in data.get("traceEvents", []):
                    if PROCESS_LABEL in str(item.get("name", "")):
                        yield item
                return
            yield event


def load_process_index(run_dir: Path) -> list[dict[str, Any]]:
    candidates = sorted(
        (run_dir / "contexts").glob("*/fx_trace/traces/*/fx_process_reconstruction.json")
    )
    if not candidates:
        raise SystemExit(f"no fx_process_reconstruction.json found under {run_dir}/contexts")
    data = read_json(candidates[0])
    processes = []
    for process in data["processes"]:
        processes.append(
            {
                "order": int(process["order"]),
                "process_id": process["process_id"],
                "title": process["title"],
                "node_ranges": process.get("node_ranges", []),
                "node_count": len(process.get("node_indices", [])),
            }
        )
    return processes


def load_event_index(run_dir: Path) -> list[dict[str, Any]]:
    rows = []
    for path in sorted((run_dir / "contexts").glob("*/fx_trace/traces/*/fx_trace_metadata.json")):
        data = read_json(path)
        rows.append(
            {
                "context": path.relative_to(run_dir / "contexts").parts[0],
                "event_id": data.get("event_id") or path.parent.name,
                "layer_id": data.get("layer_id"),
                "forward_id": data.get("forward_id"),
                "q_len": data.get("q_len"),
                "phase": data.get("phase"),
                "metadata_path": str(path),
            }
        )
    return rows


def load_patch_rows(latency_dir: Path) -> list[dict[str, Any]]:
    rows = []
    for path in sorted(latency_dir.glob("contexts/*/trace/process_latency_events.csv")):
        context = context_from_path(path, latency_dir)
        with path.open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                row = dict(row)
                row.setdefault("context", context)
                row["source_csv"] = str(path)
                rows.append(row)
    for path in sorted(latency_dir.glob("*/process_latency_events.csv")):
        if "/contexts/" in str(path):
            continue
        context = context_from_path(path, latency_dir)
        with path.open(encoding="utf-8", newline="") as handle:
            for row in csv.DictReader(handle):
                row = dict(row)
                row.setdefault("context", context)
                row["source_csv"] = str(path)
                rows.append(row)
    return rows


def load_hiptx_rows(latency_dir: Path) -> list[dict[str, Any]]:
    rows = []
    for json_path in sorted(latency_dir.glob("contexts/*/hipprof/*.json")):
        context = context_from_path(json_path, latency_dir)
        for event in iter_hiptx_events(json_path):
            name = str(event.get("name", ""))
            info = parse_label(name)
            args = event.get("args", {}) if isinstance(event.get("args"), dict) else {}
            begin_ns = int_or_none(args.get("BeginNs"))
            end_ns = int_or_none(args.get("EndNs"))
            dur_us = numeric(event.get("dur"))
            rows.append(
                {
                    "context": info.get("ctx") or context,
                    "event_id": info.get("event", ""),
                    "layer_id": info.get("layer", ""),
                    "q_len": info.get("q_len", ""),
                    "process_order": info.get("process", ""),
                    "process_id": info.get("id", ""),
                    "hiptx_label": name,
                    "hiptx_dur_us": dur_us,
                    "hiptx_duration_ns": (end_ns - begin_ns) if begin_ns is not None and end_ns is not None else "",
                    "begin_ns": begin_ns if begin_ns is not None else "",
                    "end_ns": end_ns if end_ns is not None else "",
                    "trace_json": str(json_path),
                }
            )
    return rows


def aggregate(
    processes: list[dict[str, Any]],
    events: list[dict[str, Any]],
    patch_rows: list[dict[str, Any]],
    hiptx_rows: list[dict[str, Any]],
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    process_by_order = {str(item["order"]).zfill(2): item for item in processes}
    process_by_order.update({str(item["order"]): item for item in processes})
    event_index = {(item["context"], item["event_id"]): item for item in events}

    patch_by_key: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in patch_rows:
        key = (row.get("context", ""), row.get("event_id", ""), str(row.get("process_order", "")).zfill(2))
        patch_by_key[key].append(row)

    hiptx_by_key: dict[tuple[str, str, str], list[dict[str, Any]]] = defaultdict(list)
    for row in hiptx_rows:
        key = (row.get("context", ""), row.get("event_id", ""), str(row.get("process_order", "")).zfill(2))
        hiptx_by_key[key].append(row)

    summary_rows = []
    for event in events:
        for process in processes:
            order = str(process["order"]).zfill(2)
            key = (event["context"], event["event_id"], order)
            patch_items = patch_by_key.get(key, [])
            hiptx_items = hiptx_by_key.get(key, [])
            patch_ms = [
                (float(item["duration_ns"]) / 1_000_000.0)
                for item in patch_items
                if numeric(item.get("duration_ns")) is not None
            ]
            hiptx_ms = [
                (float(item["hiptx_dur_us"]) / 1000.0)
                for item in hiptx_items
                if numeric(item.get("hiptx_dur_us")) is not None
            ]
            summary_rows.append(
                {
                    "context": event["context"],
                    "event_id": event["event_id"],
                    "layer_id": event.get("layer_id"),
                    "q_len": event.get("q_len"),
                    "process_order": process["order"],
                    "process_id": process["process_id"],
                    "process_title": process["title"],
                    "node_ranges": ",".join(process.get("node_ranges", [])),
                    "node_count": process.get("node_count", ""),
                    "hiptx_count": len(hiptx_items),
                    "hiptx_median_ms": median(hiptx_ms),
                    "hiptx_mean_ms": mean(hiptx_ms),
                    "patch_count": len(patch_items),
                    "patch_median_ms": median(patch_ms),
                    "patch_mean_ms": mean(patch_ms),
                    "trace_json": hiptx_items[0]["trace_json"] if hiptx_items else "",
                    "source_csv": patch_items[0]["source_csv"] if patch_items else "",
                }
            )

    context_rows = []
    grouped: dict[tuple[str, int], list[dict[str, Any]]] = defaultdict(list)
    for row in summary_rows:
        grouped[(row["context"], int(row["process_order"]))].append(row)
    for (context, order), rows in sorted(grouped.items()):
        process = process_by_order[str(order)]
        hiptx_vals = [row["hiptx_median_ms"] for row in rows if row["hiptx_median_ms"] is not None]
        patch_vals = [row["patch_median_ms"] for row in rows if row["patch_median_ms"] is not None]
        context_rows.append(
            {
                "context": context,
                "process_order": order,
                "process_id": process["process_id"],
                "process_title": process["title"],
                "event_count": len(rows),
                "hiptx_available_events": sum(1 for row in rows if row["hiptx_count"]),
                "hiptx_median_ms": median(hiptx_vals),
                "patch_available_events": sum(1 for row in rows if row["patch_count"]),
                "patch_median_ms": median(patch_vals),
            }
        )
    return summary_rows, context_rows


def write_csv(path: Path, rows: list[dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("", encoding="utf-8")
        return
    fields = list(rows[0].keys())
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)


def write_markdown(
    path: Path,
    run_dir: Path,
    latency_dir: Path,
    processes: list[dict[str, Any]],
    events: list[dict[str, Any]],
    summary_rows: list[dict[str, Any]],
    context_rows: list[dict[str, Any]],
    hiptx_rows: list[dict[str, Any]],
    patch_rows: list[dict[str, Any]],
) -> None:
    contexts = ["4-8K", "8-16K", "16-32K"]
    by_context_process = {
        (row["context"], int(row["process_order"])): row for row in context_rows
    }
    event_by_context: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for event in events:
        event_by_context[event["context"]].append(event)

    lines = [
        "# Selected-layer FX Process Latency",
        "",
        f"索引文档：`{run_dir / 'selected_layer_fx_process_visualization.md'}`",
        "",
        "## 采集方式",
        "",
        "- 对 12 个 FX process group 使用同一套 `order/process_id/title` 索引。",
        "- 远程容器中已运行 `hipprof --hip-trace --hiptx-trace` 包裹 vLLM server，并保留每个 context 的 hipprof DB/log。",
        "- range 来自 `process_latency_patch` 的 Python 接口注入，不修改已安装 vLLM wheel 文件。",
        "- 为了让 kernel 落在对应 range 内，目标 layer profiling 时默认在每个 process 前后做 device synchronize；因此这里是 profiling-instrumented latency，不是吞吐 benchmark 的无扰动端到端延迟。",
        "- 目标 layer 的 RMSNorm/RoPE 使用 Python-visible native 边界，以便和 FX process 6/7/8/10/11 分组一致。",
        "- 当前 vLLM server 路径仍会把模型执行放到 EngineCore worker；已尝试 `--disable-frontend-multiprocessing` 和 `VLLM_ENABLE_V1_MULTIPROCESSING=0`，hipprof DB 重建仍报告 `has not valid trace data`，因此本文表格使用 patch 写出的同步 device range latency，HIPTX 列保留为诊断字段。",
        "",
        "## 覆盖范围",
        "",
        "| context | events | q_len | HIPTX ranges | patch ranges |",
        "| --- | --- | --- | ---: | ---: |",
    ]
    for context in contexts:
        evs = event_by_context.get(context, [])
        event_text = ", ".join(item["event_id"] for item in evs)
        q_lens = ", ".join(sorted({str(item.get("q_len")) for item in evs}))
        hiptx_count = sum(1 for row in summary_rows if row["context"] == context and row["hiptx_count"])
        patch_count = sum(1 for row in summary_rows if row["context"] == context and row["patch_count"])
        lines.append(f"| {context} | {event_text} | {q_lens} | {hiptx_count}/36 | {patch_count}/36 |")

    lines.extend(
        [
            "",
            "## Context Median Latency",
            "",
            "单位：ms。优先使用 hipprof HIPTX range；括号内是 patch 同步 CPU duration 的 median，作为 hipprof 缺失时的兜底读数。",
            "",
            "| # | process | 4-8K | 8-16K | 16-32K |",
            "| ---: | --- | ---: | ---: | ---: |",
        ]
    )
    for process in processes:
        cells = []
        for context in contexts:
            row = by_context_process.get((context, process["order"]))
            if not row:
                cells.append("")
                continue
            hiptx = fmt_ms(row.get("hiptx_median_ms"))
            patch = fmt_ms(row.get("patch_median_ms"))
            if hiptx and patch:
                cells.append(f"{hiptx} ({patch})")
            else:
                cells.append(hiptx or (f"({patch})" if patch else ""))
        lines.append(
            f"| {process['order']} | `{process['process_id']}` | {cells[0]} | {cells[1]} | {cells[2]} |"
        )

    lines.extend(
        [
            "",
            "## Event-level 明细",
            "",
            "完整 event/process 明细见 `process_latency_summary.csv`；下面只列每个 event 是否完整。",
            "",
            "| context | event | q_len | HIPTX processes | patch processes |",
            "| --- | --- | ---: | ---: | ---: |",
        ]
    )
    for event in events:
        rows = [row for row in summary_rows if row["context"] == event["context"] and row["event_id"] == event["event_id"]]
        hiptx_count = sum(1 for row in rows if row["hiptx_count"])
        patch_count = sum(1 for row in rows if row["patch_count"])
        lines.append(
            f"| {event['context']} | `{event['event_id']}` | {event.get('q_len')} | {hiptx_count}/12 | {patch_count}/12 |"
        )

    lines.extend(
        [
            "",
            "## 产物",
            "",
            f"- `process_latency_summary.csv`: 9 个 event × 12 个 process 的汇总表。",
            f"- `process_latency_context_summary.csv`: 每个 context 内跨 3 个 event 的 process median。",
            f"- `process_latency_hiptx_ranges.csv`: 从 hipprof JSON 抽出的原始 HIPTX range；当前为空，因为 hipprof DB 未捕获到有效 worker trace。",
            f"- `process_latency_patch_ranges.csv`: patch 写出的同步 CPU range。",
            f"- `contexts/<context>/hipprof/vllm_process_latency.db` 和 `hipprof_db_timeline.log`: hipprof 原始 DB 与 DB 重建日志。",
            f"- `contexts/<context>/trace/process_latency_events.csv`: 目标 layer process range 原始记录。",
            "",
            "## 结论",
            "",
            "这份结果可以按 process 对比三种上下文范围中的目标层计算耗时。当前所有单元均为括号读数，含义是 patch 已记录同步 device range duration；hipprof 已执行但没有捕获到 EngineCore worker 的有效 HIPTX timeline，不能作为本次 per-process latency 的数值来源。",
            "",
        ]
    )
    path.write_text("\n".join(lines), encoding="utf-8")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: summarize_process_latency_hipprof.py <selected_layer_fx_run_dir>", file=sys.stderr)
        return 2
    run_dir = Path(argv[1]).resolve()
    latency_dir = run_dir / "process_latency"
    latency_dir.mkdir(parents=True, exist_ok=True)

    processes = load_process_index(run_dir)
    events = load_event_index(run_dir)
    patch_rows = load_patch_rows(latency_dir)
    hiptx_rows = load_hiptx_rows(latency_dir)
    summary_rows, context_rows = aggregate(processes, events, patch_rows, hiptx_rows)

    write_csv(latency_dir / "process_latency_patch_ranges.csv", patch_rows)
    write_csv(latency_dir / "process_latency_hiptx_ranges.csv", hiptx_rows)
    write_csv(latency_dir / "process_latency_summary.csv", summary_rows)
    write_csv(latency_dir / "process_latency_context_summary.csv", context_rows)
    (latency_dir / "process_latency_summary.json").write_text(
        json.dumps(
            {
                "run_dir": str(run_dir),
                "latency_dir": str(latency_dir),
                "process_count": len(processes),
                "event_count": len(events),
                "patch_range_count": len(patch_rows),
                "hiptx_range_count": len(hiptx_rows),
                "processes": processes,
                "events": events,
                "context_summary": context_rows,
            },
            indent=2,
            ensure_ascii=False,
        )
        + "\n",
        encoding="utf-8",
    )
    write_markdown(
        latency_dir / "selected_layer_fx_process_latency.md",
        run_dir,
        latency_dir,
        processes,
        events,
        summary_rows,
        context_rows,
        hiptx_rows,
        patch_rows,
    )

    print(f"wrote {latency_dir / 'selected_layer_fx_process_latency.md'}")
    print(f"patch_ranges={len(patch_rows)} hiptx_ranges={len(hiptx_rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
