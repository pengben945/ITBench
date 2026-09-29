#!/usr/bin/env python3
"""ITBench evaluation dashboard local server.

Usage: python3 evaluation/dashboard/server.py [--port 8790]

Serves the static dashboard and a tiny JSON API backed by files in this
directory (runs.json = generated run data, notes.json = user overrides,
notes and manual records). Bind address is 127.0.0.1 only.

API:
  GET    /api/data       -> {"runs": [...merged...], "manual": [...]}
  PUT    /api/override   body {"key", "official_score"?, "evidence_score"?,
                               "protocol_valid"?, "notes"?}  (null clears a field)
  POST   /api/manual     body {record fields}  -> appends a manual record
  POST   /api/register   body {scored comparison run} -> idempotently registers a run
  DELETE /api/manual     body {"id"}           -> removes a manual record

New scored runs are appended to registered-runs.json; the generated runs.json
and user notes are not rewritten by the registration endpoint.
"""
import argparse
import json
import math
import re
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BASE = Path(__file__).resolve().parent
RUNS = BASE / "runs.json"
NOTES = BASE / "notes.json"
REGISTERED_RUNS = BASE / "registered-runs.json"
LOCK = threading.Lock()

SCORE_DIMENSIONS = {
    "trigger_identification": 25,
    "technical_bottleneck": 10,
    "causal_propagation": 15,
    "temporal_consistency": 10,
    "evidence_quality": 15,
    "investigation_coverage": 10,
    "competing_hypotheses": 5,
    "repair_and_verification": 5,
    "output_and_reproducibility": 5,
}
FAILURE_CATEGORIES = {
    "DATA", "PARSING", "RETRIEVAL", "REASONING", "ENTITY",
    "OUTPUT", "INFRA", "GRADER",
}
BATCHES = {"v6-pi-native", "v6-user-knowledge"}


def load_notes():
    if NOTES.exists():
        return json.loads(NOTES.read_text())
    return {"overrides": {}, "manual": []}


def load_records(path):
    if not path.exists():
        return []
    records = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(records, list):
        raise ValueError(f"Expected a JSON array in {path}")
    return records


def save_records(path, records):
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    tmp.replace(path)


def _number(value, name, minimum, maximum=None):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{name} must be a number")
    if not math.isfinite(value) or value < minimum:
        raise ValueError(f"{name} must be finite and at least {minimum}")
    if maximum is not None and value > maximum:
        raise ValueError(f"{name} must not exceed {maximum}")
    return value


