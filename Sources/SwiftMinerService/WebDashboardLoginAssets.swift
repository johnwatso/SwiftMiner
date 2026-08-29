extension WebDashboardAssets {
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
    static func loginPage(
        discordSSOURL: String?,
        twitch: Bool,
        local: Bool,
        appIcon: Bool = false,
        accountRemoved: Bool = false
    ) -> String {
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
            let label = accountRemoved ? "Add a Twitch account" : "Sign in with Discord"
            blocks += #"<a class="btn discord" href="\#(href)">\#(discordMark)\#(label)</a>"#
        }
        // A removed account no longer has a stored miner record, so a Twitch
        // OAuth login alone cannot restore it. Discord sign-in starts the
        // existing account-linking flow instead.
        if twitch && !accountRemoved {
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
            blocks = accountRemoved
                ? #"<p class="hint">Ask the SwiftMiner operator to add this Twitch account again.</p>"#
                : #"<p class="hint">No sign-in methods are configured yet. Ask the operator to finish setup in SwiftMiner's Web settings.</p>"#
        }
        let title = accountRemoved ? "Account removed" : "SwiftMiner"
        let subtitle = accountRemoved
            ? "Your miner was removed and its Twitch authorization was revoked."
            : local && discordSSOURL == nil && !twitch
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
            <h1>\(title)</h1>
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
