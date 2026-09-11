from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "check_twitchdropsminer_upstream.py"
SPEC = importlib.util.spec_from_file_location("upstream_monitor", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MONITOR = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MONITOR
SPEC.loader.exec_module(MONITOR)


class PersistedQueryHashMonitorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.config = {
            "hashMappings": [
                {"upstreamKey": "GameDirectory", "swiftConstant": "directoryPage_Game"}
            ],
        }
        self.hash = "1" * 64
        self.upstream = {
            "GameDirectory": ("DirectoryPage_Game", self.hash),
        }
        self.swift = {"directoryPage_Game": self.hash}

    def test_parses_upstream_registry_entry_with_inline_comment(self) -> None:
        source = f'''\n"GameDirectory": GQLPersistedQuery(  # directory lookup\n    "DirectoryPage_Game",\n    "{self.hash}",\n)\n'''
        self.assertEqual(
            MONITOR.parse_upstream_queries(source),
            {"GameDirectory": ("DirectoryPage_Game", self.hash)},
        )

    def test_parses_swift_hash_constants(self) -> None:
        source = f'public static let directoryPage_Game = "{self.hash}"'
        self.assertEqual(
            MONITOR.parse_swift_hashes(source),
            {"directoryPage_Game": self.hash},
        )

    def test_identical_state_has_no_drift(self) -> None:
        report = MONITOR.analyze(
            self.config,
            head="a" * 40,
            upstream_queries=self.upstream,
            swift_hashes=self.swift,
        )
        self.assertFalse(report.has_drift)

    def test_upstream_commit_change_with_matching_hashes_is_silent(self) -> None:
        report = MONITOR.analyze(
            self.config,
            head="b" * 40,
            upstream_queries=self.upstream,
            swift_hashes=self.swift,
        )
        self.assertFalse(report.has_drift)

    def test_hash_change_requires_update(self) -> None:
        upstream = {
            "GameDirectory": ("DirectoryPage_Game", "2" * 64),
        }
        report = MONITOR.analyze(
            self.config,
            head="b" * 40,
            upstream_queries=upstream,
            swift_hashes=self.swift,
        )
        self.assertTrue(report.has_drift)
        self.assertEqual(len(report.hash_mismatches), 1)

    def test_missing_query_is_reported_instead_of_ignored(self) -> None:
        report = MONITOR.analyze(
            self.config,
            head="b" * 40,
            upstream_queries={},
            swift_hashes=self.swift,
        )
        self.assertTrue(report.has_drift)
        self.assertIsNone(report.hash_mismatches[0].upstream_hash)

    def test_config_requires_complete_hash_mappings(self) -> None:
        config = {
            "repository": "DevilXD/TwitchDropsMiner",
            "branch": "master",
            "hashMappings": [{"upstreamKey": "GameDirectory"}],
        }
        with self.assertRaises(MONITOR.CheckError):
            MONITOR.validate_config(config)

    def test_checked_in_config_covers_campaign_inventory_and_directory_probes(self) -> None:
        config_path = Path(__file__).parents[2] / ".github/upstream/twitchdropsminer.json"
        config = json.loads(config_path.read_text(encoding="utf-8"))
        mappings = {
            mapping["upstreamKey"]: mapping["swiftConstant"]
            for mapping in config["hashMappings"]
        }

        self.assertEqual(mappings["Campaigns"], "viewerDropsDashboard")
        self.assertEqual(mappings["Inventory"], "inventory")
        self.assertEqual(mappings["GameDirectory"], "directoryPage_Game")
        self.assertNotIn("reviewedCommit", config)
        self.assertNotIn("watchedPaths", config)


if __name__ == "__main__":
    unittest.main()
