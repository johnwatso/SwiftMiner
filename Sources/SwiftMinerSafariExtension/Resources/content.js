// SwiftMiner query-hash update driver.
//
// Inert during normal browsing. The extension does nothing at all unless SwiftMiner has
// explicitly asked for an update, and it asks by opening one Twitch tab whose URL fragment
// carries the queue. Everything after that runs inside this single tab: the session lives
// in sessionStorage, so it survives each navigation, dies with the tab, and can never leak
// into another tab or another browsing session.
(() => {
  "use strict";

  const SESSION_KEY = "swiftminer.update.session";
  const FRAGMENT = "#swiftminer-update=";
  const HASH_PATTERN = /^[0-9a-f]{64}$/;
  const ALLOWED_OPERATIONS = new Set([
    "DirectoryPage_Game",
    "ViewerDropsDashboard",
    "Inventory",
    "DropsHighlightService_AvailableDrops",
    "DropCampaignDetails"
  ]);
  // Long enough for a cold Twitch page on a slow connection, short enough that a page
  // which no longer issues the operation cannot hang the run.
  const ITEM_TIMEOUT_MS = 20000;
  const COMPLETION_LINGER_MS = 4000;
  const OPERATION_LABELS = {
    DirectoryPage_Game: "game directory",
    ViewerDropsDashboard: "Drops dashboard",
    Inventory: "Drops inventory",
    DropsHighlightService_AvailableDrops: "channel Drops",
    DropCampaignDetails: "campaign details"
  };
  // These client documents cannot be reproduced by passively loading Twitch pages:
  // Inventory is a same-name sibling there, while campaign details require an explicit
  // user click. Prefer the TDM catalog value SwiftMiner placed in the session for them.
  const FALLBACK_FIRST_OPERATIONS = new Set(["Inventory", "DropCampaignDetails"]);

  const allowedPage = (operation, page) => {
    if (typeof page !== "string") return false;
    try {
      const url = new URL(page, location.origin);
      if (url.origin !== location.origin || url.search || url.hash) return false;
      switch (operation) {
        case "ViewerDropsDashboard":
        case "DropCampaignDetails":
          return /^\/drops\/campaigns\/?$/.test(url.pathname);
        case "Inventory":
          return /^\/drops\/inventory\/?$/.test(url.pathname);
        case "DirectoryPage_Game":
          return /^\/directory\/category\/[a-z0-9_-]+\/?$/.test(url.pathname);
        case "DropsHighlightService_AvailableDrops":
          return /^\/[a-z0-9_]+\/?$/.test(url.pathname);
        default:
          return false;
      }
    } catch (_) {
      return false;
    }
  };

  // Twitch owns this origin's sessionStorage, so every resume is validated just as
  // strictly as the app-created fragment. A page cannot turn the queue into a redirect.
  const normalizedSession = value => {
    if (!value || !Array.isArray(value.items) || value.items.length === 0) return null;
    const items = value.items
      .filter(item => item && ALLOWED_OPERATIONS.has(item.operation) &&
        allowedPage(item.operation, item.page))
      .map(item => ({
        operation: item.operation,
        page: new URL(item.page, location.origin).pathname,
        state: item.state === "ok" || item.state === "failed" ? item.state : "pending",
        hash: HASH_PATTERN.test(item.hash) ? item.hash : null,
        fallbackHash: HASH_PATTERN.test(item.fallbackHash) ? item.fallbackHash : null
      }));
    if (!items.length) return null;
    const index = Number.isInteger(value.index)
      ? Math.max(0, Math.min(value.index, items.length))
      : 0;
    return { items, index, hookPrimed: value.hookPrimed === true };
  };

  const readSession = () => {
    try {
      const raw = sessionStorage.getItem(SESSION_KEY);
      return raw ? normalizedSession(JSON.parse(raw)) : null;
    } catch (_) {
      return null;
    }
  };

  const writeSession = session => {
    try {
      sessionStorage.setItem(SESSION_KEY, JSON.stringify(session));
    } catch (_) {
      /* A session we cannot persist simply ends at this page. */
    }
  };

  const clearSession = () => {
    try {
      sessionStorage.removeItem(SESSION_KEY);
      for (const item of session.items) {
        sessionStorage.removeItem(`swiftminer.update.observed.${item.operation}`);
      }
    } catch (_) {}
  };

  /// A session SwiftMiner has just requested, or null.
  const sessionFromFragment = () => {
    if (!location.hash.startsWith(FRAGMENT)) return null;
    const encoded = location.hash.slice(FRAGMENT.length);
    let queue;
    try {
      queue = JSON.parse(atob(decodeURIComponent(encoded)));
    } catch (_) {
      return null;
    }
    if (!Array.isArray(queue) || queue.length === 0) return null;

    const items = queue
      .filter(item => item && ALLOWED_OPERATIONS.has(item.operation) &&
        allowedPage(item.operation, item.page))
      .map(item => ({
        operation: item.operation,
        page: item.page,
        state: "pending",
        hash: null,
        fallbackHash: HASH_PATTERN.test(item.fallbackHash) ? item.fallbackHash : null
      }));
    return normalizedSession({ items, index: 0, hookPrimed: false });
  };

  const startedSession = sessionFromFragment();
  if (startedSession) {
    writeSession(startedSession);
    // Drop the fragment so a reload, a bookmark or a shared URL cannot restart the run.
    history.replaceState(null, "", location.pathname + location.search);
  }

  const session = startedSession || readSession();
  if (!session) return; // Normal browsing: nothing is injected and nothing is watched.
  const requestedOperations = new Set(session.items.map(item => item.operation));

  // ---------------------------------------------------------------- progress banner

  const BANNER_ID = "swiftminer-update-banner";
  const ACCENT = "#a78bfa";

  const injectStyles = () => {
    if (document.getElementById("swiftminer-update-style")) return;
    const style = document.createElement("style");
    style.id = "swiftminer-update-style";
    style.textContent = `
      @keyframes sm-glass-enter {
        from { opacity: 0; transform: translate(-50%, -10px) scale(0.97); }
        to { opacity: 1; transform: translate(-50%, 0) scale(1); }
      }
      @keyframes sm-glass-pulse {
        0%, 100% { transform: scale(0.82); opacity: 0.35; }
        50% { transform: scale(1.35); opacity: 0; }
      }
      @keyframes sm-glass-shimmer {
        from { transform: translateX(-115%); }
        to { transform: translateX(320%); }
      }
      #${BANNER_ID} {
        all: initial;
        position: fixed; top: 18px; left: 50%; z-index: 2147483000;
        box-sizing: border-box; width: min(560px, calc(100vw - 32px));
        min-height: 94px; padding: 15px 17px;
        display: flex; align-items: center; gap: 15px;
        overflow: hidden; isolation: isolate; pointer-events: none;
        color: rgba(255,255,255,0.96);
        background:
          linear-gradient(135deg, rgba(33,29,49,0.84), rgba(20,18,31,0.72));
        border: 1px solid rgba(255,255,255,0.18);
        border-radius: 22px;
        box-shadow:
          0 20px 55px rgba(4,3,10,0.38),
          0 5px 16px rgba(4,3,10,0.24),
          inset 0 1px 0 rgba(255,255,255,0.16);
        -webkit-backdrop-filter: blur(26px) saturate(175%);
        backdrop-filter: blur(26px) saturate(175%);
        font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        animation: sm-glass-enter 360ms cubic-bezier(.2,.8,.2,1) both;
      }
      #${BANNER_ID}::before {
        content: ""; position: absolute; inset: 0; z-index: -1;
        background:
          radial-gradient(circle at 16% 0%, rgba(167,139,250,0.24), transparent 38%),
          radial-gradient(circle at 92% 115%, rgba(96,165,250,0.15), transparent 42%);
      }
      #${BANNER_ID}::after {
        content: ""; position: absolute; left: 18px; right: 18px; top: 0; height: 1px;
        background: linear-gradient(90deg, transparent, rgba(255,255,255,0.6), transparent);
      }
      #${BANNER_ID} .sm-mark-wrap {
        position: relative; width: 44px; height: 44px; flex: 0 0 44px;
      }
      #${BANNER_ID} .sm-mark {
        position: relative; z-index: 1; width: 44px; height: 44px; border-radius: 13px;
        display: flex; align-items: center; justify-content: center;
        overflow: hidden; background: rgba(255,255,255,0.08);
        box-shadow: 0 7px 20px rgba(0,0,0,0.28), inset 0 1px 0 rgba(255,255,255,0.2);
      }
      #${BANNER_ID} .sm-mark img { width: 100%; height: 100%; display: block; }
      #${BANNER_ID} .sm-mark.sm-glyph {
        background: linear-gradient(160deg, ${ACCENT}, #7c5cd6);
        font-weight: 700; font-size: 18px; color: #fff;
      }
      #${BANNER_ID} .sm-pulse {
        position: absolute; inset: -4px; border-radius: 17px;
        border: 1px solid rgba(167,139,250,0.6);
        animation: sm-glass-pulse 2.2s ease-out infinite;
      }
      #${BANNER_ID}.sm-done .sm-pulse,
      #${BANNER_ID}.sm-issues .sm-pulse { display: none; }
      #${BANNER_ID} .sm-body { flex: 1 1 auto; min-width: 0; }
      #${BANNER_ID} .sm-kicker {
        display: flex; align-items: center; gap: 6px; margin-bottom: 3px;
        color: rgba(224,217,255,0.7); font-size: 9px; line-height: 1;
        font-weight: 700; letter-spacing: 0.14em; text-transform: uppercase;
      }
      #${BANNER_ID} .sm-live {
        width: 6px; height: 6px; border-radius: 50%; background: ${ACCENT};
        box-shadow: 0 0 10px rgba(167,139,250,0.9);
      }
      #${BANNER_ID}.sm-done .sm-live { background: #52e2a5; box-shadow: 0 0 10px rgba(82,226,165,0.75); }
      #${BANNER_ID}.sm-issues .sm-live { background: #f8c66b; box-shadow: 0 0 10px rgba(248,198,107,0.75); }
      #${BANNER_ID} .sm-title {
        color: rgba(255,255,255,0.96); font-size: 14px; line-height: 1.25;
        font-weight: 650; letter-spacing: -0.01em;
      }
      #${BANNER_ID} .sm-sub {
        margin-top: 3px; color: rgba(229,226,240,0.68); font-size: 11.5px;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      }
      #${BANNER_ID} .sm-track {
        position: relative; margin-top: 9px; height: 4px; border-radius: 999px;
        background: rgba(255,255,255,0.1); overflow: hidden;
      }
      #${BANNER_ID} .sm-fill {
        position: relative; height: 100%; width: 0%; border-radius: inherit;
        background: linear-gradient(90deg, #8b6ee8, #b79cff 58%, #8ec5ff);
        box-shadow: 0 0 12px rgba(167,139,250,0.55);
        transition: width 420ms cubic-bezier(.2,.8,.2,1);
      }
      #${BANNER_ID}:not(.sm-done):not(.sm-issues) .sm-fill::after {
        content: ""; position: absolute; inset: 0; width: 34%;
        background: linear-gradient(90deg, transparent, rgba(255,255,255,0.72), transparent);
        animation: sm-glass-shimmer 1.8s ease-in-out infinite;
      }
      #${BANNER_ID} .sm-meta {
        flex: 0 0 auto; min-width: 54px; display: flex; align-items: center;
        justify-content: flex-end; gap: 8px;
      }
      #${BANNER_ID} .sm-state {
        width: 24px; height: 24px;
        display: none; align-items: center; justify-content: center;
        border-radius: 50%; font-size: 12px; font-weight: 800; color: #12101a;
      }
      #${BANNER_ID}.sm-done .sm-state,
      #${BANNER_ID}.sm-issues .sm-state { display: flex; }
      #${BANNER_ID}.sm-done .sm-state { background: #52e2a5; box-shadow: 0 0 18px rgba(82,226,165,0.3); }
      #${BANNER_ID}.sm-issues .sm-state { background: #f8c66b; box-shadow: 0 0 18px rgba(248,198,107,0.3); }
      #${BANNER_ID} .sm-count {
        color: rgba(229,226,240,0.7); font-size: 10px; font-weight: 650;
        letter-spacing: 0.05em; text-transform: uppercase; white-space: nowrap;
        font-variant-numeric: tabular-nums;
      }
      @media (max-width: 520px) {
        #${BANNER_ID} { top: 10px; width: calc(100vw - 20px); padding: 13px 14px; border-radius: 19px; }
        #${BANNER_ID} .sm-mark-wrap, #${BANNER_ID} .sm-mark { width: 40px; height: 40px; }
        #${BANNER_ID} .sm-mark-wrap { flex-basis: 40px; }
        #${BANNER_ID} .sm-meta { min-width: 42px; }
      }
      @media (prefers-reduced-motion: reduce) {
        #${BANNER_ID}, #${BANNER_ID} .sm-pulse, #${BANNER_ID} .sm-fill::after {
          animation: none !important;
        }
        #${BANNER_ID} .sm-fill { transition: none; }
      }
    `;
    (document.head || document.documentElement).appendChild(style);
  };

  const ensureBanner = () => {
    let banner = document.getElementById(BANNER_ID);
    if (banner) return banner;
    injectStyles();
    banner = document.createElement("div");
    banner.id = BANNER_ID;
    banner.setAttribute("role", "status");
    banner.setAttribute("aria-live", "polite");
    banner.innerHTML =
      '<div class="sm-mark-wrap"><div class="sm-mark"></div><span class="sm-pulse"></span></div>' +
      '<div class="sm-body">' +
      '<div class="sm-kicker"><span class="sm-live"></span><span class="sm-kicker-text">Secure local check</span></div>' +
      '<div class="sm-title">SwiftMiner</div>' +
      '<div class="sm-sub"></div>' +
      '<div class="sm-track"><div class="sm-fill"></div></div>' +
      "</div>" +
      '<div class="sm-meta"><div class="sm-state"></div><div class="sm-count"></div></div>';

    // The app icon ships with the extension, so this is a local load, not a network one.
    const mark = banner.querySelector(".sm-mark");
    const icon = document.createElement("img");
    icon.alt = "";
    icon.src = browser.runtime.getURL("swiftminer-icon.png");
    icon.onerror = () => {
      mark.classList.add("sm-glyph");
      mark.textContent = "S";
    };
    mark.appendChild(icon);

    (document.body || document.documentElement).appendChild(banner);
    return banner;
  };

  const renderProgress = () => {
    const banner = ensureBanner();
    const total = session.items.length;
    const done = session.items.filter(item => item.state !== "pending").length;
    const current = session.items[session.index];
    banner.querySelector(".sm-kicker-text").textContent = "Secure local check";
    banner.querySelector(".sm-title").textContent = "Collecting Twitch query hashes";
    banner.querySelector(".sm-sub").textContent = current
      ? `Waiting up to ${ITEM_TIMEOUT_MS / 1000}s for Twitch to issue ${OPERATION_LABELS[current.operation] || current.operation}`
      : "Handing the results back to SwiftMiner";
    const progress = Math.round(((done + (current ? 0.12 : 0)) / total) * 100);
    banner.querySelector(".sm-fill").style.width = `${Math.max(7, progress)}%`;
    banner.querySelector(".sm-count").textContent = current
      ? `${Math.min(session.index + 1, total)} / ${total}`
      : `${total} / ${total}`;
  };

  const renderCompletion = () => {
    const banner = ensureBanner();
    const total = session.items.length;
    const delivered = session.items.filter(item => item.state === "ok").length;
    const missed = session.items
      .filter(item => item.state !== "ok")
      .map(item => OPERATION_LABELS[item.operation] || item.operation);
    const clean = delivered === total;
    banner.classList.remove("sm-done", "sm-issues");
    banner.classList.add(clean ? "sm-done" : "sm-issues");
    banner.querySelector(".sm-kicker-text").textContent = clean ? "Collection complete" : "Collection finished";
    banner.querySelector(".sm-state").textContent = clean ? "✓" : "!";
    banner.querySelector(".sm-title").textContent = clean
      ? "Hash check complete"
      : "Hash check completed with issues";
    banner.querySelector(".sm-sub").textContent = clean
      ? `${delivered} ${delivered === 1 ? "hash" : "hashes"} sent to SwiftMiner for validation`
      : `Not issued by Twitch: ${missed.join(", ")} · ${delivered} of ${total} hashes sent`;
    banner.querySelector(".sm-fill").style.width = "100%";
    banner.querySelector(".sm-count").textContent = "";
  };

  const removeBanner = () => {
    const banner = document.getElementById(BANNER_ID);
    if (banner) banner.remove();
    const style = document.getElementById("swiftminer-update-style");
    if (style) style.remove();
  };

  // ---------------------------------------------------------------- observation

  // Twitch dispatches several startup requests together. Keep every requested hash seen
  // on this page so an operation is not lost merely because the queue was still waiting
  // for its neighbour when both requests fired.
  const observedHashes = new Map();
  let awaiting = null;

  window.addEventListener("message", event => {
    const value = event.data;
    if (event.source !== window || event.origin !== "https://www.twitch.tv") return;
    if (!value || value.source !== "swiftminer-query-hash" || value.version !== 1) return;
    if (!HASH_PATTERN.test(value.sha256Hash)) return;
    if (!requestedOperations.has(value.operationName)) return;
    observedHashes.set(value.operationName, value.sha256Hash);
    if (awaiting && value.operationName === awaiting.operation) {
      awaiting.resolve(value.sha256Hash);
    }
  });

  // Ask the background worker immediately, while this document_start content script is
  // still ahead of Twitch's application startup. Safari runs content scripts in an
  // isolated world, and Twitch's CSP rejects the older script-element bridge.
  const pageHookReady = browser.runtime.sendMessage({
    type: "swiftminer:install-page-hook"
  }).catch(() => undefined);

  const observedHashFor = operation => {
    let retained = null;
    try {
      retained = sessionStorage.getItem(`swiftminer.update.observed.${operation}`);
    } catch (_) {}
    return observedHashes.get(operation) ||
      (HASH_PATTERN.test(retained) ? retained : null);
  };

  const waitForOperation = operation => {
    const observed = observedHashFor(operation);
    if (observed) return Promise.resolve(observed);

    return new Promise(resolve => {
      const timer = setTimeout(() => {
        awaiting = null;
        resolve(null);
      }, ITEM_TIMEOUT_MS);
      awaiting = {
        operation,
        resolve: hash => {
          clearTimeout(timer);
          awaiting = null;
          resolve(hash);
        }
      };
    });
  };

  const send = message => browser.runtime.sendMessage(message)
    .catch(() => ({ accepted: false }));

  // ---------------------------------------------------------------- queue

  const samePage = page => location.pathname === new URL(page, location.origin).pathname;

  const run = async () => {
    renderProgress();

    while (session.index < session.items.length) {
      const item = session.items[session.index];
      const observedHash = observedHashFor(item.operation);
      const immediateFallback = FALLBACK_FIRST_OPERATIONS.has(item.operation)
        ? item.fallbackHash
        : null;
      const retainedHash = observedHash || immediateFallback;

      if (!samePage(item.page) && !retainedHash) {
        // One tab, navigated in place. The session resumes from sessionStorage on load.
        writeSession(session);
        location.assign(new URL(item.page, location.origin).toString());
        return;
      }

      renderProgress();
      // Twitch often dispatches several useful operations together. If the document-start
      // hook already buffered this one on the previous page, deliver it immediately instead
      // of loading another heavy Twitch route solely to observe the same request again.
      // Prefer a hash genuinely seen on Twitch. If the page cannot issue it, the exact
      // TDM operation/hash tuple carried by this SwiftMiner-created session prevents the
      // run from stalling or accepting an incompatible same-name document.
      const hash = retainedHash || await waitForOperation(item.operation) || item.fallbackHash;
      if (hash) {
        item.hash = hash;
        const response = await send({
          type: "swiftminer:hash",
          operationName: item.operation,
          sha256Hash: hash
        });
        item.state = response && response.accepted === true ? "ok" : "failed";
      } else {
        item.state = "failed";
      }

      session.index += 1;
      writeSession(session);
      renderProgress();
    }

    renderCompletion();
    await send({
      type: "swiftminer:done",
      results: session.items.map(item => ({
        operation: item.operation,
        ok: item.state === "ok"
      }))
    });
    clearSession();
    setTimeout(removeBanner, COMPLETION_LINGER_MS);
  };

  const start = () => { run().catch(() => { clearSession(); removeBanner(); }); };

  // The first document registers the early main-world script, then reloads once. From the
  // second document onward Safari injects that script before Twitch's application code.
  pageHookReady.then(() => {
    if (!session.hookPrimed) {
      session.hookPrimed = true;
      writeSession(session);
      location.reload();
      return;
    }
    if (document.body) {
      start();
    } else {
      document.addEventListener("DOMContentLoaded", start, { once: true });
    }
  }).catch(() => { clearSession(); removeBanner(); });
})();