def validate_registration(data):
    if not isinstance(data, dict):
        raise ValueError("Request body must be a JSON object")
    required_strings = (
        "batch", "scenario", "run_id", "model", "provider", "prompt_version",
        "system_prompt_mode", "schema_version", "data_revision", "pi_version",
        "diagnosis_status", "started_at",
    )
    for field in required_strings:
        if not isinstance(data.get(field), str) or not data[field].strip():
            raise ValueError(f"{field} is required")
    if data["batch"] not in BATCHES:
        raise ValueError("batch must be v6-pi-native or v6-user-knowledge")
    if not re.fullmatch(r"Scenario-[0-9]+", data["scenario"]):
        raise ValueError("scenario must look like Scenario-N")
    if not re.fullmatch(r"run-[0-9]{3}", data["run_id"]):
        raise ValueError("run_id must look like run-NNN")
    if data["system_prompt_mode"] != "pi-default":
        raise ValueError("comparison runs must use Pi's default system prompt")

    for field in ("protocol_valid", "diagnosis_valid"):
        if not isinstance(data.get(field), bool):
            raise ValueError(f"{field} must be a boolean")
    if data["diagnosis_valid"] and not data["protocol_valid"]:
        raise ValueError("diagnosis_valid cannot be true when protocol_valid is false")

    session_id = data.get("session_id")
    if session_id is not None and not isinstance(session_id, str):
        raise ValueError("session_id must be a string or null")

    official_score = data.get("official_score")
    evidence_score = data.get("evidence_score")
    if data["diagnosis_valid"]:
        _number(official_score, "official_score", 0, 1)
        _number(evidence_score, "evidence_score", 0, 100)
    elif official_score is not None or evidence_score is not None:
        raise ValueError("invalid diagnoses must not carry comparison scores")

    subscores = data.get("evidence_subscores")
    if not isinstance(subscores, dict):
        raise ValueError("evidence_subscores must be an object")
    if data["diagnosis_valid"] and set(subscores) != set(SCORE_DIMENSIONS):
        raise ValueError("evidence_subscores must contain all nine rubric dimensions")
    if not data["diagnosis_valid"] and subscores:
        raise ValueError("invalid diagnoses must not carry evidence subscores")
    for dimension, result in subscores.items():
        if dimension not in SCORE_DIMENSIONS or not isinstance(result, dict):
            raise ValueError(f"Unknown or invalid evidence subscore: {dimension}")
        if result.get("max_score") != SCORE_DIMENSIONS[dimension]:
            raise ValueError(f"Incorrect max_score for {dimension}")
        _number(result.get("score"), f"{dimension}.score", 0, SCORE_DIMENSIONS[dimension])
        if not isinstance(result.get("rationale"), str) or not result["rationale"].strip():
            raise ValueError(f"{dimension}.rationale is required")
    if data["diagnosis_valid"] and not math.isclose(
        sum(result["score"] for result in subscores.values()),
        evidence_score,
        rel_tol=0,
        abs_tol=1e-6,
    ):
        raise ValueError("evidence_score must equal the sum of its nine subscores")

    for field in ("duration_seconds", "tool_calls", "total_tokens"):
        _number(data.get(field), field, 0)
    if data.get("cost") is not None:
        _number(data["cost"], "cost", 0)
    if not isinstance(data.get("failure_categories"), list) or any(
        not isinstance(category, str) or category not in FAILURE_CATEGORIES
        for category in data["failure_categories"]
    ):
        raise ValueError("failure_categories contains an unknown category")
    for field in ("predicted_entities", "true_positives", "false_positives", "false_negatives"):
        values = data.get(field)
        if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
            raise ValueError(f"{field} must be an array of strings")
        if len(values) != len(set(values)):
            raise ValueError(f"{field} must not contain duplicate entities")
    predicted = set(data["predicted_entities"])
    true_positives = set(data["true_positives"])
    false_positives = set(data["false_positives"])
    false_negatives = set(data["false_negatives"])
    if true_positives & false_positives or predicted != true_positives | false_positives:
        raise ValueError("predicted_entities must equal the disjoint TP and FP sets")
    if true_positives & false_negatives or false_positives & false_negatives:
        raise ValueError("TP/FP entities must not overlap FN entities")
    if data["diagnosis_valid"]:
        if false_negatives:
            expected_score = 0.0
        elif true_positives or false_positives:
            expected_score = len(true_positives) / (len(true_positives) + len(false_positives))
        else:
            expected_score = None
        if expected_score is None or not math.isclose(
            expected_score, official_score, rel_tol=0, abs_tol=1e-9
        ):
            raise ValueError("official_score does not match the recorded TP/FP/FN sets")
    if not isinstance(data.get("notes", ""), str):
        raise ValueError("notes must be a string")

    record = {
        field: data.get(field)
        for field in (
            "batch", "scenario", "run_id", "model", "provider", "prompt_version",
            "system_prompt_mode", "schema_version", "data_revision", "pi_version",
            "session_id", "protocol_valid", "diagnosis_valid", "diagnosis_status",
            "official_score", "evidence_score", "evidence_subscores",
            "predicted_entities", "true_positives", "false_positives",
            "false_negatives", "failure_categories", "duration_seconds",
            "tool_calls", "total_tokens", "cost", "started_at", "notes",
        )
    }
    record["key"] = f'{record["batch"]}|{record["scenario"]}|{record["run_id"]}'
    record["manual"] = False
    return record


