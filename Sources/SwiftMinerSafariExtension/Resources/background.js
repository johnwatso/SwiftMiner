// Relay between the Twitch content script and SwiftMiner.
//
// Safari does not let a content script talk to the containing app directly, so this is the
// only layer that speaks native messaging. It holds no state and watches nothing: it exists
// solely to forward what an active SwiftMiner update session has already found.
(() => {
  "use strict";

  const NATIVE_HOST = "com.swiftminer.app.SafariQueryHash";
  const HASH_PATTERN = /^[0-9a-f]{64}$/;
  const allowedOperations = new Set([
    "DirectoryGameRedirect",
    "ViewerDropsDashboard",
    "DropCampaignDetails",
    "Inventory",
    "DropsPage_ClaimDropRewards",
    "PlaybackAccessToken",
    "DirectoryPage_Game",
    "VideoPlayerStreamInfoOverlayChannel",
    "DropCurrentSessionContext",
    "DropsHighlightService_AvailableDrops",
    "ChannelPointsContext",
    "ClaimCommunityPoints"
  ]);

  const toNative = payload =>
    browser.runtime.sendNativeMessage(NATIVE_HOST, payload).catch(() => undefined);

  browser.runtime.onMessage.addListener(message => {
    if (!message) return;

    if (message.type === "swiftminer:hash") {
      // Re-validated here even though the content script already checked: this is the last
      // point before the value leaves the browser, and it is the only thing that does.
      if (!allowedOperations.has(message.operationName)) return;
      if (!HASH_PATTERN.test(message.sha256Hash)) return;
      return toNative({
        type: "queryHashCandidate",
        operationName: message.operationName,
        sha256Hash: message.sha256Hash
      });
    }

    if (message.type === "swiftminer:done") {
      const results = Array.isArray(message.results) ? message.results : [];
      return toNative({
        type: "queryHashSessionFinished",
        succeeded: results.filter(r => r && r.ok === true).map(r => r.operation),
        failed: results.filter(r => r && r.ok !== true).map(r => r.operation)
      });
    }
  });
})();
