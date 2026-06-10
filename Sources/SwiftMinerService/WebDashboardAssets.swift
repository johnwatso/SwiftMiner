import Foundation

/// Static markup for the dashboard. Kept tiny and dependency-free: a single
/// page that talks only to the session-scoped `/me/*` endpoints. Scripts are
/// served externally so the strict `Content-Security-Policy` (no inline JS)
/// holds.
enum WebDashboardAssets {
    static let appHTML = """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>SwiftMiner</title>
      <style>
        :root { color-scheme: light dark; }
        body { font: 15px -apple-system, system-ui, sans-serif; max-width: 640px; margin: 2rem auto; padding: 0 1rem; }
        h1 { font-size: 1.4rem; }
        .card { border: 1px solid color-mix(in srgb, currentColor 18%, transparent); border-radius: 12px; padding: 1rem 1.2rem; margin: 1rem 0; }
        .muted { opacity: 0.65; }
        button { font: inherit; padding: 0.5rem 0.9rem; border-radius: 8px; border: 1px solid color-mix(in srgb, currentColor 30%, transparent); background: transparent; cursor: pointer; }
        .bar { width: 100%; height: 8px; border-radius: 4px; background: color-mix(in srgb, currentColor 15%, transparent); overflow: hidden; }
        .bar > i { display: block; height: 100%; background: #5b8def; }
        code { background: color-mix(in srgb, currentColor 12%, transparent); padding: 0.1rem 0.35rem; border-radius: 5px; }
      </style>
    </head>
    <body>
      <h1>SwiftMiner</h1>
      <div id="app"><p class="muted">Loading…</p></div>
      <script src="/app/app.js"></script>
    </body>
    </html>
    """

    static let appJS = """
    const $ = (id) => document.getElementById(id);
    let CSRF = null;

    async function api(path, opts = {}) {
      opts.headers = opts.headers || {};
      if (CSRF && opts.method && opts.method !== 'GET') opts.headers['X-SM-CSRF'] = CSRF;
      opts.credentials = 'same-origin';
      const r = await fetch(path, opts);
      if (r.status === 401) { location.href = '/login'; return null; }
      return r;
    }

    function esc(s) { return String(s == null ? '' : s).replace(/[&<>"]/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c])); }

    function render(p) {
      const app = $('app');
      let html = '';
      if (p.state === 'notConfigured') {
        html += `<div class="card"><p>No Twitch account linked yet.</p>
          <button id="link">Link Twitch account</button><p id="linkOut" class="muted"></p></div>`;
      } else {
        const acc = p.account || {};
        html += `<div class="card"><strong>${esc(acc.username || 'Your account')}</strong>
          <span class="muted"> · ${esc(p.state)}</span></div>`;
        if (p.activeCampaign) {
          const c = p.activeCampaign, pr = c.progress || {};
          html += `<div class="card"><div>Mining <strong>${esc(c.game)}</strong></div>
            <div class="bar"><i style="width:${Number(pr.pct||0)}%"></i></div>
            <small class="muted">${esc(pr.current||0)}/${esc(pr.required||0)} ${esc(pr.unit||'')}</small></div>`;
        }
        if (p.issues && p.issues.length) {
          html += '<div class="card"><strong>Needs attention</strong>';
          for (const is of p.issues) html += `<div>⚠️ ${esc(is.message || is.type)}</div>`;
          html += '</div>';
        }
      }
      html += `<form method="POST" action="/logout" id="logoutForm"><button>Sign out</button></form>`;
      app.innerHTML = html;

      const linkBtn = $('link');
      if (linkBtn) linkBtn.onclick = startLink;
      $('logoutForm').onsubmit = (e) => { e.preventDefault(); doLogout(); };
    }

    async function startLink() {
      const out = $('linkOut');
      out.textContent = 'Requesting code…';
      const r = await api('/me/activation', { method: 'POST' });
      if (!r) return;
      const j = await r.json();
      if (j.userCode) {
        out.innerHTML = `Go to <a href="${esc(j.verificationUri)}" target="_blank" rel="noopener">twitch.tv/activate</a> and enter <code>${esc(j.userCode)}</code>.`;
        poll(j.sessionId);
      } else { out.textContent = j.message || 'Could not start linking.'; }
    }

    async function poll(sid) {
      const r = await api('/me/activation/' + encodeURIComponent(sid));
      if (!r) return;
      const j = await r.json();
      if (j.state === 'authorized') return load();
      if (j.state === 'pending') return setTimeout(() => poll(sid), 5000);
      $('linkOut').textContent = 'Linking ' + (j.state || 'failed') + '.';
    }

    async function doLogout() {
      await api('/logout', { method: 'POST' });
      location.href = '/login';
    }

    function renderOverview(miners) {
      const app = $('app');
      let html = '<div class="card"><strong>Operator overview</strong>'
               + `<span class="muted"> · ${miners.length} miner${miners.length === 1 ? '' : 's'}</span></div>`;
      if (!miners.length) {
        html += '<div class="card"><p class="muted">No miners yet.</p></div>';
      }
      for (const p of miners) {
        const acc = p.account || {};
        html += `<div class="card"><div class="row"><strong>${esc(acc.username || 'Account')}</strong>`
              + `<span class="muted" style="margin-left:auto">${esc(p.state)}</span></div>`;
        if (p.activeCampaign) {
          const c = p.activeCampaign, pr = c.progress || {};
          html += `<div style="margin-top:0.5rem">Mining <strong>${esc(c.game)}</strong>`
                + `<div class="bar"><i style="width:${Number(pr.pct||0)}%"></i></div>`
                + `<small class="muted">${esc(pr.current||0)}/${esc(pr.required||0)} ${esc(pr.unit||'')}</small></div>`;
        }
        html += '</div>';
      }
      html += `<form method="POST" action="/logout" id="logoutForm"><button>Sign out</button></form>`;
      app.innerHTML = html;
      $('logoutForm').onsubmit = (e) => { e.preventDefault(); doLogout(); };
    }

    async function load() {
      const sr = await api('/me/session');
      if (!sr) return;
      const session = await sr.json();
      CSRF = session.csrfToken;
      const pr = await api('/me/projection');
      if (!pr) return;
      const data = await pr.json();
      if (session.provider === 'local') { renderOverview(data.miners || []); return; }
      if (pr.status === 404) { $('app').innerHTML = '<p class="muted">No miner found for your account yet.</p>'; return; }
      render(data);
    }

    load();
    """

