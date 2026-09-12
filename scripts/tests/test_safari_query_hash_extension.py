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
PROJECT = ROOT / "project.yml"
ADVANCED_SETTINGS = ROOT / "Sources" / "SwiftMiner" / "AdvancedSettingsPane.swift"
RECOVERY = ROOT / "Sources" / "SwiftMiner" / "TwitchCompatibilityRecovery.swift"


def allowed_operations(source: str) -> set[str]:
    start = source.index("allowedOperations")
    end = source.index("]", start)
    return set(re.findall(r'"([A-Za-z][A-Za-z0-9_]+)"', source[start:end]))


class SafariQueryHashExtensionTests(unittest.TestCase):
    def test_debug_extension_is_sandboxed_without_protected_app_group(self) -> None:
        project = PROJECT.read_text()
        debug_entitlements = (
            ROOT
            / "Sources"
            / "SwiftMinerSafariExtension"
            / "SwiftMinerSafariExtensionDebug.entitlements"
        ).read_text()

        self.assertIn("ENABLE_APP_SANDBOX: YES", project)
        self.assertIn("SwiftMinerSafariExtensionDebug.entitlements", project)
        self.assertIn("com.apple.security.app-sandbox", debug_entitlements)
        self.assertNotIn("com.apple.security.application-groups", debug_entitlements)

    def test_check_action_opens_both_supported_twitch_pages(self) -> None:
        source = ADVANCED_SETTINGS.read_text()
        recovery = RECOVERY.read_text()

        self.assertIn('Button("Update via Safari")', source)
        self.assertIn("TwitchCompatibilityRecovery.startUpdate(", source)

        # The queue covers each page that issues an operation SwiftMiner can refresh.
        self.assertIn('"/drops/campaigns"', recovery)
        self.assertIn('"/drops/inventory"', recovery)
        # DirectoryPage_Game only fires on a real category page, and it is the single
        # most-rotated operation upstream.
        self.assertIn('"/directory/category/', recovery)

    def test_progress_is_shown_in_the_page_not_a_toolbar_popover(self) -> None:
        content = (RESOURCES / "content.js").read_text()
        popup = (RESOURCES / "popup.html").read_text()

        self.assertIn("swiftminer-update-banner", content)
        self.assertIn("Updating hashes via Safari", content)

        # The banner shows the real app icon, which a content script can only load when
        # the file is declared web-accessible.
        manifest = json.loads((RESOURCES / "manifest.json").read_text())
        self.assertIn("swiftminer-icon.png", content)
        self.assertIn(
            "swiftminer-icon.png",
            manifest["web_accessible_resources"][0]["resources"],
        )
        self.assertTrue((RESOURCES / "swiftminer-icon.png").exists())
        # The popup is static information; it carries no progress and no controls.
        self.assertNotIn("progress", popup.lower())
        self.assertNotIn("<button", popup.lower())

    def test_automatic_recovery_only_chases_a_broken_query(self) -> None:
        """Discovery must fire on breakage, never on mere difference.

        Twitch's own pages use sibling documents for some operations — a different query
        wearing the same operation name. Adopting one of those over a *working* hash is
        what replaced a healthy Drops inventory query with one that reported every claimed
        drop as unclaimed. `queriesNeedingRecovery` is only ever populated when SwiftMiner's
        own bundled hash has stopped working.
        """
        recovery = RECOVERY.read_text()

        self.assertIn("store.queriesNeedingRecovery()", recovery)
        self.assertIn("store.automaticDiscoveryEnabled", recovery)
        self.assertIn("lastRecoveryAttempt", recovery)
        self.assertIn("startUpdate(", recovery)

    def test_advanced_settings_expose_no_manual_hash_entry(self) -> None:
        """The compatibility screen reports a comparison; it is not a hash editor.

        A field that accepts a pasted hash is the one way a user can put an unverified
        value into the store by hand, and the screen's whole premise is that adoption is
        automatic and validated. These are the strings that came back if it returned.
        """
        source = ADVANCED_SETTINGS.read_text()

        for banned in (
            "Paste 64-character SHA-256 hash",
            'Button("Save & Test")',
            'Button("Reset to Bundled"',
            "Emergency manual override",
            "Manual hash override",
            "submitQueryHashCandidate",
        ):
            self.assertNotIn(banned, source)

    def test_manifest_has_only_the_required_surface(self) -> None:
        manifest = json.loads((RESOURCES / "manifest.json").read_text())

        self.assertEqual(manifest["manifest_version"], 3)
        self.assertEqual(manifest["permissions"], ["nativeMessaging"])
        # Drops pages carry ViewerDropsDashboard and Inventory; the category directory
        # carries DirectoryPage_Game, which TDM has rotated more often than every other
        # operation combined. Anything wider would mean the whole of twitch.tv.
        self.assertEqual(
            manifest["host_permissions"],
            ["https://www.twitch.tv/drops/*", "https://www.twitch.tv/directory/*"],
        )
        self.assertEqual(
            manifest["action"]["default_popup"],
            "popup.html",
        )
        self.assertEqual(
            manifest["content_scripts"][0]["matches"],
            ["https://www.twitch.tv/drops/*", "https://www.twitch.tv/directory/*"],
        )

    def test_operation_allow_lists_match_the_core_catalog(self) -> None:
        core = CORE_HASHES.read_text()
        query_catalog = core.split("public enum GQLQuery", 1)[1].split(
            "/// Immutable fallbacks", 1
        )[0]
        expected = set(re.findall(r'case \w+ = "([^"]+)"', query_catalog))
        self.assertEqual(len(expected), 12)

        # content.js is absent by design: it accepts only the operation the current queue
        # item is waiting for, which is narrower than any list it could hold.
        for path in [
            RESOURCES / "page-hook.js",
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

    def test_background_is_a_stateless_relay(self) -> None:
        """Every hash is forwarded, and nothing is remembered between them.

        The old worker de-duplicated because it watched Twitch continuously. A session
        sends each operation once, deliberately, so suppressing a repeat would mean losing
        a hash the queue is actively waiting on.
        """
        harness = r'''
const fs = require("fs");
let listener;
const sent = [];
global.browser = { runtime: {
  onMessage: { addListener: value => { listener = value; } },
  sendNativeMessage: (host, payload) => { sent.push(payload); return Promise.resolve({ accepted: true }); }
} };
eval(fs.readFileSync(process.argv[1], "utf8"));
const hash = { type: "swiftminer:hash", operationName: "ViewerDropsDashboard", sha256Hash: "a".repeat(64) };
(async () => {
  await listener(hash);
  await listener(hash);
  await listener({ type: "swiftminer:hash", operationName: "NotAnOperation", sha256Hash: "a".repeat(64) });
  await listener({ type: "swiftminer:hash", operationName: "Inventory", sha256Hash: "nope" });
  await listener({ type: "swiftminer:done", results: [
    { operation: "ViewerDropsDashboard", ok: true },
    { operation: "Inventory", ok: false }
  ] });
  console.log(JSON.stringify(sent));
})().catch(error => { console.error(error); process.exit(1); });
'''
        result = subprocess.run(
            ["node", "-e", harness, str(RESOURCES / "background.js")],
            check=True,
            capture_output=True,
            text=True,
        )
        sent = json.loads(result.stdout)

        # Both repeats forwarded; neither the unknown operation nor the malformed hash was.
        self.assertEqual(len([m for m in sent if m["type"] == "queryHashCandidate"]), 2)

        finished = [m for m in sent if m["type"] == "queryHashSessionFinished"]
        self.assertEqual(len(finished), 1)
        self.assertEqual(finished[0]["succeeded"], ["ViewerDropsDashboard"])
        self.assertEqual(finished[0]["failed"], ["Inventory"])


if __name__ == "__main__":
    unittest.main()
