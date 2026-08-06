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
        .triage-toolbar {
          display: flex; flex-wrap: wrap; gap: 9px; align-items: center;
          margin: 0 0 14px; padding: 10px;
          border: 1px solid var(--glass-stroke); border-radius: 18px;
          background: rgba(255,255,255,0.045);
        }
        .triage-search {
          flex: 1 1 180px; min-width: 0; font: 14px inherit; font-family: inherit; color: var(--text);
          padding: 10px 12px; border-radius: 11px; background: var(--field); border: 1px solid var(--field-stroke); outline: none;
        }
        .triage-search:focus { border-color: var(--blue-a); box-shadow: 0 0 0 3px rgba(86,188,255,0.18); }
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
        .stat-icon-wrapper img {
          width: 100%; height: 100%; border-radius: inherit; object-fit: cover;
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
          .stats-row { grid-template-columns: 1fr; }
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

    static let appJS = """
    (() => {
    const $ = (id) => document.getElementById(id);
    let CSRF = null;
    let SESSION = null;
    let PROJ = null;          // last projection (user sessions)
    let CAMPAIGNS = [];
    let ACTIVATION = null;
    let activationTimer = null;
    let personal = [];        // editable personal priority list (working copy)
    let includeGlobalPriorities = true;
    let prioritySource = 'global';
    let globalPrioritiesModalOpen = false;
    let prioritiesModalOpen = false;
    let activityModalOpen = false;
    let OPERATOR_MINERS = [];
    let OPERATOR_STATE = { selectedMinerId: null, query: '', filter: 'all' };

    function startLoadingCopy() {
      const target = $('loading-copy');
      if (!target) return;
      const lines = [
        'Checking miner link',
        'Syncing campaign state',
        'Reading drop progress',
        'Finding the next best stream',
        'Polishing the control room'
      ];
      let idx = 0;
      window.setInterval(() => {
        const live = $('loading-copy');
        if (!live) return;
        idx = (idx + 1) % lines.length;
        live.textContent = lines[idx];
      }, 1800);
    }

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
    function shortDateTime(iso) {
      if (!iso) return '—';
      const d = new Date(iso);
      if (isNaN(d)) return '—';
      return d.toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' });
    }
    function healthConfig(d) {
      const h = d && d.health ? String(d.health) : '';
      if (h === 'mining') return { label: 'Mining', color: '#34c759' };
      if (h === 'blocked' || h === 'needsAuth' || h === 'stalled' || h === 'attention') return { label: h === 'stalled' ? 'Stalled' : 'Attention', color: '#ff9f0a' };
      if (h === 'recovering') return { label: 'Recovering', color: '#56bcff' };
      return { label: 'Idle', color: '#8e8e93' };
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
      const diagnostics = p.diagnostics || {};
      const hasAuthenticationIssue = (p.issues || []).some(is => /auth|link_account|account_not_linked/i.test(String(is.type || '') + ' ' + String(is.action || '')));
      if (diagnostics.isRunning === false && p.state !== 'notConfigured') {
        return {
          headline: 'Offline', subtitle: 'SwiftMiner is not currently running for this account.', color: '#8e8e93',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#8e8e93" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v10"></path><path d="M5.64 5.64a9 9 0 1 0 12.73 0"></path></svg>`
        };
      }
      if (diagnostics.isStalled || diagnostics.health === 'stalled') {
        return {
          headline: 'Error', subtitle: diagnostics.statusLabel || 'Mining has stopped making progress and needs attention.', color: '#ff453a',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#ff453a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"></circle><path d="M12 8v4"></path><path d="M12 16h.01"></path></svg>`
        };
      }
      if (p.state === 'active') {
        if (p.activeCampaign) {
          const streamer = p.activeCampaign.currentChannelName;
          return {
            headline: 'Mining',
            subtitle: streamer ? 'Watching ' + streamer + ' for ' + p.activeCampaign.game : 'Earning drops for ' + p.activeCampaign.game,
            color: '#34c759',
            icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#34c759" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
              <circle cx="12" cy="12" r="2"></circle>
              <path d="M16.24 7.76a6 6 0 0 1 0 8.49m-8.48-.01a6 6 0 0 1 0-8.49m11.31-2.82a10 10 0 0 1 0 14.14m-14.14 0a10 10 0 0 1 0-14.14"></path>
            </svg>`
          };
        } else {
          return {
            headline: 'Waiting for stream',
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
        const hasUnlinked = hasAuthenticationIssue;
        return {
          headline: hasUnlinked ? 'Authentication required' : 'Needs attention',
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
          headline: 'Authentication required',
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

    function progressStateCard(p, cfg, style = '') {
      const styleAttr = style ? ` style="${style}"` : '';
      if (p.activeCampaign) {
        const c = p.activeCampaign;
        const pr = c.progress || {};
        const pct = Math.max(0, Math.min(100, Number(pr.pct || 0)));
        const isCompleted = pct >= 100;
        const ends = endsIn(c.endsAt);
        const metaStatus = isCompleted
          ? '<span style="color:var(--green);font-weight:600;">Ready to claim!</span>'
          : `<span>Mining${ends ? ' · ' + ends : ''}</span>`;
        return `
          <div class="hero-progress"${styleAttr}>
            <div class="progress-header">
              <span class="progress-title">${esc(c.game)}</span>
              <span class="progress-pct" style="color: ${isCompleted ? 'var(--green)' : 'var(--blue-a)'}">${pct}%</span>
            </div>
            <div class="bar"><i style="width:${pct}%${isCompleted ? ';background:linear-gradient(90deg, var(--green), #30d158);box-shadow:0 0 12px rgba(52,199,89,0.45);' : ''}"></i></div>
            <div class="progress-meta">
              <span>${esc(pr.current || 0)} / ${esc(pr.required || 0)} ${esc(pr.unit || '')}</span>
              ${metaStatus}
            </div>
          </div>
        `;
      }

      if (p.state === 'idle') {
        return `
          <div class="up-to-date-state"${styleAttr}>
            <span class="up-to-date-icon" aria-hidden="true">
              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
                <circle cx="12" cy="12" r="9"></circle>
                <path d="m8 12 2.5 2.5L16.5 8.5"></path>
              </svg>
            </span>
            <div>
              <div class="up-to-date-title">Up to Date</div>
              <div class="up-to-date-detail">All currently available drops are completed.</div>
            </div>
          </div>
        `;
      }

      const title = cfg.headline;
      const meta = cfg.subtitle || 'Waiting for the next campaign update.';
      return `
        <div class="hero-progress"${styleAttr}>
          <div class="progress-header">
            <span class="progress-title">${esc(title)}</span>
            <span class="progress-pct" style="color:${cfg.color}">0%</span>
          </div>
          <div class="bar"><i style="width:0%;background:linear-gradient(90deg, ${cfg.color}, ${cfg.color});box-shadow:none"></i></div>
          <div class="progress-meta">
            <span>${esc(meta)}</span>
            <span>${esc(p.state || 'idle')}</span>
          </div>
        </div>
      `;
    }

    function heroStateCard(p) {
      const cfg = getStatusConfig(p);
      const accId = p.account && p.account.twitchAccountId ? String(p.account.twitchAccountId) : '';

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
            <div style="display:flex;align-items:center;gap:8px;margin-left:auto;flex-shrink:0">
              ${accId ? `<button class="btn-secondary refresh-btn" data-account-id="${esc(accId)}" style="padding: 6px 12px; font-size: 12px; height: 28px; line-height: 1; flex-shrink: 0;">Refresh</button>` : ''}
            </div>
          </div>
        </div>
      `;
    }

    function progressCard(p) {
      // The primary status panel already communicates the completed state and
      // offers Refresh. Repeating it below adds no new information.
      if (p.state === 'idle') return '';
      const cfg = getStatusConfig(p);
      return `<div class="card"><div class="label" style="margin-bottom:12px">Progress</div>${progressStateCard(p, cfg, 'background:transparent;border:none;padding:0')}</div>`;
    }

    function customProfileImageURL(...urls) {
      return urls.find((url) => {
        if (typeof url !== 'string' || !url.toLowerCase().startsWith('https://')) return false;
        const value = url.toLowerCase();
        return !value.includes('/xarth/404_user_') && !value.includes('discordapp.com/embed/avatars/');
      });
    }

    // Honours the account's picture source from the app, trying the other
    // service second so the dashboard resolves exactly as the app does.
    function accountProfileImageURL(acc) {
      return acc.prefersDiscordProfileImage
        ? customProfileImageURL(acc.discordProfileImageURL, acc.profileImageURL)
        : customProfileImageURL(acc.profileImageURL, acc.discordProfileImageURL);
    }

    function minerIdentity(p) {
      const acc = p.account || {};
      const twitchIcon = `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714ZM6 0 1.714 4.286V19.714H6.857V24l4.286-4.286h3.428L22.286 12V0Zm14.571 11.143-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714ZM11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714Z"/></svg>`;
      const profileImageURL = accountProfileImageURL(acc);
      const twitchAvatar = profileImageURL
        ? `<img src="${esc(profileImageURL)}" alt="" referrerpolicy="no-referrer">`
        : twitchIcon;
      return `
        <section class="miner-identity" aria-label="Twitch account">
          <div class="miner-avatar">${twitchAvatar}</div>
          <h2>${esc(acc.username || 'Twitch account')}</h2>
          <p class="miner-linked${acc.twitchAccountId ? '' : ' unlinked'}">${acc.twitchAccountId ? 'Twitch connected' : 'Twitch not connected'}</p>
        </section>
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

    function globalPriorityGames(p) {
      const source = p.prioritySource || (p.includesGlobalPriorityGames === false ? 'personal' : 'global');
      const personalSet = source === 'globalAndPersonal'
        ? new Set((p.personalPriorityGames || []).map(g => g.toLowerCase()))
        : new Set();
      return (p.priorityGames || []).filter(g => !personalSet.has(g.toLowerCase()));
    }

    function priorityArtworkURL(p, game) {
      const key = String(game || '').trim().toLowerCase();
      const url = p && p.priorityGameArtwork ? p.priorityGameArtwork[key] : '';
      return typeof url === 'string' && url.toLowerCase().startsWith('https://') ? url : '';
    }

    function globalCard(p) {
      const source = p.prioritySource || (p.includesGlobalPriorityGames === false ? 'personal' : 'global');
      if (source === 'personal') {
        return `<div class="card"><div class="label">Global priorities</div>
          <div class="muted" style="font-size:13px">This miner uses only its personal priorities.</div></div>`;
      }
      const global = globalPriorityGames(p);
      if (!global.length) return '';
      let artwork = '';
      global.slice(0, 4).forEach(g => { artwork += `<img alt="" data-game="${esc(g)}" data-art="${esc(priorityArtworkURL(p, g))}">`; });
      const detail = source === 'global'
        ? 'Used by this miner.'
        : 'Set by the operator for every miner. Personal priorities run first.';
      return `<div class="card"><div class="label">Global priorities</div>
        <button class="global-priorities-link" id="viewglobalpriorities" type="button" aria-label="View global priorities">
          <div class="global-priority-artwork">${artwork}</div>
          <div class="global-priority-copy">
            <div class="global-priority-title">View Global Priorities</div>
            <div class="global-priority-detail">${global.length} ${global.length === 1 ? 'game' : 'games'} · ${detail}</div>
          </div>
          <span class="global-priority-chevron" aria-hidden="true">›</span>
        </button></div>`;
    }

    function globalPrioritiesModal(p) {
      const games = globalPriorityGames(p);
      let rows = '';
      games.forEach((game, index) => {
        rows += `<div class="campaign-row">
          <img class="boxart" alt="" data-game="${esc(game)}" data-art="${esc(priorityArtworkURL(p, game))}">
          <div class="copy">
            <div class="title">${esc(game)}</div>
            <div class="details">Global priority ${index + 1}</div>
          </div>
        </div>`;
      });
      return `<div class="modal-backdrop" id="globalprioritiesmodal">
          <section class="modal-card" role="dialog" aria-modal="true" aria-labelledby="globalprioritiestitle" tabindex="-1">
            <div class="modal-header">
              <div class="copy">
                <div class="modal-title" id="globalprioritiestitle">Global Priorities</div>
                <div class="modal-subtitle">Shared by miners that use global priorities.</div>
              </div>
              <button class="btn-secondary" id="closeglobalpriorities" type="button">Close</button>
            </div>
            <div class="campaign-list">${rows || '<div class="muted">No global priorities have been selected.</div>'}</div>
          </section>
        </div>`;
    }

    function closeGlobalPrioritiesModal() {
      globalPrioritiesModalOpen = false;
      render(PROJ);
    }

    function wireGlobalPrioritiesModal() {
      const modal = $('globalprioritiesmodal');
      if (!modal) return;
      const dialog = modal.querySelector('[role="dialog"]');
      if (dialog) dialog.focus();
      $('closeglobalpriorities').addEventListener('click', closeGlobalPrioritiesModal);
      modal.addEventListener('click', (event) => {
        if (event.target === modal) closeGlobalPrioritiesModal();
      });
      modal.addEventListener('keydown', (event) => {
        if (event.key === 'Escape') closeGlobalPrioritiesModal();
      });
    }

    function hasMultipleConfiguredMiners(p) {
      return Number(p && p.configuredMinerCount || 0) > 1;
    }

    function personalCard(p) {
      const source = prioritySource || 'global';
      const helper = source === 'global'
        ? 'Use the operator’s shared priority list.'
        : source === 'globalAndPersonal'
          ? 'Use your priorities first, then the shared list.'
          : 'Use only the priorities for this miner.';
      const sourcePicker = hasMultipleConfiguredMiners(p) ? `
        <div class="priority-source toggle-copy" style="margin-bottom:12px">
          <span class="toggle-title">Priority Source</span>
          <div class="segmented" role="radiogroup" aria-label="Priority source" style="margin-top:8px">
            <button type="button" data-priority-source="global" class="${source === 'global' ? 'active' : ''}" role="radio" aria-checked="${source === 'global'}" title="Use global priorities">Global</button>
            <button type="button" data-priority-source="globalAndPersonal" class="${source === 'globalAndPersonal' ? 'active' : ''}" role="radio" aria-checked="${source === 'globalAndPersonal'}" title="Use global and personal priorities">Global + Personal</button>
            <button type="button" data-priority-source="personal" class="${source === 'personal' ? 'active' : ''}" role="radio" aria-checked="${source === 'personal'}" title="Use personal priorities">Personal</button>
          </div>
          <span class="muted" style="display:block;font-size:12px;margin-top:8px">${helper}</span>
        </div>` : '';
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
      const personalEditor = source === 'global' && hasMultipleConfiguredMiners(p)
        ? '<div class="muted" style="font-size:13px">Choose Global + Personal or Personal to edit this miner’s priorities.</div>'
        : `<div class="priorities-flow" id="priorities-flow">
            ${items || '<span class="muted" style="font-size:13px">No personal priorities yet — add a game below.</span>'}
          </div>
          <div class="addrow">
            <input id="addgame" placeholder="Add a game…" autocapitalize="words" autocomplete="off" list="gamesuggest">
            <button class="btn-primary" id="addbtn">Add</button>
          </div>
          <datalist id="gamesuggest"></datalist>`;
      return `<div class="card">
        <div class="label">Your priorities</div>
        ${sourcePicker}
        ${personalEditor}
        <div class="savemsg" id="savemsg"></div>
      </div>`;
    }

    function upNextCard(p) {
      const campaigns = CAMPAIGNS.filter(c => !c.requiresSubscription).slice(0, 6);
      if (!campaigns.length) return '';
      const accountId = p && p.account && p.account.twitchAccountId;
      let rows = '';
      for (const c of campaigns) {
        const active = c.status === 'available';
        const when = active ? endsIn(c.endsAt) : dateLabel(c.startsAt, 'starts');
        const gatedCount = Number(c.subscriptionRequiredDropCount || 0);
        const gatedDetail = gatedCount ? ` · ${gatedCount} ${gatedCount === 1 ? 'drop needs' : 'drops need'} sub` : '';
        rows += `<div class="campaign-row">
          <img class="boxart" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="copy">
            <div class="title">${esc(c.game)}</div>
            <div class="details">${esc(c.dropCount || 0)} drops${gatedDetail}${when ? ' · ' + esc(when) : ''}</div>
          </div>
          <button class="btn-secondary campaign-priority" data-game="${esc(c.game)}" ${accountId ? '' : 'disabled'}>${personal.some(g => g.toLowerCase() === String(c.game || '').toLowerCase()) ? 'Prioritised' : 'Prioritise'}</button>
        </div>`;
      }
      return `<div class="card"><div class="label">Up next</div><div class="campaign-list">${rows}</div>${accountId ? '' : '<div class="muted" style="font-size:12px;margin-top:10px">Link Twitch before setting priorities.</div>'}</div>`;
    }

    function subscriptionRequiredCard() {
      const campaigns = CAMPAIGNS.filter(c => c.requiresSubscription).slice(0, 6);
      if (!campaigns.length) return '';
      let rows = '';
      for (const c of campaigns) {
        const active = c.status === 'available';
        const when = active ? endsIn(c.endsAt) : dateLabel(c.startsAt, 'starts');
        const gatedCount = Number(c.subscriptionRequiredDropCount || c.dropCount || 0);
        rows += `<div class="campaign-row">
          <img class="boxart" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="copy">
            <div class="title">${esc(c.game)}</div>
            <div class="details">${gatedCount} ${gatedCount === 1 ? 'drop' : 'drops'} · Paid Twitch sub required${when ? ' · ' + esc(when) : ''}</div>
          </div>
          <span class="campaign-gate">Needs Sub</span>
        </div>`;
      }
      return `<div class="card"><div class="label">Subscription required</div><div class="campaign-list">${rows}</div></div>`;
    }

    function dropsCard(p) {
      const recents = p.recentCompletedCampaigns || [];
      const dropsThisWeek = Number(p.dropsClaimedThisWeek || 0);
      if (!recents.length && !dropsThisWeek) return '';
      let rows = '';
      for (const c of recents) {
        const title = c.campaignName && c.campaignName.toLowerCase() !== c.game.toLowerCase()
          ? `${esc(c.game)} — ${esc(c.campaignName)}` : esc(c.game);
        rows += `<div class="drop"><img class="icon" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="t"><div class="reward">${title}</div>
          <div class="muted" style="font-size:12px">${esc(c.claimedDrops)} / ${esc(c.totalDrops)} drops claimed${agoText(c.completedAt) ? ' · ' + agoText(c.completedAt) : ''}</div></div></div>`;
      }
      const count = `${dropsThisWeek} ${dropsThisWeek === 1 ? 'drop' : 'drops'} this week`;
      const empty = rows ? '' : '<div class="empty-activity">No campaign completions to show yet.</div>';
      return `<section class="card" aria-label="Completed drops">
        <div class="detail-section-header">
          <div class="label">Completed Drops</div>
          <div class="completed-count">${count}</div>
        </div>
        ${rows || empty}
      </section>`;
    }

    function operatorBackCard(p) {
      if (OPERATOR_MINERS.length <= 1) return '';
      return `<button class="detail-back" id="backoverview" type="button" aria-label="Back to all miners">‹ All Miners</button>`;
    }

    function render(p) {
      PROJ = p;
      if (needsOnboarding(p)) {
        renderOnboarding(p);
        return;
      }
      personal = (p.personalPriorityGames || []).slice();
      prioritySource = p.prioritySource || (p.includesGlobalPriorityGames === false ? 'personal' : 'global');
      includeGlobalPriorities = prioritySource !== 'personal';
      $('app').innerHTML = `<main class="miner-detail">${operatorBackCard(p)}${minerIdentity(p)}${heroStateCard(p)}${progressCard(p)}${activationCard(p)}${issuesCard(p)}${subscriptionRequiredCard()}${upNextCard(p)}${globalCard(p)}${personalCard(p)}${dropsCard(p)}${globalPrioritiesModalOpen ? globalPrioritiesModal(p) : ''}</main>`;
      hydrateArt();
      wireActivation();
      wireOperatorBack();
      wireIssues();
      wireCampaigns();
      wirePersonal();
      const viewGlobalPriorities = $('viewglobalpriorities');
      if (viewGlobalPriorities) viewGlobalPriorities.addEventListener('click', () => {
        globalPrioritiesModalOpen = true;
        render(PROJ);
      });
      wireGlobalPrioritiesModal();
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
      document.querySelectorAll('[data-priority-source]').forEach(btn => {
        btn.addEventListener('click', () => {
          prioritySource = btn.dataset.prioritySource || 'global';
          includeGlobalPriorities = prioritySource !== 'personal';
          commit();
        });
      });
      if (!flow) return;
      flow.addEventListener('click', (e) => {
        const item = e.target.closest('.priority-chip'); if (!item) return;
        const i = Number(item.dataset.i);
        if (e.target.closest('.del')) { personal.splice(i, 1); commit(); }
      });
      const input = $('addgame');
      if (!input) return;
      const add = () => {
        const name = input.value.trim();
        if (!name) return;
        if (personal.some(g => g.toLowerCase() === name.toLowerCase())) { input.value = ''; return; }
        personal.push(name); input.value = '';
        if (prioritySource === 'global') prioritySource = 'globalAndPersonal';
        commit();
      };
      $('addbtn').addEventListener('click', add);
      input.addEventListener('keydown', (e) => { if (e.key === 'Enter') { e.preventDefault(); add(); } });
    }

    function addPersonalGame(name) {
      name = String(name || '').trim();
      if (!name) return;
      if (!personal.some(g => g.toLowerCase() === name.toLowerCase())) personal.unshift(name);
      if (prioritySource === 'global') prioritySource = 'globalAndPersonal';
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
        body: JSON.stringify({ games: personal, include_global_priorities: includeGlobalPriorities, priority_source: prioritySource })
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
      const cards = personalCard(PROJ);
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
      const query = String(OPERATOR_STATE.query || '').trim().toLowerCase();
      const filter = OPERATOR_STATE.filter || 'all';
      const attentionCount = miners.filter(m => m.state === 'blocked' || (m.diagnostics && ['blocked','needsAuth','stalled','attention'].includes(String(m.diagnostics.health || '')))).length;
      const idleCount = miners.filter(m => m.state !== 'active' && m.state !== 'blocked').length;
      const visibleMiners = miners.filter(m => {
        const d = m.diagnostics || {};
        const health = String(d.health || '');
        const isAttention = m.state === 'blocked' || ['blocked','needsAuth','stalled','attention'].includes(health);
        if (filter === 'active' && m.state !== 'active') return false;
        if (filter === 'attention' && !isAttention) return false;
        if (filter === 'idle' && (m.state === 'active' || isAttention)) return false;
        if (!query) return true;
        const acc = m.account || {};
        const haystack = [
          acc.username,
          acc.twitchAccountId,
          m.state,
          d.statusLabel,
          d.currentChannelName,
          ...((m.issues || []).map(is => is.message || is.type || ''))
        ].join(' ').toLowerCase();
        return haystack.includes(query);
      });

      const playIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polygon points="5 3 19 12 5 21 5 3"></polygon></svg>`;
      const giftIcon = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><polyline points="20 12 20 22 4 22 4 12"></polyline><rect x="2" y="7" width="20" height="5"></rect><line x1="12" y1="22" x2="12" y2="7"></line><path d="M12 7H7.5a2.5 2.5 0 0 1 0-5C11 2 12 7 12 7z"></path><path d="M12 7h4.5a2.5 2.5 0 0 0 0-5C13 2 12 7 12 7z"></path></svg>`;
      const twitchIcon = `<svg viewBox="0 0 24 24" fill="currentColor"><path d="M11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714ZM6 0 1.714 4.286V19.714H6.857V24l4.286-4.286h3.428L22.286 12V0Zm14.571 11.143-3.428 3.428h-3.429l-3 3v-3H6.857V1.714h13.714ZM11.571 4.714h1.715v5.143h-1.715Zm4.715 0H18v5.143h-1.714Z"/></svg>`;

      let html = `<div class="hero-card">
        <div class="hero-header">
          <div class="status-icon-container" style="background-color: rgba(86, 188, 255, 0.12); --icon-bg: rgba(86, 188, 255, 0.10);">
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
            <div class="stat-value">${attentionCount}</div>
            <div class="stat-label">Need Attention</div>
          </div>
        </div>
      `;
      html += `
        <div class="triage-toolbar">
          <input class="triage-search" id="operatorsearch" placeholder="Search miners or channels…" value="${esc(OPERATOR_STATE.query || '')}" autocomplete="off">
          <div class="segmented" role="group" aria-label="Filter miners">
            <button type="button" data-filter="all" class="${filter === 'all' ? 'active' : ''}">All ${totalMiners}</button>
            <button type="button" data-filter="active" class="${filter === 'active' ? 'active' : ''}">Active ${activeMiners}</button>
            <button type="button" data-filter="attention" class="${filter === 'attention' ? 'active' : ''}">Attention ${attentionCount}</button>
            <button type="button" data-filter="idle" class="${filter === 'idle' ? 'active' : ''}">Up to Date ${idleCount}</button>
          </div>
        </div>
      `;

      if (!miners.length) {
        html += '<div class="card muted">No miners configured yet.</div>';
      } else if (!visibleMiners.length) {
        html += '<div class="card muted">No miners match the current filter.</div>';
      }

      for (const p of visibleMiners) {
        const acc = p.account || {};
        const cfg = getStatusConfig(p);
        const id = minerId(p);
        const profileImageURL = accountProfileImageURL(acc);
        const avatar = profileImageURL
          ? `<img src="${esc(profileImageURL)}" alt="" referrerpolicy="no-referrer">`
          : twitchIcon;
        const progressHTML = progressStateCard(p, cfg, 'margin-top: 14px;');

        html += `
          <div class="card miner-card" style="padding: 20px;" data-miner-id="${esc(id)}" role="button" tabindex="0" aria-label="Open ${esc(acc.username || 'miner')}">
            <div class="hero-header" style="gap: 14px; align-items: center; justify-content: space-between; width: 100%;">
              <div style="display: flex; align-items: center; gap: 14px;">
                <div class="operator-miner-avatar">${avatar}</div>
                <div class="hero-info">
                  <h3 class="hero-headline" style="font-size: 16px; margin: 0;">${esc(acc.username || 'Account')}</h3>
                </div>
              </div>
              <div style="display:flex;align-items:center;gap:8px;margin-left:auto;flex-shrink:0">
                <button class="btn-secondary refresh-btn" data-account-id="${esc(acc.twitchAccountId)}" style="padding: 6px 12px; font-size: 12px; height: 28px; line-height: 1; flex-shrink: 0;">Refresh</button>
              </div>
            </div>
            ${progressHTML}
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
      const search = $('operatorsearch');
      if (search) {
        search.addEventListener('input', () => {
          OPERATOR_STATE.query = search.value;
          renderOverview(OPERATOR_MINERS);
          const fresh = $('operatorsearch');
          if (fresh) {
            fresh.focus();
            const end = fresh.value.length;
            fresh.setSelectionRange(end, end);
          }
        });
      }
      document.querySelectorAll('[data-filter]').forEach(btn => {
        btn.addEventListener('click', () => {
          OPERATOR_STATE.filter = btn.dataset.filter || 'all';
          renderOverview(OPERATOR_MINERS);
        });
      });
      document.querySelectorAll('.miner-card').forEach(card => {
        const open = () => showOperatorMiner(card.dataset.minerId);
        card.addEventListener('click', (e) => {
          if (e.target.closest('.refresh-btn')) return;
          open();
        });
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
    startLoadingCopy();
    load();
    // Keep progress fresh without being chatty.
    setInterval(() => load(true), 60000);
    })();
    """

    static let loginJS = """
    (function() {
      const canvas = document.getElementById('nebula-canvas');
      if (!canvas) return;
      const ctx = canvas.getContext('2d');
      
      const viewport = () => window.visualViewport || window;
      const resizeCanvas = () => {
        const vv = viewport();
        width = canvas.width = Math.ceil(vv.width || window.innerWidth);
        height = canvas.height = Math.ceil(vv.height || window.innerHeight);
      };
      let width = 0;
      let height = 0;
      resizeCanvas();

      window.addEventListener('resize', resizeCanvas);
      window.visualViewport?.addEventListener('resize', resizeCanvas);

      const saluteLayer = document.querySelector('.salute-layer');
      const saluteEnabled = document.body?.dataset.saluteEasterEgg === 'true';
      const prefersReducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
      let lastSaluteAt = 0;

      function spawnSalutes() {
        if (!saluteLayer) return;

        const now = Date.now();
        if (now - lastSaluteAt < 650) return;
        lastSaluteAt = now;

        const count = prefersReducedMotion.matches ? 12 : 36;
        for (let i = 0; i < count; i++) {
          const salute = document.createElement('span');
          salute.className = 'salute';
          salute.textContent = '🫡';
          salute.style.left = `${10 + Math.random() * 80}%`;
          salute.style.setProperty('--drift', `${Math.random() * 180 - 90}px`);
          salute.style.setProperty('--rise', `${240 + Math.random() * 180}px`);
          salute.style.setProperty('--spin', `${Math.random() * 42 - 21}deg`);
          salute.style.setProperty('--scale', `${0.72 + Math.random() * 0.72}`);
          salute.style.animationDuration = `${3.1 + Math.random() * 1.4}s`;
          salute.style.animationDelay = `${Math.random() * 0.35}s`;
          saluteLayer.appendChild(salute);
          window.setTimeout(() => salute.remove(), 5200);
        }
      }

      document.addEventListener('keydown', (event) => {
        if (!saluteEnabled || event.key.toLowerCase() !== 'f') return;
        if (event.metaKey || event.ctrlKey || event.altKey) return;

        const target = event.target;
        const isTyping = target && (
          target.matches?.('input, textarea, select') ||
          target.isContentEditable
        );
        if (isTyping) return;

        event.preventDefault();
        spawnSalutes();
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
        let saluteEasterEgg = tagline == "Press F to pay respects to missed Drops."
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
          html {
            min-height: 100%;
            background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
          }
          body {
            margin: 0; min-height: 100vh; min-height: 100svh; min-height: 100dvh;
            display: grid; place-items: center;
            padding: max(1rem, env(safe-area-inset-top)) max(1rem, env(safe-area-inset-right)) max(1rem, env(safe-area-inset-bottom)) max(1rem, env(safe-area-inset-left));
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
          .salute-layer {
            position: fixed; inset: 0; overflow: hidden;
            z-index: 0; pointer-events: none;
          }
          .salute {
            position: absolute; bottom: clamp(7rem, 18vh, 12rem);
            font-size: clamp(24px, 4.8vw, 46px); line-height: 1;
            opacity: 0;
            filter: drop-shadow(0 8px 18px rgba(0, 0, 0, 0.35));
            transform: translate3d(0, 42px, 0) scale(0.72) rotate(calc(var(--spin, 0deg) * -1));
            animation: salute-rise 3.8s cubic-bezier(0.16, 1, 0.3, 1) forwards;
            will-change: transform, opacity;
          }
          @keyframes salute-rise {
            0% { opacity: 0; transform: translate3d(0, 42px, 0) scale(0.72) rotate(calc(var(--spin, 0deg) * -1)); }
            12% { opacity: 0.95; }
            78% { opacity: 0.9; }
            100% { opacity: 0; transform: translate3d(var(--drift, 0), calc(var(--rise, 320px) * -1), 0) scale(var(--scale, 1)) rotate(var(--spin, 0deg)); }
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
          @media (max-height: 620px) {
            body { align-content: center; }
            .card { padding: 24px; border-radius: 24px; }
            .logo-img { width: 64px; height: 64px; }
            .logo { width: 52px; height: 52px; }
            h1 { font-size: 26px; }
            .sub { margin-bottom: 18px; }
            .foot { margin-top: 16px; }
          }
        </style></head>
        <body data-salute-easter-egg="\(saluteEasterEgg ? "true" : "false")">
          <canvas id="nebula-canvas"></canvas>
          <div class="salute-layer" aria-hidden="true"></div>
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
          html {
            min-height: 100%;
            background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
          }
          body {
            margin: 0; min-height: 100vh; min-height: 100svh; min-height: 100dvh;
            display: grid; place-items: center;
            padding: max(1rem, env(safe-area-inset-top)) max(1rem, env(safe-area-inset-right)) max(1rem, env(safe-area-inset-bottom)) max(1rem, env(safe-area-inset-left));
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
