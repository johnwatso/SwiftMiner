extension WebDashboardAssets {
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
    var exclusionsModalOpen = false;
    var excludedGames = [];
    var accountRemovalModalOpen = false;
    var accountRemovalAccountId = null;
    var accountRemovalReturnToOverview = false;
    var accountRemovalNotice = '';
    let OPERATOR_MINERS = [];
    let OPERATOR_STATE = { selectedMinerId: null };

    // ---------- deep-link routing ----------
    // Discord DMs link straight at the thing they are about. The portal is a
    // single page, so destinations are fragment routes and "navigating" means
    // rendering as normal, then scrolling the matching card into view. Routes
    // are mirrored in SwiftMinerPortalLink.swift, which builds these URLs.
    //
    //   #/miner/<twitchAccountId>   #/campaign/<campaignId>
    //   #/campaigns                 #/account/connection
    //   #/drops
    let ROUTE = { name: 'home' };
    let lastAppliedRouteKey = null;
    /// Set when we wrote the fragment ourselves, so the resulting hashchange
    /// does not re-render a view that is already on screen.
    let suppressHashChange = false;

    function parseRoute() {
      const raw = String(location.hash || '');
      let path = raw.charAt(0) === '#' ? raw.slice(1) : raw;
      while (path.charAt(0) === '/') path = path.slice(1);
      if (!path) return { name: 'home' };
      const parts = path.split('/').filter(Boolean).map(part => {
        try { return decodeURIComponent(part); } catch { return part; }
      });
      switch (parts[0]) {
        case 'miner':     return parts[1] ? { name: 'miner', id: parts[1] } : { name: 'home' };
        case 'campaign':  return parts[1] ? { name: 'campaign', id: parts[1] } : { name: 'campaigns' };
        case 'campaigns': return { name: 'campaigns' };
        case 'drops':     return { name: 'drops' };
        case 'account':   return { name: 'account', section: parts[1] || 'overview' };
        default:          return { name: 'home' };
      }
    }

    function routeKey(r) {
      return r.name + ':' + (r.id || r.section || '');
    }

    /// The element a route wants in view, or null when this page has nothing
    /// matching — a campaign that has since ended, for instance.
    function routeTarget(r) {
      // The identity card always renders on a miner page, so it is the last
      // resort that keeps a deep link from silently doing nothing.
      if (r.name === 'miner') return $('route-identity');
      if (r.name === 'campaign' && r.id) {
        const row = document.querySelector('[data-campaign-id="' + cssEscape(r.id) + '"]');
        if (row) return row;
        // The campaign is gone or not listed; the campaign list is still the
        // most useful place to land.
        return $('route-campaigns');
      }
      if (r.name === 'campaigns') return $('route-campaigns') || $('route-subscription');
      if (r.name === 'drops') return $('route-drops');
      if (r.name === 'account') {
        if (r.section === 'connection') {
          return $('route-connection') || $('route-issues') || $('route-identity');
        }
        return $('route-identity');
      }
      return null;
    }

    function cssEscape(value) {
      const s = String(value);
      if (window.CSS && typeof window.CSS.escape === 'function') return window.CSS.escape(s);
      let out = '';
      for (const ch of s) {
        out += /[a-zA-Z0-9_-]/.test(ch) ? ch : '_';
      }
      return out;
    }

    /// Called after every render. Scrolls once per distinct route so a
    /// background refresh never yanks the page out from under the reader.
    function applyRoute() {
      if (ROUTE.name === 'home') { lastAppliedRouteKey = null; return; }
      const key = routeKey(ROUTE);
      if (key === lastAppliedRouteKey) return;
      const target = routeTarget(ROUTE);
      if (!target) return;
      lastAppliedRouteKey = key;
      window.requestAnimationFrame(() => {
        target.scrollIntoView({ behavior: 'smooth', block: 'center' });
        target.classList.add('route-focus');
        window.setTimeout(() => target.classList.remove('route-focus'), 2600);
      });
    }

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

    function secureProfileImageURL(url) {
      return typeof url === 'string' && url.toLowerCase().startsWith('https://') ? url : undefined;
    }

    // Honours the account's picture source from the app, trying the other
    // service second so the dashboard resolves exactly as the app does.
    // One sentence covering the whole fleet, so the header answers "is everything OK?"
    // on its own rather than leaving the reader to add up stat tiles.
    function fleetSummary(total, active, attention, idle) {
      if (!total) return 'No miners configured yet';
      const miners = total === 1 ? 'miner' : 'miners';
      if (attention > 0) {
        const needs = attention === 1 ? 'needs' : 'need';
        return `${attention} of ${total} ${miners} ${needs} attention`;
      }
      if (active === total) return `All ${total} ${miners} operational`;
      if (active > 0) return `${active} of ${total} ${miners} mining, ${idle} waiting`;
      return `All ${total} ${miners} up to date, none mining right now`;
    }

    // The app's miner list leads with the nickname and keeps the Twitch login
    // as the secondary line. The dashboard reads the same way, so a fleet named
    // in the app is recognisable here.
    function accountDisplayName(acc) {
      const nickname = typeof acc.nickname === 'string' ? acc.nickname.trim() : '';
      return nickname || acc.username || '';
    }

    // The Twitch login, but only when it isn't already the headline.
    function accountSecondaryName(acc) {
      const nickname = typeof acc.nickname === 'string' ? acc.nickname.trim() : '';
      return nickname && acc.username && nickname !== acc.username ? acc.username : '';
    }

    function accountProfileImageURL(acc) {
      return acc.prefersDiscordProfileImage
        ? secureProfileImageURL(acc.discordProfileImageURL) || customProfileImageURL(acc.profileImageURL)
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
        <section class="miner-identity" id="route-identity" aria-label="Twitch account">
          <div class="miner-avatar">${twitchAvatar}</div>
          <h2>${esc(accountDisplayName(acc) || 'Twitch account')}</h2>
          ${accountSecondaryName(acc) ? `<p class="miner-handle">${esc(accountSecondaryName(acc))}</p>` : ''}
          <p class="miner-linked${acc.twitchAccountId ? '' : ' unlinked'}">${acc.twitchAccountId ? 'Twitch connected' : 'Twitch not connected'}</p>
        </section>
      `;
    }

    function activationCard(p) {
      if (!SESSION || SESSION.provider !== 'discord' || (p.account && p.account.twitchAccountId)) return '';
      if (!ACTIVATION) {
        return `<div class="card" id="route-connection">
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
      return `<div class="card" id="route-issues"><div class="label">Needs attention</div>${rows}</div>`;
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
      // With a single miner using global priorities, there is no per-account
      // choice or personal list to edit, so showing an empty editor is noise.
      if (!hasMultipleConfiguredMiners(p) && source === 'global') return '';
      const helper = source === 'global'
        ? 'Use the operator’s shared priority list. Your miner will still claim every drop linked to this account.'
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
        ? '<div class="muted" style="font-size:13px">Choose Global + Personal or Personal to edit this miner’s priorities. Your miner will still claim every drop linked to this account.</div>'
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

    function exclusionsCard(p) {
      if (!(p && p.account && p.account.twitchAccountId)) return '';
      const source = p.prioritySource || (p.includesGlobalPriorityGames === false ? 'personal' : 'global');
      // Exclusions are a per-miner rule. When this miner follows the shared
      // Global configuration, there is no local configuration to inspect or edit.
      if (source === 'global') return '';
      const games = p.excludedGames || [];
      const summary = games.length
        ? games.map(esc).join(', ')
        : 'No games excluded for this miner.';
      return `<div class="card">
        <div class="label">Excluded games</div>
        <div class="row" style="align-items:flex-start;justify-content:space-between;gap:16px">
          <div style="flex:1;min-width:0">
            <div class="name">Skip selected games</div>
            <div class="muted" style="font-size:13px;margin-top:4px">${summary}</div>
          </div>
          <button class="btn-secondary" id="manageexclusions" type="button">Manage</button>
        </div>
      </div>`;
    }

    function campaignArtworkURL(game) {
      const needle = String(game || '').trim().toLowerCase();
      const campaign = CAMPAIGNS.find(item => String(item.game || '').trim().toLowerCase() === needle);
      const url = campaign && campaign.boxArtURL;
      return typeof url === 'string' && url.toLowerCase().startsWith('https://') ? url : '';
    }

    function exclusionOption(game) {
      const selected = excludedGames.some(item => item.toLowerCase() === String(game).toLowerCase());
      return `<button class="pitem exclusion-option${selected ? ' selected' : ''}" data-exclusion-game="${esc(game)}" type="button">
        <img class="exclusion-art" alt="" data-game="${esc(game)}" data-art="${esc(campaignArtworkURL(game))}">
        <span class="rank" style="background:${selected ? 'linear-gradient(135deg,#ef5149,#c92d27)' : 'linear-gradient(135deg,var(--blue-a),var(--blue-c))'}">${selected ? '−' : '+'}</span>
        <span class="pname">${esc(game)}</span>
        <span class="muted" style="font-size:12px">${selected ? 'Excluded' : 'Exclude'}</span>
      </button>`;
    }

    function exclusionsModal(p) {
      const filter = String($('exclusionsearch') ? $('exclusionsearch').value : '').trim().toLowerCase();
      const matches = filter ? GAMES.filter(game => String(game).toLowerCase().includes(filter)).slice(0, 60) : [];
      const rows = matches.map(exclusionOption).join('');
      return `<div class="modal-backdrop" id="exclusionsmodal">
        <section class="modal-card" role="dialog" aria-modal="true" aria-labelledby="exclusionstitle" tabindex="-1">
          <div class="modal-header">
            <div class="copy">
              <div class="modal-title" id="exclusionstitle">Excluded games</div>
              <div class="modal-subtitle">This miner will not watch or claim drops for these games. Other miners are unaffected.</div>
            </div>
          </div>
          <div class="chips" style="margin-bottom:12px">${excludedGames.length ? excludedGames.map(game => `<span class="chip">${esc(game)} <button class="remove-btn" data-remove-exclusion="${esc(game)}" aria-label="Include ${esc(game)} again">×</button></span>`).join('') : '<span class="muted" style="font-size:13px">No games excluded.</span>'}</div>
          <div class="addrow" style="margin:0"><input id="exclusionsearch" placeholder="Search active games…" autocomplete="off"><button class="btn-secondary" id="closeexclusions" type="button">Done</button></div>
          <div class="campaign-list" id="exclusionoptions" style="margin-top:12px">${rows || `<div class="muted" style="font-size:13px">${filter ? 'No matching active games.' : 'Search for a game to exclude.'}</div>`}</div>
          <div class="savemsg" id="exclusionsmsg"></div>
        </section>
      </div>`;
    }

    function closeExclusionsModal() {
      exclusionsModalOpen = false;
      render(PROJ);
    }

    function wireExclusions() {
      const open = $('manageexclusions');
      if (open) open.addEventListener('click', () => {
        excludedGames = ((PROJ && PROJ.excludedGames) || []).slice();
        exclusionsModalOpen = true;
        render(PROJ);
      });
      const modal = $('exclusionsmodal');
      if (!modal) return;
      const dialog = modal.querySelector('[role="dialog"]');
      if (dialog) dialog.focus();
      $('closeexclusions').addEventListener('click', closeExclusionsModal);
      modal.addEventListener('click', event => { if (event.target === modal) closeExclusionsModal(); });
      modal.addEventListener('keydown', event => { if (event.key === 'Escape') closeExclusionsModal(); });
      const toggle = game => {
        const index = excludedGames.findIndex(item => item.toLowerCase() === String(game).toLowerCase());
        if (index >= 0) excludedGames.splice(index, 1); else excludedGames.push(game);
        saveExclusions();
      };
      document.querySelectorAll('[data-exclusion-game]').forEach(button => button.addEventListener('click', () => toggle(button.dataset.exclusionGame)));
      document.querySelectorAll('[data-remove-exclusion]').forEach(button => button.addEventListener('click', () => toggle(button.dataset.removeExclusion)));
      const search = $('exclusionsearch');
      search.addEventListener('input', () => {
        const query = search.value;
        const options = query.trim()
          ? GAMES.filter(game => String(game).toLowerCase().includes(query.toLowerCase())).slice(0, 60)
          : [];
        $('exclusionoptions').innerHTML = options.map(exclusionOption).join('') || `<div class="muted" style="font-size:13px">${query.trim() ? 'No matching active games.' : 'Search for a game to exclude.'}</div>`;
        hydrateArt($('exclusionoptions'));
        document.querySelectorAll('[data-exclusion-game]').forEach(button => button.addEventListener('click', () => toggle(button.dataset.exclusionGame)));
      });
    }

    async function saveExclusions() {
      const accountId = PROJ && PROJ.account && PROJ.account.twitchAccountId;
      if (!accountId) return;
      const message = $('exclusionsmsg');
      if (message) { message.textContent = 'Saving…'; message.className = 'savemsg'; }
      const r = await api('/me/miners/' + encodeURIComponent(accountId) + '/exclusions', {
        method: 'PUT', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ games: excludedGames })
      });
      if (r && r.ok) {
        const data = await r.json();
        excludedGames = data.excluded_games || excludedGames;
        PROJ.excludedGames = excludedGames;
        exclusionsModalOpen = true;
        render(PROJ);
      } else if (message) {
        let detail = 'Could not save exclusions.';
        try { detail = (await r.json()).message || detail; } catch {}
        message.textContent = detail; message.className = 'savemsg err';
      }
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
        rows += `<div class="campaign-row" data-campaign-id="${esc(c.campaignId || '')}">
          <img class="boxart" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="copy">
            <div class="title">${esc(c.game)}</div>
            <div class="details">${esc(c.dropCount || 0)} drops${gatedDetail}${when ? ' · ' + esc(when) : ''}</div>
          </div>
          <button class="btn-secondary campaign-priority" data-game="${esc(c.game)}" ${accountId ? '' : 'disabled'}>${personal.some(g => g.toLowerCase() === String(c.game || '').toLowerCase()) ? 'Prioritised' : 'Prioritise'}</button>
        </div>`;
      }
      return `<div class="card" id="route-campaigns"><div class="label">Up next</div><div class="campaign-list">${rows}</div>${accountId ? '' : '<div class="muted" style="font-size:12px;margin-top:10px">Link Twitch before setting priorities.</div>'}</div>`;
    }

    function subscriptionRequiredCard() {
      const campaigns = CAMPAIGNS.filter(c => c.requiresSubscription).slice(0, 6);
      if (!campaigns.length) return '';
      let rows = '';
      for (const c of campaigns) {
        const active = c.status === 'available';
        const when = active ? endsIn(c.endsAt) : dateLabel(c.startsAt, 'starts');
        const gatedCount = Number(c.subscriptionRequiredDropCount || c.dropCount || 0);
        rows += `<div class="campaign-row" data-campaign-id="${esc(c.campaignId || '')}">
          <img class="boxart" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
          <div class="copy">
            <div class="title">${esc(c.game)}</div>
            <div class="details">${gatedCount} ${gatedCount === 1 ? 'drop' : 'drops'} · Paid Twitch sub required${when ? ' · ' + esc(when) : ''}</div>
          </div>
          <span class="campaign-gate">Needs Sub</span>
        </div>`;
      }
      return `<div class="card" id="route-subscription"><div class="label">Subscription required</div><div class="campaign-list">${rows}</div></div>`;
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
      return `<section class="card" id="route-drops" aria-label="Completed drops">
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

    function accountRemovalCard(p) {
      if (!SESSION || !(p && p.account && p.account.twitchAccountId)) return '';
      if (SESSION.provider === 'local' && !SESSION.allows_operator_account_removal) return '';
      return `<section class="card">
        <div class="label">Account</div>
        <div class="row" style="align-items:flex-start;justify-content:space-between;gap:16px">
          <div style="flex:1;min-width:0">
            <div class="name">Remove account</div>
            <div class="muted" style="font-size:13px;margin-top:4px">Stops mining, removes this account from SwiftMiner, and revokes its Twitch authorization.</div>
          </div>
          <button class="btn-secondary btn-danger-outline" id="removeaccount" data-remove-account-id="${esc(p.account.twitchAccountId)}" type="button">Remove</button>
        </div>
      </section>`;
    }

    function accountRemovalModal() {
      return `<div class="modal-backdrop" id="accountremovalmodal">
        <section class="modal-card" role="dialog" aria-modal="true" aria-labelledby="accountremovaltitle" tabindex="-1">
          <div class="modal-header">
            <div class="copy">
              <div class="modal-title" id="accountremovaltitle">Remove your SwiftMiner account?</div>
              <div class="modal-subtitle">This stops mining, removes this account from SwiftMiner, and revokes its Twitch authorization. It does not delete your Twitch account.</div>
            </div>
          </div>
          <label class="muted" for="removalconfirmation" style="display:block;font-size:13px;margin:0 0 8px">Type <strong style="color:var(--text)">swiftminer</strong> to confirm.</label>
          <input id="removalconfirmation" autocomplete="off" autocapitalize="none" spellcheck="false" style="width:100%;font:15px inherit;font-family:inherit;color:var(--text);padding:11px 13px;border-radius:12px;background:var(--field);border:1px solid var(--field-stroke);outline:none" aria-describedby="removalerror">
          <div class="savemsg err" id="removalerror" role="alert"></div>
          <div class="modal-actions">
            <button class="btn-secondary" id="cancelaccountremoval" type="button">Cancel</button>
            <button class="btn-primary btn-danger" id="confirmaccountremoval" type="button" disabled>Remove account</button>
          </div>
        </section>
      </div>`;
    }

    function closeAccountRemovalModal() {
      accountRemovalModalOpen = false;
      if (accountRemovalReturnToOverview) renderOverview(OPERATOR_MINERS);
      else render(PROJ);
    }

    function wireAccountRemoval() {
      const open = $('removeaccount');
      if (open) open.addEventListener('click', () => {
        accountRemovalAccountId = open.dataset.removeAccountId || null;
        accountRemovalReturnToOverview = false;
        accountRemovalModalOpen = true;
        render(PROJ);
      });
      document.querySelectorAll('[data-overview-remove-account-id]').forEach(button => {
        button.addEventListener('click', (event) => {
          event.stopPropagation();
          accountRemovalAccountId = button.dataset.overviewRemoveAccountId || null;
          accountRemovalReturnToOverview = true;
          accountRemovalModalOpen = true;
          renderOverview(OPERATOR_MINERS);
        });
      });
      const modal = $('accountremovalmodal');
      if (!modal) return;
      const dialog = modal.querySelector('[role="dialog"]');
      const input = $('removalconfirmation');
      const confirm = $('confirmaccountremoval');
      const error = $('removalerror');
      if (dialog) dialog.focus();
      if (input) {
        input.focus();
        input.addEventListener('input', () => { confirm.disabled = input.value !== 'swiftminer'; });
      }
      $('cancelaccountremoval').addEventListener('click', closeAccountRemovalModal);
      modal.addEventListener('click', (event) => { if (event.target === modal) closeAccountRemovalModal(); });
      modal.addEventListener('keydown', (event) => { if (event.key === 'Escape') closeAccountRemovalModal(); });
      confirm.addEventListener('click', async () => {
        confirm.disabled = true;
        const r = await api('/me/account/remove', {
          method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ confirmation: input.value, account_id: accountRemovalAccountId })
        });
        if (r && r.ok) {
          if (SESSION && SESSION.provider === 'local') {
            const removed = OPERATOR_MINERS.find(m => minerId(m) === String(accountRemovalAccountId));
            const name = removed ? accountDisplayName(removed.account || {}) : 'Account';
            accountRemovalNotice = `${name} was removed from SwiftMiner. A Twitch authorization revocation was requested.`;
            accountRemovalModalOpen = false;
            accountRemovalAccountId = null;
            await load(false);
          } else {
            await doLogout(true);
          }
          return;
        }
        let detail = 'Could not remove your account.';
        try { detail = (await r.json()).message || detail; } catch {}
        error.textContent = detail;
        confirm.disabled = input.value !== 'swiftminer';
      });
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
      $('app').innerHTML = `<main class="miner-detail">${operatorBackCard(p)}${minerIdentity(p)}${heroStateCard(p)}${progressCard(p)}${activationCard(p)}${issuesCard(p)}${subscriptionRequiredCard()}${upNextCard(p)}${globalCard(p)}${personalCard(p)}${exclusionsCard(p)}${dropsCard(p)}${accountRemovalCard(p)}${globalPrioritiesModalOpen ? globalPrioritiesModal(p) : ''}${exclusionsModalOpen ? exclusionsModal(p) : ''}${accountRemovalModalOpen ? accountRemovalModal() : ''}</main>`;
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
      wireExclusions();
      wireAccountRemoval();
      fillGameOptions();
      applyRoute();
    }

    function hydrateArt(root = document) {
      root.querySelectorAll('img[data-game]').forEach(img => {
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
      const attentionCount = miners.filter(m => m.state === 'blocked' || (m.diagnostics && ['blocked','needsAuth','stalled','attention'].includes(String(m.diagnostics.health || '')))).length;
      const idleCount = miners.filter(m => m.state !== 'active' && m.state !== 'blocked').length;
      // Every miner is listed. The counts live in the headline sentence instead of a
      // stats row and a filter bar, which cost a third of the first screen to say what
      // the cards below already show.
      const visibleMiners = miners;

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
            <p class="hero-subtitle">${esc(fleetSummary(totalMiners, activeMiners, attentionCount, idleCount))}</p>
          </div>
        </div>
      </div>`;

      if (accountRemovalNotice) {
        html += `<div class="removal-notice" role="status"><span aria-hidden="true">✓</span><div><strong>Account removed</strong><br>${esc(accountRemovalNotice)}</div></div>`;
      }

      if (!miners.length) {
        html += '<div class="card muted">No miners configured yet.</div>';
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
          <div class="card miner-card" style="padding: 20px;" data-miner-id="${esc(id)}" role="button" tabindex="0" aria-label="Open ${esc(accountDisplayName(acc) || 'miner')}">
            <div class="hero-header" style="gap: 14px; align-items: center; justify-content: space-between; width: 100%;">
              <div style="display: flex; align-items: center; gap: 14px;">
                <div class="operator-miner-avatar">${avatar}</div>
                <div class="hero-info">
                  <h3 class="hero-headline" style="font-size: 16px; margin: 0;">${esc(accountDisplayName(acc) || 'Account')}</h3>
                  ${accountSecondaryName(acc) ? `<p class="hero-subtitle" style="font-size: 12px;">${esc(accountSecondaryName(acc))}</p>` : ''}
                </div>
              </div>
              <div style="display:flex;align-items:center;gap:8px;margin-left:auto;flex-shrink:0">
                <button class="btn-secondary refresh-btn" data-account-id="${esc(acc.twitchAccountId)}" style="padding: 6px 12px; font-size: 12px; height: 28px; line-height: 1; flex-shrink: 0;">Refresh</button>
                ${SESSION && SESSION.provider === 'local' && SESSION.allows_operator_account_removal ? `<button class="btn-secondary btn-danger-outline" data-overview-remove-account-id="${esc(acc.twitchAccountId)}" style="padding: 6px 12px; font-size: 12px; height: 28px; line-height: 1; flex-shrink: 0;">Remove</button>` : ''}
              </div>
            </div>
            ${progressHTML}
          </div>
        `;
      }

      if (accountRemovalModalOpen) html += accountRemovalModal();
      $('app').innerHTML = html;
      hydrateArt();
      wireOperatorOverview();
      wireAccountRemoval();
      applyRoute();
    }

    function showOperatorMiner(id) {
      const p = OPERATOR_MINERS.find(m => minerId(m) === String(id));
      if (!p) return;
      OPERATOR_STATE.selectedMinerId = String(id);
      setRoute({ name: 'miner', id: String(id) });
      render(p);
      window.scrollTo({ top: 0, behavior: 'smooth' });
    }

    /// Updates the fragment without re-entering the router: the caller is
    /// already rendering the view this route describes.
    function setRoute(next) {
      ROUTE = next;
      lastAppliedRouteKey = routeKey(next);
      const hash = next.name === 'miner' && next.id
        ? '#/miner/' + encodeURIComponent(next.id)
        : '#/';
      if (location.hash !== hash) {
        suppressHashChange = true;
        location.hash = hash;
      }
    }

    function wireOperatorOverview() {
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
        setRoute({ name: 'home' });
        renderOverview(OPERATOR_MINERS);
        window.scrollTo({ top: 0, behavior: 'smooth' });
      });
    }

    // ---------- bootstrap ----------

    async function doLogout(accountRemoved = false) {
      await api('/logout', { method: 'POST' });
      location.href = accountRemoved ? '/login?account_removed=1' : '/login';
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
          OPERATOR_MINERS.splice(0, OPERATOR_MINERS.length, ...miners);
          // A #/miner/<twitchAccountId> deep link chooses the miner before the
          // default view does, so a DM lands on the account it is about.
          if (ROUTE.name === 'miner' && ROUTE.id && miners.some(m => minerId(m) === ROUTE.id)) {
            OPERATOR_STATE.selectedMinerId = ROUTE.id;
          }
          if (miners.length === 1) {
            OPERATOR_STATE.selectedMinerId = null;
            render(miners[0]);
          } else if (OPERATOR_STATE.selectedMinerId) {
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
    // These two only populate suggestion lists, so a failure degrades to an empty picker
    // rather than a broken page — but it should not be indistinguishable from "no games".
    async function loadGames() {
      try {
        const r = await api('/me/games');
        if (!r || !r.ok) {
          console.warn('Could not load the game list:', r && r.status);
          return;
        }
        GAMES = (await r.json()).games || [];
        fillGameOptions();
      } catch (err) {
        console.warn('Could not load the game list:', err);
      }
    }
    async function loadCampaigns() {
      try {
        const r = await api('/me/campaigns');
        if (!r || !r.ok) {
          console.warn('Could not load the campaign list:', r && r.status);
          return;
        }
        CAMPAIGNS = (await r.json()).campaigns || [];
      } catch (err) {
        console.warn('Could not load the campaign list:', err);
      }
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

    window.addEventListener('hashchange', () => {
      if (suppressHashChange) { suppressHashChange = false; return; }
      ROUTE = parseRoute();
      lastAppliedRouteKey = null;
      // Only an operator session has a miner list to switch between. A
      // single-miner user is already on the page the link refers to, so it
      // falls through to applyRoute() rather than being dropped.
      if (ROUTE.name === 'miner' && ROUTE.id
          && OPERATOR_MINERS.some(m => minerId(m) === ROUTE.id)) {
        showOperatorMiner(ROUTE.id);
        return;
      }
      if (ROUTE.name === 'home' && OPERATOR_STATE.selectedMinerId && OPERATOR_MINERS.length > 1) {
        OPERATOR_STATE.selectedMinerId = null;
        renderOverview(OPERATOR_MINERS);
        return;
      }
      applyRoute();
    });

    const hdr = $('hdrlogo');
    if (hdr) hideOnError(hdr);
    $('signout').addEventListener('click', doLogout);
    startLoadingCopy();
    ROUTE = parseRoute();
    load();
    // Keep progress fresh without being chatty.
    setInterval(() => load(true), 60000);
    })();
    """

}
