import tempfile
import json
import threading
import unittest
from pathlib import Path
from urllib.request import Request, urlopen
from http.server import ThreadingHTTPServer

import server


def valid_registration():
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
    return {
        "batch": "v6-pi-native",
        "scenario": "Scenario-1",
        "run_id": "run-001",
        "model": "model-x",
        "provider": "provider-x",
        "prompt_version": "6.1-pi-native",
        "system_prompt_mode": "pi-default",
        "schema_version": "3.0",
        "data_revision": "revision-x",
        "pi_version": "pi x",
        "session_id": "session-x",
        "protocol_valid": True,
        "diagnosis_valid": True,
        "diagnosis_status": "resolved",
        "official_score": 1.0,
        "evidence_score": 90,
        "evidence_subscores": {
            name: {
                "score": maximum - (10 if name == "trigger_identification" else 0),
                "max_score": maximum,
                "rationale": "supported",
            }
            for name, maximum in dimensions.items()
        },
        "predicted_entities": ["Deployment/example"],
        "true_positives": ["Deployment/example"],
        "false_positives": [],
        "false_negatives": [],
        "failure_categories": [],
        "duration_seconds": 12,
        "tool_calls": 4,
        "total_tokens": 1000,
        "cost": 0.12,
        "started_at": "2026-09-29T00:00:00+00:00",
        "notes": "",
    }


class RegistrationTests(unittest.TestCase):
    def test_validates_and_builds_stable_key(self):
        record = server.validate_registration(valid_registration())
        self.assertEqual(record["key"], "v6-pi-native|Scenario-1|run-001")
        self.assertFalse(record["manual"])

    def test_rejects_historical_batch_as_new_comparison(self):
        payload = valid_registration()
        payload["batch"] = "v6-user-full"
        with self.assertRaisesRegex(ValueError, "batch must be"):
            server.validate_registration(payload)

    def test_registration_is_idempotent_and_conflicts_are_rejected(self):
        record = server.validate_registration(valid_registration())
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "registered-runs.json"
            self.assertTrue(server.append_registration(record.copy(), path))
            self.assertFalse(server.append_registration(record.copy(), path))
            changed = record.copy()
            changed["notes"] = "changed"
            with self.assertRaisesRegex(KeyError, "Conflicting registration"):
                server.append_registration(changed, path)
            self.assertEqual(len(server.load_records(path)), 1)

    def test_registration_http_endpoint_persists_and_merges_record(self):
        with tempfile.TemporaryDirectory() as directory:
            original = server.RUNS, server.NOTES, server.REGISTERED_RUNS
            server.RUNS = Path(directory) / "runs.json"
            server.RUNS.write_text("[]", encoding="utf-8")
            server.NOTES = Path(directory) / "notes.json"
            server.REGISTERED_RUNS = Path(directory) / "registered-runs.json"
            httpd = ThreadingHTTPServer(("127.0.0.1", 0), server.Handler)
            thread = threading.Thread(target=httpd.serve_forever)
            thread.start()
            try:
                endpoint = f"http://127.0.0.1:{httpd.server_port}/api/register"
                body = json.dumps(valid_registration()).encode("utf-8")
                request = Request(endpoint, data=body, headers={"Content-Type": "application/json"})
                with urlopen(request) as response:
                    first = json.loads(response.read())
                with urlopen(request) as response:
                    second = json.loads(response.read())
                with urlopen(f"http://127.0.0.1:{httpd.server_port}/api/data") as response:
                    data = json.loads(response.read())
                self.assertTrue(first["created"])
                self.assertFalse(second["created"])
                self.assertEqual(len(data["runs"]), 1)
                self.assertEqual(data["runs"][0]["key"], "v6-pi-native|Scenario-1|run-001")
            finally:
                httpd.shutdown()
                thread.join()
                httpd.server_close()
                server.RUNS, server.NOTES, server.REGISTERED_RUNS = original


if __name__ == "__main__":
    unittest.main()
