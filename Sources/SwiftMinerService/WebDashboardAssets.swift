import Foundation

/// Static markup for the dashboard. Kept tiny and dependency-free: a single
/// page that talks only to the session-scoped `/me/*` endpoints. Scripts are
/// served externally so the strict `Content-Security-Policy` (no inline JS)
/// holds.
enum WebDashboardAssets {
    /// Per-launch cache-buster appended to asset URLs. Cloudflare's edge caches
    /// static extensions (.js/.png) by default, so without a changing query the
    /// tunnel can keep serving an old dashboard script long after an update —
    /// which shows up as a stale "generic" page.
    static let assetVersion = String(Int(Date().timeIntervalSince1970))

    static let appHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1"><link rel="icon" type="image/png" href="/app/logo-dark.png?v=\(assetVersion)"><link rel="apple-touch-icon" href="/app/logo-dark.png?v=\(assetVersion)">
      <title>SwiftMiner</title>
      <style>
        :root {
          --bg-a: #0a0a0a; --bg-b: #121212; --bg-c: #1a1a1a;
          --text: rgba(255,255,255,0.94); --muted: rgba(255,255,255,0.62);
          --glass-top: rgba(255,255,255,0.08); --glass-bottom: rgba(255,255,255,0.03);
          --glass-stroke: rgba(255,255,255,0.10);
          --field: rgba(255,255,255,0.06); --field-stroke: rgba(255,255,255,0.12);
          --blue-a: #56bcff; --blue-b: #208cff; --blue-c: #1669dd;
          --green: #34c759; --orange: #ff9f0a;
        }
        * { box-sizing: border-box; }
        body {
          margin: 0; min-height: 100vh; padding: 0 16px 48px;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;
          font-size: 15px; color: var(--text);
          background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
          background-attachment: fixed;
        }
        .shell { max-width: 640px; margin: 0 auto; }
        header {
          display: flex; align-items: center; gap: 10px; padding: 18px 2px 14px;

        }
        header img { width: 34px; height: 34px; }
        header h1 { margin: 0; font-size: 19px; letter-spacing: -0.02em; }
        header .spacer { flex: 1; }
        .ghost {
          font: 600 13px/1 inherit; font-family: inherit; color: var(--text); cursor: pointer;
          padding: 9px 14px; border-radius: 11px; border: 1px solid var(--glass-stroke);
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
        }
        .card {
          background: rgba(25, 20, 40, 0.45);
          border: 1px solid rgba(255, 255, 255, 0.08); border-radius: 18px;
          box-shadow: 0 24px 64px rgba(0, 0, 0, 0.5), inset 0 1px 0 rgba(255, 255, 255, 0.1);
          backdrop-filter: blur(28px) saturate(1.6); -webkit-backdrop-filter: blur(28px) saturate(1.6);
          padding: 16px 18px; margin: 0 0 14px;
          animation: rise 0.4s cubic-bezier(0.21,1,0.27,1) both;
        }
        .miner-card {
          cursor: pointer;
          transition: transform 0.15s ease, border-color 0.15s ease, background 0.15s ease;
        }
        .miner-card:hover,
        .miner-card:focus-visible {
          transform: translateY(-1px);
          border-color: rgba(86, 188, 255, 0.36);
          background: rgba(34, 30, 54, 0.56);
          outline: none;
        }
        /* Entrance animation only on first paint — refreshes must not flicker. */
        body.loaded .card { animation: none; }
        @keyframes rise { from { opacity: 0; transform: translateY(10px); } }
        .row { display: flex; align-items: center; gap: 10px; }
        .label { color: var(--muted); font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; margin-bottom: 10px; }
        .muted { color: var(--muted); }
        .name { font-weight: 650; font-size: 17px; }
        .pill {
          font-size: 11px; font-weight: 650; letter-spacing: 0.02em; text-transform: uppercase;
          padding: 4px 10px; border-radius: 999px; margin-left: auto; white-space: nowrap;
        }
        .pill.active  { background: rgba(52,199,89,0.16); color: var(--green); border: 1px solid rgba(52,199,89,0.30); }
        .pill.idle    { background: rgba(255,255,255,0.10); color: var(--muted); border: 1px solid var(--glass-stroke); }
        .pill.blocked { background: rgba(255,159,10,0.16); color: var(--orange); border: 1px solid rgba(255,159,10,0.30); }
        .mining { display: flex; gap: 14px; align-items: stretch; }
        .boxart {
          width: 64px; height: 85px; flex: none; border-radius: 11px; object-fit: cover;
          border: 1px solid var(--glass-stroke); box-shadow: 0 8px 20px rgba(0,0,0,0.30);
          background: linear-gradient(135deg, var(--bg-c), var(--bg-b));
        }
        .mining .info { flex: 1; min-width: 0; display: flex; flex-direction: column; justify-content: center; }
        .game { font-size: 16px; font-weight: 650; }
        .bar { height: 9px; border-radius: 999px; background: rgba(127,127,127,0.18); overflow: hidden; margin: 9px 0 5px; }
        .bar > i { display: block; height: 100%; border-radius: 999px;
                   background: linear-gradient(90deg, var(--blue-a), var(--blue-b));
                   box-shadow: 0 0 12px rgba(86,188,255,0.55); transition: width 0.4s ease; }
        .meta { display: flex; justify-content: space-between; font-size: 12px; }
        .chips { display: flex; flex-wrap: wrap; gap: 8px; }
        .chip {
          display: inline-flex; align-items: center; gap: 6px; font-size: 13px; font-weight: 550;
          padding: 7px 12px; border-radius: 999px;
          background: var(--field); border: 1px solid var(--field-stroke);
        }
        .chip .n { font-size: 10px; font-weight: 700; color: #fff; width: 16px; height: 16px; border-radius: 5px;
                   display: inline-flex; align-items: center; justify-content: center;
                   background: linear-gradient(135deg, var(--blue-a), var(--blue-c)); }
        .plist { list-style: none; margin: 0; padding: 0; }
        .pitem {
          display: flex; align-items: center; gap: 9px; padding: 9px 10px; margin: 7px 0;
          border: 1px solid var(--glass-stroke); border-radius: 12px; background: var(--field);
        }
        .pitem .rank { width: 22px; height: 22px; flex: none; border-radius: 7px; font-size: 11px; font-weight: 700;
                       display: grid; place-items: center; color: #fff;
                       background: linear-gradient(135deg, var(--blue-a), var(--blue-c)); }
        .pitem .pname { font-weight: 550; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .icon-btn {
          width: 34px; height: 34px; flex: none; border-radius: 9px; cursor: pointer;
          font: 600 15px/1 inherit; font-family: inherit; color: var(--text);
          background: transparent; border: 1px solid var(--glass-stroke);
        }
        .icon-btn:disabled { opacity: 0.3; }
        .icon-btn.danger { color: #ff6b62; }
        .addrow { display: flex; gap: 9px; margin-top: 11px; }
        .addrow input {
          flex: 1; min-width: 0; font: 15px inherit; font-family: inherit; color: var(--text);
          padding: 11px 13px; border-radius: 12px; background: var(--field); border: 1px solid var(--field-stroke); outline: none;
        }
        .addrow input:focus { border-color: var(--blue-a); box-shadow: 0 0 0 3px rgba(86,188,255,0.18); }
        .btn-primary {
          font: 600 14px/1 inherit; font-family: inherit; color: #fff; cursor: pointer; border: none;
          padding: 0 18px; border-radius: 12px;
          background: linear-gradient(135deg, var(--blue-a), var(--blue-c));
          box-shadow: 0 8px 18px rgba(32,140,255,0.30);
        }
        .btn-secondary {
          font: 650 13px/1 inherit; font-family: inherit; color: var(--text); cursor: pointer;
          padding: 10px 13px; border-radius: 11px; border: 1px solid var(--glass-stroke);
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
        }
        .btn-secondary:disabled, .btn-primary:disabled { opacity: 0.45; cursor: default; }
        .detail-nav { margin: 0 0 14px; }
        .back-row { display: flex; align-items: center; gap: 10px; }
        .back-row .hero-info { min-width: 0; }
        .toggle-row {
          display: flex; align-items: center; justify-content: space-between; gap: 12px;
          margin: 0 0 12px; padding: 10px 12px; border: 1px solid var(--glass-stroke);
          border-radius: 8px; background: rgba(255,255,255,0.035);
        }
        .toggle-row .toggle-copy { min-width: 0; }
        .toggle-row .toggle-title { font-size: 13px; font-weight: 800; color: var(--text); }
        .toggle-row input { width: 18px; height: 18px; flex: 0 0 auto; accent-color: var(--blue-a); }
        .issue-row {
          display: flex; align-items: flex-start; gap: 10px; padding: 10px 0;
          border-top: 1px solid var(--glass-stroke);
        }
        .issue-row:first-of-type { border-top: none; padding-top: 0; }
        .issue-icon {
          flex: 0 0 auto; display: inline-flex; align-items: center; justify-content: center;
          width: 18px; height: 18px; border-radius: 50%; margin-top: 1px;
          background: rgba(255, 159, 10, 0.16); color: #ff9f0a;
          font-size: 12px; font-weight: 800; line-height: 1;
        }
        .issue-body { flex: 1; min-width: 0; font-size: 14px; line-height: 1.35; }
        .issue-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 9px; }
        .activation-code {
          display: inline-flex; align-items: center; justify-content: center;
          min-width: 136px; padding: 10px 14px; border-radius: 12px;
          font: 750 22px/1 ui-monospace, SFMono-Regular, Menlo, monospace; letter-spacing: 0.08em;
          color: #fff; background: rgba(255,255,255,0.08); border: 1px solid var(--glass-stroke);
        }
        .onboarding-hero {
          background: linear-gradient(180deg, rgba(86,188,255,0.12), rgba(255,255,255,0.03));
          border: 1px solid rgba(86,188,255,0.22); border-radius: 18px;
          box-shadow: 0 18px 44px rgba(0,0,0,0.28);
          backdrop-filter: blur(24px) saturate(1.4); -webkit-backdrop-filter: blur(24px) saturate(1.4);
          padding: 24px; margin: 0 0 14px; animation: rise 0.4s cubic-bezier(0.21,1,0.27,1) both;
        }
        .onboarding-title { margin: 0 0 7px; font-size: 24px; line-height: 1.1; letter-spacing: 0; }
        .onboarding-copy { margin: 0; color: var(--muted); font-size: 14px; line-height: 1.45; max-width: 520px; }
        .onboarding-actions { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 18px; align-items: center; }
        .onboarding-actions .btn-primary,
        .onboarding-actions .btn-secondary {
          display: inline-flex; align-items: center; justify-content: center; min-height: 42px; text-decoration: none;
        }
        .onboarding-steps { display: grid; gap: 10px; grid-template-columns: repeat(3, minmax(0, 1fr)); margin: 0 0 14px; }
        .onboarding-step {
          border: 1px solid var(--glass-stroke); border-radius: 14px; padding: 13px;
          background: rgba(255,255,255,0.055);
        }
        .onboarding-step .n {
          width: 24px; height: 24px; border-radius: 8px; display: grid; place-items: center;
          color: #fff; font-size: 12px; font-weight: 750; margin-bottom: 9px;
          background: linear-gradient(135deg, var(--blue-a), var(--blue-c));
        }
        .onboarding-step .t { font-size: 13px; font-weight: 650; margin-bottom: 3px; }
        .onboarding-step .d { font-size: 12px; color: var(--muted); line-height: 1.35; }
        @media (max-width: 560px) {
          .onboarding-steps { grid-template-columns: 1fr; }
        }
        .campaign-list { display: flex; flex-direction: column; gap: 10px; }
        .campaign-row {
          display: flex; align-items: center; gap: 11px; padding: 9px;
          border: 1px solid var(--glass-stroke); border-radius: 13px; background: var(--field);
        }
        .campaign-row .copy { flex: 1; min-width: 0; }
        .campaign-row .title { font-size: 14px; font-weight: 650; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .campaign-row .details { font-size: 12px; color: var(--muted); margin-top: 3px; }
        .campaign-row .boxart { width: 42px; height: 56px; border-radius: 8px; }
        .drop { display: flex; align-items: center; gap: 11px; padding: 8px 0; border-top: 1px solid var(--glass-stroke); }
        .drop:first-of-type { border-top: none; padding-top: 0; }
        .drop .icon { width: 34px; height: 45px; flex: none; border-radius: 8px; object-fit: cover;
                      background: linear-gradient(135deg, var(--bg-c), var(--bg-b)); border: 1px solid var(--glass-stroke); }
        .drop .t { min-width: 0; }
        .drop .reward { font-weight: 550; font-size: 14px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .savemsg { font-size: 12px; margin-top: 8px; }
        .savemsg.ok { color: var(--green); }
        .savemsg.err { color: var(--orange); }

        /* New Redesigned UI Elements aligned with Native GUI */
        .hero-card {
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
          border: 1px solid var(--glass-stroke); border-radius: 18px;
          box-shadow: 0 16px 40px rgba(0,0,0,0.22);
          backdrop-filter: blur(24px) saturate(1.4); -webkit-backdrop-filter: blur(24px) saturate(1.4);
          padding: 22px; margin: 0 0 14px;
          animation: rise 0.4s cubic-bezier(0.21,1,0.27,1) both;
          display: flex;
          flex-direction: column;
          gap: 18px;
        }
        .hero-header {
          display: flex;
          align-items: flex-start;
          gap: 16px;
        }
        .status-icon-container {
          width: 44px; height: 44px; border-radius: 50%;
          display: grid; place-items: center; flex: none;
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.1), 0 4px 12px rgba(0,0,0,0.15);
          transition: background-color 0.3s ease;
        }
        .status-svg {
          width: 22px; height: 22px;
        }
        .hero-info {
          flex: 1; min-width: 0;
        }
        .hero-headline {
          font-size: 19px; font-weight: 700; margin: 0 0 4px; letter-spacing: -0.02em;
        }
        .hero-subtitle {
          font-size: 13px; color: var(--muted); margin: 0; line-height: 1.4;
        }
        .hero-progress {
          padding: 14px;
          background: rgba(255,255,255,0.04);
          border: 1px solid var(--glass-stroke);
          border-radius: 12px;
          display: flex;
          flex-direction: column;
          gap: 10px;
        }
        .hero-progress .progress-header {
          display: flex; justify-content: space-between; align-items: center;
        }
        .hero-progress .progress-title {
          font-size: 13px; font-weight: 600; color: var(--text);
        }
        .hero-progress .progress-pct {
          font-size: 13px; font-weight: 700; color: var(--green);
        }
        .hero-progress .bar {
          margin: 0;
        }
        .hero-progress .bar > i {
          background: linear-gradient(90deg, #34c759, #30d158);
          box-shadow: 0 0 12px rgba(52,199,89,0.45);
        }
        .hero-progress .progress-meta {
          display: flex; justify-content: space-between; font-size: 11px; color: var(--muted);
        }
        .stats-row {
          display: grid;
          grid-template-columns: 1fr 1fr;
          gap: 12px;
          margin-bottom: 14px;
        }
        .stat-card {
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
          border: 1px solid var(--glass-stroke); border-radius: 18px;
          backdrop-filter: blur(24px) saturate(1.4); -webkit-backdrop-filter: blur(24px) saturate(1.4);
          padding: 16px 12px;
          text-align: center;
          display: flex;
          flex-direction: column;
          align-items: center;
          gap: 12px;
          min-width: 0;
        }
        .stat-icon-wrapper {
          width: 40px; height: 40px; border-radius: 50%;
          display: grid; place-items: center;
          box-shadow: inset 0 1px 0 rgba(255,255,255,0.1);
        }
        .stat-icon-wrapper svg {
          width: 20px; height: 20px;
        }
        .stat-value {
          font-size: 16px; font-weight: 700; color: var(--text);
          margin-top: -2px;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap; max-width: 100%;
        }
        .stat-label {
          font-size: 10px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.08em; color: var(--muted);
        }
        .priorities-flow {
          display: flex;
          flex-wrap: wrap;
          gap: 6px;
          margin: 10px 0 14px;
        }
        .priority-chip {
          display: inline-flex; align-items: center; gap: 6px; font-size: 12px; font-weight: 550;
          padding: 5px 10px; border-radius: 999px;
          background: rgba(255, 159, 10, 0.10);
          border: 1px solid rgba(255, 159, 10, 0.25);
          color: var(--text);
          transition: all 0.2s ease;
        }
        .priority-chip .star {
          width: 7px; height: 7px; border-radius: 50%; display: inline-flex; align-items: center;
          background: #ff9f0a; box-shadow: 0 0 0 3px rgba(255, 159, 10, 0.12);
        }
        .priority-chip .remove-btn {
          background: none; border: none; padding: 0; cursor: pointer; color: var(--muted);
          font-size: 12px; line-height: 1; display: inline-flex; align-items: center; justify-content: center;
          width: 14px; height: 14px; border-radius: 50%;
          transition: background 0.15s ease, color 0.15s ease;
        }
        .priority-chip .remove-btn:hover {
          background: rgba(255,255,255,0.15); color: #fff;
        }

        @media (max-width: 420px) {
          .boxart { width: 54px; height: 72px; }
          .card { padding: 14px; border-radius: 16px; }
          .stats-row { grid-template-columns: 1fr; }
        }
      </style>
    </head>
    <body>
      <div class="shell">
        <header>
          <picture>
            <source srcset="/app/logo-light.png?v=\(assetVersion)" media="(prefers-color-scheme: light)">
            <img id="hdrlogo" src="/app/logo-dark.png?v=\(assetVersion)" alt="">
          </picture>
          <h1>SwiftMiner</h1>
          <span class="spacer"></span>
          <button class="ghost" id="signout">Sign out</button>
        </header>
        <div id="app"><div class="card muted">Loading…</div></div>
      </div>
      <script src="/app/app.js?v=\(assetVersion)"></script>
    </body>
    </html>
    """

    static let appJS = """
    const $ = (id) => document.getElementById(id);
    let CSRF = null;
    let SESSION = null;
    let PROJ = null;          // last projection (user sessions)
    let CAMPAIGNS = [];
    let ACTIVATION = null;
    let activationTimer = null;
    let personal = [];        // editable personal priority list (working copy)
    let includeGlobalPriorities = true;
    let OPERATOR_MINERS = [];
    let OPERATOR_STATE = { selectedMinerId: null };

    async function api(path, opts = {}) {
      const timeoutMs = opts.timeoutMs || 15000;
      delete opts.timeoutMs;
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), timeoutMs);
      opts.headers = opts.headers || {};
      if (CSRF && opts.method && opts.method !== 'GET') opts.headers['X-SM-CSRF'] = CSRF;
      opts.credentials = 'same-origin';
      opts.signal = opts.signal || controller.signal;
      try {
        const r = await fetch(path, opts);
        if (r.status === 401) { location.href = '/login'; return null; }
        return r;
      } catch (err) {
        if (err && err.name === 'AbortError') {
          throw new Error('Request timed out while loading ' + path);
        }
        throw err;
      } finally {
        clearTimeout(timeout);
      }
    }

    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }
    function endsIn(iso) {
      if (!iso) return '';
      const ms = new Date(iso) - Date.now();
      if (isNaN(ms) || ms <= 0) return '';
      const h = Math.floor(ms / 3600000);
      if (h >= 48) return 'ends in ' + Math.floor(h / 24) + 'd';
      if (h >= 1) return 'ends in ' + h + 'h';
      return 'ends in ' + Math.max(1, Math.floor(ms / 60000)) + 'm';
    }
    function agoText(iso) {
      if (!iso) return '';
      const ms = Date.now() - new Date(iso);
      if (isNaN(ms) || ms < 0) return '';
      const h = Math.floor(ms / 3600000);
      if (h >= 48) return Math.floor(h / 24) + 'd ago';
      if (h >= 1) return h + 'h ago';
      return Math.max(1, Math.floor(ms / 60000)) + 'm ago';
    }
    function dateLabel(iso, prefix) {
      if (!iso) return '';
      const d = new Date(iso);
      if (isNaN(d)) return '';
      return prefix + ' ' + d.toLocaleDateString([], { month: 'short', day: 'numeric' });
    }
    function boxart(name, w = 144, h = 192) {
      return 'https://static-cdn.jtvnw.net/ttv-boxart/' + encodeURIComponent(name) + '-' + w + 'x' + h + '.jpg';
    }
    function hideOnError(img) { img.addEventListener('error', () => img.removeAttribute('src')); }
    function pillClass(state) {
      if (state === 'active') return 'active';
      if (state === 'blocked' || state === 'notConfigured') return 'blocked';
      return 'idle';
    }

