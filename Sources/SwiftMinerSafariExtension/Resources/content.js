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

  window.addEventListener("message", event => {
    const value = event.data;
    if (event.source !== window || event.origin !== "https://www.twitch.tv") return;
    if (!value || value.source !== "swiftminer-query-hash" || value.version !== 1) return;
    if (!allowedOperations.has(value.operationName)) return;
    if (!hashPattern.test(value.sha256Hash)) return;

    browser.runtime.sendMessage({
      type: "queryHashCandidate",
      operationName: value.operationName,
      sha256Hash: value.sha256Hash
    }).catch(() => {});
  });

  const inject = () => {
    const parent = document.documentElement || document.head;
    if (!parent) {
      setTimeout(inject, 0);
      return;
    }
    const script = document.createElement("script");
    script.src = browser.runtime.getURL("page-hook.js");
    script.onload = () => script.remove();
    parent.appendChild(script);
  };

  inject();
})();
