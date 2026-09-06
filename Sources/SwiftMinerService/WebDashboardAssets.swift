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
          margin: 0; min-height: 100vh; padding: 0 24px 48px;
          font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", "SF Pro Text", system-ui, sans-serif;
          font-size: 15px; color: var(--text);
          background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
          background-attachment: fixed;
        }
        /* Desktop gets a wider column and real margins around it; the layout
           stays one focused column, never a multi-column dashboard. */
        .shell { max-width: 720px; margin: 0 auto; }
        header {
          display: flex; align-items: center; gap: 10px; padding: 12px 2px 10px;
        }
        /* The detail view's "All Miners" link lives in the chrome, not in the
           content column: it is navigation, and the column should open with the
           account it is about. */
        header #navback { display: inline-flex; align-items: center; margin-left: 4px; }
        header #navback:empty { display: none; }
        header img { width: 34px; height: 34px; }
        header h1 { margin: 0; font-size: 19px; letter-spacing: -0.02em; }
        header .spacer { flex: 1; }
        /* Signing out is account context rather than a page action, so it sits
           behind a small profile button instead of a standing top-level one. */
        .account-menu { position: relative; z-index: 80; }
        .account-menu-btn {
          display: inline-flex; align-items: center; gap: 3px; padding: 6px 8px;
          border: 1px solid transparent; border-radius: 10px; cursor: pointer;
          color: var(--muted); background: transparent;
        }
        .account-menu-btn svg { width: 18px; height: 18px; }
        .account-menu-btn .account-menu-caret { width: 13px; height: 13px; opacity: 0.8; }
        .account-menu-btn:hover, .account-menu-btn[aria-expanded="true"] {
          color: var(--text); border-color: var(--glass-stroke); background: rgba(255,255,255,0.06);
        }
        .account-menu-btn:focus-visible { outline: 2px solid rgba(145,70,255,0.5); outline-offset: 2px; }
        .account-menu-pop {
          position: absolute; top: calc(100% + 6px); right: 0; z-index: 80; min-width: 168px;
          display: flex; flex-direction: column; padding: 5px; border-radius: 12px;
          border: 1px solid var(--glass-stroke); background: rgba(32, 26, 54, 0.98);
          box-shadow: 0 16px 38px rgba(0,0,0,0.46);
        }
        .account-menu-item {
          padding: 8px 10px; border: 0; border-radius: 8px; color: var(--text); text-align: left;
          background: transparent; cursor: pointer; font: 550 13px/1.2 inherit; font-family: inherit;
        }
        /* `display: flex/grid` on a menu would otherwise beat the UA's
           `[hidden] { display: none }`, leaving both menus permanently open. */
        .account-menu-pop[hidden], .source-menu[hidden] { display: none; }
        .account-menu-item:hover { background: rgba(145,70,255,0.20); }
        .account-menu-item:focus-visible { outline: 2px solid rgba(145,70,255,0.5); outline-offset: -2px; }
        .ghost {
          font: 600 13px/1 inherit; font-family: inherit; color: var(--text); cursor: pointer;
          padding: 9px 14px; border-radius: 11px; border: 1px solid var(--glass-stroke);
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
        }
        .card {
          background: rgba(24, 19, 43, 0.72);
          border: 1px solid rgba(255, 255, 255, 0.12); border-radius: 18px;
          box-shadow: 0 12px 30px rgba(0, 0, 0, 0.34), inset 0 1px 0 rgba(255, 255, 255, 0.07);
          backdrop-filter: blur(20px) saturate(1.4); -webkit-backdrop-filter: blur(20px) saturate(1.4);
          padding: 17px 20px; margin: 0 0 14px;
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
        .loading-card {
          position: relative; overflow: hidden; padding: 22px; min-height: 280px;
          display: flex; flex-direction: column; gap: 18px;
        }
        .loading-card::before {
          content: ""; position: absolute; inset: -40% -20% auto -20%; height: 220px;
          background: radial-gradient(circle at 50% 50%, rgba(86,188,255,0.22), rgba(145,70,255,0.12) 45%, transparent 70%);
          filter: blur(18px); opacity: 0.9; animation: loading-drift 4.8s ease-in-out infinite alternate;
        }
        .loading-hero { position: relative; z-index: 1; display: flex; align-items: center; gap: 14px; }
        .loading-mark {
          width: 52px; height: 52px; flex: none; border-radius: 16px; display: grid; place-items: center;
          background: radial-gradient(circle at 35% 30%, #fff, #a78ff2 34%, #6c52d9 70%);
          box-shadow: 0 14px 30px rgba(124,92,230,0.38), inset 0 1px 0 rgba(255,255,255,0.55);
          animation: loading-float 1.9s ease-in-out infinite;
        }
        .loading-mark::after {
          content: ""; width: 22px; height: 22px; border-radius: 7px;
          background: linear-gradient(135deg, rgba(255,255,255,0.95), rgba(86,188,255,0.45));
          clip-path: polygon(50% 0, 100% 34%, 78% 100%, 22% 100%, 0 34%);
          box-shadow: 0 0 18px rgba(255,255,255,0.48);
        }
        .loading-copy { min-width: 0; }
        .loading-title { margin: 0 0 5px; font-size: 19px; font-weight: 750; letter-spacing: -0.02em; }
        .loading-status { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.4; }
        .loading-dots::after {
          content: ""; animation: loading-dots 1.2s steps(4, end) infinite;
        }
        .loading-skeleton { position: relative; z-index: 1; display: grid; gap: 10px; }
        .loading-row {
          height: 64px; border-radius: 14px; border: 1px solid var(--glass-stroke);
          background:
            linear-gradient(90deg, transparent, rgba(255,255,255,0.09), transparent),
            linear-gradient(180deg, rgba(255,255,255,0.07), rgba(255,255,255,0.035));
          background-size: 220px 100%, 100% 100%;
          background-position: -220px 0, 0 0;
          animation: loading-shimmer 1.8s ease-in-out infinite;
        }
        .loading-row:nth-child(2) { height: 86px; animation-delay: 0.14s; }
        .loading-row:nth-child(3) { height: 46px; animation-delay: 0.28s; opacity: 0.78; }
        .loading-meter {
          position: relative; z-index: 1; height: 8px; border-radius: 999px; overflow: hidden;
          background: rgba(255,255,255,0.08); border: 1px solid rgba(255,255,255,0.08);
        }
        .loading-meter i {
          display: block; width: 46%; height: 100%; border-radius: inherit;
          background: linear-gradient(90deg, var(--blue-a), #a78ff2, var(--green));
          box-shadow: 0 0 18px rgba(86,188,255,0.45);
          animation: loading-meter 2.4s ease-in-out infinite;
        }
        @keyframes loading-drift {
          from { transform: translate3d(-18px, -8px, 0) scale(0.96); }
          to { transform: translate3d(18px, 10px, 0) scale(1.04); }
        }
        @keyframes loading-float {
          0%, 100% { transform: translateY(0) rotate(-2deg); }
          50% { transform: translateY(-5px) rotate(2deg); }
        }
        @keyframes loading-shimmer {
          to { background-position: calc(100% + 220px) 0, 0 0; }
        }
        @keyframes loading-meter {
          0% { transform: translateX(-100%); }
          55% { transform: translateX(75%); }
          100% { transform: translateX(230%); }
        }
        @keyframes loading-dots {
          0% { content: ""; }
          25% { content: "."; }
          50% { content: ".."; }
          75%, 100% { content: "..."; }
        }
        @media (prefers-reduced-motion: reduce) {
          .loading-card::before,
          .loading-mark,
          .loading-row,
          .loading-meter i,
          .loading-dots::after {
            animation: none;
          }
        }
        /* Entrance animation only on first paint — refreshes must not flicker. */
        body.loaded .card { animation: none; }
        @keyframes rise { from { opacity: 0; transform: translateY(10px); } }
        /* Arriving from a Discord deep link: mark what the DM was about, then
           fade back so the page does not stay decorated. */
        .route-focus {
          animation: routeFocus 2.6s ease-out both;
          border-radius: 14px;
        }
        @keyframes routeFocus {
          0%   { box-shadow: 0 0 0 0 rgba(86, 188, 255, 0.0); }
          12%  { box-shadow: 0 0 0 3px rgba(86, 188, 255, 0.55); }
          70%  { box-shadow: 0 0 0 3px rgba(86, 188, 255, 0.42); }
          100% { box-shadow: 0 0 0 0 rgba(86, 188, 255, 0.0); }
        }
        @media (prefers-reduced-motion: reduce) {
          .route-focus { animation: none; box-shadow: 0 0 0 3px rgba(86, 188, 255, 0.45); }
        }
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
        .global-priority-artwork { display: flex; flex-wrap: wrap; gap: 8px; }
        .global-priority-artwork img, .priority-art-more {
          width: 56px; height: 56px; flex: none; border-radius: 13px; object-fit: cover;
          border: 1px solid var(--glass-stroke); background: var(--field);
        }
        .priority-art-more {
          display: grid; place-items: center; color: var(--muted);
          font-size: 13px; font-weight: 700; background: rgba(255,255,255,0.05);
        }
        /* The strip carries both widths' tiles and both "+N" labels; only one
           set is ever on screen, so it refills as the column grows without a
           resize listener re-rendering the card. */
        @media (max-width: 679px) {
          .global-priority-artwork .priority-art-wide,
          .global-priority-artwork .priority-art-more.at-wide { display: none; }
        }
        @media (min-width: 680px) {
          .global-priority-artwork .priority-art-more.at-narrow { display: none; }
        }
        .modal-backdrop {
          position: fixed; inset: 0; z-index: 50; display: grid; place-items: center; padding: 24px;
          background: rgba(0,0,0,0.52); backdrop-filter: blur(8px); -webkit-backdrop-filter: blur(8px);
        }
        .modal-card {
          width: min(560px, 100%); max-height: min(700px, calc(100dvh - 48px)); overflow: auto;
          padding: 20px; border: 1px solid var(--glass-stroke); border-radius: 20px;
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
          box-shadow: 0 24px 72px rgba(0,0,0,0.46);
        }
        .modal-header { display: flex; align-items: flex-start; gap: 12px; margin-bottom: 16px; }
        .modal-header .copy { flex: 1; min-width: 0; }
        .modal-title { color: var(--text); font-size: 18px; font-weight: 700; }
        .modal-subtitle { margin-top: 3px; color: var(--muted); font-size: 13px; }
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
          width: 100%; color: var(--text); text-align: left; cursor: pointer; font: inherit; font-family: inherit;
          border: 1px solid var(--glass-stroke); border-radius: 12px; background: var(--field);
        }
        .pitem .rank { width: 22px; height: 22px; flex: none; border-radius: 7px; font-size: 11px; font-weight: 700;
                       display: grid; place-items: center; color: #fff;
                       background: linear-gradient(135deg, var(--blue-a), var(--blue-c)); }
        .pitem .pname { font-weight: 550; flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .exclusion-art { width: 30px; height: 40px; flex: none; border-radius: 7px; object-fit: cover;
                         border: 1px solid var(--glass-stroke); background: var(--bg-c); }
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
        .btn-danger {
          min-height: 40px; padding: 0 17px; color: #fff; border: 1px solid #ff716a;
          background: linear-gradient(180deg, #ef5149, #c92d27);
          box-shadow: 0 8px 18px rgba(201,45,39,0.28);
        }
        .btn-danger:not(:disabled):hover { filter: brightness(1.08); }
        .btn-danger-outline { color: #ff9b95; border-color: rgba(255,100,92,0.38); background: rgba(201,45,39,0.16); }
        .btn-danger-outline:hover { color: #fff; border-color: rgba(255,113,106,0.72); background: rgba(201,45,39,0.30); }
        .modal-actions { display: flex; justify-content: flex-end; gap: 10px; margin-top: 18px; }
        .modal-actions .btn-secondary { min-height: 40px; padding: 0 16px; }
        .removal-notice {
          display: flex; align-items: flex-start; gap: 10px; margin: 0 0 14px; padding: 13px 15px;
          color: #baf6ca; font-size: 13px; line-height: 1.4; border: 1px solid rgba(52,199,89,0.34);
          border-radius: 14px; background: rgba(52,199,89,0.13); box-shadow: inset 0 1px rgba(255,255,255,0.08);
        }
        .removal-notice strong { color: #e6ffec; }
        .detail-nav { margin: 0 0 14px; }
        .back-row { display: flex; align-items: center; gap: 10px; }
        .back-row .hero-info { min-width: 0; }
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
        .segmented { display: flex; flex-wrap: wrap; gap: 6px; }
        .segmented button {
          font: 650 12px/1 inherit; font-family: inherit; color: var(--muted); cursor: pointer;
          padding: 8px 10px; border-radius: 999px; border: 1px solid var(--glass-stroke);
          background: transparent;
        }
        .segmented button.active {
          color: var(--text); border-color: rgba(86,188,255,0.38);
          background: rgba(86,188,255,0.13);
        }

        .diagnostic-grid { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 9px; }
        .diagnostic-stat {
          padding: 10px; border-radius: 11px; border: 1px solid var(--glass-stroke); background: var(--field);
          min-width: 0;
        }
        .diagnostic-stat .v { font-size: 13px; font-weight: 700; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .diagnostic-stat .k { font-size: 10px; color: var(--muted); text-transform: uppercase; letter-spacing: 0.08em; margin-top: 4px; }
        .signal-list { display: flex; flex-direction: column; gap: 7px; margin-top: 12px; }
        .signal-row { display: flex; gap: 8px; align-items: flex-start; font-size: 13px; color: var(--muted); }
        .signal-dot { width: 7px; height: 7px; border-radius: 50%; background: var(--orange); flex: 0 0 auto; margin-top: 5px; }
        .event-list { display: flex; flex-direction: column; gap: 9px; margin-top: 12px; }
        .event-row { display: flex; gap: 9px; align-items: flex-start; padding-top: 9px; border-top: 1px solid var(--glass-stroke); }
        .event-row:first-child { border-top: none; padding-top: 0; }
        .event-type { font-size: 11px; font-weight: 700; color: var(--text); }
        .event-summary { font-size: 13px; color: var(--muted); line-height: 1.35; }
        @media (max-width: 560px) {
          .diagnostic-grid { grid-template-columns: 1fr; }
        }
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
        .campaign-gate {
          flex: none; padding: 5px 9px; border-radius: 999px; font-size: 11px; font-weight: 700;
          color: #ff7ac8; background: rgba(255, 55, 165, 0.11); border: 1px solid rgba(255, 55, 165, 0.28);
        }
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
          box-shadow: 0 10px 26px rgba(0,0,0,0.26);
          backdrop-filter: blur(20px) saturate(1.4); -webkit-backdrop-filter: blur(20px) saturate(1.4);
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
        .up-to-date-state {
          display: flex; align-items: center; gap: 12px; padding: 14px;
          border: 1px solid rgba(52,199,89,0.28); border-radius: 12px;
          background: rgba(52,199,89,0.10);
        }
        .up-to-date-icon {
          width: 28px; height: 28px; flex: none; display: grid; place-items: center;
          color: var(--green); border-radius: 50%; background: rgba(52,199,89,0.16);
        }
        .up-to-date-icon svg { width: 18px; height: 18px; }
        .up-to-date-title { color: var(--text); font-size: 14px; font-weight: 700; }
        .up-to-date-detail { margin-top: 2px; color: var(--muted); font-size: 12px; }
        /* Your priorities: an ordered queue. The rank is the point, so it leads
           each row, and the row itself stays a row — not a card. */
        .priority-rows { list-style: none; margin: 9px 0 0; padding: 0; }
        .priority-row {
          display: flex; align-items: center; gap: 11px; padding: 6px 8px 6px 4px; border-radius: 11px;
          border: 1px solid transparent;
        }
        .priority-row + .priority-row { margin-top: 2px; }
        .priority-row:hover { background: rgba(255,255,255,0.04); }
        .priority-row.dragging { opacity: 0.45; }
        .priority-row.drag-over { border-color: rgba(145,70,255,0.55); background: rgba(145,70,255,0.10); }
        .priority-rank {
          flex: none; width: 20px; text-align: center; color: var(--muted);
          font-size: 12px; font-weight: 700; font-variant-numeric: tabular-nums;
        }
        .priority-row-art {
          width: 30px; height: 30px; flex: none; border-radius: 8px; object-fit: cover;
          border: 1px solid var(--glass-stroke); background: var(--field);
        }
        .priority-row-name { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13.5px; font-weight: 600; }
        .priority-row-btn {
          flex: none; display: inline-grid; width: 26px; height: 26px; place-items: center;
          padding: 0; border: 0; border-radius: 7px; cursor: pointer;
          color: var(--muted); background: transparent;
        }
        .priority-row-btn svg { width: 14px; height: 14px; }
        .priority-row-btn:hover { color: var(--text); background: rgba(255,255,255,0.08); }
        .priority-row-btn:focus-visible { outline: 2px solid rgba(145,70,255,0.5); outline-offset: 1px; }

        /* Row actions rest behind a menu: the list should read as a ranking,
           not as a row of buttons repeated once per game. */
        .priority-row { position: relative; }
        .row-menu {
          position: absolute; right: 6px; top: calc(100% - 4px); z-index: 30; min-width: 208px;
          display: flex; flex-direction: column; padding: 5px; border-radius: 12px;
          border: 1px solid var(--glass-stroke); background: rgba(32, 26, 54, 0.98);
          box-shadow: 0 16px 38px rgba(0,0,0,0.46);
        }
        .row-menu-item {
          display: flex; align-items: center; gap: 9px; padding: 8px 10px; border: 0; border-radius: 8px;
          color: var(--text); text-align: left; background: transparent; cursor: pointer;
          font: 550 13px/1.2 inherit; font-family: inherit;
        }
        .row-menu-item svg { width: 14px; height: 14px; flex: none; opacity: 0.8; }
        .row-menu-item:hover:not([disabled]) { background: rgba(145,70,255,0.20); }
        .row-menu-item:focus-visible { outline: 2px solid rgba(145,70,255,0.5); outline-offset: -2px; }
        .row-menu-item[disabled] { opacity: 0.34; cursor: default; }
        .row-menu-item.danger { color: #ff9b95; }
        .row-menu-item.danger:hover:not([disabled]) { background: rgba(201,45,39,0.24); }
        .row-menu-sep { height: 1px; margin: 4px 6px; background: var(--glass-stroke); }
        .priority-empty { padding: 8px 0 2px; color: var(--muted); font-size: 13px; }

        /* Adding is one quiet line until it is actually being used. */
        .priority-add {
          display: inline-flex; align-items: center; gap: 7px; margin-top: 8px;
          padding: 6px 10px 6px 7px; border: 1px dashed var(--glass-stroke); border-radius: 10px;
          color: var(--muted); background: transparent; cursor: pointer;
          font: 600 13px/1 inherit; font-family: inherit;
        }
        .priority-add:hover { color: var(--text); border-color: rgba(145,70,255,0.45); }
        .priority-add-plus { font-size: 15px; line-height: 1; }
        .priority-add-open { display: flex; gap: 8px; margin-top: 9px; }
        .priority-add-open input {
          flex: 1; min-width: 0; font: 14px inherit; font-family: inherit; color: var(--text);
          padding: 9px 12px; border-radius: 10px; background: var(--field);
          border: 1px solid var(--field-stroke); outline: none;
        }
        .priority-add-open input:focus { border-color: rgba(145,70,255,0.6); box-shadow: 0 0 0 3px rgba(145,70,255,0.16); }
        .priority-add-cancel {
          flex: none; padding: 0 11px; border: 1px solid var(--glass-stroke); border-radius: 10px;
          color: var(--muted); background: transparent; cursor: pointer; font: 600 12px/1 inherit; font-family: inherit;
        }
        .priority-add-cancel:hover { color: var(--text); }
        .priority-results { display: flex; flex-direction: column; margin-top: 6px; max-height: 232px; overflow-y: auto; }
        .priority-result {
          display: flex; align-items: center; gap: 11px; padding: 6px 8px; border: 0; border-radius: 9px;
          color: inherit; text-align: left; background: transparent; cursor: pointer; font: inherit; font-family: inherit;
        }
        .priority-result:hover, .priority-result:focus-visible { background: rgba(145,70,255,0.14); outline: none; }

        /* Miner detail: a quiet, single-column account view rather than a dashboard. */
        .miner-detail { display: flex; flex-direction: column; gap: 18px; padding-bottom: 6px; }
        .miner-detail > * { margin: 0; }
        .detail-back {
          display: inline-flex; align-items: center; gap: 6px; min-height: 30px;
          padding: 5px 9px; border: 1px solid var(--glass-stroke); border-radius: 9px; color: var(--muted); background: transparent;
          font: 600 13px/1 inherit; font-family: inherit; cursor: pointer;
        }
        .detail-back:hover { color: var(--text); }
        .detail-back:focus-visible, .text-action:focus-visible,
        .status-refresh:focus-visible { outline: 3px solid rgba(145,70,255,0.42); outline-offset: 3px; }
        /* Account header: prominent, but a row rather than a full screen of
           centred whitespace, so the status card starts above the fold. */
        .miner-identity {
          display: flex; align-items: center; gap: 16px; padding: 13px 18px; border-radius: 18px;
          border: 1px solid rgba(145,70,255,0.24);
          background: linear-gradient(135deg, rgba(145,70,255,0.16), rgba(145,70,255,0.05));
          box-shadow: 0 10px 26px rgba(0,0,0,0.24);
        }
        .miner-avatar {
          width: 64px; height: 64px; flex: none; overflow: hidden; border-radius: 50%;
          display: grid; place-items: center; color: #d9cffb; background: rgba(145,70,255,0.20);
          border: 1px solid rgba(145,70,255,0.32); font-size: 22px; font-weight: 700;
        }
        .miner-avatar img { width: 100%; height: 100%; object-fit: cover; }
        .miner-avatar svg { width: 30px; height: 30px; }
        .miner-identity-copy { min-width: 0; flex: 1; }
        .miner-identity h2 { margin: 0; font-size: 22px; letter-spacing: -0.03em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .miner-handle { display: flex; align-items: center; gap: 5px; margin: 3px 0 0; color: var(--muted); font-size: 13px; }
        .miner-handle svg { width: 12px; height: 12px; flex: none; color: #a970ff; }
        .miner-linked { display: flex; align-items: center; gap: 6px; margin: 4px 0 0; color: var(--muted); font-size: 12.5px; }
        .miner-linked::before { content: ""; display: block; width: 7px; height: 7px; flex: none; border-radius: 50%; background: var(--green); box-shadow: 0 0 0 3px rgba(52,199,89,0.18); }
        .miner-linked.unlinked::before { background: var(--orange); box-shadow: 0 0 0 3px rgba(255,159,10,0.18); }
        .text-action { border: 0; padding: 7px 2px; border-radius: 7px; color: #c8b4ff; background: transparent; cursor: pointer; font: 600 13px/1 inherit; font-family: inherit; }
        .text-action:hover { color: #e3d9ff; }
        .empty-activity { padding: 7px 0 1px; color: var(--muted); font-size: 13px; }
        .operator-miner-avatar { width: 42px; height: 42px; flex: none; overflow: hidden; display: grid; place-items: center; border: 1px solid rgba(145,70,255,.30); border-radius: 50%; color: #d9cffb; background: rgba(145,70,255,.16); }
        .operator-miner-avatar img { width: 100%; height: 100%; object-fit: cover; }
        .operator-miner-avatar svg { width: 20px; height: 20px; }

        /* Current status: the one card that is allowed to shout. */
        .status-card { display: flex; flex-direction: column; gap: 13px; border-left: 3px solid var(--status-color, var(--green)); }
        .status-head { display: flex; align-items: flex-start; gap: 13px; }
        .status-head .status-icon-container { width: 42px; height: 42px; background: color-mix(in srgb, var(--status-color) 15%, transparent); box-shadow: none; }
        .status-card-copy { flex: 1; min-width: 0; }
        .status-card-copy h3 { margin: 2px 0 4px; font-size: 18px; letter-spacing: -0.015em; }
        .status-card-copy p { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.4; }
        /* Up to date is status information, not a feature section: one slim
           strip, tall enough to read and no taller. */
        .status-strip { flex-direction: row; align-items: center; gap: 12px; padding: 12px 16px 12px 14px; }
        .status-strip-icon {
          width: 30px; height: 30px; flex: none; display: grid; place-items: center; border-radius: 50%;
          background: color-mix(in srgb, var(--status-color) 15%, transparent);
        }
        .status-strip-icon .status-svg { width: 17px; height: 17px; }
        .status-strip-copy { flex: 1; min-width: 0; }
        .status-strip-copy h3 { margin: 0; font-size: 15px; letter-spacing: -0.015em; }
        .status-strip-copy p {
          margin: 2px 0 0; color: var(--muted); font-size: 12.5px; line-height: 1.35;
          overflow: hidden; text-overflow: ellipsis; white-space: nowrap;
        }

        /* Refresh is a way back to a fresh reading, not the point of the card. */
        .status-refresh {
          flex: none; display: inline-flex; align-items: center; gap: 6px;
          min-height: 32px; padding: 0 12px; font-size: 12px;
        }
        .refresh-glyph { width: 13px; height: 13px; flex: none; opacity: 0.75; }

        /* Section chrome shared by Up Next, Priorities and Completed Drops. */
        .section-card { display: flex; flex-direction: column; gap: 13px; }
        .section-head { display: flex; align-items: center; gap: 11px; }
        .section-icon { display: inline-grid; width: 34px; height: 34px; flex: none; place-items: center; border-radius: 11px; color: #c8b4ff; background: rgba(145,70,255,0.15); }
        .section-icon svg { width: 17px; height: 17px; }
        .section-title { flex: 1; min-width: 0; display: flex; align-items: center; gap: 9px; flex-wrap: wrap; }
        .section-title h3 { margin: 0; font-size: 16px; letter-spacing: -0.015em; }
        .section-note { color: var(--muted); font-size: 12px; font-weight: 600; white-space: nowrap; }
        .section-foot { display: flex; justify-content: flex-end; margin-top: -5px; }
        /* Currently mining / Up next: the same card in its featured shape, led
           by an eyebrow instead of a status headline because the artwork and
           title already say what the state is. */
        .state-head { display: flex; align-items: center; gap: 12px; }
        .state-eyebrow { flex: 1; min-width: 0; color: var(--muted); font-size: 11px; font-weight: 700; letter-spacing: 0.09em; text-transform: uppercase; }
        /* Only the live state borrows the status colour — a queued campaign in
           green would read as something already achieved. */
        .state-eyebrow.live { color: var(--status-color, var(--green)); }
        .state-feature { display: flex; align-items: center; gap: 14px; }
        .state-art {
          width: 52px; height: 69px; flex: none; border-radius: 10px; object-fit: cover;
          border: 1px solid var(--glass-stroke); background: linear-gradient(135deg, var(--bg-c), var(--bg-b));
          box-shadow: 0 8px 20px rgba(0,0,0,0.30);
        }
        .state-feature-copy { flex: 1; min-width: 0; }
        .state-title { font-size: 18px; font-weight: 700; letter-spacing: -0.015em; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
        .state-bar-row { display: flex; align-items: center; gap: 12px; margin: 10px 0 7px; }
        .state-bar-row .bar { flex: 1; min-width: 0; margin: 0; }
        .state-pct { flex: none; font-size: 13px; font-weight: 700; color: var(--blue-a); font-variant-numeric: tabular-nums; }
        .state-pct.done { color: var(--green); }
        .state-meta { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; color: var(--muted); font-size: 12px; }
        .state-progress { color: var(--blue-a); font-size: 13px; font-weight: 650; }
        .state-progress.done { color: var(--green); }
        .state-watching { flex: none; display: flex; align-items: center; gap: 6px; }
        .state-watching::before { content: ""; width: 6px; height: 6px; border-radius: 50%; background: var(--status-color, var(--green)); }
        .state-art { width: 60px; height: 80px; }
        .state-detail { margin-top: 3px; color: var(--muted); font-size: 12px; }
        .state-checked { color: var(--muted); font-size: 11.5px; }

        /* Priorities: one card for source, the shared list and this miner's own. */
        .priorities-card { gap: 13px; }
        .priorities-card .section-head { align-items: flex-start; }
        .priorities-card .section-title { padding-top: 7px; }
        .priorities-body { display: flex; flex-direction: column; gap: 12px; }
        .priorities-explainer { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.45; }
        /* The source is a compact control, not a panel: a label and one button
           that opens a layer. Nothing here grows when it is used. */
        .priority-source { position: relative; flex: none; display: flex; flex-direction: column; align-items: flex-end; gap: 5px; }
        .priority-source-label { color: var(--muted); font-size: 10.5px; font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; }
        .priority-source-btn, .priority-source-static {
          display: inline-flex; align-items: center; gap: 7px; min-height: 32px; padding: 0 10px;
          border: 1px solid var(--glass-stroke); border-radius: 10px; color: var(--text);
          background: linear-gradient(180deg, var(--glass-top), var(--glass-bottom));
          font: 650 13px/1 inherit; font-family: inherit;
        }
        .priority-source-btn { cursor: pointer; }
        .priority-source-btn:hover, .priority-source-btn[aria-expanded="true"] { border-color: rgba(145,70,255,0.45); }
        .priority-source-btn:focus-visible { outline: 2px solid rgba(145,70,255,0.5); outline-offset: 2px; }
        .priority-source-icon { flex: none; display: inline-grid; width: 16px; height: 16px; place-items: center; color: #c8b4ff; }
        .priority-source-icon svg { width: 16px; height: 16px; }
        .priority-source-name { white-space: nowrap; }
        .priority-source-caret { flex: none; display: inline-grid; width: 13px; height: 13px; place-items: center; color: var(--muted); }
        .priority-source-caret svg { width: 13px; height: 13px; }
        /* The menu floats over the page. Every card is its own stacking context
           (they all carry a backdrop filter), so the card is lifted while the
           menu is open — otherwise Recent Completed Drops would paint over it. */
        .priorities-card.menu-open { position: relative; z-index: 70; }
        .source-menu {
          position: absolute; top: calc(100% + 8px); right: 0; z-index: 70; width: 296px; max-width: 78vw;
          display: flex; flex-direction: column; gap: 2px; padding: 6px; border-radius: 14px;
          border: 1px solid var(--glass-stroke); background: rgba(32, 26, 54, 0.98);
          box-shadow: 0 20px 44px rgba(0,0,0,0.50);
          backdrop-filter: blur(20px) saturate(1.4); -webkit-backdrop-filter: blur(20px) saturate(1.4);
        }
        .source-option {
          display: flex; align-items: flex-start; gap: 9px; padding: 9px 10px; border-radius: 10px;
          border: 1px solid transparent; color: var(--text); text-align: left;
          background: transparent; cursor: pointer; font: inherit; font-family: inherit;
        }
        .source-option:hover { background: rgba(255,255,255,0.05); }
        .source-option.active { border-color: rgba(145,70,255,0.42); background: rgba(145,70,255,0.14); }
        .source-option:focus-visible { outline: 2px solid rgba(145,70,255,0.5); outline-offset: -2px; }
        .source-option-icon { flex: none; display: inline-grid; width: 17px; height: 17px; margin-top: 1px; place-items: center; color: #c8b4ff; }
        .source-option-icon svg { width: 15px; height: 15px; }
        .source-option-copy { flex: 1; min-width: 0; }
        .source-option-name { display: block; font-size: 13px; font-weight: 650; }
        .source-option-detail { display: block; margin-top: 2px; color: var(--muted); font-size: 11.5px; line-height: 1.35; }
        .source-option-check { flex: none; display: inline-grid; width: 15px; height: 15px; margin-top: 2px; place-items: center; color: #c8b4ff; }
        .source-option-check svg { width: 14px; height: 14px; }
        /* Artwork is the anchor: a spaced row of tiles with the count and the
           attribution directly beneath it, so the two read as one block. */
        .priority-preview { display: flex; flex-direction: column; gap: 9px; }
        /* Count then attribution, stacked: the count already uses a middle dot
           in the hybrid case, so a second one between them would read as part
           of the same list. */
        .priority-preview-meta { display: flex; flex-direction: column; gap: 2px; }
        .priority-preview-count { font-size: 13.5px; font-weight: 650; }
        .priority-preview-attribution { color: var(--muted); font-size: 12.5px; }
        .priority-personal { border-top: 1px solid var(--glass-stroke); padding-top: 14px; }
        .priority-personal-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
        .priority-personal-label { color: var(--muted); font-size: 11px; font-weight: 700; letter-spacing: 0.07em; text-transform: uppercase; }
        .priority-exclusions { border-top: 1px solid var(--glass-stroke); padding-top: 14px; }
        .priority-exclusions-head { display: flex; align-items: center; justify-content: space-between; gap: 12px; }
        .priority-exclusions-head .text-action { padding: 2px 0; }
        .priority-exclusions-detail { margin-top: 4px; color: var(--muted); font-size: 12.5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }

        /* Actionable exceptions: amber rather than purple, but no status accent
           bar — Current Status stays the loudest thing on the page. */
        .exception-card { border-color: rgba(255,159,10,0.24); }
        .exception-card .section-icon { color: var(--orange); background: rgba(255,159,10,0.14); }
        .exception-card .section-note { color: var(--orange); }

        /* Recent completed drops: a short receipt, not a history table. */
        .completed-row { display: flex; align-items: center; gap: 12px; padding: 8px 0; border-top: 1px solid var(--glass-stroke); }
        .completed-row:first-child { border-top: none; padding-top: 0; }
        .completed-row:last-child { padding-bottom: 0; }
        .completed-art { width: 38px; height: 50px; flex: none; border-radius: 8px; object-fit: cover; border: 1px solid var(--glass-stroke); background: var(--field); }
        .completed-copy { flex: 1; min-width: 0; }
        .completed-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13.5px; font-weight: 600; }
        .completed-when { margin-top: 2px; color: var(--muted); font-size: 11.5px; }
        /* Tally and check share a fixed right-hand column so the rows line up
           however wide the titles run. */
        .completed-tally { flex: none; min-width: 46px; text-align: right; color: var(--muted); font-size: 12.5px; font-weight: 650; font-variant-numeric: tabular-nums; }
        .completed-check { width: 19px; height: 19px; flex: none; display: grid; place-items: center; border-radius: 50%; color: var(--green); background: rgba(52,199,89,0.16); }
        .completed-check svg { width: 12px; height: 12px; }
        .completed-list { display: flex; flex-direction: column; }

        /* Account removal: a danger-zone row at the foot of the page. Red is
           spent on the icon, the label and the button — the surface itself
           stays quieter than the cards it sits under. */
        .danger-row {
          display: flex; align-items: center; gap: 12px; padding: 12px 16px;
          border: 1px solid rgba(201,45,39,0.22); border-radius: 14px;
          background: rgba(255,255,255,0.02);
        }
        .danger-row-icon { flex: none; display: inline-grid; width: 22px; height: 22px; place-items: center; color: #ff8a83; }
        .danger-row-icon svg { width: 20px; height: 20px; }
        .danger-row-copy { flex: 1; min-width: 0; }
        .danger-row-copy h3 { margin: 0; font-size: 13.5px; font-weight: 650; letter-spacing: -0.01em; color: #ff8a83; }
        .danger-row-copy p { margin: 2px 0 0; color: var(--muted); font-size: 12px; line-height: 1.4; }
        .danger-row .btn-danger-outline { flex: none; min-height: 30px; padding: 0 12px; font-size: 12px; }
        /* Still used by the operator overview's per-miner rows. */
        .danger-card { border-color: rgba(201,45,39,0.34); background: rgba(60, 20, 26, 0.42); }
        .danger-card .section-icon { color: #ff8a83; background: rgba(201,45,39,0.18); }
        .danger-card .section-title h3 { color: #ff8a83; }

        .portal-footer {
          display: flex; flex-wrap: wrap; justify-content: center; gap: 6px 10px;
          padding: 30px 4px 6px; color: rgba(255,255,255,0.34); font-size: 12px;
        }
        .portal-footer a { color: rgba(255,255,255,0.44); text-decoration: none; }
        .portal-footer a:hover { color: var(--muted); text-decoration: underline; }
        .portal-footer .sep { color: rgba(255,255,255,0.20); }

        @media (max-width: 620px) {
          body { padding: 0 14px 48px; }
          /* Narrow enough that one line would drop "Checked …" entirely. */
          .status-strip-copy p { white-space: normal; }
          /* The source control drops under the title rather than squeezing it. */
          .priorities-card .section-head { flex-wrap: wrap; }
          .priorities-card .section-title { padding-top: 0; }
          .priority-source { width: 100%; flex-direction: row; align-items: center; gap: 9px; }
          .source-menu { right: auto; left: 0; }
          .danger-row { align-items: flex-start; flex-wrap: wrap; }
        }
        @media (max-width: 420px) {
          /* Five slots have to fit the phone column without wrapping. */
          .global-priority-artwork img, .priority-art-more { width: 50px; height: 50px; border-radius: 12px; }
          /* The countdown should not break across lines to make room for the
             channel name; stack them instead. */
          .state-meta { flex-direction: column; align-items: flex-start; gap: 4px; }
          .boxart { width: 54px; height: 72px; }
          .card { padding: 14px; border-radius: 16px; }
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
          <span id="navback"></span>
          <span class="spacer"></span>
          <div class="account-menu">
            <button class="account-menu-btn" id="accountmenubtn" type="button"
                    aria-haspopup="menu" aria-expanded="false" aria-label="Account menu">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="3.4"></circle><path d="M4.6 20a7.6 7.6 0 0 1 14.8 0"></path></svg>
              <svg class="account-menu-caret" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m6 9 6 6 6-6"></path></svg>
            </button>
            <div class="account-menu-pop" id="accountmenu" role="menu" aria-label="Account" hidden>
              <button class="account-menu-item" id="signout" type="button" role="menuitem">Sign out</button>
            </div>
          </div>
        </header>
        <div id="app">
          <div class="card loading-card" role="status" aria-live="polite">
            <div class="loading-hero">
              <div class="loading-mark" aria-hidden="true"></div>
              <div class="loading-copy">
                <h2 class="loading-title">Warming up SwiftMiner</h2>
                <p class="loading-status"><span id="loading-copy">Checking miner link</span><span class="loading-dots" aria-hidden="true"></span></p>
              </div>
            </div>
            <div class="loading-meter" aria-hidden="true"><i></i></div>
            <div class="loading-skeleton" aria-hidden="true">
              <div class="loading-row"></div>
              <div class="loading-row"></div>
              <div class="loading-row"></div>
            </div>
          </div>
        </div>
        <footer class="portal-footer">
          <span id="footer-meta">SwiftMiner</span>
          <span class="sep" aria-hidden="true">·</span>
          <a href="https://swiftminer.app/help/security-privacy/" target="_blank" rel="noreferrer">Privacy</a>
          <span class="sep" aria-hidden="true">·</span>
          <a href="https://swiftminer.app/help/" target="_blank" rel="noreferrer">Support</a>
        </footer>
      </div>
      <script src="/app/app.js?v=\(assetVersion)"></script>
    </body>
    </html>
    """

}
