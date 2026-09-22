#!/usr/bin/env python3
"""Structural and behavioral privacy tests for the Safari hash observer."""

from __future__ import annotations

import json
import plistlib
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
DEBUG_BRIDGE = ROOT / "Sources" / "SwiftMiner" / "SafariQueryHashDebugBridge.swift"
APP_INFO = ROOT / "Sources" / "SwiftMiner" / "Info.plist"
EXTENSION_INFO = ROOT / "Sources" / "SwiftMinerSafariExtension" / "Info.plist"


def allowed_operations(source: str) -> set[str]:
    start = source.index("allowedOperations")
    end = source.index("]", start)
    return set(re.findall(r'"([A-Za-z][A-Za-z0-9_]+)"', source[start:end]))


class SafariQueryHashExtensionTests(unittest.TestCase):
    def test_safari_converter_metadata_belongs_to_the_containing_app(self) -> None:
        with APP_INFO.open("rb") as file:
            app_info = plistlib.load(file)
        with EXTENSION_INFO.open("rb") as file:
            extension_info = plistlib.load(file)

        self.assertEqual(app_info["SFSafariWebExtensionConverterVersion"], "27.0")
        self.assertNotIn("SFSafariWebExtensionConverterVersion", extension_info)

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

    def test_release_uses_unprovisioned_macos_app_group_consistently(self) -> None:
        """ShipHook's manual Developer ID archive has no provisioning profiles."""
        expected_group = "FHXMYC956U.com.swiftminer.shared"
        entitlement_paths = [
            ROOT / "Sources" / "SwiftMiner" / "SwiftMinerRelease.entitlements",
            ROOT
            / "Sources"
            / "SwiftMinerSafariExtension"
            / "SwiftMinerSafariExtension.entitlements",
        ]

        for path in entitlement_paths:
            with path.open("rb") as file:
                entitlements = plistlib.load(file)
            self.assertEqual(
                entitlements["com.apple.security.application-groups"],
                [expected_group],
            )

        self.assertIn(
            f'public static let suiteName = "{expected_group}"',
            CORE_HASHES.read_text(),
        )
        self.assertIn(
            f'private static let suiteName = "{expected_group}"',
            SWIFT_HANDLER.read_text(),
        )

    def test_check_action_targets_the_high_churn_twitch_pages(self) -> None:
        source = ADVANCED_SETTINGS.read_text()
        recovery = RECOVERY.read_text()

        self.assertIn('Button("Update via Safari\\u{2026}")', source)
        self.assertIn("startSafariUpdate()", source)
        self.assertIn("updates.startUpdate(", source)
        self.assertIn("TwitchCompatibilityRecovery.startUpdate(", recovery)

        # The queue covers each page that issues an operation SwiftMiner can refresh.
        self.assertIn('"/drops/campaigns"', recovery)
        self.assertIn('"/drops/inventory"', recovery)
        # DirectoryPage_Game only fires on a real category page, and it is the single
        # most-rotated operation in TDM's history.
        self.assertIn('"/directory/category/', recovery)
        # AvailableDrops is the other repeatedly rotated operation; Twitch issues it on
        # a Drops-enabled live channel page, not on either /drops page.
        self.assertIn("dropsHighlightServiceAvailableDrops", recovery)
        self.assertIn('page: "/\\(channelLogin)"', recovery)
        self.assertIn("TwitchDropsMinerQueryCatalog.fetch", recovery)
        self.assertIn('value["fallbackHash"] = fallbackHash', recovery)

        core = CORE_HASHES.read_text()
        frequent = (
            core.split("public static let frequentlyRotated", 1)[1]
            .split("= [", 1)[1]
            .split("]", 1)[0]
        )
        for query in (
            "directoryPageGame",
            "viewerDropsDashboard",
            "inventory",
            "dropsHighlightServiceAvailableDrops",
            "dropCampaignDetails",
        ):
            self.assertIn(f".{query}", frequent)

    def test_progress_is_shown_in_the_page_not_a_toolbar_popover(self) -> None:
        content = (RESOURCES / "content.js").read_text()
        popup = (RESOURCES / "popup.html").read_text()

        self.assertIn("swiftminer-update-banner", content)
        self.assertIn("Collecting Twitch query hashes", content)
        self.assertIn("backdrop-filter: blur(26px) saturate(175%)", content)
        self.assertIn("border-radius: 22px", content)
        self.assertIn("prefers-reduced-motion: reduce", content)
        self.assertNotIn("html { padding-top", content)

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

    def test_native_delivery_preserves_rejected_hash_safety_and_session_results(self) -> None:
        handler = SWIFT_HANDLER.read_text()
        rejected = 'defaults.string(forKey: "TwitchQueryHash.rejected.\\(operation)") == hash'
        candidate_write = 'defaults.set(hash, forKey: "TwitchQueryHash.candidate.\\(operation)")'

        # Release shares defaults directly with the app, so it must apply the same
        # no-requeue rule as TwitchQueryHashStore.recordObservation.
        self.assertIn(rejected, handler)
        self.assertLess(handler.index(rejected), handler.index(candidate_write))

        # Debug cannot use the signed App Group. Its notification bridge must still
        # persist the same completed-session summary that Release writes directly.
        bridge = DEBUG_BRIDGE.read_text()
        self.assertIn("sessionNotificationName", bridge)
        self.assertIn("recordSessionResult(", bridge)
        self.assertIn("latestSessionResult", ADVANCED_SETTINGS.read_text())

    def test_broken_query_report_does_not_start_safari_update(self) -> None:
        """A broken query may be reported, but only the user starts discovery.

        Twitch's own pages use sibling documents for some operations — a different query
        wearing the same operation name. Adopting one of those over a *working* hash is
        what replaced a healthy Drops inventory query with one that reported every claimed
        drop as unclaimed. Reporting a broken query must never open Safari or replace a hash.
        """
        recovery = RECOVERY.read_text()
        report = recovery.split("func reportBrokenQueries(", 1)[1].split("\n    }\n", 1)[0]

        self.assertIn("store.queriesNeedingRecovery()", report)
        self.assertIn("navigation.logEvent(", report)
        self.assertIn("choose Update via Safari", report)
        self.assertNotIn("startUpdate(", report)

    def test_advanced_settings_expose_no_manual_hash_entry(self) -> None:
        """The compatibility screen reports a comparison; it is not a hash editor.

        A field that accepts a pasted hash is the one way a user can put an unverified
        value into the store by hand; Safari observations must still be validated by
        SwiftMiner's normal request path. These are the strings that came back if it returned.
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
        self.assertEqual(manifest["permissions"], ["nativeMessaging", "scripting"])
        # AvailableDrops is one of TDM's five repeat rotators and only appears on channel
        # pages, so Safari must grant twitch.tv. content.js returns before installing its
        # page hook unless SwiftMiner's validated one-tab session is present.
        self.assertEqual(
            manifest["host_permissions"],
            ["https://www.twitch.tv/*"],
        )
        self.assertEqual(
            manifest["action"]["default_popup"],
            "popup.html",
        )
        [coordinator] = manifest["content_scripts"]
        self.assertEqual(coordinator["matches"], ["https://www.twitch.tv/*"])
        self.assertEqual(coordinator["js"], ["content.js"])
        self.assertEqual(coordinator["run_at"], "document_start")

        # The fetch observer is injected by Safari itself. Exposing it as a page-loadable
        # resource lets Twitch's CSP block it and makes the Debug extension look active
        # while silently missing every startup request.
        web_resources = manifest["web_accessible_resources"][0]["resources"]
        self.assertNotIn("page-hook.js", web_resources)

    def test_page_hook_starts_before_dom_ready_and_buffers_parallel_requests(self) -> None:
        content = (RESOURCES / "content.js").read_text()
        background = (RESOURCES / "background.js").read_text()

        # Twitch's startup requests can precede DOMContentLoaded. The document_start
        # coordinator registers the observer in the page's main world and primes it with
        # one reload. A script element is blocked by CSP, and one-off execution is too late.
        self.assertIn('type: "swiftminer:install-page-hook"', content)
        self.assertLess(content.index("const pageHookReady"), content.index("if (document.body)"))
        self.assertIn("registerContentScripts", background)
        self.assertIn('js: ["page-hook.js"]', background)
        self.assertIn('runAt: "document_start"', background)
        self.assertIn('world: "MAIN"', background)
        self.assertIn("location.reload()", content)
        self.assertNotIn("injectPageHook", content)

        # ViewerDropsDashboard and DropCampaignDetails are dispatched together on the
        # campaigns page. Seeing the second before the queue awaits it must not lose it.
        self.assertIn("const observedHashes = new Map();", content)
        self.assertIn("observedHashes.set(value.operationName, value.sha256Hash)", content)
        self.assertIn("const observed = observedHashFor(operation)", content)
        self.assertIn("swiftminer.update.observed.${operation}", content)
        self.assertIn(
            'new Set(["Inventory", "DropCampaignDetails"])',
            content,
        )
        self.assertIn("item.fallbackHash", content)
        self.assertIn("if (!samePage(item.page) && !retainedHash)", content)
        self.assertIn("const hash = retainedHash || await waitForOperation(item.operation)", content)
        self.assertIn("Waiting up to ${ITEM_TIMEOUT_MS / 1000}s", content)
        self.assertIn('Not issued by Twitch: ${missed.join(", ")}', content)

        # A Twitch page cannot forge a stored session that leaves twitch.tv or asks the
        # page hook to forward operations outside the five recovery targets.
        self.assertIn("url.origin !== location.origin", content)
        self.assertIn("ALLOWED_OPERATIONS.has(item.operation)", content)

        harness = r'''
const fs = require("fs");
const nativeSetTimeout = global.setTimeout;
const sent = [];
const listeners = {};
const hashes = {
  ViewerDropsDashboard: "a".repeat(64),
  DropCampaignDetails: "b".repeat(64)
};
const queue = Object.keys(hashes).map(operation => ({
  operation,
  page: "/drops/campaigns"
}));
queue.push({
  operation: "Inventory",
  page: "/drops/inventory",
  fallbackHash: "c".repeat(64)
});

global.window = global;
global.location = {
  origin: "https://www.twitch.tv",
  pathname: "/drops/campaigns",
  search: "",
  hash: "",
  assign: () => { throw new Error("unexpected navigation"); },
  reload: () => { throw new Error("unexpected reload"); }
};
global.history = { replaceState: () => { location.hash = ""; } };
global.sessionStorage = {
  values: new Map([["swiftminer.update.session", JSON.stringify({
    items: queue.map(item => ({ ...item, state: "pending", hash: null })),
    index: 0,
    hookPrimed: true
  })]]),
  getItem(key) { return this.values.get(key) || null; },
  setItem(key, value) { this.values.set(key, value); },
  removeItem(key) { this.values.delete(key); }
};
global.setTimeout = (fn, delay) => nativeSetTimeout(fn, delay === 4000 ? 0 : delay);
global.clearTimeout = clearTimeout;
global.addEventListener = (name, listener) => { listeners[name] = listener; };

const makeElement = tag => {
  const children = new Map();
  return {
    tagName: tag.toUpperCase(),
    style: {},
    classList: { add() {}, remove() {} },
    appendChild() {},
    remove() {},
    setAttribute() {},
    querySelector(selector) {
      if (!children.has(selector)) children.set(selector, makeElement("div"));
      return children.get(selector);
    }
  };
};
const elements = new Map();
global.document = {
  documentElement: makeElement("html"),
  head: makeElement("head"),
  body: makeElement("body"),
  createElement: makeElement,
  getElementById: id => elements.get(id) || null,
  addEventListener() {}
};
const originalCreate = document.createElement;
document.createElement = tag => {
  const element = originalCreate(tag);
  Object.defineProperty(element, "id", {
    set(value) { this._id = value; elements.set(value, this); },
    get() { return this._id; }
  });
  return element;
};
global.browser = { runtime: {
  getURL: value => `extension://${value}`,
  sendMessage: value => {
    if (value.type !== "swiftminer:install-page-hook") sent.push(value);
    return Promise.resolve(value.type === "swiftminer:install-page-hook"
      ? { registered: true }
      : { accepted: true });
  }
} };

eval(fs.readFileSync(process.argv[1], "utf8"));
for (const [operationName, sha256Hash] of Object.entries(hashes)) {
  listeners.message({
    source: global,
    origin: "https://www.twitch.tv",
    data: { source: "swiftminer-query-hash", version: 1, operationName, sha256Hash }
  });
}
nativeSetTimeout(() => {
  console.log(JSON.stringify(sent));
}, 25);
'''
        result = subprocess.run(
            ["node", "-e", harness, str(RESOURCES / "content.js")],
            check=True,
            capture_output=True,
            text=True,
        )
        sent = json.loads(result.stdout)
        candidates = [message for message in sent if message["type"] == "swiftminer:hash"]
        self.assertEqual(
            [(message["operationName"], message["sha256Hash"]) for message in candidates],
            [
                ("ViewerDropsDashboard", "a" * 64),
                ("DropCampaignDetails", "b" * 64),
                ("Inventory", "c" * 64),
            ],
        )

    def test_operation_allow_lists_match_the_core_catalog(self) -> None:
        core = CORE_HASHES.read_text()
        query_catalog = core.split("public enum GQLQuery", 1)[1].split(
            "/// Immutable fallbacks", 1
        )[0]
        expected = set(re.findall(r'case \w+ = "([^"]+)"', query_catalog))
        self.assertEqual(len(expected), 12)

        # content.js is absent by design: its recovery-session allow-list is the five
        # high-churn operations, while these relays accept the complete query catalog.
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
global.location = {
  href: "https://www.twitch.tv/drops/campaigns#swiftminer-update=test",
  hash: "#swiftminer-update=test"
};
global.sessionStorage = {
  values: new Map(),
  getItem(key) { return this.values.get(key) || null; },
  setItem(key, value) { this.values.set(key, value); }
};
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
window.fetch("https://gql.twitch.tv/gql", {
  method: "POST",
  body: JSON.stringify({
    operationName: "Inventory",
    variables: { fetchRewardCampaigns: true, oauthToken: "sibling-must-never-leave-page" },
    extensions: { persistedQuery: { sha256Hash: "d".repeat(64) } }
  })
});
window.fetch("https://gql.twitch.tv/gql", {
  method: "POST",
  body: JSON.stringify({
    operationName: "Inventory",
    variables: { fetchRewardCampaigns: false, oauthToken: "must-stay-in-page" },
    extensions: { persistedQuery: { sha256Hash: "e".repeat(64) } }
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
                },
                {
                    "source": "swiftminer-query-hash",
                    "version": 1,
                    "operationName": "Inventory",
                    "sha256Hash": "e" * 64,
                },
            ],
        )
        self.assertNotIn("must-never-leave-page", result.stdout)
        self.assertNotIn("sibling-must-never-leave-page", result.stdout)
        self.assertNotIn("must-stay-in-page", result.stdout)

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
const registrations = [];
global.browser = { runtime: {
  onMessage: { addListener: value => { listener = value; } },
  sendNativeMessage: (host, payload) => { sent.push(payload); return Promise.resolve({ accepted: true }); }
}, scripting: {
  getRegisteredContentScripts: () => Promise.resolve([]),
  registerContentScripts: options => { registrations.push(...options); return Promise.resolve(); },
  updateContentScripts: () => Promise.resolve()
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
  await listener({ type: "swiftminer:install-page-hook" }, { tab: { id: 42 } });
  console.log(JSON.stringify({ sent, registrations }));
})().catch(error => { console.error(error); process.exit(1); });
'''
        result = subprocess.run(
            ["node", "-e", harness, str(RESOURCES / "background.js")],
            check=True,
            capture_output=True,
            text=True,
        )
        output = json.loads(result.stdout)
        sent = output["sent"]

        # Both repeats forwarded; neither the unknown operation nor the malformed hash was.
        self.assertEqual(len([m for m in sent if m["type"] == "queryHashCandidate"]), 2)

        finished = [m for m in sent if m["type"] == "queryHashSessionFinished"]
        self.assertEqual(len(finished), 1)
        self.assertEqual(finished[0]["succeeded"], ["ViewerDropsDashboard"])
        self.assertEqual(finished[0]["failed"], ["Inventory"])

        self.assertEqual(
            output["registrations"],
            [
                {
                    "id": "swiftminer-query-hash-page-hook",
                    "matches": ["https://www.twitch.tv/*"],
                    "js": ["page-hook.js"],
                    "runAt": "document_start",
                    "world": "MAIN",
                }
            ],
        )


if __name__ == "__main__":
    unittest.main()
