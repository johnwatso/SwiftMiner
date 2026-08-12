from __future__ import annotations

import unittest
from pathlib import Path


class SparkleReleasePathTests(unittest.TestCase):
    root = Path(__file__).parents[2]

    def test_release_tools_use_docs_as_the_appcast_source_of_truth(self) -> None:
        validate_script = (self.root / "scripts/validate_sparkle.sh").read_text(encoding="utf-8")
        preflight_script = (self.root / "scripts/preflight_release.sh").read_text(encoding="utf-8")
        publish_script = (self.root / "scripts/publish_sparkle_release.sh").read_text(encoding="utf-8")
        publisher_source = (self.root / "Tools/SparklePublisher/main.swift").read_text(encoding="utf-8")

        self.assertIn('APPCAST_STABLE="$ROOT_DIR/docs/appcast.xml"', validate_script)
        self.assertIn('APPCAST="$ROOT_DIR/docs/appcast.xml"', preflight_script)
        self.assertIn('appcast short version is missing', preflight_script)
        self.assertNotIn('APPCAST_SHORT_VERSION" == "$MARKETING_VERSION', preflight_script)
        self.assertIn('appcast_path="$ROOT_DIR/docs/appcast.xml"', publish_script)
        self.assertIn('rootDir.appendingPathComponent("docs", isDirectory: true)', publisher_source)

    def test_validator_checks_a_present_release_notes_link(self) -> None:
        validate_script = (self.root / "scripts/validate_sparkle.sh").read_text(encoding="utf-8")

        self.assertIn('local-name()="releaseNotesLink"', validate_script)
        self.assertIn('Website/public/release-notes', validate_script)


if __name__ == "__main__":
    unittest.main()
