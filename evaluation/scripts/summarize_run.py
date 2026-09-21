#!/usr/bin/env python3
"""Summarize reproducible Pi run metrics from a run directory."""

from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime
from pathlib import Path


def load_time(path: Path) -> datetime:
    return datetime.fromisoformat(path.read_text(encoding="utf-8").strip())


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("Usage: summarize_run.py RUN_DIR")

    run_dir = Path(sys.argv[1])
    raw_path = run_dir / "raw_output.jsonl"
    tool_counts: Counter[str] = Counter()
    turns = 0
    api_calls = 0
    usage = Counter()
    total_cost = 0.0

    with raw_path.open(encoding="utf-8") as stream:
        for line in stream:
            event = json.loads(line)
            event_type = event.get("type")
            if event_type == "turn_end":
                turns += 1
            if event_type == "tool_execution_start":
                tool_counts[event.get("toolName", "unknown")] += 1
            if event_type != "message_end":
                continue
            message = event.get("message", {})
            message_usage = message.get("usage")
            if isinstance(message_usage, dict):
                api_calls += 1
                for key in ("input", "output", "cacheRead", "cacheWrite", "reasoning", "totalTokens"):
                    value = message_usage.get(key)
                    if isinstance(value, (int, float)):
                        usage[key] += value
                cost = message_usage.get("cost", {}).get("total")
                if isinstance(cost, (int, float)):
                    total_cost += cost
    started = load_time(run_dir / "started_at.txt")
    finished = load_time(run_dir / "finished_at.txt")
    answer = json.loads((run_dir / "answer.json").read_text(encoding="utf-8"))
    trigger_findings = [
        finding
        for finding in answer.get("findings", [])
        if finding.get("role") == "trigger" and finding.get("status") == "supported"
    ]
    confidence = answer.get("confidence")
    if confidence is None and trigger_findings:
        confidence = max(finding.get("confidence", 0) for finding in trigger_findings)
    result = {
        "run_dir": str(run_dir),
        "duration_seconds": (finished - started).total_seconds(),
        "exit_code": int((run_dir / "exit_code.txt").read_text().strip()),
        "session_id": (run_dir / "session_id.txt").read_text().strip(),
        "schema_version": answer.get("schema_version"),
        "diagnosis_status": answer.get("diagnosis_status", answer.get("status")),
        "summary": answer.get("summary"),
        "root_cause": answer.get("root_cause", trigger_findings or None),
        "confidence": confidence,
        "turns": turns,
        "api_calls_with_usage": api_calls,
        "tool_calls": sum(tool_counts.values()),
        "tool_calls_by_name": dict(sorted(tool_counts.items())),
        "usage_sum": dict(usage),
        "cost_sum": total_cost,
        "raw_output_bytes": raw_path.stat().st_size,
        "answer_bytes": (run_dir / "answer.json").stat().st_size,
    }
    (run_dir / "metrics.json").write_text(
        json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
