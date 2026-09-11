from __future__ import annotations

import base64
import importlib.util
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from io import StringIO
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "discover_twitch_query_hash.py"
SPEC = importlib.util.spec_from_file_location("query_hash_discovery", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
DISCOVERY = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = DISCOVERY
SPEC.loader.exec_module(DISCOVERY)


class TwitchQueryHashDiscoveryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dashboard_hash = "a" * 64
        self.inventory_hash = "b" * 64

    def payload(self, operation: str, query_hash: str) -> dict[str, object]:
        return {
            "operationName": operation,
            "variables": {"sensitive": "deliberately ignored"},
            "extensions": {
                "persistedQuery": {"version": 1, "sha256Hash": query_hash}
            },
        }

    def har_entry(
        self,
        payload: object,
        *,
        url: str = "https://gql.twitch.tv/gql",
        encoding: str | None = None,
    ) -> dict[str, object]:
        text = json.dumps(payload)
        if encoding == "base64":
            text = base64.b64encode(text.encode("utf-8")).decode("ascii")
        post_data: dict[str, object] = {"mimeType": "application/json", "text": text}
        if encoding is not None:
            post_data["encoding"] = encoding
        return {
            "request": {
                "method": "POST",
                "url": url,
                "headers": [{"name": "Authorization", "value": "secret"}],
                "postData": post_data,
            },
            "response": {"content": {"text": "must not be inspected"}},
        }

    def test_discovers_hash_from_direct_request_body(self) -> None:
        document = self.payload("ViewerDropsDashboard", self.dashboard_hash)
        self.assertEqual(
            DISCOVERY.discover(document),
            [DISCOVERY.QueryHash("ViewerDropsDashboard", self.dashboard_hash)],
        )

    def test_discovers_batched_requests_from_twitch_har(self) -> None:
        batch = [
            self.payload("ViewerDropsDashboard", self.dashboard_hash),
            self.payload("Inventory", self.inventory_hash),
        ]
        document = {"log": {"entries": [self.har_entry(batch)]}}
        self.assertEqual(
            DISCOVERY.latest_by_operation(DISCOVERY.discover(document)),
            {
                "ViewerDropsDashboard": self.dashboard_hash,
                "Inventory": self.inventory_hash,
            },
        )

    def test_uses_latest_hash_when_capture_contains_a_change(self) -> None:
        document = {
            "log": {
                "entries": [
                    self.har_entry(
                        self.payload("ViewerDropsDashboard", self.dashboard_hash)
                    ),
                    self.har_entry(
                        self.payload("ViewerDropsDashboard", self.inventory_hash)
                    ),
                ]
            }
        }
        latest = DISCOVERY.latest_by_operation(DISCOVERY.discover(document))
        self.assertEqual(latest["ViewerDropsDashboard"], self.inventory_hash)

    def test_decodes_base64_har_post_data(self) -> None:
        document = {
            "log": {
                "entries": [
                    self.har_entry(
                        self.payload("ViewerDropsDashboard", self.dashboard_hash),
                        encoding="base64",
                    )
                ]
            }
        }
        self.assertEqual(len(DISCOVERY.discover(document)), 1)

    def test_ignores_non_twitch_requests_and_response_bodies(self) -> None:
        response_payload = self.payload("ViewerDropsDashboard", self.dashboard_hash)
        document = {
            "log": {
                "entries": [
                    self.har_entry(
                        response_payload,
                        url="https://example.com/gql",
                    ),
                    {
                        "request": {
                            "method": "GET",
                            "url": "https://gql.twitch.tv/gql",
                        },
                        "response": {"content": {"text": json.dumps(response_payload)}},
                    },
                ]
            }
        }
        self.assertEqual(DISCOVERY.discover(document), [])

    def test_rejects_malformed_hash(self) -> None:
        document = self.payload("ViewerDropsDashboard", "not-a-sha256")
        self.assertEqual(DISCOVERY.discover(document), [])

    def test_cli_hash_only_output_contains_no_request_data(self) -> None:
        document = self.payload("ViewerDropsDashboard", self.dashboard_hash)
        with tempfile.TemporaryDirectory() as directory:
            capture = Path(directory) / "payload.json"
            capture.write_text(json.dumps(document), encoding="utf-8")
            output = StringIO()
            with redirect_stdout(output):
                result = DISCOVERY.main([str(capture), "--hash-only"])

        self.assertEqual(result, 0)
        self.assertEqual(output.getvalue(), f"{self.dashboard_hash}\n")
        self.assertNotIn("sensitive", output.getvalue())

    def test_missing_capture_explains_how_to_export_one(self) -> None:
        error_output = StringIO()
        with redirect_stderr(error_output):
            result = DISCOVERY.main(["/path/that/does/not/exist.har"])

        self.assertEqual(result, 1)
        self.assertIn("press Command-S to export a HAR", error_output.getvalue())
        self.assertNotIn("Errno", error_output.getvalue())


if __name__ == "__main__":
    unittest.main()
