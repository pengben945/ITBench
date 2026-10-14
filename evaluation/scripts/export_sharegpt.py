#!/usr/bin/env python3
"""Export Pi agent run trajectories to LLaMA-Factory ShareGPT format.

Reads raw_output.jsonl (Pi session event stream) from selected run dirs and
produces three training products plus a manifest:

- sharegpt_full.jsonl   one full-trajectory sample per run
- sharegpt_steps.jsonl  per-step decision samples (sliding window + summary)
- sharegpt_final.jsonl  final-answer samples (evidence summary -> diagnosis JSON)

Design decisions (fixed for this export):
- thinking blocks are dropped; only actions and final answers are kept.
- tool outputs are truncated to head 1500 + tail 500 chars when > 2400 chars.
- LLaMA-Factory ShareGPT schema: conversations[] with from in
  {system, human, gpt, function_call, observation}; tools as a JSON string.
"""
import argparse
import json
import sys
from pathlib import Path

TRUNC_HEAD = 1500
TRUNC_TAIL = 500
TRUNC_MIN = 2400
STEP_WINDOW_MSGS = 10          # verbatim recent messages in step samples
STEP_CONTEXT_CHAR_BUDGET = 96000

TOOLS = [
    {"name": "read", "description": "Read a file with line offset and limit.",
     "parameters": {"type": "object", "properties": {
         "path": {"type": "string"}, "offset": {"type": "integer"},
         "limit": {"type": "integer"}}, "required": ["path"]}},
    {"name": "grep", "description": "Search file contents with a regex pattern.",
     "parameters": {"type": "object", "properties": {
         "pattern": {"type": "string"}, "path": {"type": "string"},
         "glob": {"type": "string"}, "ignoreCase": {"type": "boolean"},
         "literal": {"type": "boolean"}, "context": {"type": "integer"},
         "limit": {"type": "integer"}}, "required": ["pattern"]}},
    {"name": "find", "description": "Find files matching a glob pattern.",
     "parameters": {"type": "object", "properties": {
         "pattern": {"type": "string"}, "path": {"type": "string"},
         "limit": {"type": "integer"}}, "required": ["pattern"]}},
    {"name": "ls", "description": "List directory entries.",
     "parameters": {"type": "object", "properties": {
         "path": {"type": "string"}, "limit": {"type": "integer"}},
         "required": ["path"]}},
    {"name": "bash", "description": "Run a read-only shell command for parsing "
     "and aggregation (python3, jq, rg, awk, ...).",
     "parameters": {"type": "object", "properties": {
         "command": {"type": "string"}, "timeout": {"type": "integer"}},
         "required": ["command"]}},
]
TOOLS_STR = json.dumps(TOOLS, ensure_ascii=False)

LEAK_MARKERS = ("ground_truth", "groundtruth", "root_cause:")


def trunc(s: str) -> str:
    if len(s) <= TRUNC_MIN:
        return s
    cut = len(s) - TRUNC_HEAD - TRUNC_TAIL
    return s[:TRUNC_HEAD] + f"\n[...truncated {cut} chars...]\n" + s[-TRUNC_TAIL:]


def parse_args(a):
    if isinstance(a, dict):
        return a
    try:
        return json.loads(a)
    except Exception:
        return {"_raw": a}


def load_trajectory(run_dir: Path):
    msgs, compactions = [], []
    with open(run_dir / "raw_output.jsonl") as f:
        for line in f:
            x = json.loads(line)
            t = x.get("type")
            if t == "message_end":
                m = x["message"]
                r = m.get("role")
                if r == "user":
                    text = "".join(b.get("text", "") for b in m.get("content", [])
                                   if b.get("type") == "text")
                    msgs.append({"role": "user", "text": text})
                elif r == "assistant":
                    text = "".join(b.get("text", "") for b in m.get("content", [])
                                   if b.get("type") == "text")
                    tcs = [{"id": b.get("id"), "name": b.get("name"),
                            "arguments": parse_args(b.get("arguments", {}))}
                           for b in m.get("content", [])
                           if b.get("type") == "toolCall"]
                    msgs.append({"role": "assistant", "text": text,
                                 "tool_calls": tcs})
                elif r == "toolResult":
                    text = "\n".join(b.get("text", "")
                                     for b in m.get("content", [])
                                     if isinstance(b, dict)
                                     and b.get("type") == "text")
                    msgs.append({"role": "tool", "id": m.get("toolCallId"),
                                 "name": m.get("toolName"), "text": text,
                                 "isError": bool(m.get("isError"))})
            elif t == "compaction_end":
                summary = (x.get("result") or {}).get("summary")
                if summary:
                    compactions.append({"before_msg_index": len(msgs),
                                        "summary": summary})
    return msgs, compactions


