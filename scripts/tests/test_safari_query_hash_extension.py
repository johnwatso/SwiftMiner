#!/usr/bin/env python3
"""Structural and behavioral privacy tests for the Safari hash observer."""

from __future__ import annotations

import json
import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
RESOURCES = ROOT / "Sources" / "SwiftMinerSafariExtension" / "Resources"
SWIFT_HANDLER = (
    ROOT / "Sources" / "SwiftMinerSafariExtension" / "SafariWebExtensionHandler.swift"
)
CORE_HASHES = ROOT / "Sources" / "SwiftMinerCore" / "Utils" / "GQLHashes.swift"


def allowed_operations(source: str) -> set[str]:
    start = source.index("allowedOperations")
    end = source.index("]", start)
    return set(re.findall(r'"([A-Za-z][A-Za-z0-9_]+)"', source[start:end]))


class SafariQueryHashExtensionTests(unittest.TestCase):
    def test_manifest_has_only_the_required_surface(self) -> None:
        manifest = json.loads((RESOURCES / "manifest.json").read_text())

        self.assertEqual(manifest["manifest_version"], 3)
        self.assertEqual(manifest["permissions"], ["nativeMessaging"])
        self.assertEqual(manifest["host_permissions"], ["https://www.twitch.tv/drops/*"])
        self.assertNotIn("action", manifest)
        self.assertEqual(
            manifest["content_scripts"][0]["matches"],
            ["https://www.twitch.tv/drops/*"],
        )

    def test_operation_allow_lists_match_the_core_catalog(self) -> None:
        core = CORE_HASHES.read_text()
        query_catalog = core.split("public enum GQLQuery", 1)[1].split(
            "/// Immutable fallbacks", 1
        )[0]
        expected = set(re.findall(r'case \w+ = "([^"]+)"', query_catalog))
        self.assertEqual(len(expected), 12)

        for path in [
            RESOURCES / "page-hook.js",
            RESOURCES / "content.js",
            RESOURCES / "background.js",
            SWIFT_HANDLER,
        ]:
            self.assertEqual(allowed_operations(path.read_text()), expected, path)

    def test_page_hook_emits_only_allow_listed_operation_and_hash(self) -> None:
        harness = r'''
const fs = require("fs");
const emitted = [];
global.window = global;
global.location = { href: "https://www.twitch.tv/drops/campaigns" };
global.postMessage = value => emitted.push(value);
global.fetch = () => Promise.resolve({ ok: true });
global.XMLHttpRequest = function() {};
global.XMLHttpRequest.prototype.open = function() {};
global.XMLHttpRequest.prototype.send = function() {};
eval(fs.readFileSync(process.argv[1], "utf8"));
const hash = "a".repeat(64);
window.fetch("https://gql.twitch.tv/gql", {
  method: "POST",
  body: JSON.stringify({
    operationName: "ViewerDropsDashboard",
    variables: { oauthToken: "must-never-leave-page" },
    extensions: { persistedQuery: { sha256Hash: hash } }
  })
});
window.fetch("https://gql.twitch.tv/gql", {
  method: "POST",
  body: JSON.stringify({
    operationName: "UnknownSensitiveQuery",
    extensions: { persistedQuery: { sha256Hash: "b".repeat(64) } }
  })
});
window.fetch("https://example.com/gql", {
  method: "POST",
  body: JSON.stringify({
    operationName: "ViewerDropsDashboard",
    extensions: { persistedQuery: { sha256Hash: "c".repeat(64) } }
  })
});
console.log(JSON.stringify(emitted));
'''
        result = subprocess.run(
            ["node", "-e", harness, str(RESOURCES / "page-hook.js")],
            check=True,
            capture_output=True,
            text=True,
        )
        emitted = json.loads(result.stdout)

        self.assertEqual(
            emitted,
            [
                {
                    "source": "swiftminer-query-hash",
                    "version": 1,
                    "operationName": "ViewerDropsDashboard",
                    "sha256Hash": "a" * 64,
                }
            ],
        )
        self.assertNotIn("must-never-leave-page", result.stdout)

    def test_background_retries_only_when_native_store_declines(self) -> None:
        harness = r'''
const fs = require("fs");
let listener;
let calls = 0;
const responses = [{ accepted: false }, { accepted: true }];
global.browser = { runtime: {
  onMessage: { addListener: value => { listener = value; } },
  sendNativeMessage: () => Promise.resolve(responses[calls++])
} };
eval(fs.readFileSync(process.argv[1], "utf8"));
const message = {
  type: "queryHashCandidate",
  operationName: "ViewerDropsDashboard",
  sha256Hash: "a".repeat(64)
};
(async () => {
  await listener(message);
  await listener(message);
  const suppressed = listener(message);
  console.log(JSON.stringify({ calls, suppressed: suppressed === undefined }));
})().catch(error => { console.error(error); process.exit(1); });
'''
        result = subprocess.run(
            ["node", "-e", harness, str(RESOURCES / "background.js")],
            check=True,
            capture_output=True,
            text=True,
        )

        self.assertEqual(json.loads(result.stdout), {"calls": 2, "suppressed": True})


if __name__ == "__main__":
    unittest.main()
