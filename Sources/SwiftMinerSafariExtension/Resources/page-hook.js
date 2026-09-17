(() => {
  "use strict";

  const SESSION_KEY = "swiftminer.update.session";
  const FRAGMENT = "#swiftminer-update=";
  // Safari registers this script ahead of time so it can run before Twitch's page code,
  // but normal Twitch browsing remains completely inert.
  let sessionActive = location.hash.startsWith(FRAGMENT);
  if (!sessionActive) {
    try {
      sessionActive = sessionStorage.getItem(SESSION_KEY) !== null;
    } catch (_) {}
  }
  if (!sessionActive) return;

  if (window.__swiftMinerQueryHashHookInstalled) return;
  Object.defineProperty(window, "__swiftMinerQueryHashHookInstalled", { value: true });

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

  // Twitch sometimes reuses an operation name for more than one persisted document.
  // SwiftMiner's Inventory request is the drops-progress document; the sibling document
  // asks Twitch to include reward campaigns and is not compatible even though it has the
  // same operationName. Inspect this one non-sensitive discriminator in the page world,
  // but continue forwarding only the operation/hash pair across the privacy boundary.
  const matchesSwiftMinerDocument = request => {
    if (request && request.operationName === "Inventory") {
      return request.variables && request.variables.fetchRewardCampaigns === false;
    }
    return true;
  };

  const isTwitchGQL = value => {
    try {
      const url = new URL(value, location.href);
      return url.protocol === "https:" && url.hostname === "gql.twitch.tv" && url.pathname === "/gql";
    } catch (_) {
      return false;
    }
  };

  const inspectBody = body => {
    if (typeof body !== "string") return;
    let value;
    try {
      value = JSON.parse(body);
    } catch (_) {
      return;
    }

    const requests = Array.isArray(value) ? value : [value];
    for (const request of requests) {
      const operationName = request && request.operationName;
      const sha256Hash = request && request.extensions &&
        request.extensions.persistedQuery &&
        request.extensions.persistedQuery.sha256Hash;
      if (!allowedOperations.has(operationName) ||
          !hashPattern.test(sha256Hash) ||
          !matchesSwiftMinerDocument(request)) continue;
      // Retaining only the allow-listed operation/hash pair closes the tiny startup race
      // where the main-world hook can observe a request before the isolated coordinator
      // has attached its message listener.
      try {
        sessionStorage.setItem(`swiftminer.update.observed.${operationName}`, sha256Hash);
      } catch (_) {}
      window.postMessage({
        source: "swiftminer-query-hash",
        version: 1,
        operationName,
        sha256Hash
      }, "https://www.twitch.tv");
    }
  };

  const originalFetch = window.fetch;
  window.fetch = function(input, init) {
    const url = typeof input === "string" || input instanceof URL ? String(input) : input && input.url;
    const method = (init && init.method) || (input && input.method) || "GET";
    if (method.toUpperCase() === "POST" && isTwitchGQL(url)) {
      if (init && typeof init.body === "string") {
        inspectBody(init.body);
      } else if (input instanceof Request) {
        input.clone().text().then(inspectBody).catch(() => {});
      }
    }
    return originalFetch.apply(this, arguments);
  };

  const requestMetadata = new WeakMap();
  const originalOpen = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function(method, url) {
    requestMetadata.set(this, { method: String(method), url: String(url) });
    return originalOpen.apply(this, arguments);
  };

  const originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.send = function(body) {
    const metadata = requestMetadata.get(this);
    if (metadata && metadata.method.toUpperCase() === "POST" && isTwitchGQL(metadata.url)) {
      inspectBody(body);
    }
    return originalSend.apply(this, arguments);
  };
})();