    /// Sign-in chooser. Renders a button per enabled provider, plus a local
    /// username/password form when local sign-in is available on this request.
    /// `discordSSOURL` is SwiftBot's companion-SSO entry point (Discord
    /// sign-in brokered by the paired SwiftBot).
    static func loginPage(discordSSOURL: String?, twitch: Bool, local: Bool) -> String {
        var blocks = ""
        if let discordSSOURL {
            let href = discordSSOURL
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "\"", with: "&quot;")
            blocks += #"<a class="btn discord" href="\#(href)">Sign in with Discord</a>"#
        }
        if twitch {
            blocks += #"<a class="btn twitch" href="/login/twitch">Sign in with Twitch</a>"#
        }
        if local {
            if !blocks.isEmpty { blocks += #"<div class="divider">or</div>"# }
            blocks += """
            <form class="local" method="POST" action="/login/local" autocomplete="off">
              <input name="username" placeholder="Username" autocapitalize="off" autocorrect="off">
              <input name="password" type="password" placeholder="Password">
              <button class="btn local-btn" type="submit">Sign in locally</button>
            </form>
            """
        }
        if blocks.isEmpty {
            blocks = #"<p class="muted">No sign-in methods are configured.</p>"#
        }
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>Sign in · SwiftMiner</title>
        <style>
          :root { color-scheme: light dark; }
          body { font: 15px -apple-system, system-ui, sans-serif; min-height: 100vh; margin: 0;
                 display: grid; place-items: center; background: #0e0e10; color: #fff; }
          .card { width: 320px; text-align: center; padding: 2rem 1.5rem; }
          h1 { font-size: 1.4rem; margin: 0 0 0.3rem; }
          .muted { opacity: 0.6; margin-bottom: 1.5rem; }
          .btn { display: block; padding: 0.7rem 1rem; margin: 0.6rem 0; border-radius: 10px;
                 font-weight: 600; text-decoration: none; color: #fff; border: none; width: 100%; font-size: 15px; cursor: pointer; }
          .discord { background: #5865F2; }
          .twitch { background: #9146FF; }
          .local-btn { background: #2d2d31; }
          .divider { opacity: 0.4; margin: 1rem 0 0.5rem; font-size: 0.85rem; }
          .local input { display: block; width: 100%; box-sizing: border-box; margin: 0.4rem 0;
                 padding: 0.65rem 0.8rem; border-radius: 10px; border: 1px solid #2d2d31;
                 background: #161618; color: #fff; font-size: 15px; }
        </style></head>
        <body><div class="card">
          <h1>SwiftMiner</h1>
          <p class="muted">Sign in to manage your miner</p>
          \(blocks)
        </div></body></html>
        """
    }

    /// A minimal standalone status page (used for OAuth error/landing messages).
    static func message(_ text: String, linkToLogin: Bool = false) -> String {
        let link = linkToLogin ? "<p><a href=\"/login\">Try again</a></p>" : ""
        return """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>SwiftMiner</title>
        <style>body{font:15px -apple-system,system-ui,sans-serif;max-width:520px;margin:3rem auto;padding:0 1rem;}</style>
        </head><body><h1>SwiftMiner</h1><p>\(text)</p>\(link)</body></html>
        """
    }
}
