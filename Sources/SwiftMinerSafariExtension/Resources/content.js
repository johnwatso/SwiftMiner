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
  // Long enough for a cold Twitch page on a slow connection, short enough that a page
  // which no longer issues the operation cannot hang the run.
  const ITEM_TIMEOUT_MS = 20000;
  const COMPLETION_LINGER_MS = 4000;

  const readSession = () => {
    try {
      const raw = sessionStorage.getItem(SESSION_KEY);
      return raw ? JSON.parse(raw) : null;
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
      .filter(item => item && typeof item.operation === "string" && typeof item.page === "string")
      .map(item => ({ operation: item.operation, page: item.page, state: "pending", hash: null }));
    return items.length ? { items, index: 0 } : null;
  };

  const startedSession = sessionFromFragment();
  if (startedSession) {
    writeSession(startedSession);
    // Drop the fragment so a reload, a bookmark or a shared URL cannot restart the run.
    history.replaceState(null, "", location.pathname + location.search);
  }

  const session = startedSession || readSession();
  if (!session) return; // Normal browsing: nothing is injected and nothing is watched.

  // ---------------------------------------------------------------- progress banner

  const BANNER_ID = "swiftminer-update-banner";
  const ACCENT = "#a78bfa";

  const injectStyles = () => {
    if (document.getElementById("swiftminer-update-style")) return;
    const style = document.createElement("style");
    style.id = "swiftminer-update-style";
    style.textContent = `
      html { padding-top: 84px !important; }
      #${BANNER_ID} {
        position: fixed; top: 0; left: 0; right: 0; z-index: 2147483000;
        box-sizing: border-box; height: 84px; padding: 14px 22px;
        display: flex; align-items: center; gap: 18px;
        font: 13px/1.35 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
        color: #f4f3ff; background: #1a1725;
        border-bottom: 1px solid rgba(167,139,250,0.28);
        box-shadow: 0 1px 12px rgba(0,0,0,0.35);
      }
      #${BANNER_ID} .sm-mark {
        width: 32px; height: 32px; flex: 0 0 32px; border-radius: 8px;
        display: flex; align-items: center; justify-content: center;
        overflow: hidden;
      }
      #${BANNER_ID} .sm-mark img { width: 100%; height: 100%; display: block; }
      /* Only ever seen if the icon fails to load; keeps the row from collapsing. */
      #${BANNER_ID} .sm-mark.sm-glyph {
        background: linear-gradient(160deg, ${ACCENT}, #7c5cd6);
        font-weight: 700; font-size: 16px; color: #fff;
      }
      #${BANNER_ID} .sm-state {
        flex: 0 0 auto; width: 18px; height: 18px; margin-left: 2px;
        display: none; align-items: center; justify-content: center;
        border-radius: 50%; font-size: 11px; font-weight: 700; color: #12101a;
      }
      #${BANNER_ID}.sm-done .sm-state,
      #${BANNER_ID}.sm-issues .sm-state { display: flex; }
      #${BANNER_ID}.sm-done .sm-state { background: #34d399; }
      #${BANNER_ID}.sm-issues .sm-state { background: #fbbf24; }
      #${BANNER_ID} .sm-body { flex: 1 1 auto; min-width: 0; }
      #${BANNER_ID} .sm-title { font-weight: 600; font-size: 13px; letter-spacing: 0.1px; }
      #${BANNER_ID} .sm-sub {
        margin-top: 3px; font-size: 11.5px; color: #b9b4cc;
        white-space: nowrap; overflow: hidden; text-overflow: ellipsis;
      }
      #${BANNER_ID} .sm-track {
        margin-top: 8px; height: 4px; border-radius: 2px;
        background: rgba(255,255,255,0.12); overflow: hidden;
      }
      #${BANNER_ID} .sm-fill {
        height: 100%; width: 0%; border-radius: 2px; background: ${ACCENT};
        transition: width 240ms ease;
      }
      #${BANNER_ID} .sm-count {
        flex: 0 0 auto; font-variant-numeric: tabular-nums;
        font-size: 12px; color: #b9b4cc;
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
    banner.innerHTML =
      '<div class="sm-mark"></div>' +
      '<div class="sm-body">' +
      '<div class="sm-title">SwiftMiner</div>' +
      '<div class="sm-sub"></div>' +
      '<div class="sm-track"><div class="sm-fill"></div></div>' +
      "</div>" +
      '<div class="sm-state"></div>' +
      '<div class="sm-count"></div>';

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
    banner.querySelector(".sm-title").textContent = "Updating hashes via Safari";
    banner.querySelector(".sm-sub").textContent = current
      ? `Current operation: ${current.operation}`
      : "Finishing up";
    banner.querySelector(".sm-fill").style.width = `${Math.round((done / total) * 100)}%`;
    banner.querySelector(".sm-count").textContent = `${done} of ${total}`;
  };

  const renderCompletion = () => {
    const banner = ensureBanner();
    const total = session.items.length;
    const updated = session.items.filter(item => item.state === "ok").length;
    const clean = updated === total;
    banner.classList.add(clean ? "sm-done" : "sm-issues");
    banner.querySelector(".sm-state").textContent = clean ? "✓" : "!";
    banner.querySelector(".sm-title").textContent = clean
      ? "SwiftMiner is up to date"
      : "Update completed with issues";
    banner.querySelector(".sm-sub").textContent = clean
      ? `${updated} ${updated === 1 ? "hash" : "hashes"} updated`
      : `${updated} of ${total} hashes updated`;
    banner.querySelector(".sm-fill").style.width = "100%";
    banner.querySelector(".sm-count").textContent = "";
  };

  const removeBanner = () => {
    const banner = document.getElementById(BANNER_ID);
    if (banner) banner.remove();
    const style = document.getElementById("swiftminer-update-style");
    if (style) style.remove();
    document.documentElement.style.paddingTop = "";
  };

  // ---------------------------------------------------------------- observation

  const injectPageHook = () => {
    const parent = document.documentElement || document.head;
    if (!parent) return;
    const script = document.createElement("script");
    script.src = browser.runtime.getURL("page-hook.js");
    script.onload = () => script.remove();
    parent.appendChild(script);
  };

  let awaiting = null;

  window.addEventListener("message", event => {
    const value = event.data;
    if (event.source !== window || event.origin !== "https://www.twitch.tv") return;
    if (!value || value.source !== "swiftminer-query-hash" || value.version !== 1) return;
    if (!HASH_PATTERN.test(value.sha256Hash)) return;
    if (!awaiting || value.operationName !== awaiting.operation) return;
    awaiting.resolve(value.sha256Hash);
  });

  const waitForOperation = operation => new Promise(resolve => {
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

  const send = message => browser.runtime.sendMessage(message).catch(() => {});

  // ---------------------------------------------------------------- queue

  const samePage = page => location.pathname === new URL(page, location.origin).pathname;

  const run = async () => {
    injectPageHook();
    renderProgress();

    while (session.index < session.items.length) {
      const item = session.items[session.index];

      if (!samePage(item.page)) {
        // One tab, navigated in place. The session resumes from sessionStorage on load.
        writeSession(session);
        location.assign(new URL(item.page, location.origin).toString());
        return;
      }

      renderProgress();
      const hash = await waitForOperation(item.operation);
      if (hash) {
        item.state = "ok";
        item.hash = hash;
        await send({ type: "swiftminer:hash", operationName: item.operation, sha256Hash: hash });
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

  if (document.body) {
    start();
  } else {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  }
})();
