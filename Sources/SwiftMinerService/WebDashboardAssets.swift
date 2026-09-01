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
        .global-priorities-link {
          display: flex; align-items: center; width: 100%; gap: 12px; padding: 0;
          color: inherit; text-align: left; cursor: pointer; border: none; background: transparent;
        }
        .global-priority-artwork { display: flex; flex: none; }
        .global-priority-artwork img {
          width: 38px; height: 52px; margin-left: -10px; border-radius: 8px; object-fit: cover;
          border: 2px solid var(--glass-stroke); background: var(--field);
        }
        .global-priority-artwork img:first-child { margin-left: 0; }
        .global-priority-copy { min-width: 0; flex: 1; }
        .global-priority-title { color: var(--text); font-size: 14px; font-weight: 650; }
        .global-priority-detail { margin-top: 3px; color: var(--muted); font-size: 12px; }
        .global-priority-chevron { color: var(--muted); font-size: 20px; line-height: 1; }
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
        .priority-source .segmented { display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); }
        .priority-source .segmented button { min-width: 0; }
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

        /* Miner detail: a quiet, single-column account view rather than a dashboard. */
        .miner-detail { display: flex; flex-direction: column; gap: 18px; padding-bottom: 18px; }
        .miner-detail > * { margin: 0; }
        .detail-back {
          align-self: flex-start; display: inline-flex; align-items: center; gap: 6px; min-height: 34px;
          padding: 6px 2px; border: 0; border-radius: 8px; color: var(--muted); background: transparent;
          font: 600 13px/1 inherit; font-family: inherit; cursor: pointer;
        }
        .detail-back:hover { color: var(--text); }
        .detail-back:focus-visible, .text-action:focus-visible, .action-link:focus-visible,
        .status-refresh:focus-visible, .priority-summary:focus-visible { outline: 3px solid rgba(145,70,255,0.42); outline-offset: 3px; }
        .miner-identity { text-align: center; padding: 8px 0 10px; }
        .miner-avatar {
          width: 92px; height: 92px; margin: 0 auto 12px; overflow: hidden; border-radius: 50%;
          display: grid; place-items: center; color: #d9cffb; background: rgba(145,70,255,0.16);
          border: 1px solid rgba(145,70,255,0.28); font-size: 28px; font-weight: 700;
        }
        .miner-avatar img { width: 100%; height: 100%; object-fit: cover; }
        .miner-identity h2 { margin: 0; font-size: 30px; letter-spacing: -0.04em; }
        .miner-handle { margin: 4px 0 0; color: var(--muted); font-size: 14px; }
        .miner-linked { margin: 5px 0 0; color: var(--muted); font-size: 13px; }
        .miner-linked::before { content: ""; display: inline-block; width: 7px; height: 7px; margin: 0 6px 1px 0; border-radius: 50%; background: var(--green); }
        .miner-linked.unlinked::before { background: var(--orange); }
        .status-panel {
          display: flex; align-items: flex-start; gap: 14px; padding: 17px 18px; border-radius: 16px;
          background: rgba(255,255,255,0.055); border: 1px solid var(--glass-stroke);
          border-left: 3px solid var(--status-color, var(--green)); box-shadow: 0 12px 28px rgba(0,0,0,0.16);
        }
        .status-panel .status-icon-container { width: 40px; height: 40px; background: color-mix(in srgb, var(--status-color) 14%, transparent) !important; box-shadow: none; }
        .status-panel-copy { flex: 1; min-width: 0; }
        .status-panel h3 { margin: 1px 0 4px; font-size: 17px; letter-spacing: -0.015em; }
        .status-panel p { margin: 0; color: var(--muted); font-size: 13px; line-height: 1.4; }
        .status-progress { margin-top: 12px; }
        .status-refresh { flex: none; min-height: 34px; padding: 0 11px; }
        .miner-details {
          display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); border: 1px solid var(--glass-stroke);
          border-radius: 14px; background: rgba(255,255,255,0.025); overflow: hidden;
        }
        .miner-detail-item { padding: 12px 15px; min-width: 0; }
        .miner-detail-item + .miner-detail-item { border-left: 1px solid var(--glass-stroke); }
        .miner-detail-key { color: var(--muted); font-size: 10px; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; }
        .miner-detail-value { margin-top: 5px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 600; }
        .detail-section { border-top: 1px solid var(--glass-stroke); padding-top: 17px; }
        .detail-section-header { display: flex; align-items: center; justify-content: space-between; gap: 12px; margin-bottom: 9px; }
        .detail-section-title { display: flex; align-items: center; gap: 8px; margin: 0; font-size: 15px; letter-spacing: -0.01em; }
        .detail-section-icon { display: inline-grid; width: 25px; height: 25px; place-items: center; border-radius: 8px; color: #c8b4ff; background: rgba(145,70,255,.13); }
        .detail-section-icon svg { width: 15px; height: 15px; }
        .text-action { border: 0; padding: 7px 2px; border-radius: 7px; color: #c8b4ff; background: transparent; cursor: pointer; font: 600 13px/1 inherit; font-family: inherit; }
        .text-action:hover { color: #e3d9ff; }
        .priority-summary { width: 100%; display: flex; align-items: center; gap: 12px; padding: 12px 0 0; border: 0; color: inherit; text-align: left; background: transparent; cursor: pointer; }
        .priority-summary-copy { flex: 1; min-width: 0; }
        .priority-mode { font-size: 13px; font-weight: 650; }
        .priority-description { margin-top: 3px; color: var(--muted); font-size: 12px; line-height: 1.35; }
        .activity-list { border-top: 1px solid var(--glass-stroke); }
        .activity-row { display: flex; align-items: center; gap: 10px; padding: 11px 0; border-bottom: 1px solid var(--glass-stroke); }
        .activity-art, .activity-state { flex: none; display: grid; place-items: center; }
        .activity-art { width: 34px; height: 44px; overflow: hidden; border: 1px solid var(--glass-stroke); border-radius: 8px; background: var(--field); }
        .activity-art img { width: 100%; height: 100%; object-fit: cover; }
        .activity-state { width: 22px; height: 22px; margin-left: -19px; margin-top: 25px; color: var(--green); border: 2px solid var(--bg-b); border-radius: 50%; background: rgba(52,199,89,.18); }
        .activity-state svg { width: 12px; height: 12px; }
        .activity-copy { flex: 1; min-width: 0; }
        .activity-title { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 650; }
        .activity-subtitle { overflow: hidden; margin-top: 2px; color: var(--muted); text-overflow: ellipsis; white-space: nowrap; font-size: 12px; }
        .activity-time { flex: none; color: var(--muted); font-size: 11px; }
        .empty-activity { padding: 7px 0 1px; color: var(--muted); font-size: 13px; }
        .completed-count { color: var(--muted); font-size: 12px; font-weight: 600; white-space: nowrap; }
        .operator-miner-avatar { width: 42px; height: 42px; flex: none; overflow: hidden; display: grid; place-items: center; border: 1px solid rgba(145,70,255,.30); border-radius: 50%; color: #d9cffb; background: rgba(145,70,255,.16); }
        .operator-miner-avatar img { width: 100%; height: 100%; object-fit: cover; }
        .operator-miner-avatar svg { width: 20px; height: 20px; }
        .account-actions { display: flex; justify-content: center; padding: 4px 0 0; }
        .action-link { border: 0; padding: 9px; border-radius: 8px; color: var(--muted); background: transparent; cursor: pointer; font: 600 13px/1 inherit; font-family: inherit; }
        .action-link:hover { color: var(--text); }

        @media (max-width: 420px) {
          .boxart { width: 54px; height: 72px; }
          .card { padding: 14px; border-radius: 16px; }
          .status-panel { flex-wrap: wrap; }
          .status-refresh { margin-left: 54px; }
          .miner-details { grid-template-columns: 1fr; }
          .miner-detail-item + .miner-detail-item { border-top: 1px solid var(--glass-stroke); border-left: 0; }
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
      </div>
      <script src="/app/app.js?v=\(assetVersion)"></script>
    </body>
    </html>
    """

}
