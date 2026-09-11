(() => {
  "use strict";

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
  const hashPattern = /^[0-9a-f]{64}$/;
  const lastSent = new Map();

  browser.runtime.onMessage.addListener(message => {
    if (!message || message.type !== "queryHashCandidate") return;
    if (!allowedOperations.has(message.operationName)) return;
    if (!hashPattern.test(message.sha256Hash)) return;
    if (lastSent.get(message.operationName) === message.sha256Hash) return;
    lastSent.set(message.operationName, message.sha256Hash);

    return browser.runtime.sendNativeMessage("com.swiftminer.app.SafariQueryHash", {
      type: "queryHashCandidate",
      operationName: message.operationName,
      sha256Hash: message.sha256Hash
    }).then(response => {
      // Discovery may be off in SwiftMiner when Safari first sees this hash.
      // Do not suppress it permanently unless the native store accepted it.
      if (!response || response.accepted !== true) {
        lastSent.delete(message.operationName);
      }
    }).catch(() => {
      lastSent.delete(message.operationName);
    });
  });
})();
