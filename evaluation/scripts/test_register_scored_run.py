import json
import tempfile
import unittest
from pathlib import Path

import register_scored_run as registration


def valid_score():
    dimensions = {
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
    subscores = {
        name: {
            "score": maximum - (10 if name == "trigger_identification" else 0),
            "max_score": maximum,
            "rationale": "Supported by the Case evidence",
        }
        for name, maximum in dimensions.items()
    }
    return {
        "score_version": "1.0",
        "diagnosis_valid": True,
        "official_gt_score": 1.0,
        "evidence_quality_score": 90,
        "evidence_subscores": subscores,
        "predicted_entities": ["Deployment/example"],
        "true_positives": ["Deployment/example"],
        "false_positives": [],
        "false_negatives": [],
        "failure_categories": [],
        "notes": "",
    }


class ScoredRunTests(unittest.TestCase):
    def test_validates_score_and_builds_dashboard_record(self):
        score = valid_score()
        registration.validate_score(score)
        with tempfile.TemporaryDirectory() as directory:
            run_dir = Path(directory) / "runs" / "Scenario-1" / "run-001"
            run_dir.mkdir(parents=True)
            (run_dir / "model_config.json").write_text(json.dumps({
                "batch": "v6-pi-native",
                "systemPromptMode": "pi-default",
                "promptVersion": "6.1-pi-native",
                "outputSchemaVersion": "3.0",
                "dataRevision": "revision-x",
                "piVersion": "pi x",
                "id": "model-x",
                "provider": "provider-x",
            }), encoding="utf-8")
            (run_dir / "exit_code.txt").write_text("0\n", encoding="utf-8")
            (run_dir / "answer.json").write_text("{}\n", encoding="utf-8")
            (run_dir / "metrics.json").write_text(json.dumps({
                "diagnosis_status": "resolved",
                "duration_seconds": 12,
                "tool_calls": 4,
                "usage_sum": {"totalTokens": 1000},
            }), encoding="utf-8")
            (run_dir / "session_id.txt").write_text("session-x\n", encoding="utf-8")
            (run_dir / "started_at.txt").write_text("2026-09-29T00:00:00+00:00\n", encoding="utf-8")

            record = registration.make_registration(run_dir, score)

        self.assertEqual(record["batch"], "v6-pi-native")
        self.assertTrue(record["protocol_valid"])
        self.assertEqual(record["official_score"], 1.0)
        self.assertEqual(record["evidence_score"], 90)
        self.assertEqual(record["session_id"], "session-x")

    def test_rejects_mismatched_entity_score(self):
        score = valid_score()
        score["official_gt_score"] = 0.5
        with self.assertRaisesRegex(ValueError, "official_gt_score"):
            registration.validate_score(score)

    def test_invalid_diagnosis_cannot_keep_scores(self):
        score = valid_score()
        score["diagnosis_valid"] = False
        score["official_gt_score"] = None
        score["evidence_quality_score"] = None
        score["evidence_subscores"] = {}
        registration.validate_score(score)


if __name__ == "__main__":
    unittest.main()