def conv_of(msgs_slice, system):
    conv = [{"from": "system", "value": system}]
    for m in msgs_slice:
        if m["role"] == "user":
            conv.append({"from": "human", "value": m["text"]})
        elif m["role"] == "assistant":
            if m["text"].strip():
                conv.append({"from": "gpt", "value": m["text"]})
            for tc in m["tool_calls"]:
                conv.append({"from": "function_call",
                             "value": json.dumps(
                                 {"name": tc["name"],
                                  "arguments": tc["arguments"]},
                                 ensure_ascii=False)})
        elif m["role"] == "tool":
            prefix = "[tool error] " if m.get("isError") else ""
            conv.append({"from": "observation",
                         "value": prefix + trunc(m["text"])})
    return conv


def digest_of(msgs_slice):
    """Mechanical one-line-per-turn digest of earlier investigation turns."""
    lines = []
    for i, m in enumerate(msgs_slice):
        if m["role"] != "assistant":
            continue
        for tc in m["tool_calls"]:
            args = json.dumps(tc["arguments"], ensure_ascii=False)
            lines.append(f"- 第{i}轮 调用 {tc['name']}: {args[:100]}")
    return "\n".join(lines) if lines else "（此前无调查动作）"


def build_samples(run_cfg):
    run_dir = Path(run_cfg["run_dir"])
    msgs, compactions = load_trajectory(run_dir)
    system = (run_dir / "system_prompt.txt").read_text().strip()
    scenario = run_cfg["scenario"]
    run_id = run_cfg["run_id"]

    # sanity: final assistant text must be valid JSON equal to answer.json
    final_text = next(m["text"] for m in reversed(msgs)
                      if m["role"] == "assistant" and m["text"].strip())
    answer = json.loads((run_dir / "answer.json").read_text())
    final_ok = json.loads(final_text) == answer

    samples = []
    full = {"id": f"{scenario}-{run_id}-full-000",
            "conversations": conv_of(msgs, system), "tools": TOOLS_STR}
    samples.append(("full", full))

    step_idx = 0
    for i, m in enumerate(msgs):
        if m["role"] != "assistant" or not m["tool_calls"]:
            continue
        # context: task + summary-or-digest + recent window
        ctx = [msgs[0]]
        prior = [c for c in compactions if c["before_msg_index"] < i]
        if prior:
            last = prior[-1]
            ctx.append({"role": "user",
                        "text": "【前轮调查摘要】\n" + last["summary"]})
            win_start = last["before_msg_index"]
        else:
            win_start = 1
        window = msgs[max(win_start, i - STEP_WINDOW_MSGS):i]
        if not prior and i - STEP_WINDOW_MSGS > 1:
            ctx.append({"role": "user",
                        "text": "【此前调查动作摘要】\n"
                                + digest_of(msgs[1:i - STEP_WINDOW_MSGS])})
        ctx.extend(window)
        while (sum(len(json.dumps(c, ensure_ascii=False)) for c in ctx)
               > STEP_CONTEXT_CHAR_BUDGET and len(window) > 2):
            window = window[2:]
            ctx = ctx[:len(ctx) - len(window) - 2] + window
        conv = conv_of(ctx + [m], system)
        samples.append(("steps", {
            "id": f"{scenario}-{run_id}-step-{step_idx:03d}",
            "conversations": conv, "tools": TOOLS_STR}))
        step_idx += 1

    final_msg = next(m for m in reversed(msgs)
                     if m["role"] == "assistant" and m["text"].strip())
    if compactions:
        ev_ctx = "【前轮调查摘要】\n" + compactions[-1]["summary"]
    else:
        ev_ctx = "【调查动作摘要】\n" + digest_of(msgs[:-1])
    conv = conv_of([msgs[0], {"role": "user", "text": ev_ctx}, final_msg],
                   system)
    samples.append(("final", {
        "id": f"{scenario}-{run_id}-final-000",
        "conversations": conv, "tools": TOOLS_STR}))
    return samples, final_ok


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", required=True,
                    help="JSON list of runs with scores and run dirs")
    ap.add_argument("--out-dir", required=True)
    args = ap.parse_args()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    runs = json.loads(Path(args.config).read_text())

    handles = {p: open(out / f"sharegpt_{p}.jsonl", "w")
               for p in ("full", "steps", "final")}
    manifest = open(out / "manifest.jsonl", "w")
    leak_hits = []
    for cfg in runs:
        samples, final_ok = build_samples(cfg)
        for product, s in samples:
            text = json.dumps(s, ensure_ascii=False)
            for marker in LEAK_MARKERS:
                if marker in text:
                    leak_hits.append((s["id"], marker))
            handles[product].write(text + "\n")
            manifest.write(json.dumps({
                "id": s["id"], "product": product,
                "scenario": cfg["scenario"], "run_id": cfg["run_id"],
                "session_id": cfg["session_id"], "model": cfg["model"],
                "official_score": cfg["official_score"],
                "evidence_score": cfg["evidence_score"],
                "n_messages": len(s["conversations"]),
                "n_chars": len(text),
                "approx_tokens": len(text) // 4,
                "final_answer_valid": final_ok,
            }, ensure_ascii=False) + "\n")
    for h in handles.values():
        h.close()
    manifest.close()
    if leak_hits:
        print("LEAK MARKERS FOUND:", leak_hits, file=sys.stderr)
        sys.exit(2)
    print("done")


if __name__ == "__main__":
    main()
