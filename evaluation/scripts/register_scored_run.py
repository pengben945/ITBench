#!/usr/bin/env python3
"""Register a manually scored V6 comparison run in the evaluation dashboard."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

DIMENSIONS = {
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
COMPARISON_BATCHES = {"v6-pi-native", "v6-user-knowledge"}


def read_json(path: Path, default=None):
    if not path.exists():
        return default
    return json.loads(path.read_text(encoding="utf-8"))


def validate_score(score):
    if not isinstance(score, dict) or score.get("score_version") != "1.0":
        raise ValueError("score.json must use score_version '1.0'")
    diagnosis_valid = score.get("diagnosis_valid")
    if not isinstance(diagnosis_valid, bool):
        raise ValueError("diagnosis_valid must be a boolean")
    official = score.get("official_gt_score")
    evidence = score.get("evidence_quality_score")
    dimensions = score.get("evidence_subscores")
    if not isinstance(dimensions, dict):
        raise ValueError("evidence_subscores must be an object")
    if diagnosis_valid:
        if set(dimensions) != set(DIMENSIONS):
            raise ValueError("All nine evidence rubric dimensions are required")
        if isinstance(official, bool) or not isinstance(official, (int, float)):
            raise ValueError("official_gt_score must be a number from 0 to 1")
        if not math.isfinite(official) or not 0 <= official <= 1:
            raise ValueError("official_gt_score must be a number from 0 to 1")
        if isinstance(evidence, bool) or not isinstance(evidence, (int, float)):
            raise ValueError("evidence_quality_score must be a number from 0 to 100")
        if not math.isfinite(evidence) or not 0 <= evidence <= 100:
            raise ValueError("evidence_quality_score must be a number from 0 to 100")
        for name, maximum in DIMENSIONS.items():
            result = dimensions[name]
            if (
                not isinstance(result, dict)
                or result.get("max_score") != maximum
                or isinstance(result.get("score"), bool)
                or not isinstance(result.get("score"), (int, float))
                or not math.isfinite(result["score"])
                or not 0 <= result["score"] <= maximum
                or not isinstance(result.get("rationale"), str)
                or not result["rationale"].strip()
            ):
                raise ValueError(f"Invalid evidence subscore: {name}")
        if not math.isclose(
            sum(result["score"] for result in dimensions.values()),
            evidence,
            rel_tol=0,
            abs_tol=1e-6,
        ):
            raise ValueError("evidence_quality_score must equal the sum of its nine subscores")
    elif official is not None or evidence is not None or dimensions:
        raise ValueError("Invalid diagnoses must have null scores and no evidence subscores")

    for field in ("predicted_entities", "true_positives", "false_positives", "false_negatives"):
        values = score.get(field)
        if not isinstance(values, list) or any(not isinstance(value, str) for value in values):
            raise ValueError(f"{field} must be an array of strings")
    categories = score.get("failure_categories")
    if not isinstance(categories, list) or any(
        not isinstance(category, str) or category not in FAILURE_CATEGORIES
        for category in categories
    ):
        raise ValueError("failure_categories contains an unknown category")
    if len(set(categories)) != len(categories):
        raise ValueError("failure_categories must not contain duplicates")
    for field in ("predicted_entities", "true_positives", "false_positives", "false_negatives"):
        if len(set(score[field])) != len(score[field]):
            raise ValueError(f"{field} must not contain duplicate entities")
    predicted = set(score["predicted_entities"])
    true_positives = set(score["true_positives"])
    false_positives = set(score["false_positives"])
    false_negatives = set(score["false_negatives"])
    if true_positives & false_positives or predicted != true_positives | false_positives:
        raise ValueError("predicted_entities must equal the disjoint TP and FP sets")
    if true_positives & false_negatives or false_positives & false_negatives:
        raise ValueError("TP/FP entities must not overlap FN entities")
    if diagnosis_valid:
        if false_negatives:
            expected = 0.0
        elif true_positives or false_positives:
            expected = len(true_positives) / (len(true_positives) + len(false_positives))
        else:
            expected = None
        if expected is None or not math.isclose(expected, official, rel_tol=0, abs_tol=1e-9):
            raise ValueError("official_gt_score does not match the recorded TP/FP/FN sets")
    if not isinstance(score.get("notes"), str):
        raise ValueError("notes must be a string")


def make_registration(run_dir: Path, score):
    model_config = read_json(run_dir / "model_config.json")
    if not isinstance(model_config, dict):
        raise ValueError("model_config.json is missing or invalid")
    batch = model_config.get("batch")
    if batch not in COMPARISON_BATCHES:
        raise ValueError("Run is not part of the Pi-native/user-knowledge comparison")
    scenario = run_dir.parent.name
    run_id = run_dir.name
    if not re.fullmatch(r"Scenario-[0-9]+", scenario) or not re.fullmatch(r"run-[0-9]{3}", run_id):
        raise ValueError("RUN_DIR must be runs/Scenario-N/run-NNN")
    if model_config.get("systemPromptMode") != "pi-default":
        raise ValueError("Comparison run must use Pi's default system prompt")

    exit_code_path = run_dir / "exit_code.txt"
    exit_code = (
        exit_code_path.read_text(encoding="utf-8").strip()
        if exit_code_path.exists()
        else None
    )
    protocol_valid = (
        exit_code == "0"
        and (run_dir / "answer.json").is_file()
        and (run_dir / "metrics.json").is_file()
    )
    if score["diagnosis_valid"] and not protocol_valid:
        raise ValueError("Diagnosis cannot be valid when the runner protocol failed")

    metrics = read_json(run_dir / "metrics.json", {}) or {}
    usage = metrics.get("usage_sum", {})
    if not isinstance(usage, dict):
        usage = {}
    session_path = run_dir / "session_id.txt"
    session_id = session_path.read_text(encoding="utf-8").strip() if session_path.exists() else None
    started_path = run_dir / "started_at.txt"
    started_at = started_path.read_text(encoding="utf-8").strip() if started_path.exists() else "unknown"
    official = score["official_gt_score"] if score["diagnosis_valid"] else None
    evidence = score["evidence_quality_score"] if score["diagnosis_valid"] else None

    return {
        "batch": batch,
        "scenario": scenario,
        "run_id": run_id,
        "model": model_config.get("id", ""),
        "provider": model_config.get("provider", ""),
        "prompt_version": model_config.get("promptVersion", ""),
        "system_prompt_mode": model_config.get("systemPromptMode", ""),
        "schema_version": model_config.get("outputSchemaVersion", ""),
        "data_revision": model_config.get("dataRevision", ""),
        "pi_version": model_config.get("piVersion", ""),
        "session_id": session_id or None,
        "protocol_valid": protocol_valid,
        "diagnosis_valid": score["diagnosis_valid"],
        "diagnosis_status": metrics.get("diagnosis_status", "invalid" if not protocol_valid else "unscored"),
        "official_score": official,
        "evidence_score": evidence,
        "evidence_subscores": score["evidence_subscores"],
        "predicted_entities": score["predicted_entities"],
        "true_positives": score["true_positives"],
        "false_positives": score["false_positives"],
        "false_negatives": score["false_negatives"],
        "failure_categories": score["failure_categories"],
        "duration_seconds": metrics.get("duration_seconds", 0),
        "tool_calls": metrics.get("tool_calls", 0),
        "total_tokens": usage.get("totalTokens", 0),
        "cost": metrics.get("cost_sum", metrics.get("cost")),
        "started_at": started_at,
        "notes": score["notes"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path)
    parser.add_argument(
        "--dashboard-url",
        default=os.environ.get("ITBENCH_DASHBOARD_URL", "http://10.106.3.100:8790"),
        help="Dashboard base URL (default: ITBENCH_DASHBOARD_URL or http://10.106.3.100:8790)",
    )
    args = parser.parse_args()
    run_dir = args.run_dir.resolve()
    score_path = run_dir / "score.json"
    if not score_path.is_file():
        raise SystemExit(f"Scoring record is missing: {score_path}")

    parsed = urlparse(args.dashboard_url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise SystemExit("--dashboard-url must be an absolute HTTP(S) URL")
    try:
        score = read_json(score_path)
        validate_score(score)
        registration = make_registration(run_dir, score)
    except (OSError, json.JSONDecodeError, ValueError) as error:
        raise SystemExit(f"Cannot register scored run: {error}") from error

    endpoint = args.dashboard_url.rstrip("/") + "/api/register"
    request = Request(
        endpoint,
        data=json.dumps(registration, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(request, timeout=15) as response:
            result = json.loads(response.read().decode("utf-8"))
    except HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Dashboard registration failed ({error.code}): {detail}") from error
    except URLError as error:
        raise SystemExit(f"Dashboard is unreachable: {error.reason}") from error
    except json.JSONDecodeError as error:
        raise SystemExit(f"Dashboard returned invalid JSON after registration: {error}") from error
    expected_key = "|".join((registration["batch"], registration["scenario"], registration["run_id"]))
    if not isinstance(result, dict) or not result.get("ok") or result.get("key") != expected_key:
        raise SystemExit(f"Dashboard returned an unexpected registration response: {result}")

    try:
        with urlopen(args.dashboard_url.rstrip("/") + "/api/data", timeout=15) as response:
            dashboard_data = json.loads(response.read().decode("utf-8"))
    except (HTTPError, URLError, json.JSONDecodeError) as error:
        raise SystemExit(f"Registration succeeded but dashboard verification failed: {error}") from error
    if not isinstance(dashboard_data, dict) or not isinstance(dashboard_data.get("runs"), list):
        raise SystemExit("Dashboard verification response has no runs list")
    rows = dashboard_data["runs"]
    stored = next((row for row in rows if row.get("key") == result["key"]), None)
    if stored is None:
        raise SystemExit(f"Registration was acknowledged but not visible in /api/data: {result['key']}")
    for field in ("batch", "scenario", "run_id", "official_score", "evidence_score"):
        if stored.get(field) != registration[field]:
            raise SystemExit(f"Dashboard verification mismatch for {field}: {result['key']}")
    result["verified"] = True
    print(json.dumps(result, ensure_ascii=False))


if __name__ == "__main__":
    main()