def append_registration(record, path):
    records = load_records(path)
    existing = next((item for item in records if item.get("key") == record["key"]), None)
    if existing is not None:
        if any(existing.get(key) != value for key, value in record.items()):
            raise KeyError(f'Conflicting registration for {record["key"]}')
        return False
    record["registered_at"] = datetime.now(timezone.utc).isoformat()
    records.append(record)
    save_records(path, records)
    return True


def save_notes(n):
    tmp = NOTES.with_suffix(".tmp")
    tmp.write_text(json.dumps(n, ensure_ascii=False, indent=1))
    tmp.replace(NOTES)


def merged():
    runs = json.loads(RUNS.read_text()) if RUNS.exists() else []
    runs.extend(load_records(REGISTERED_RUNS))
    notes = load_notes()
    for r in runs:
        ov = notes["overrides"].get(r["key"])
        if ov:
            r.update({k: v for k, v in ov.items() if v is not None})
            r["has_override"] = True
    return {"runs": runs, "manual": notes["manual"]}


class Handler(BaseHTTPRequestHandler):
    def _json(self, obj, code=200):
        body = json.dumps(obj, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > 1_000_000:
            raise ValueError("Request body must be between 1 byte and 1 MB")
        return json.loads(self.rfile.read(length))

    def do_GET(self):
        if self.path == "/api/data":
            return self._json(merged())
        if self.path in ("/", "/index.html"):
            self.path = "/index.html"
        p = (BASE / self.path.lstrip("/")).resolve()
        if not str(p).startswith(str(BASE)) or not p.is_file():
            return self._json({"error": "not found"}, 404)
        ctype = ("text/html" if p.suffix == ".html" else
                 "application/json" if p.suffix == ".json" else "text/plain")
        body = p.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", ctype + "; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        if self.path != "/api/override":
            return self._json({"error": "not found"}, 404)
        try:
            b = self._body()
        except (ValueError, json.JSONDecodeError) as error:
            return self._json({"error": str(error)}, 400)
        key = b.get("key")
        if not key:
            return self._json({"error": "key required"}, 400)
        with LOCK:
            notes = load_notes()
            ov = notes["overrides"].setdefault(key, {})
            for f in ("official_score", "evidence_score", "protocol_valid", "notes"):
                if f in b:
                    if b[f] is None:
                        ov.pop(f, None)
                    else:
                        ov[f] = b[f]
            if not ov:
                notes["overrides"].pop(key, None)
            save_notes(notes)
        return self._json({"ok": True})

    def do_POST(self):
        if self.path == "/api/register":
            try:
                record = validate_registration(self._body())
            except (ValueError, json.JSONDecodeError) as error:
                return self._json({"error": str(error)}, 400)
            with LOCK:
                try:
                    created = append_registration(record, REGISTERED_RUNS)
                except KeyError as error:
                    return self._json({"error": str(error)}, 409)
                except OSError as error:
                    return self._json({"error": f"Could not persist registration: {error}"}, 500)
            return self._json({"ok": True, "created": created, "key": record["key"]})
        if self.path != "/api/manual":
            return self._json({"error": "not found"}, 404)
        try:
            b = self._body()
        except (ValueError, json.JSONDecodeError) as error:
            return self._json({"error": str(error)}, 400)
        with LOCK:
            notes = load_notes()
            b["key"] = f"manual|{int(time.time())}"
            b["manual"] = True
            notes["manual"].append(b)
            save_notes(notes)
        return self._json({"ok": True, "key": b["key"]})

    def do_DELETE(self):
        if self.path != "/api/manual":
            return self._json({"error": "not found"}, 404)
        try:
            key = self._body().get("key")
        except (ValueError, json.JSONDecodeError) as error:
            return self._json({"error": str(error)}, 400)
        with LOCK:
            notes = load_notes()
            notes["manual"] = [m for m in notes["manual"] if m.get("key") != key]
            save_notes(notes)
        return self._json({"ok": True})

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", default="127.0.0.1",
                    help="bind address; use 0.0.0.0 to allow LAN access")
    ap.add_argument("--port", type=int, default=8790)
    args = ap.parse_args()
    print(f"dashboard: http://{args.host}:{args.port}")
    ThreadingHTTPServer((args.host, args.port), Handler).serve_forever()