    // ---------- user dashboard ----------

    function getStatusConfig(p) {
      if (p.state === 'active') {
        if (p.activeCampaign) {
          const streamer = p.activeCampaign.currentChannelName;
          return {
            headline: 'Watching ' + p.activeCampaign.game,
            subtitle: streamer ? 'Watching ' + streamer : 'Mining active drops',
            color: '#34c759',
            icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#34c759" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <circle cx="12" cy="12" r="2"></circle>
              <path d="M16.24 7.76a6 6 0 0 1 0 8.49m-8.48-.01a6 6 0 0 1 0-8.49m11.31-2.82a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14"></path>
            </svg>`
          };
        } else {
          return {
            headline: 'Looking for Streams',
            subtitle: 'No participating channels are live right now.',
            color: '#56bcff',
            icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#56bcff" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <path d="M12 2a10 10 0 0 1 10 10c0 2.45-1.39 4.9-3 6m-14 0c-1.61-1.1-3-3.55-3-6A10 10 0 0 1 12 2z"></path>
              <path d="M12 12m-3 0a3 3 0 1 0 6 0 3 3 0 1 0-6 0"></path>
              <path d="M12 12v9"></path>
            </svg>`
          };
        }
      } else if (p.state === 'blocked') {
        const hasUnlinked = p.issues && p.issues.some(is => is.type === 'accountNotLinked' || is.type === 'account_not_linked');
        return {
          headline: hasUnlinked ? 'Blocked — Account not linked' : 'Needs attention',
          subtitle: p.issues && p.issues.length ? p.issues[0].message : 'Link your account to earn drops.',
          color: '#ff9f0a',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#ff9f0a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M1 1l22 22M16.72 11.06A10.94 10.94 0 0 1 19 12.5a12.92 12.92 0 0 1-3 5.5m-5.18-1.57A8 8 0 0 1 12 16.5m-1.78-8.24A10.94 10.94 0 0 1 12 8.16a12.92 12.92 0 0 1 3 5.5m-9-2.58A8 8 0 0 1 12 11.5"></path>
            <circle cx="12" cy="12" r="2"></circle>
          </svg>`
        };
      } else if (p.state === 'idle') {
        return {
          headline: 'Up to Date',
          subtitle: 'All currently available drops are completed.',
          color: '#34c759',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#34c759" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path>
            <polyline points="22 4 12 14.01 9 11.01"></polyline>
          </svg>`
        };
      } else {
        return {
          headline: 'Not Configured',
          subtitle: SESSION && SESSION.provider === 'discord' ? 'Link Twitch to start mining.' : 'Ask the operator to finish setup.',
          color: '#8e8e93',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#8e8e93" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <circle cx="12" cy="12" r="10"></circle>
            <line x1="12" y1="8" x2="12" y2="12"></line>
            <line x1="12" y1="16" x2="12.01" y2="16"></line>
          </svg>`
        };
      }
    }

    function heroStateCard(p) {
      const cfg = getStatusConfig(p);
      const accId = p.account && p.account.twitchAccountId ? String(p.account.twitchAccountId) : '';
      let progressHTML = '';
      if (p.activeCampaign) {
        const c = p.activeCampaign;
        const pr = c.progress || {};
        const isCompleted = pr.pct >= 100;
        const ends = endsIn(c.endsAt);
        const metaStatus = isCompleted
          ? '<span style="color:var(--green);font-weight:600;">Ready to claim!</span>'
          : `<span>Mining${ends ? ' · ' + ends : ''}</span>`;
        progressHTML = `
          <div class="hero-progress">
            <div class="progress-header">
              <span class="progress-title">${esc(c.game)}</span>
              <span class="progress-pct" style="color: ${isCompleted ? 'var(--green)' : 'var(--blue-a)'}">${Number(pr.pct || 0)}%</span>
            </div>
            <div class="bar"><i style="width:${Math.min(100, Number(pr.pct || 0))}%${isCompleted ? ';background:linear-gradient(90deg, var(--green), #30d158);box-shadow:0 0 12px rgba(52,199,89,0.45);' : ''}"></i></div>
            <div class="progress-meta">
              <span>${esc(pr.current || 0)} / ${esc(pr.required || 0)} ${esc(pr.unit || '')}</span>
              ${metaStatus}
            </div>
          </div>
        `;
      }
      
      return `
        <div class="hero-card">
          <div class="hero-header" style="align-items: center; justify-content: space-between; width: 100%;">
            <div style="display: flex; align-items: center; gap: 16px;">
              <div class="status-icon-container" style="background-color: ${cfg.color}1e; --icon-bg: ${cfg.color}1a;">
                ${cfg.icon}
              </div>
              <div class="hero-info">
                <h2 class="hero-headline">${esc(cfg.headline)}</h2>
                ${cfg.subtitle ? `<p class="hero-subtitle">${esc(cfg.subtitle)}</p>` : ''}
              </div>
            </div>
            ${accId ? `<button class="btn-secondary refresh-btn" data-account-id="${esc(accId)}" style="padding: 6px 12px; font-size: 12px; height: 28px; line-height: 1; flex-shrink: 0; margin-left: auto;">Refresh</button>` : ''}
          </div>
          ${progressHTML}
        </div>
      `;
    }

    function statsRow(p) {
      const acc = p.account || {};
      const recents = p.recentCompletedCampaigns || [];
      const totalDropsClaimed = recents.reduce((sum, c) => sum + (c.claimedDrops || 0), 0);
      
      const twitchVal = acc.username ? esc(acc.username) : 'Not Linked';
      const twitchLabel = acc.twitchAccountId ? 'Twitch Linked' : 'Twitch Account';
      
      const twitchIcon = `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714ZM6 0 1.714 4.286V19.714H6.857V24l4.286-4.286h3.428L22.286 12V0Zm14.571 11.143-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714ZM11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714Z"/></svg>`;
      
      const giftIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 12 20 22 4 22 4 12"></polyline><rect x="2" y="7" width="20" height="5"></rect><line x1="12" y1="22" x2="12" y2="7"></line><path d="M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7z"></path><path d="M12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z"></path></svg>`;

      return `
        <div class="stats-row">
          <div class="stat-card">
            <div class="stat-icon-wrapper" style="background-color: rgba(145, 70, 255, 0.12); color: #9146FF; --tint-rgb: 145, 70, 255;">
              ${twitchIcon}
            </div>
            <div class="stat-value">${twitchVal}</div>
            <div class="stat-label">${twitchLabel}</div>
          </div>
          <div class="stat-card">
            <div class="stat-icon-wrapper" style="background-color: rgba(52, 199, 89, 0.12); color: #34C759; --tint-rgb: 52, 199, 89;">
              ${giftIcon}
            </div>
            <div class="stat-value">${totalDropsClaimed}</div>
            <div class="stat-label">Drops Claimed</div>
          </div>
        </div>
      `;
    }

    function activationCard(p) {
      if (!SESSION || SESSION.provider !== 'discord' || (p.account && p.account.twitchAccountId)) return '';
      if (!ACTIVATION) {
        return `<div class="card">
          <div class="label">Link Twitch</div>
          <div class="row" style="align-items:flex-start">
            <div style="flex:1;min-width:0">
              <div class="name">Connect your Twitch account</div>
              <div class="muted" style="font-size:13px;margin-top:4px">Start the Twitch device-code flow from here, then SwiftMiner will begin mining automatically.</div>
            </div>
            <button class="btn-primary" id="startactivation" style="height:40px">Link</button>
          </div>
          <div class="savemsg" id="activationmsg"></div>
        </div>`;
      }
      return `<div class="card">
        <div class="label">Link Twitch</div>
        <div class="row" style="align-items:center;justify-content:space-between;margin-bottom:10px">
          <div>
            <div class="muted" style="font-size:12px;margin-bottom:6px">Enter this code at Twitch</div>
            <div class="activation-code">${esc(ACTIVATION.userCode)}</div>
          </div>
          <a class="btn-primary" style="display:inline-flex;align-items:center;height:40px;text-decoration:none" href="${esc(ACTIVATION.verificationUri)}" target="_blank" rel="noreferrer">Open Twitch</a>
        </div>
        <div class="muted" style="font-size:12px">Polling for authorization${dateLabel(ACTIVATION.expiresAt, ' · expires') || ''}</div>
        <div class="savemsg" id="activationmsg"></div>
      </div>`;
    }

    function needsOnboarding(p) {
      return SESSION && SESSION.provider === 'discord' && !(p && p.account && p.account.twitchAccountId);
    }

    function onboardingHTML() {
      const activationActive = ACTIVATION && ACTIVATION.userCode;
      const actionHTML = activationActive ? `
        <div class="onboarding-actions">
          <div>
            <div class="muted" style="font-size:12px;margin-bottom:6px">Enter this code at Twitch</div>
            <div class="activation-code">${esc(ACTIVATION.userCode)}</div>
          </div>
          <a class="btn-primary" href="${esc(ACTIVATION.verificationUri)}" target="_blank" rel="noreferrer">Open Twitch</a>
        </div>
        <div class="muted" style="font-size:12px;margin-top:10px">Waiting for Twitch authorization${dateLabel(ACTIVATION.expiresAt, ' · expires') || ''}</div>
      ` : `
        <div class="onboarding-actions">
          <button class="btn-primary" id="startactivation" style="height:42px">Link Twitch</button>
        </div>
      `;
      return `
        <div class="onboarding-hero">
          <h2 class="onboarding-title">Set up your miner</h2>
          <p class="onboarding-copy">Connect your Twitch account to this Discord sign-in. Once Twitch confirms the link, SwiftMiner will create your miner and take you to the dashboard automatically.</p>
          ${actionHTML}
          <div class="savemsg" id="activationmsg"></div>
        </div>
        <div class="onboarding-steps">
          <div class="onboarding-step"><div class="n">1</div><div class="t">Start linking</div><div class="d">SwiftMiner creates a short Twitch activation code.</div></div>
          <div class="onboarding-step"><div class="n">2</div><div class="t">Confirm on Twitch</div><div class="d">Open Twitch, enter the code, and approve the connection.</div></div>
          <div class="onboarding-step"><div class="n">3</div><div class="t">Mining starts</div><div class="d">Your dashboard appears as soon as the miner is ready.</div></div>
        </div>
      `;
    }

    function renderOnboarding(p) {
      PROJ = p;
      personal = [];
      $('app').innerHTML = onboardingHTML();
      wireActivation();
    }

    function issueButtons(is) {
      const action = String(is.action || '');
      let buttons = '';
      if (action.includes('link_account') && SESSION && SESSION.provider === 'discord' && !(PROJ && PROJ.account)) {
        buttons += '<button class="btn-secondary issue-action" data-action="activation">Link Twitch</button>';
      }
      if (is.game) {
        buttons += `<button class="btn-secondary issue-action" data-action="priority-game" data-game="${esc(is.game)}" ${PROJ && PROJ.account ? '' : 'disabled'}>Prioritise</button>`;
      }
      if (action.includes('ignore_campaign') && is.campaignId) {
        buttons += `<button class="btn-secondary issue-action" data-action="ignore" data-campaign="${esc(is.campaignId)}" data-scope="campaign">Ignore campaign</button>`;
      }
      if (action.includes('ignore_game') && is.campaignId) {
        buttons += `<button class="btn-secondary issue-action" data-action="ignore" data-campaign="${esc(is.campaignId)}" data-scope="game">Ignore game</button>`;
      }
      return buttons ? `<div class="issue-actions">${buttons}</div>` : '';
    }

    function issuesCard(p) {
      if (!p.issues || !p.issues.length) return '';
      let rows = '';
      for (const is of p.issues) rows += `<div class="issue-row"><span class="issue-icon" aria-hidden="true">!</span><div class="issue-body"><div>${esc(is.message || is.type)}</div>${issueButtons(is)}</div></div>`;
      return `<div class="card"><div class="label">Needs attention</div>${rows}</div>`;
    }

    function globalCard(p) {
      if (p.includesGlobalPriorityGames === false) {
        return `<div class="card"><div class="label">Global priorities</div>
          <div class="muted" style="font-size:13px">Off for this miner. Only your own list will be used.</div></div>`;
      }
      const personalSet = new Set((p.personalPriorityGames || []).map(g => g.toLowerCase()));
      const global = (p.priorityGames || []).filter(g => !personalSet.has(g.toLowerCase()));
      if (!global.length) return '';
      let chips = '';
      global.forEach((g, i) => { chips += `<span class="chip"><span class="n">${i + 1}</span>${esc(g)}</span>`; });
      return `<div class="card"><div class="label">Global priorities</div>
        <div class="chips">${chips}</div>
        <div class="muted" style="font-size:12px;margin-top:10px">Set by the operator for every miner. Your own list below runs first.</div></div>`;
    }

    function personalCard() {
      const globalChecked = includeGlobalPriorities ? 'checked' : '';
      const helper = includeGlobalPriorities
        ? 'Your list runs first, then the operator list fills in behind it.'
        : 'Only this miner\'s list will be used.';
      let items = '';
      personal.forEach((g, i) => {
        items += `
          <span class="priority-chip" data-i="${i}">
            <span class="star" aria-hidden="true"></span>
            <span>${esc(g)}</span>
            <button class="remove-btn del" aria-label="Remove ${esc(g)}">×</button>
          </span>
        `;
      });
      return `<div class="card">
        <div class="label">Your priorities</div>
        <label class="toggle-row">
          <span class="toggle-copy">
            <span class="toggle-title">Use global priorities</span>
            <span class="muted" style="display:block;font-size:12px;margin-top:2px">${helper}</span>
          </span>
          <input id="globaltoggle" type="checkbox" ${globalChecked}>
        </label>
        <div class="priorities-flow" id="priorities-flow">
          ${items || '<span class="muted" style="font-size:13px">No personal priorities yet — add a game below.</span>'}
        </div>
        <div class="addrow">
          <input id="addgame" placeholder="Add a game…" autocapitalize="words" autocomplete="off" list="gamesuggest">
          <button class="btn-primary" id="addbtn">Add</button>
        </div>
        <datalist id="gamesuggest"></datalist>
        <div class="savemsg" id="savemsg"></div>
      </div>`;
    }

    function upNextCard(p) {
      const campaigns = CAMPAIGNS.slice(0, 6);
      if (!campaigns.length) return '';
      const accountId = p && p.account && p.account.twitchAccountId;
      let rows = '';
      for (const c of campaigns) {
        const active = c.status === 'available';
        const when = active ? endsIn(c.endsAt) : dateLabel(c.startsAt, 'starts');
        rows += `<div class="campaign-row">
          <img class="boxart" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="copy">
            <div class="title">${esc(c.game)}</div>
            <div class="details">${esc(c.dropCount || 0)} drops${when ? ' · ' + esc(when) : ''}</div>
          </div>
          <button class="btn-secondary campaign-priority" data-game="${esc(c.game)}" ${accountId ? '' : 'disabled'}>${personal.some(g => g.toLowerCase() === String(c.game || '').toLowerCase()) ? 'Prioritised' : 'Prioritise'}</button>
        </div>`;
      }
      return `<div class="card"><div class="label">Up next</div><div class="campaign-list">${rows}</div>${accountId ? '' : '<div class="muted" style="font-size:12px;margin-top:10px">Link Twitch before setting priorities.</div>'}</div>`;
    }

    function dropsCard(p) {
      const recents = p.recentCompletedCampaigns || [];
      if (!recents.length) return '';
      let rows = '';
      for (const c of recents) {
        const title = c.campaignName && c.campaignName.toLowerCase() !== c.game.toLowerCase()
          ? `${esc(c.game)} — ${esc(c.campaignName)}` : esc(c.game);
        rows += `<div class="drop"><img class="icon" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="t"><div class="reward">${title}</div>
          <div class="muted" style="font-size:12px">${esc(c.claimedDrops)} / ${esc(c.totalDrops)} drops claimed${agoText(c.completedAt) ? ' · ' + agoText(c.completedAt) : ''}</div></div></div>`;
      }
      return `<div class="card"><div class="label">Recently completed</div>${rows}</div>`;
    }

    function operatorBackCard(p) {
      if (!(SESSION && SESSION.provider === 'local') || OPERATOR_MINERS.length <= 1) return '';
      const acc = p.account || {};
      return `<div class="card detail-nav">
        <div class="back-row">
          <button class="btn-secondary" id="backoverview" type="button">All miners</button>
          <div class="hero-info">
            <div class="label" style="margin:0 0 3px">Viewing miner</div>
            <div class="name">${esc(acc.username || 'Account')}</div>
          </div>
        </div>
      </div>`;
    }

    function render(p) {
      PROJ = p;
      if (needsOnboarding(p)) {
        renderOnboarding(p);
        return;
      }
      personal = (p.personalPriorityGames || []).slice();
      includeGlobalPriorities = p.includesGlobalPriorityGames !== false;
      $('app').innerHTML = operatorBackCard(p) + heroStateCard(p) + statsRow(p) + activationCard(p) + issuesCard(p) + upNextCard(p) + globalCard(p) + personalCard() + dropsCard(p);
      hydrateArt();
      wireActivation();
      wireOperatorBack();
      wireIssues();
      wireCampaigns();
      wirePersonal();
      fillGameOptions();
    }

    function hydrateArt() {
      document.querySelectorAll('img[data-game]').forEach(img => {
        const real = img.dataset.art;
        const guess = boxart(img.dataset.game);
        img.addEventListener('error', () => {
          // Real URL failed (or guess failed): fall back once, then hide.
          if (real && img.src !== guess) { img.src = guess; }
          else { img.removeAttribute('src'); }
        });
        img.src = real || guess;
      });
    }

    function wirePersonal() {
      const flow = $('priorities-flow');
      const globalToggle = $('globaltoggle');
      if (globalToggle) globalToggle.addEventListener('change', () => {
        includeGlobalPriorities = globalToggle.checked;
        commit();
      });
      if (flow) flow.addEventListener('click', (e) => {
        const item = e.target.closest('.priority-chip'); if (!item) return;
        const i = Number(item.dataset.i);
        if (e.target.closest('.del')) { personal.splice(i, 1); commit(); }
      });
      const input = $('addgame');
      const add = () => {
        const name = input.value.trim();
        if (!name) return;
        if (personal.some(g => g.toLowerCase() === name.toLowerCase())) { input.value = ''; return; }
        personal.push(name); input.value = '';
        commit();
      };
      $('addbtn').addEventListener('click', add);
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } });
    }

    function addPersonalGame(name) {
      name = String(name || '').trim();
      if (!name) return;
      if (!personal.some(g => g.toLowerCase() === name.toLowerCase())) personal.unshift(name);
      commit();
    }

    function wireCampaigns() {
      document.querySelectorAll('.campaign-priority').forEach(btn => {
        btn.addEventListener('click', () => addPersonalGame(btn.dataset.game));
      });
    }

    function wireIssues() {
      document.querySelectorAll('.issue-action').forEach(btn => {
        btn.addEventListener('click', async () => {
          if (btn.dataset.action === 'activation') { await startActivation(); return; }
          if (btn.dataset.action === 'priority-game') { addPersonalGame(btn.dataset.game); return; }
          btn.disabled = true;
          const r = await api('/me/campaigns/' + encodeURIComponent(btn.dataset.campaign) + '/' + encodeURIComponent(btn.dataset.action), {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ scope: btn.dataset.scope || 'campaign' })
          });
          if (r && r.ok) await load(false);
          else btn.disabled = false;
        });
      });
    }

    function wireActivation() {
      const start = $('startactivation');
      if (start) start.addEventListener('click', startActivation);
    }

    async function startActivation() {
      const msg = $('activationmsg');
      if (msg) { msg.textContent = 'Starting Twitch linking…'; msg.className = 'savemsg'; }
      const r = await api('/me/activation', { method: 'POST' });
      if (!r) return;
      if (!r.ok) {
        let detail = 'Could not start Twitch linking.';
        try { detail = (await r.json()).message || detail; } catch {}
        if (msg) { msg.textContent = detail; msg.className = 'savemsg err'; }
        return;
      }
      ACTIVATION = await r.json();
      render(PROJ);
      pollActivation();
    }

    async function pollActivation() {
      if (!ACTIVATION || !ACTIVATION.sessionId) return;
      if (activationTimer) clearTimeout(activationTimer);
      const r = await api('/me/activation/' + encodeURIComponent(ACTIVATION.sessionId));
      if (!r) return;
      if (r.ok) {
        const status = await r.json();
        if (status.status === 'authorized') {
          ACTIVATION = null;
          await load(false);
          return;
        }
        if (status.status === 'failed' || status.status === 'expired') {
          const msg = $('activationmsg');
          if (msg) { msg.textContent = status.failureReason || 'Activation expired. Start again when you are ready.'; msg.className = 'savemsg err'; }
          return;
        }
      }
      const wait = Math.max(3, Number(ACTIVATION.intervalSeconds || 5)) * 1000;
      activationTimer = setTimeout(pollActivation, wait);
    }

    async function commit() {
      refreshPersonalDOM('Saving…', '');
      const accountId = PROJ && PROJ.account && PROJ.account.twitchAccountId;
      if (!accountId) { refreshPersonalDOM('No miner account to save to.', 'err'); return; }
      const r = await api('/me/miners/' + encodeURIComponent(accountId) + '/priorities', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ games: personal, include_global_priorities: includeGlobalPriorities })
      });
      if (!r) return;
      if (r.ok) {
        // Re-fetch so effective/global lists reflect the change too.
        await load(true);
        const msg = $('savemsg'); if (msg) { msg.textContent = 'Saved'; msg.className = 'savemsg ok'; setTimeout(() => { msg.textContent = ''; }, 2000); }
      } else {
        let detail = 'Could not save.';
        try { detail = (await r.json()).message || detail; } catch {}
        refreshPersonalDOM(detail, 'err');
      }
    }

    function refreshPersonalDOM(message, cls) {
      const cards = personalCard();
      const wrapper = document.createElement('div');
      wrapper.innerHTML = cards;
      const old = $('priorities-flow') && $('priorities-flow').closest('.card');
      if (old) old.replaceWith(wrapper.firstElementChild);
      wirePersonal();
      fillGameOptions();
      const msg = $('savemsg');
      if (msg && message) { msg.textContent = message; msg.className = 'savemsg ' + cls; }
    }

    // ---------- operator overview (local sign-in) ----------

    function minerId(p) {
      return p && p.account && p.account.twitchAccountId ? String(p.account.twitchAccountId) : '';
    }

    function renderOverview(miners, data = {}) {
      OPERATOR_MINERS.splice(0, OPERATOR_MINERS.length, ...miners);
      const totalMiners = data.totalMiners || miners.length;
      const activeMiners = data.activeMiners || miners.filter(m => m.state === 'active').length;
      const claimsToday = data.claimsToday || 0;

      const pcIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="3" width="18" height="12" rx="2" ry="2"></rect><line x1="8" y1="21" x2="16" y2="21"></line><line x1="12" y1="15" x2="12" y2="21"></line></svg>`;
      const playIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg>`;
      const giftIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 12 20 22 4 22 4 12"></polyline><rect x="2" y="7" width="20" height="5"></rect><line x1="12" y1="22" x2="12" y2="7"></line><path d="M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7z"></path><path d="M12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z"></path></svg>`;

      let html = `<div class="hero-card">
        <div class="hero-header">
          <div class="status-icon-container" style="background-color: var(--blue-a)1e; --icon-bg: var(--blue-a)1a;">
            <svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="var(--blue-a)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect>
              <line x1="9" y1="3" x2="9" y2="21"></line>
            </svg>
          </div>
          <div class="hero-info">
            <h2 class="hero-headline">Operator Overview</h2>
            <p class="hero-subtitle">${totalMiners} configured miner${totalMiners === 1 ? '' : 's'}</p>
          </div>
        </div>
      </div>`;

      // Render the stats row
      html += `
        <div class="stats-row" style="margin-bottom: 24px;">
          <div class="stat-card">
            <div class="stat-icon-wrapper" style="background-color: rgba(86, 188, 255, 0.12); color: var(--blue-a); --tint-rgb: 86, 188, 255;">
              ${pcIcon}
            </div>
            <div class="stat-value">${totalMiners}</div>
            <div class="stat-label">Total Miners</div>
          </div>
          <div class="stat-card">
            <div class="stat-icon-wrapper" style="background-color: rgba(52, 199, 89, 0.12); color: #34C759; --tint-rgb: 52, 199, 89;">
              ${playIcon}
            </div>
            <div class="stat-value">${activeMiners}</div>
            <div class="stat-label">Active Miners</div>
          </div>
          <div class="stat-card">
            <div class="stat-icon-wrapper" style="background-color: rgba(255, 149, 0, 0.12); color: #FF9500; --tint-rgb: 255, 149, 0;">
              ${giftIcon}
            </div>
            <div class="stat-value">${claimsToday}</div>
            <div class="stat-label">Claims Today</div>
          </div>
        </div>
      `;

      if (!miners.length) {
        html += '<div class="card muted">No miners configured yet.</div>';
      }

      for (const p of miners) {
        const acc = p.account || {};
        const cfg = getStatusConfig(p);
        const id = minerId(p);
        
        let watchingHTML = '';
        if (p.activeCampaign && p.activeCampaign.currentChannelName) {
          watchingHTML = ` · watching ${esc(p.activeCampaign.currentChannelName)}`;
        }
        
        let progressHTML = '';
        if (p.activeCampaign) {
          const c = p.activeCampaign;
          const pr = c.progress || {};
          const isCompleted = pr.pct >= 100;
          progressHTML = `
            <div class="hero-progress" style="margin-top: 14px;">
              <div class="progress-header">
                <span class="progress-title">${esc(c.game)}</span>
                <span class="progress-pct">${Number(pr.pct || 0)}%</span>
              </div>
              <div class="bar"><i style="width:${Math.min(100, Number(pr.pct || 0))}%${isCompleted ? ';background:linear-gradient(90deg, var(--green), #30d158);box-shadow:0 0 12px rgba(52,199,89,0.45);' : ''}"></i></div>
              <div class="progress-meta">
                <span>${esc(pr.current || 0)} / ${esc(pr.required || 0)} ${esc(pr.unit || '')}</span>
              </div>
            </div>
          `;
        }

        let prioHTML = '';
        const prio = p.priorityGames || [];
        if (prio.length) {
          let chips = '';
          prio.forEach((g) => {
            chips += `
              <span class="priority-chip" style="background: rgba(86, 188, 255, 0.10); border-color: rgba(86, 188, 255, 0.25);">
                <span class="star" style="background: var(--blue-a); box-shadow: 0 0 0 3px rgba(86, 188, 255, 0.12);" aria-hidden="true"></span>
                <span>${esc(g)}</span>
              </span>
            `;
          });
          prioHTML = `
            <div style="margin-top: 14px;">
              <div class="label" style="margin-bottom: 6px;">Priorities</div>
              <div class="priorities-flow" style="margin: 0;">${chips}</div>
            </div>
          `;
        }

        html += `
          <div class="card miner-card" style="padding: 20px;" data-miner-id="${esc(id)}" role="button" tabindex="0" aria-label="Open ${esc(acc.username || 'miner')}">
            <div class="hero-header" style="gap: 14px; align-items: center; justify-content: space-between; width: 100%;">
              <div style="display: flex; align-items: center; gap: 14px;">
                <div class="status-icon-container" style="width: 38px; height: 38px; background-color: ${cfg.color}1e; --icon-bg: ${cfg.color}1a;">
                  ${cfg.icon.replace('class="status-svg"', 'class="status-svg" style="width: 18px; height: 18px;"')}
                </div>
                <div class="hero-info">
                  <h3 class="hero-headline" style="font-size: 16px; margin-bottom: 2px;">${esc(acc.username || 'Account')}</h3>
                  <p class="hero-subtitle" style="font-size: 12px; color: ${cfg.color}">${esc(cfg.headline)}${watchingHTML}</p>
                </div>
              </div>
              <button class="btn-secondary refresh-btn" data-account-id="${esc(acc.twitchAccountId)}" style="padding: 6px 12px; font-size: 12px; height: 28px; line-height: 1; flex-shrink: 0; margin-left: auto;">Refresh</button>
            </div>
            ${progressHTML}
            ${prioHTML}
          </div>
        `;
      }

      $('app').innerHTML = html;
      hydrateArt();
      wireOperatorOverview();
    }

    function showOperatorMiner(id) {
      const p = OPERATOR_MINERS.find(m => minerId(m) === String(id));
      if (!p) return;
      OPERATOR_STATE.selectedMinerId = String(id);
      render(p);
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    function wireOperatorOverview() {
      document.querySelectorAll('.miner-card').forEach(card => {
        const open = () => showOperatorMiner(card.dataset.minerId);
        card.addEventListener('click', open);
        card.addEventListener('keydown', (e) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault();
            open();
          }
        });
      });
    }

    function wireOperatorBack() {
      const back = $('backoverview');
      if (!back) return;
      back.addEventListener('click', () => {
        OPERATOR_STATE.selectedMinerId = null;
        renderOverview(OPERATOR_MINERS);
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    }

    // ---------- bootstrap ----------

    async function doLogout() {
      await api('/logout', { method: 'POST' });
      location.href = '/login';
    }

    let lastPayload = null;

    function editingNow() {
      const a = document.activeElement;
      return a && (a.id === 'addgame' || a.tagName === 'INPUT');
    }

    async function load(soft) {
      // Never clobber the page while the user is typing or mid-save.
      if (soft && editingNow()) return;
      try {
        const sr = await api('/me/session');
        if (!sr) return;
        if (!sr.ok) throw new Error('Session request failed with status ' + sr.status);
        const session = await sr.json();
        SESSION = session;
        CSRF = session.csrfToken;
        if (!GAMES.length) loadGames();
        const campaignsReady = loadCampaigns();
        const pr = await api('/me/projection');
        if (!pr) return;
        if (pr.status === 404) { $('app').innerHTML = '<div class="card muted">No miner found for your account yet.</div>'; return; }
        if (!pr.ok) throw new Error('Projection request failed with status ' + pr.status);
        const text = await pr.text();
        // Background refresh with identical data: leave the DOM alone entirely.
        if (soft && text === lastPayload) return;
        lastPayload = text;
        const data = JSON.parse(text);
        if (data.miners) {
          const miners = data.miners || [];
          if (miners.length === 1) {
            OPERATOR_STATE.selectedMinerId = null;
            render(miners[0]);
          } else if (OPERATOR_STATE.selectedMinerId) {
            OPERATOR_MINERS.splice(0, OPERATOR_MINERS.length, ...miners);
            const selected = miners.find(m => minerId(m) === OPERATOR_STATE.selectedMinerId);
            if (selected) render(selected);
            else {
              OPERATOR_STATE.selectedMinerId = null;
              renderOverview(miners, data);
            }
          } else {
            renderOverview(miners, data);
          }
        } else {
          render(data);
        }
        document.body.classList.add('loaded');
        campaignsReady.then(() => {
          if (!PROJ || editingNow()) return;
          render(PROJ);
        }).catch(() => {});
      } catch (err) {
        console.error('Failed to load dashboard:', err);
        if (!soft || !document.body.classList.contains('loaded')) {
          $('app').innerHTML = `
            <div class="card" style="padding: 30px; text-align: center; max-width: 400px; margin: 40px auto;">
              <div class="issue-icon" style="width: 42px; height: 42px; margin: 0 auto 16px; font-size: 22px;">!</div>
              <h2 style="margin: 0 0 10px 0; font-size: 20px;">Could not load dashboard</h2>
              <p class="muted" style="font-size: 14px; margin-bottom: 24px; line-height: 1.5;">${esc(err.message || err)}</p>
              <button class="btn-primary" id="retryload" style="height: 40px; padding: 0 24px;">Retry</button>
            </div>
          `;
          const retry = $('retryload');
          if (retry) retry.addEventListener('click', () => window.location.reload());
          document.body.classList.add('loaded');
        }
      }
    }

    let GAMES = [];
    async function loadGames() {
      try {
        const r = await api('/me/games');
        if (!r || !r.ok) return;
        GAMES = (await r.json()).games || [];
        fillGameOptions();
      } catch {}
    }
    async function loadCampaigns() {
      try {
        const r = await api('/me/campaigns');
        if (!r || !r.ok) return;
        CAMPAIGNS = (await r.json()).campaigns || [];
      } catch {}
    }
    function fillGameOptions() {
      const dl = $('gamesuggest');
      if (!dl) return;
      dl.innerHTML = GAMES.map(g => `<option value="${esc(g)}"></option>`).join('');
    }

    document.addEventListener('click', async (e) => {
      const btn = e.target.closest('.refresh-btn');
      if (!btn) return;
      e.stopPropagation();
      e.preventDefault();
      
      const accountId = btn.dataset.accountId;
      if (!accountId) return;
      
      const originalText = btn.textContent;
      btn.textContent = 'Refreshed';
      btn.disabled = true;
      
      try {
        const r = await api('/me/miners/' + encodeURIComponent(accountId) + '/control/refresh', {
          method: 'POST'
        });
        if (r && r.ok) {
          await load(true);
        } else {
          let detail = 'Refresh failed';
          try { detail = (await r.json()).message || detail; } catch {}
          alert(detail);
        }
      } catch (err) {
        alert('Failed to trigger refresh: ' + err.message);
      } finally {
        btn.textContent = originalText;
        btn.disabled = false;
      }
    });

    const hdr = $('hdrlogo');
    if (hdr) hideOnError(hdr);
    $('signout').addEventListener('click', doLogout);
    load();
    // Keep progress fresh without being chatty.
    setInterval(() => load(true), 60000);
    """

    static let loginJS = """
    (function() {
      const canvas = document.getElementById('nebula-canvas');
      if (!canvas) return;
      const ctx = canvas.getContext('2d');
      
      let width = canvas.width = window.innerWidth;
      let height = canvas.height = window.innerHeight;
      
      window.addEventListener('resize', () => {
        width = canvas.width = window.innerWidth;
        height = canvas.height = window.innerHeight;
      });
      
      const cloudColors = [
        { r: 145, g: 70,  b: 255 },
        { r: 86,  g: 188, b: 255 },
        { r: 255, g: 59,  b: 48  },
        { r: 32,  g: 140, b: 255 },
        { r: 167, g: 143, b: 242 },
        { r: 22,  g: 105, b: 221 }
      ];
      
      const clouds = [];
      for (let i = 0; i < 6; i++) {
        const color = cloudColors[i % cloudColors.length];
        clouds.push({
          x: Math.random() * width,
          y: Math.random() * height,
          r: 150 + Math.random() * 250,
          vx: (Math.random() - 0.5) * 0.4,
          vy: (Math.random() - 0.5) * 0.4,
          color: color
        });
      }
      
      const stars = [];
      for (let i = 0; i < 150; i++) {
        stars.push({
          x: Math.random() * width,
          y: Math.random() * height,
          r: 0.5 + Math.random() * 1.2,
          alpha: 0.1 + Math.random() * 0.9,
          twinkleSpeed: (0.005 + Math.random() * 0.015) * (Math.random() > 0.5 ? 1 : -1)
        });
      }
      
      function animate() {
        ctx.clearRect(0, 0, width, height);
        
        ctx.globalCompositeOperation = 'screen';
        for (const cloud of clouds) {
          cloud.x += cloud.vx;
          cloud.y += cloud.vy;
          
          if (cloud.x - cloud.r > width) cloud.x = -cloud.r;
          else if (cloud.x + cloud.r < 0) cloud.x = width + cloud.r;
          if (cloud.y - cloud.r > height) cloud.y = -cloud.r;
          else if (cloud.y + cloud.r < 0) cloud.y = height + cloud.r;
          
          const grad = ctx.createRadialGradient(cloud.x, cloud.y, 0, cloud.x, cloud.y, cloud.r);
          const c = cloud.color;
          grad.addColorStop(0, `rgba(${c.r}, ${c.g}, ${c.b}, 0.15)`);
          grad.addColorStop(1, `rgba(${c.r}, ${c.g}, ${c.b}, 0)`);
          
          ctx.beginPath();
          ctx.arc(cloud.x, cloud.y, cloud.r, 0, Math.PI * 2);
          ctx.fillStyle = grad;
          ctx.fill();
        }
        
        ctx.globalCompositeOperation = 'source-over';
        for (const star of stars) {
          star.y -= 0.05;
          if (star.y < 0) {
            star.y = height;
            star.x = Math.random() * width;
          }
          
          star.alpha += star.twinkleSpeed;
          if (star.alpha >= 1.0) {
            star.alpha = 1.0;
            star.twinkleSpeed = -Math.abs(star.twinkleSpeed);
          } else if (star.alpha <= 0.1) {
            star.alpha = 0.1;
            star.twinkleSpeed = Math.abs(star.twinkleSpeed);
          }
          
          ctx.beginPath();
          ctx.arc(star.x, star.y, star.r, 0, Math.PI * 2);
          ctx.fillStyle = `rgba(255, 255, 255, ${star.alpha})`;
          ctx.fill();
        }
        
        requestAnimationFrame(animate);
      }
      
      animate();
    })();
    """

    /// Login logo echoing the app icon: a faceted purple gem with a pickaxe
    /// resting on it, plus sparkles. Inline SVG so it's crisp at any size and
    /// CSP-safe (markup, not script).
    private static let gemMark = """
    <svg viewBox="0 0 64 64" xmlns="http://www.w3.org/2000/svg" aria-hidden="true">
      <!-- gem body + facets -->
      <polygon points="32,25 46,31 52,44 40,57 22,57 12,42 20,29" fill="#cdc0f7"/>
      <polygon points="32,25 46,31 36,41" fill="#b6a4f4"/>
      <polygon points="32,25 36,41 20,29" fill="#ded5fb"/>
      <polygon points="20,29 36,41 12,42" fill="#a994ef"/>
      <polygon points="46,31 52,44 36,41" fill="#9d86ec"/>
      <polygon points="12,42 36,41 22,57" fill="#8f78e6"/>
      <polygon points="36,41 52,44 40,57" fill="#7f62de"/>
      <polygon points="36,41 40,57 22,57" fill="#9d88ea"/>
      <!-- pickaxe handle then head -->
      <path d="M27 12 L48 33" stroke="#b9b3cf" stroke-width="7" stroke-linecap="round"/>
      <path d="M27 12 L48 33" stroke="#f0eefa" stroke-width="5" stroke-linecap="round"/>
      <path d="M8 27 Q26 2 53 15" fill="none" stroke="#cfcbe2" stroke-width="7" stroke-linecap="round"/>
      <path d="M9 26 Q26 4 52 15" fill="none" stroke="#ece9f7" stroke-width="4" stroke-linecap="round"/>
      <!-- sparkles -->
      <path d="M13 14 l1.2 3 3 1.2 -3 1.2 -1.2 3 -1.2 -3 -3 -1.2 3 -1.2 Z" fill="#ffffff" opacity="0.95"/>
      <path d="M55 24 l0.9 2.2 2.2 0.9 -2.2 0.9 -0.9 2.2 -0.9 -2.2 -2.2 -0.9 2.2 -0.9 Z" fill="#ffffff" opacity="0.8"/>
      <path d="M18 50 l0.7 1.8 1.8 0.7 -1.8 0.7 -0.7 1.8 -0.7 -1.8 -1.8 -0.7 1.8 -0.7 Z" fill="#ffffff" opacity="0.6"/>
    </svg>
    """

    /// Inline brand marks (markup, not scripts — fine under the strict CSP).
    private static let discordMark = """
    <svg class="mark" viewBox="0 0 127.14 96.36" xmlns="http://www.w3.org/2000/svg" fill="currentColor" aria-hidden="true"><path d="M107.7,8.07A105.15,105.15,0,0,0,81.47,0a72.06,72.06,0,0,0-3.36,6.83A97.68,97.68,0,0,0,49,6.83,72.37,72.37,0,0,0,45.64,0,105.89,105.89,0,0,0,19.39,8.09C2.79,32.65-1.71,56.6.54,80.21h0A105.73,105.73,0,0,0,32.71,96.36,77.7,77.7,0,0,0,39.6,85.25a68.42,68.42,0,0,1-10.85-5.18c.91-.66,1.8-1.34,2.66-2a75.57,75.57,0,0,0,64.32,0c.87.71,1.76,1.39,2.66,2a68.68,68.68,0,0,1-10.87,5.19,77,77,0,0,0,6.89,11.1A105.25,105.25,0,0,0,126.6,80.22h0C129.24,52.84,122.09,29.11,107.7,8.07ZM42.45,65.69C36.18,65.69,31,60,31,53s5-12.74,11.43-12.74S54,46,53.89,53,48.84,65.69,42.45,65.69Zm42.24,0C78.41,65.69,73.25,60,73.25,53s5-12.74,11.44-12.74S96.23,46,96.12,53,91.08,65.69,84.69,65.69Z"/></svg>
    """

    private static let twitchMark = """
    <svg class="mark" viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="currentColor" aria-hidden="true"><path fill-rule="evenodd" d="M6 0 1.714 4.286V19.714H6.857V24l4.286-4.286h3.428L22.286 12V0Zm14.571 11.143-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714ZM11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714Z"/></svg>
    """

    private static let loginTaglines = [
        "Twitch Drops... now hands-free",
        "Drops handled. Tabs optional.",
        "Quietly keeping an eye on Drops.",
        "Less babysitting, more claiming.",
        "Your Drops desk, minus the desk.",
        "Campaigns tracked without the tab juggling.",
        "Drop watch, minus the watch duty.",
        "Keeping the Drops queue moving.",
        "Press F to pay respects to missed Drops.",
        "A tiny control room for Twitch Drops.",
        "Twitch Drops, handled in the background"
    ]

    /// Sign-in chooser. Renders a button per enabled provider, plus a local
    /// username/password form when local sign-in is available on this request.
    /// `discordSSOURL` is SwiftBot's companion-SSO entry point (Discord
    /// sign-in brokered by the paired SwiftBot).
    static func loginPage(discordSSOURL: String?, twitch: Bool, local: Bool, appIcon: Bool = false) -> String {
        // Prefer the bundled artwork (mode-specific shadows baked in, picked by
        // prefers-color-scheme); fall back to the drawn gem mark.
        let logoBlock = appIcon
            ? """
            <picture>
              <source srcset="/app/logo-light.png?v=\(assetVersion)" media="(prefers-color-scheme: light)">
              <img class="logo-img" src="/app/logo-dark.png?v=\(assetVersion)" alt="" width="76" height="76">
            </picture>
            """
            : #"<div class="logo">\#(gemMark)</div>"#
        var blocks = ""
        if let discordSSOURL {
            let href = discordSSOURL
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            blocks += #"<a class="btn discord" href="\#(href)">\#(discordMark)Sign in with Discord</a>"#
        }
        if twitch {
            blocks += #"<a class="btn twitch" href="/login/twitch">\#(twitchMark)Sign in with Twitch</a>"#
        }
        if local {
            if !blocks.isEmpty { blocks += #"<div class="divider"><span></span>or<span></span></div>"# }
            blocks += """
            <form class="local" method="POST" action="/login/local" autocomplete="off">
              <input name="username" placeholder="Username" autocapitalize="off" autocorrect="off">
              <input name="password" type="password" placeholder="Password">
              <button class="btn local-btn" type="submit">Sign in locally</button>
            </form>
            """
        }
        if blocks.isEmpty {
            blocks = #"<p class="hint">No sign-in methods are configured yet. Ask the operator to finish setup in SwiftMiner's Web settings.</p>"#
        }
        let subtitle = local && discordSSOURL == nil && !twitch
            ? "Sign in locally with your operator account"
            : "Sign in to manage your miner"
        let tagline = loginTaglines.randomElement() ?? "Twitch Drops, handled in the background"
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><link rel="icon" type="image/png" href="/app/logo-dark.png?v=\(assetVersion)"><link rel="apple-touch-icon" href="/app/logo-dark.png?v=\(assetVersion)"><title>Sign in · SwiftMiner</title>
        <style>
          :root {
            --bg-a: #0a0a0a; --bg-b: #121212; --bg-c: #1a1a1a;
            --text: rgba(255,255,255,0.94); --muted: rgba(255,255,255,0.62);
            --glass-top: rgba(255,255,255,0.08); --glass-bottom: rgba(255,255,255,0.03);
            --glass-stroke: rgba(255,255,255,0.10);
            --field: rgba(255,255,255,0.06); --field-stroke: rgba(255,255,255,0.12);
            --blue-a: #56bcff; --blue-c: #1669dd;
          }
          * { box-sizing: border-box; }
          body {
            margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 1.5rem;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;
            color: var(--text);
            background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
            background-size: 400% 400%;
            animation: gradient-pan 20s ease infinite alternate;
            background-attachment: fixed;
            position: relative;
            overflow: hidden;
          }
          @keyframes gradient-pan {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
          }
          #nebula-canvas {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            z-index: 0;
            pointer-events: none;
          }
          .card {
            width: min(380px, 100%); padding: 32px; border-radius: 28px; text-align: center;
            background: rgba(25, 20, 40, 0.45);
            border: 1px solid rgba(255, 255, 255, 0.08);
            box-shadow: 0 24px 64px rgba(0, 0, 0, 0.5), inset 0 1px 0 rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(28px) saturate(1.6);
            -webkit-backdrop-filter: blur(28px) saturate(1.6);
            animation: rise 0.45s cubic-bezier(0.21, 1, 0.27, 1) both;
            position: relative;
            z-index: 1;
          }
          @keyframes rise { from { opacity: 0; transform: translateY(14px) scale(0.985); } }
          .logo {
            width: 56px; height: 56px; margin: 0 auto 14px; border-radius: 15px;
            background: linear-gradient(135deg, #a78ff2, #6c52d9);
            box-shadow: 0 10px 24px rgba(124,92,230,0.45);
            display: grid; place-items: center;
          }
          .logo svg { width: 42px; height: 42px; }
          /* Shadow/glow is baked into the bundled PNGs per color scheme. */
          .logo-img { display: block; width: 76px; height: 76px; margin: 0 auto 10px; }
          h1 { margin: 0 0 4px; font-size: 28px; letter-spacing: -0.03em; font-weight: 700; }
          .sub { margin: 0 0 24px; font-size: 14px; color: var(--muted); }
          .stack { display: flex; flex-direction: column; gap: 12px; }
          .btn {
            display: flex; align-items: center; justify-content: center; gap: 10px;
            width: 100%; padding: 12px 16px; border-radius: 13px; border: none; cursor: pointer;
            font: 600 15px/1 inherit; font-family: inherit; color: #fff; text-decoration: none;
            transition: transform 0.15s ease, box-shadow 0.15s ease, filter 0.15s ease;
          }
          .btn:hover { transform: translateY(-1px); filter: brightness(1.07); }
          .btn:active { transform: translateY(0); filter: brightness(0.96); }
          .mark { width: 19px; height: 19px; flex: none; }
          .discord { background: #5865F2; box-shadow: 0 8px 20px rgba(88,101,242,0.35); }
          .twitch  { background: #9146FF; box-shadow: 0 8px 20px rgba(145,70,255,0.35); }
          .local-btn {
            background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
            border: 1px solid var(--glass-stroke); color: var(--text);
          }
          .divider {
            display: flex; align-items: center; gap: 14px; margin: 6px 0;
            color: var(--muted); font-size: 10px; font-weight: 600;
            text-transform: uppercase; letter-spacing: 0.14em;
          }
          .divider span { flex: 1; height: 1px; background: var(--glass-stroke); }
          .local { display: flex; flex-direction: column; gap: 10px; }
          .local input {
            width: 100%; padding: 12px 14px; border-radius: 13px; font: 15px inherit; font-family: inherit;
            color: var(--text); background: var(--field); border: 1px solid var(--field-stroke);
            outline: none; transition: border-color 0.15s ease, box-shadow 0.15s ease;
          }
          .local input::placeholder { color: var(--muted); }
          .local input:focus { border-color: var(--blue-a); box-shadow: 0 0 0 3px rgba(86,188,255,0.18); }
          .hint { margin: 0; font-size: 13px; line-height: 1.5; color: var(--muted); }
          .foot { margin-top: 22px; font-size: 11px; color: var(--muted); opacity: 0.8; }
        </style></head>
        <body>
          <canvas id="nebula-canvas"></canvas>
          <main class="card">
            \(logoBlock)
            <h1>SwiftMiner</h1>
            <p class="sub">\(subtitle)</p>
            <div class="stack">\(blocks)</div>
            <p class="foot">\(tagline)</p>
          </main>
          <script src="/app/login.js?v=\(assetVersion)"></script>
        </body></html>
        """
    }

    /// A standalone status page (used for OAuth error/landing messages),
    /// styled to match the login card.
    static func message(_ text: String, linkToLogin: Bool = false) -> String {
        statusMessage(title: "SwiftMiner", text: text, linkText: linkToLogin ? "Try again" : nil, linkURL: "/login")
    }

    static func statusMessage(title: String, text: String, linkText: String? = nil, linkURL: String = "/login") -> String {
        let safeTitle = title.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let safeText = text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let safeURL = linkURL.replacingOccurrences(of: "\"", with: "&quot;")
        let safeLinkText = linkText.map {
            $0.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let link = safeLinkText.map { #"<a class="again" href="\#(safeURL)">\#($0)</a>"# } ?? ""
        return statusPage(title: safeTitle, text: safeText, link: link)
    }

    private static func statusPage(title: String, text: String, link: String) -> String {
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><link rel="icon" type="image/png" href="/app/logo-dark.png?v=\(assetVersion)"><link rel="apple-touch-icon" href="/app/logo-dark.png?v=\(assetVersion)"><title>\(title) · SwiftMiner</title>
        <style>
          :root {
            --bg-a: #0a0a0a; --bg-b: #121212; --bg-c: #1a1a1a;
            --text: rgba(255,255,255,0.94); --muted: rgba(255,255,255,0.62);
            --glass-top: rgba(255,255,255,0.08); --glass-bottom: rgba(255,255,255,0.03);
            --glass-stroke: rgba(255,255,255,0.10);
          }
          body {
            margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 1.5rem;
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;
            color: var(--text);
            background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
            background-size: 400% 400%;
            animation: gradient-pan 20s ease infinite alternate;
            background-attachment: fixed;
            position: relative;
            overflow: hidden;
          }
          @keyframes gradient-pan {
            0% { background-position: 0% 50%; }
            50% { background-position: 100% 50%; }
            100% { background-position: 0% 50%; }
          }
          #nebula-canvas {
            position: fixed;
            top: 0; left: 0; width: 100%; height: 100%;
            z-index: 0;
            pointer-events: none;
          }
          .card {
            width: min(380px, 100%); padding: 32px; border-radius: 28px; text-align: center;
            background: rgba(25, 20, 40, 0.45);
            border: 1px solid rgba(255, 255, 255, 0.08);
            box-shadow: 0 24px 64px rgba(0, 0, 0, 0.5), inset 0 1px 0 rgba(255, 255, 255, 0.1);
            backdrop-filter: blur(28px) saturate(1.6);
            -webkit-backdrop-filter: blur(28px) saturate(1.6);
            position: relative;
            z-index: 1;
          }
          h1 { margin: 0 0 8px; font-size: 24px; letter-spacing: -0.03em; }
          p { margin: 0; font-size: 14px; line-height: 1.5; color: var(--muted); }
          .again {
            display: inline-block; margin-top: 20px; padding: 11px 22px; border-radius: 13px;
            background: linear-gradient(135deg, #56bcff, #1669dd); color: #fff;
            font-weight: 600; font-size: 14px; text-decoration: none;
            box-shadow: 0 8px 20px rgba(32,140,255,0.35);
          }
        </style></head>
        <body>
          <canvas id="nebula-canvas"></canvas>
          <main class="card"><h1>\(title)</h1><p>\(text)</p>\(link)</main>
          <script src="/app/login.js?v=\(assetVersion)"></script>
        </body></html>
        """
    }
}
