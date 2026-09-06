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
    let campaignsModalOpen = false;
    let campaignsModalFocusId = null;
    let prioritySourcePickerOpen = false;
    let personalAddOpen = false;
    let personalMenuIndex = null;
    let completedDropsModalOpen = false;
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
    function endsInPhrase(iso) {
      if (!iso) return '';
      const ms = new Date(iso) - Date.now();
      if (isNaN(ms) || ms <= 0) return '';
      const plural = (n, word) => n + ' ' + word + (n === 1 ? '' : 's');
      const h = Math.floor(ms / 3600000);
      if (h >= 48) return 'Ends in ' + plural(Math.floor(h / 24), 'day');
      if (h >= 1) return 'Ends in ' + plural(h, 'hour');
      return 'Ends in ' + plural(Math.max(1, Math.floor(ms / 60000)), 'minute');
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
          kind: 'offline',
          headline: 'Offline', subtitle: 'SwiftMiner is not currently running for this account.', color: '#8e8e93',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#8e8e93" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2v10"></path><path d="M5.64 5.64a9 9 0 1 0 12.73 0"></path></svg>`
        };
      }
      if (diagnostics.isStalled || diagnostics.health === 'stalled') {
        return {
          kind: 'error',
          headline: 'Error', subtitle: diagnostics.statusLabel || 'Mining has stopped making progress and needs attention.', color: '#ff453a',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#ff453a" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"></circle><path d="M12 8v4"></path><path d="M12 16h.01"></path></svg>`
        };
      }
      if (p.state === 'active') {
        if (p.activeCampaign) {
          const streamer = p.activeCampaign.currentChannelName;
          return {
            kind: 'mining',
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
            kind: 'waiting',
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
          kind: 'blocked',
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
          kind: 'idle',
          headline: 'Up to Date',
          subtitle: 'All currently available drops are complete.',
          color: '#34c759',
          icon: `<svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="#34c759" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round">
            <path d="M22 11.08V12a10 10 0 1 1-5.93-9.14"></path>
            <polyline points="22 4 12 14.01 9 11.01"></polyline>
          </svg>`
        };
      } else {
        return {
          kind: 'notConfigured',
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
              <div class="up-to-date-detail">All currently available drops are complete.</div>
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

    /// Reward-bearing detail for the campaign in progress. `ActiveCampaign`
    /// only carries the game, so the campaign's own name comes from the
    /// campaign list when it has loaded and is skipped when it has not.
    function activeCampaignTitle(p) {
      const c = p.activeCampaign;
      if (!c) return '';
      const match = CAMPAIGNS.find(item => String(item.campaignId || '') === String(c.campaignId || ''));
      const name = match && match.campaignName;
      return name && String(name).toLowerCase() !== String(c.game).toLowerCase()
        ? `${esc(c.game)} — ${esc(name)}`
        : esc(c.game);
    }

    /// "34 min remaining" when the campaign is measured in minutes, and the raw
    /// tally otherwise — some campaigns count other units. The percentage is
    /// rendered beside the bar, so it is deliberately not repeated here.
    function progressSummary(pr) {
      const pct = Math.max(0, Math.min(100, Number(pr.pct || 0)));
      const current = Number(pr.current || 0);
      const required = Number(pr.required || 0);
      const unit = String(pr.unit || '');
      if (pct >= 100) return 'Ready to claim';
      const left = required - current;
      if (left > 0 && /^min/i.test(unit)) return `${left} min remaining`;
      if (left > 0 && unit) return `${left} ${unit} remaining`;
      return `${current} / ${required} ${unit}`.trim();
    }

    /// One adaptive surface for "what is my miner doing, and what happens
    /// next?". Mining, a known next campaign, a miner-level problem and the
    /// idle case are the same card in different shapes — never two cards saying
    /// the same thing twice. Campaign-specific blockers stay in their own
    /// conditional cards below.
    function minerStateCard(p) {
      const cfg = getStatusConfig(p);
      const accId = p.account && p.account.twitchAccountId ? String(p.account.twitchAccountId) : '';
      const refresh = accId
        ? `<button class="btn-secondary status-refresh refresh-btn" data-account-id="${esc(accId)}">
             <svg class="refresh-glyph" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-3.2-6.9"></path><path d="M21 4v5h-5"></path></svg>
             <span class="refresh-label">Refresh</span>
           </button>`
        : '';
      // A deep link to the campaign list lands here: this card is now where the
      // portal says anything about what is being or about to be mined.
      const open = `<section class="card status-card" id="route-campaigns" style="--status-color:${cfg.color}" aria-label="Miner state">`;

      // Problem states keep the plain status shape and their own semantics —
      // there is no "next" worth promising while the miner cannot mine.
      const problem = cfg.kind === 'offline' || cfg.kind === 'error'
        || cfg.kind === 'blocked' || cfg.kind === 'notConfigured';
      if (problem || (!p.activeCampaign && cfg.kind === 'waiting')) {
        return `${open}
          <div class="status-head">
            <span class="status-icon-container" aria-hidden="true">${cfg.icon}</span>
            <div class="status-card-copy">
              <h3>${esc(cfg.headline)}</h3>
              ${cfg.subtitle ? `<p>${esc(cfg.subtitle)}</p>` : ''}
            </div>
            ${refresh}
          </div>
        </section>`;
      }

      // Currently mining: the strongest state, because it is the literal answer
      // to what the miner is doing.
      if (p.activeCampaign) {
        const c = p.activeCampaign;
        const pr = c.progress || {};
        const pct = Math.max(0, Math.min(100, Number(pr.pct || 0)));
        const done = pct >= 100;
        const channel = c.currentChannelName ? `Watching ${esc(c.currentChannelName)}` : '';
        const ends = endsInPhrase(c.endsAt);
        return `${open}
          <div class="state-head">
            <span class="state-eyebrow live">Currently mining</span>
            ${refresh}
          </div>
          <div class="state-feature" data-campaign-id="${esc(c.campaignId || '')}">
            <img class="state-art" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
            <div class="state-feature-copy">
              <div class="state-title">${activeCampaignTitle(p)}</div>
              <div class="state-bar-row">
                <div class="bar"><i style="width:${pct}%${done ? ';background:linear-gradient(90deg, var(--green), #30d158);box-shadow:0 0 12px rgba(52,199,89,0.45);' : ''}"></i></div>
                <span class="state-pct${done ? ' done' : ''}">${pct}%</span>
              </div>
              <div class="state-meta">
                <div>
                  <div class="state-progress${done ? ' done' : ''}">${esc(progressSummary(pr))}</div>
                  ${ends ? `<div class="state-detail">${esc(ends)}</div>` : ''}
                </div>
                ${channel ? `<span class="state-watching">${channel}</span>` : ''}
              </div>
            </div>
          </div>
        </section>`;
      }

      const decision = upNextDecision(p);

      // A named next campaign turns the same card into Up Next.
      if (decision.kind === 'campaign') {
        const c = decision.campaign;
        const ends = endsInPhrase(c.endsAt);
        return `${open}
          <div class="state-head">
            <span class="state-eyebrow">Up next</span>
            ${refresh}
          </div>
          <div class="state-feature" data-campaign-id="${esc(c.campaignId || '')}">
            <img class="state-art" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
            <div class="state-feature-copy">
              <div class="state-title">${esc(c.game)}</div>
              <div class="state-detail">Next eligible campaign · ${esc(upNextReason(p, c.game))}</div>
              ${ends ? `<div class="state-detail">${esc(ends)}</div>` : ''}
            </div>
          </div>
          <div class="section-foot">
            <button class="text-action" id="viewcampaigns" data-focus-campaign="${esc(c.campaignId || '')}" type="button">View campaign →</button>
          </div>
        </section>`;
      }

      // Eligible campaigns exist but nothing ranks them, so the miner has not
      // made a choice we can report. Say that rather than picking one.
      if (decision.kind === 'unranked') {
        return `${open}
          <div class="state-head">
            <span class="state-eyebrow">Up next</span>
            ${refresh}
          </div>
          <div class="status-head">
            <span class="status-icon-container" style="background:rgba(86,188,255,0.15)" aria-hidden="true">
              <svg class="status-svg" viewBox="0 0 24 24" fill="none" stroke="var(--blue-a)" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"></circle><path d="M12 7v5l3 2"></path></svg>
            </span>
            <div class="status-card-copy">
              <h3>${decision.count} eligible ${decision.count === 1 ? 'campaign' : 'campaigns'}</h3>
              <p>None of them are on this miner’s priority list, so SwiftMiner will pick one as channels go live.</p>
            </div>
          </div>
          <div class="section-foot">
            <button class="text-action" id="viewcampaigns" type="button">View all campaigns →</button>
          </div>
        </section>`;
      }

      // Nothing to mine and nothing waiting: one compact green card, with no
      // second heading repeating it.
      const checked = agoText(
        (p.diagnostics && (p.diagnostics.lastCampaignRefreshAt || p.diagnostics.lastSuccessfulPollAt)) || ''
      );
      const upcoming = decision.upcoming;
      const starts = upcoming ? dateLabel(upcoming.startsAt, 'starts') : '';
      return `${open}
        <div class="status-head">
          <span class="status-icon-container" aria-hidden="true">${cfg.icon}</span>
          <div class="status-card-copy">
            <h3>${esc(cfg.headline)}</h3>
            <p>Nothing waiting to be mined. SwiftMiner will automatically resume when an eligible drop becomes available.</p>
            ${upcoming && starts ? `<p class="state-detail">Next known campaign: ${esc(upcoming.game)} ${esc(starts)}.</p>` : ''}
          </div>
          ${refresh}
        </div>
        ${checked ? `<div class="state-checked">Last checked ${esc(checked)}</div>` : ''}
      </section>`;
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
      // A row rather than a centred portrait: the account still leads the page,
      // but the status card now starts within the first screen.
      return `
        <section class="miner-identity" id="route-identity" aria-label="Twitch account">
          <div class="miner-avatar">${twitchAvatar}</div>
          <div class="miner-identity-copy">
            <h2>${esc(accountDisplayName(acc) || 'Twitch account')}</h2>
            ${accountSecondaryName(acc) ? `<p class="miner-handle">${esc(accountSecondaryName(acc))}${twitchIcon}</p>` : ''}
            <p class="miner-linked${acc.twitchAccountId ? '' : ' unlinked'}">${acc.twitchAccountId ? 'Twitch connected' : 'Twitch not connected'}</p>
          </div>
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
      setNavBack('');
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
      return `<section class="card section-card exception-card" id="route-issues" aria-label="Needs attention">
        <div class="section-head">
          <span class="section-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.3 3.6 1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.6a2 2 0 0 0-3.4 0Z"></path><path d="M12 9v4M12 17h.01"></path></svg>
          </span>
          <div class="section-title"><h3>Needs attention</h3></div>
        </div>
        <div>${rows}</div>
      </section>`;
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

    function prioritySourceOf(p) {
      return (p && p.prioritySource) || (p && p.includesGlobalPriorityGames === false ? 'personal' : 'global');
    }

    /// The games this miner's configuration actually queues, so the preview
    /// shows the effective list rather than always the operator's one.
    function priorityPreviewGames(p) {
      const source = prioritySourceOf(p);
      if (source === 'personal') return (p.personalPriorityGames || []).slice();
      if (source === 'globalAndPersonal') return (p.priorityGames || []).slice();
      return globalPriorityGames(p);
    }

    /// A compact strip: four tiles and a "+N" for the rest. This is a preview of
    /// a list, not the list, so it never grows past five tiles.
    function priorityPreview(p) {
      const games = priorityPreviewGames(p);
      if (!games.length) return '';
      let tiles = '';
      games.slice(0, 4).forEach(g => { tiles += `<img alt="" data-game="${esc(g)}" data-art="${esc(priorityArtworkURL(p, g))}">`; });
      const extra = games.length - Math.min(4, games.length);
      if (extra) tiles += `<span class="priority-art-more" aria-hidden="true">+${extra}</span>`;
      const source = prioritySourceOf(p);
      const globalCount = globalPriorityGames(p).length;
      const personalCount = (p.personalPriorityGames || []).length;
      const count = source === 'globalAndPersonal'
        ? `${globalCount} global · ${personalCount} personal`
        : `${games.length} ${games.length === 1 ? 'game' : 'games'}`;
      const managed = source === 'global'
        ? 'Managed by your operator'
        : source === 'personal' ? 'Managed by you' : 'Your priorities run first';
      return `
        <div class="priority-preview">
          <div class="global-priority-artwork">${tiles}</div>
          <div class="priority-preview-copy">
            <div class="priority-preview-count">${esc(count)}</div>
            <div class="priority-preview-more">${esc(managed)}</div>
          </div>
        </div>
      `;
    }

    /// Reading of the current source: a name and an icon, not a control.
    function prioritySourceSummary(source) {
      if (source === 'personal') {
        return {
          name: 'Personal Priorities',
          icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4"></circle><path d="M4 21a8 8 0 0 1 16 0"></path></svg>`
        };
      }
      if (source === 'globalAndPersonal') {
        return {
          name: 'Hybrid Priorities',
          icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3 9 5-9 5-9-5 9-5Z"></path><path d="m3 13 9 5 9-5"></path></svg>`
        };
      }
      return {
        name: 'Global Priorities',
        icon: `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"></circle><path d="M3 12h18"></path><path d="M12 3a15 15 0 0 1 0 18a15 15 0 0 1 0-18Z"></path></svg>`
      };
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

    /// Artwork for a personal entry: the projection's own map first, then the
    /// campaign list, and hydrateArt falls back to the CDN guess after that.
    function personalArtworkURL(p, game) {
      return priorityArtworkURL(p, game) || campaignArtworkURL(game);
    }

    /// Move / remove for one row. Move Up is disabled at the top, Move Down at
    /// the bottom, and both when there is nothing to reorder against.
    function rowMenu(i, count) {
      const first = i === 0;
      const last = i === count - 1;
      const single = count <= 1;
      return `<div class="row-menu" role="menu">
        <button class="row-menu-item" role="menuitem" data-row-move="up" ${first || single ? 'disabled' : ''}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 19V5M6 11l6-6 6 6"></path></svg>
          Move Up
        </button>
        <button class="row-menu-item" role="menuitem" data-row-move="down" ${last || single ? 'disabled' : ''}>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 5v14M6 13l6 6 6-6"></path></svg>
          Move Down
        </button>
        <div class="row-menu-sep" role="separator"></div>
        <button class="row-menu-item danger" role="menuitem" data-row-remove>
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M5 12h14"></path></svg>
          Remove from Priorities
        </button>
      </div>`;
    }

    /// This miner's own priority list, as an ordered queue rather than a bag of
    /// tags: position *is* priority here, so it is numbered and reorderable.
    /// Rendered inside the Priorities card and replaced in place by
    /// refreshPersonalDOM while a save is in flight.
    function personalCard(p) {
      const source = prioritySource || 'global';
      if (source === 'global') return '';
      const count = personal.length;
      const reorderable = count > 1;
      let rows = '';
      personal.forEach((g, i) => {
        rows += `
          <li class="priority-row" data-i="${i}"${reorderable ? ' draggable="true"' : ''}>
            <span class="priority-rank">${i + 1}</span>
            <img class="priority-row-art" alt="" data-game="${esc(g)}" data-art="${esc(personalArtworkURL(p, g))}">
            <span class="priority-row-name">${esc(g)}</span>
            <button class="priority-row-btn priority-row-menu-btn" type="button" data-menu-i="${i}"
                    aria-label="Actions for ${esc(g)}" aria-haspopup="menu" aria-expanded="${personalMenuIndex === i}">
              <svg viewBox="0 0 24 24" fill="currentColor"><circle cx="5" cy="12" r="1.7"></circle><circle cx="12" cy="12" r="1.7"></circle><circle cx="19" cy="12" r="1.7"></circle></svg>
            </button>
            ${personalMenuIndex === i ? rowMenu(i, count) : ''}
          </li>`;
      });
      // The picker is only on screen while it is being used; the rest of the
      // time, adding a game is one quiet line.
      const adder = personalAddOpen
        ? `<div class="priority-add-open">
             <input id="addgame" placeholder="Search for a game…" autocapitalize="words" autocomplete="off" list="gamesuggest" aria-label="Search for a game to prioritise">
             <button class="priority-add-cancel" id="canceladdgame" type="button">Cancel</button>
           </div>
           <div class="priority-results" id="priority-results"></div>`
        : `<button class="priority-add" id="openaddgame" type="button">
             <span class="priority-add-plus" aria-hidden="true">+</span> Add game
           </button>`;
      return `<div class="priority-personal" id="priorities-personal">
        <div class="priority-personal-head">
          <span class="priority-personal-label">Your priorities</span>
          ${count ? `<span class="section-note">${count} ${count === 1 ? 'game' : 'games'}</span>` : ''}
        </div>
        ${rows ? `<ol class="priority-rows" id="priority-rows">${rows}</ol>` : '<div class="priority-empty">No personal priorities added.</div>'}
        ${adder}
        <datalist id="gamesuggest"></datalist>
        <div class="savemsg" id="savemsg"></div>
      </div>`;
    }

    /// Exclusions are the other half of "how has this miner been told to
    /// choose", so they belong in the Priorities card — but they are a per-miner
    /// rule, and a miner on the shared list has none of its own to show. They
    /// are summarised rather than listed as rows: an exclusion has no rank.
    function exclusionsRow(p) {
      if (!(p && p.account && p.account.twitchAccountId)) return '';
      if (prioritySourceOf(p) === 'global') return '';
      const games = p.excludedGames || [];
      const summary = games.length
        ? `${games.length} ${games.length === 1 ? 'game' : 'games'} excluded`
        : 'No games excluded for this miner.';
      return `<div class="priority-exclusions">
        <div class="priority-exclusions-head">
          <span class="priority-personal-label">Excluded games</span>
          <button class="text-action" id="manageexclusions" type="button">Manage</button>
        </div>
        <div class="priority-exclusions-detail" title="${esc(games.join(', '))}">${esc(summary)}</div>
      </div>`;
    }

    /// "How has SwiftMiner been told to choose what to mine?" — one card for the
    /// source, the shared list and this miner's own additions, instead of three
    /// cards describing one decision.
    function prioritiesCard(p) {
      const source = prioritySourceOf(p);
      const editable = hasMultipleConfiguredMiners(p);
      const explainer = source === 'global'
        ? 'This miner follows the operator’s shared priority list.'
        : source === 'globalAndPersonal'
          ? 'Your priorities run first, then SwiftMiner falls back to the operator’s shared list.'
          : 'This miner uses only its own priority list.';
      // Summary first: the source is stated, and the three-way control only
      // appears once the reader asks to change it.
      const summary = prioritySourceSummary(source);
      const option = (value, name, detail) => {
        const chosen = source === value;
        return `<button type="button" class="source-option${chosen ? ' active' : ''}" data-priority-source="${value}" role="radio" aria-checked="${chosen}" title="${esc(detail)}">
          <span class="source-option-icon" aria-hidden="true">${prioritySourceSummary(value).icon}</span>
          <span class="source-option-copy">
            <span class="source-option-name">${esc(name)}</span>
            <span class="source-option-detail">${esc(detail)}</span>
          </span>
        </button>`;
      };
      const controls = prioritySourcePickerOpen ? `
          <div class="source-options" role="radiogroup" aria-label="Priority Source">
            ${option('global', 'Global', 'Uses the operator’s shared priorities.')}
            ${option('globalAndPersonal', 'Hybrid', 'Your priorities first, then Global.')}
            ${option('personal', 'Personal', 'Uses only your priorities.')}
          </div>` : '';
      const picker = `
        <div class="priority-source">
          <span class="toggle-title">Priority source</span>
          <div class="priority-source-row">
            <span class="priority-source-icon" aria-hidden="true">${summary.icon}</span>
            <span class="priority-source-name">${esc(summary.name)}</span>
            ${editable ? `<button class="btn-secondary priority-source-change" id="changeprioritysource" type="button" aria-expanded="${prioritySourcePickerOpen}">${prioritySourcePickerOpen ? 'Done' : 'Change'}</button>` : ''}
          </div>
          ${controls}
        </div>`;
      const preview = priorityPreview(p);
      const viewLink = source === 'personal' || !globalPriorityGames(p).length ? '' : `
        <div class="section-foot">
          <button class="text-action" id="viewglobalpriorities" type="button" aria-label="View Global Priorities">View priorities →</button>
        </div>`;
      return `<section class="card section-card priorities-card" id="route-priorities" aria-label="Priorities">
        <div class="section-head">
          <span class="section-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><polygon points="12 2 15.09 8.26 22 9.27 17 14.14 18.18 21.02 12 17.77 5.82 21.02 7 14.14 2 9.27 8.91 8.26 12 2"></polygon></svg>
          </span>
          <div class="section-title"><h3>Priorities</h3></div>
        </div>
        <div class="priorities-split">
          <div class="priorities-explainer">
            <p>${explainer}</p>
            ${preview}
          </div>
          ${picker}
        </div>
        ${personalCard(p)}
        ${exclusionsRow(p)}
        ${viewLink}
      </section>`;
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

    /// What SwiftMiner will actually do next, as far as the projection can say.
    /// A campaign is only named when it is eligible right now *and* the priority
    /// list ranks it — anything less is reported as waiting rather than guessed
    /// at, because this card must not imply a decision the miner has not made.
    function upNextDecision(p) {
      // A stopped miner is not about to choose anything, whatever the campaign
      // list says.
      if (p.diagnostics && p.diagnostics.isRunning === false) return { kind: 'stopped' };
      const excluded = new Set((p.excludedGames || []).map(g => String(g).toLowerCase()));
      // Games the projection is already reporting an issue for (an unlinked game
      // account, say) cannot be mined right now, so naming one as next would be
      // a guess the miner would not act on.
      const blocked = new Set((p.issues || []).map(is => String(is.game || '').toLowerCase()).filter(Boolean));
      const activeGame = p.activeCampaign ? String(p.activeCampaign.game || '').toLowerCase() : '';
      const eligible = CAMPAIGNS.filter(c => !c.requiresSubscription).filter(c => {
        if (c.status !== 'available') return false;
        const game = String(c.game || '').toLowerCase();
        if (!game || game === activeGame || excluded.has(game) || blocked.has(game)) return false;
        return Number(c.claimedDrops || 0) < Number(c.dropCount || 0);
      });
      if (!eligible.length) {
        const upcoming = CAMPAIGNS
          .filter(c => !c.requiresSubscription && c.status !== 'available' && c.startsAt)
          .sort((a, b) => new Date(a.startsAt) - new Date(b.startsAt))[0];
        return { kind: 'none', upcoming: upcoming || null };
      }
      const ranking = new Map();
      (p.priorityGames || []).forEach((g, i) => {
        const key = String(g).toLowerCase();
        if (!ranking.has(key)) ranking.set(key, i);
      });
      let best = null;
      for (const c of eligible) {
        const rank = ranking.get(String(c.game || '').toLowerCase());
        if (rank === undefined) continue;
        if (!best || rank < best.rank) best = { rank: rank, campaign: c };
      }
      if (!best) return { kind: 'unranked', count: eligible.length };
      return { kind: 'campaign', campaign: best.campaign };
    }

    /// Which list the pick came from, so the card explains the decision instead
    /// of only announcing it.
    function upNextReason(p, game) {
      const source = prioritySourceOf(p);
      const isPersonal = (p.personalPriorityGames || []).some(g => String(g).toLowerCase() === String(game).toLowerCase());
      if (source === 'personal') return 'Your priority';
      if (source === 'globalAndPersonal' && isPersonal) return 'Your priority';
      return 'Global priority';
    }

    /// The browsable campaign list, moved off the overview but kept whole — it
    /// is still where a game gets prioritised from.
    function campaignsModal(p) {
      const accountId = p && p.account && p.account.twitchAccountId;
      const campaigns = CAMPAIGNS.filter(c => !c.requiresSubscription);
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
      return `<div class="modal-backdrop" id="campaignsmodal">
        <section class="modal-card" role="dialog" aria-modal="true" aria-labelledby="campaignstitle" tabindex="-1">
          <div class="modal-header">
            <div class="copy">
              <div class="modal-title" id="campaignstitle">Campaigns</div>
              <div class="modal-subtitle">Every campaign SwiftMiner can currently mine for this account.</div>
            </div>
            <button class="btn-secondary" id="closecampaigns" type="button">Close</button>
          </div>
          <div class="campaign-list">${rows || '<div class="muted">No campaigns are available right now.</div>'}</div>
          ${accountId ? '' : '<div class="muted" style="font-size:12px;margin-top:10px">Link Twitch before setting priorities.</div>'}
        </section>
      </div>`;
    }

    function closeCampaignsModal() {
      campaignsModalOpen = false;
      campaignsModalFocusId = null;
      render(PROJ);
    }

    function wireCampaignsModal() {
      const open = $('viewcampaigns');
      if (open) open.addEventListener('click', () => {
        campaignsModalFocusId = open.dataset.focusCampaign || null;
        campaignsModalOpen = true;
        render(PROJ);
      });
      const modal = $('campaignsmodal');
      if (!modal) return;
      const dialog = modal.querySelector('[role="dialog"]');
      if (dialog) dialog.focus();
      if (campaignsModalFocusId) {
        const row = modal.querySelector('[data-campaign-id="' + cssEscape(campaignsModalFocusId) + '"]');
        if (row) {
          row.scrollIntoView({ block: 'center' });
          row.classList.add('route-focus');
          window.setTimeout(() => row.classList.remove('route-focus'), 2600);
        }
      }
      $('closecampaigns').addEventListener('click', closeCampaignsModal);
      modal.addEventListener('click', event => { if (event.target === modal) closeCampaignsModal(); });
      modal.addEventListener('keydown', event => { if (event.key === 'Escape') closeCampaignsModal(); });
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
      return `<section class="card section-card exception-card" id="route-subscription" aria-label="Subscription required">
        <div class="section-head">
          <span class="section-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="10" width="18" height="11" rx="2"></rect><path d="M8 10V7a4 4 0 0 1 8 0v3"></path></svg>
          </span>
          <div class="section-title"><h3>Subscription required</h3></div>
          <span class="section-note">${campaigns.length} ${campaigns.length === 1 ? 'campaign' : 'campaigns'}</span>
        </div>
        <div class="campaign-list">${rows}</div>
      </section>`;
    }

    function completedTitle(c) {
      return c.campaignName && String(c.campaignName).toLowerCase() !== String(c.game).toLowerCase()
        ? `${esc(c.game)} — ${esc(c.campaignName)}`
        : esc(c.game);
    }

    function completedRow(c) {
      const claimed = Number(c.claimedDrops || 0);
      const total = Number(c.totalDrops || 0);
      const complete = total > 0 && claimed >= total;
      const when = agoText(c.completedAt);
      return `<div class="completed-row">
        <img class="completed-art" alt="" data-game="${esc(c.game)}" data-art="${esc(c.boxArtURL || '')}">
        <div class="completed-copy">
          <div class="completed-title">${completedTitle(c)}</div>
          ${when ? `<div class="completed-when">${esc(when)}</div>` : ''}
        </div>
        <span class="completed-tally">${claimed} / ${total}</span>
        <span class="completed-check" style="${complete ? '' : 'color:var(--muted);background:rgba(255,255,255,0.08)'}" aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round"><path d="m5 12.5 4.5 4.5L19 7.5"></path></svg>
        </span>
      </div>`;
    }

    /// The most recent completions only. The full history is a click away
    /// rather than the tallest thing on the page.
    function dropsCard(p) {
      const recents = p.recentCompletedCampaigns || [];
      const dropsThisWeek = Number(p.dropsClaimedThisWeek || 0);
      if (!recents.length && !dropsThisWeek) return '';
      const shown = recents.slice(0, 4);
      const rows = shown.map(completedRow).join('');
      const countLabel = `${dropsThisWeek} this week`;
      const countTitle = `${dropsThisWeek} ${dropsThisWeek === 1 ? 'drop' : 'drops'} claimed this week`;
      const empty = rows ? '' : '<div class="empty-activity">No campaign completions to show yet.</div>';
      return `<section class="card section-card" id="route-drops" aria-label="Recent completed drops">
        <div class="section-head">
          <span class="section-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"></circle><path d="m8.5 12 2.5 2.5 4.5-5"></path></svg>
          </span>
          <div class="section-title"><h3>Recent Completed Drops</h3></div>
          <span class="section-note" title="${esc(countTitle)}" aria-label="${esc(countTitle)}">${esc(countLabel)}</span>
        </div>
        <div class="completed-list">${rows || empty}</div>
        ${recents.length > shown.length ? `<div class="section-foot"><button class="text-action" id="viewalldrops" type="button">View all completed drops →</button></div>` : ''}
      </section>`;
    }

    function completedDropsModal(p) {
      const rows = (p.recentCompletedCampaigns || []).map(completedRow).join('');
      return `<div class="modal-backdrop" id="completeddropsmodal">
        <section class="modal-card" role="dialog" aria-modal="true" aria-labelledby="completeddropstitle" tabindex="-1">
          <div class="modal-header">
            <div class="copy">
              <div class="modal-title" id="completeddropstitle">Completed drops</div>
              <div class="modal-subtitle">Every campaign this miner has finished.</div>
            </div>
            <button class="btn-secondary" id="closecompleteddrops" type="button">Close</button>
          </div>
          <div class="completed-list">${rows || '<div class="muted">No campaign completions to show yet.</div>'}</div>
        </section>
      </div>`;
    }

    function closeCompletedDropsModal() {
      completedDropsModalOpen = false;
      render(PROJ);
    }

    function wireCompletedDrops() {
      const open = $('viewalldrops');
      if (open) open.addEventListener('click', () => { completedDropsModalOpen = true; render(PROJ); });
      const modal = $('completeddropsmodal');
      if (!modal) return;
      const dialog = modal.querySelector('[role="dialog"]');
      if (dialog) dialog.focus();
      $('closecompleteddrops').addEventListener('click', closeCompletedDropsModal);
      modal.addEventListener('click', event => { if (event.target === modal) closeCompletedDropsModal(); });
      modal.addEventListener('keydown', event => { if (event.key === 'Escape') closeCompletedDropsModal(); });
    }

    function operatorBackCard(p) {
      if (OPERATOR_MINERS.length <= 1) return '';
      return `<button class="detail-back" id="backoverview" type="button" aria-label="Back to all miners">‹ All Miners</button>`;
    }

    function accountRemovalCard(p) {
      if (!SESSION || !(p && p.account && p.account.twitchAccountId)) return '';
      if (SESSION.provider === 'local' && !SESSION.allows_operator_account_removal) return '';
      return `<section class="card section-card danger-card" aria-label="Remove account">
        <div class="section-head">
          <span class="section-icon" aria-hidden="true">
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"></circle><path d="M12 7.5v5.5M12 16.5h.01"></path></svg>
          </span>
          <div class="section-title"><h3>Remove account</h3></div>
          <button class="btn-secondary btn-danger-outline" id="removeaccount" data-remove-account-id="${esc(p.account.twitchAccountId)}" type="button">Remove</button>
        </div>
        <div class="section-body">
          <p>Stops mining, removes this account from SwiftMiner, and revokes its Twitch authorization.</p>
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
      // Account → what it is doing → what it will do next → why → what it has
      // done → the one destructive action, in that order and nothing repeated.
      $('app').innerHTML = `<main class="miner-detail">${minerIdentity(p)}${minerStateCard(p)}${activationCard(p)}${prioritiesCard(p)}${issuesCard(p)}${subscriptionRequiredCard()}${dropsCard(p)}${accountRemovalCard(p)}${globalPrioritiesModalOpen ? globalPrioritiesModal(p) : ''}${campaignsModalOpen ? campaignsModal(p) : ''}${completedDropsModalOpen ? completedDropsModal(p) : ''}${exclusionsModalOpen ? exclusionsModal(p) : ''}${accountRemovalModalOpen ? accountRemovalModal() : ''}</main>`;
      setNavBack(operatorBackCard(p));
      hydrateArt();
      wireActivation();
      wireOperatorBack();
      wireIssues();
      wireCampaigns();
      wirePersonal();
      wirePrioritySource();
      const viewGlobalPriorities = $('viewglobalpriorities');
      if (viewGlobalPriorities) viewGlobalPriorities.addEventListener('click', () => {
        globalPrioritiesModalOpen = true;
        render(PROJ);
      });
      wireGlobalPrioritiesModal();
      wireCampaignsModal();
      wireCompletedDrops();
      wireExclusions();
      wireAccountRemoval();
      fillGameOptions();
      applyRoute();
    }

    /// "All Miners" belongs to the page chrome, not the content column.
    function setNavBack(html) {
      const slot = $('navback');
      if (slot) slot.innerHTML = html || '';
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

    function movePersonal(from, to) {
      if (from === to || from < 0 || to < 0 || from >= personal.length || to >= personal.length) return;
      const [moved] = personal.splice(from, 1);
      personal.splice(to, 0, moved);
      commit();
    }

    /// Up to eight matches, so the picker stays a picker rather than a list of
    /// every game Twitch has ever run a campaign for.
    function personalSearchResults(query) {
      const needle = String(query || '').trim().toLowerCase();
      if (!needle) return [];
      const taken = new Set(personal.map(g => g.toLowerCase()));
      return GAMES.filter(g => {
        const key = String(g).toLowerCase();
        return key.includes(needle) && !taken.has(key);
      }).slice(0, 8);
    }

    function renderPersonalResults() {
      const box = $('priority-results');
      const input = $('addgame');
      if (!box || !input) return;
      const matches = personalSearchResults(input.value);
      if (!matches.length) {
        box.innerHTML = input.value.trim()
          ? '<div class="priority-empty">No matching games. Press Enter to add it anyway.</div>'
          : '';
        return;
      }
      box.innerHTML = matches.map(g => `<button class="priority-result" data-add-game="${esc(g)}" type="button">
        <img class="priority-row-art" alt="" data-game="${esc(g)}" data-art="${esc(personalArtworkURL(PROJ, g))}">
        <span class="priority-row-name">${esc(g)}</span>
      </button>`).join('');
      hydrateArt(box);
      box.querySelectorAll('[data-add-game]').forEach(btn => {
        btn.addEventListener('click', () => addPersonalGame(btn.dataset.addGame, 'append'));
      });
    }

    function wirePersonal() {
      const rows = $('priority-rows');
      if (rows) {
        rows.querySelectorAll('.priority-row-menu-btn').forEach(btn => {
          btn.addEventListener('click', event => {
            event.stopPropagation();
            const i = Number(btn.dataset.menuI);
            personalMenuIndex = personalMenuIndex === i ? null : i;
            refreshPersonalDOM('', '');
          });
        });
        const openMenu = rows.querySelector('.row-menu');
        if (openMenu) {
          const first = openMenu.querySelector('.row-menu-item:not([disabled])');
          if (first) first.focus();
          openMenu.addEventListener('keydown', event => {
            if (event.key !== 'Escape') return;
            personalMenuIndex = null;
            refreshPersonalDOM('', '');
          });
          const from = personalMenuIndex;
          openMenu.querySelectorAll('[data-row-move]').forEach(item => {
            item.addEventListener('click', () => {
              personalMenuIndex = null;
              movePersonal(from, item.dataset.rowMove === 'up' ? from - 1 : from + 1);
            });
          });
          const remove = openMenu.querySelector('[data-row-remove]');
          if (remove) remove.addEventListener('click', () => {
            personalMenuIndex = null;
            personal.splice(from, 1);
            commit();
          });
        }
        let dragIndex = null;
        rows.querySelectorAll('.priority-row').forEach(row => {
          row.addEventListener('dragstart', event => {
            dragIndex = Number(row.dataset.i);
            row.classList.add('dragging');
            if (event.dataTransfer) {
              event.dataTransfer.effectAllowed = 'move';
              // Firefox refuses to start a drag without payload.
              event.dataTransfer.setData('text/plain', String(dragIndex));
            }
          });
          row.addEventListener('dragend', () => {
            dragIndex = null;
            rows.querySelectorAll('.priority-row').forEach(r => r.classList.remove('dragging', 'drag-over'));
          });
          row.addEventListener('dragover', event => {
            if (dragIndex === null) return;
            event.preventDefault();
            if (event.dataTransfer) event.dataTransfer.dropEffect = 'move';
            row.classList.add('drag-over');
          });
          row.addEventListener('dragleave', () => row.classList.remove('drag-over'));
          row.addEventListener('drop', event => {
            event.preventDefault();
            row.classList.remove('drag-over');
            if (dragIndex === null) return;
            const to = Number(row.dataset.i);
            const from = dragIndex;
            dragIndex = null;
            movePersonal(from, to);
          });
        });
      }

      const open = $('openaddgame');
      if (open) open.addEventListener('click', () => {
        personalAddOpen = true;
        refreshPersonalDOM('', '');
        const input = $('addgame');
        if (input) input.focus();
      });
      const cancel = $('canceladdgame');
      if (cancel) cancel.addEventListener('click', () => {
        personalAddOpen = false;
        refreshPersonalDOM('', '');
      });

      const input = $('addgame');
      if (!input) return;
      input.addEventListener('input', renderPersonalResults);
      input.addEventListener('keydown', event => {
        if (event.key === 'Escape') {
          event.preventDefault();
          personalAddOpen = false;
          refreshPersonalDOM('', '');
          return;
        }
        if (event.key !== 'Enter') return;
        event.preventDefault();
        // A name that matched nothing is still allowed: campaigns appear before
        // the game list catches up.
        const first = personalSearchResults(input.value)[0];
        addPersonalGame(first || input.value, 'append');
      });
      renderPersonalResults();
    }

    /// Wired once per full render: neither the disclosure button nor the source
    /// buttons are replaced by the in-place personal-list refresh, so wiring
    /// them there would stack a second listener on every save.
    function wirePrioritySource() {
      const change = $('changeprioritysource');
      if (change) change.addEventListener('click', () => {
        prioritySourcePickerOpen = !prioritySourcePickerOpen;
        render(PROJ);
      });
      document.querySelectorAll('[data-priority-source]').forEach(btn => {
        btn.addEventListener('click', () => {
          prioritySource = btn.dataset.prioritySource || 'global';
          includeGlobalPriorities = prioritySource !== 'personal';
          prioritySourcePickerOpen = false;
          commit();
        });
      });
    }

    function addPersonalGame(name, placement) {
      name = String(name || '').trim();
      if (!name) return;
      if (!personal.some(g => g.toLowerCase() === name.toLowerCase())) {
        // "Prioritise" means top of the queue; the picker appends, because the
        // reader chose a game, not a rank.
        if (placement === 'append') personal.push(name); else personal.unshift(name);
      }
      if (prioritySource === 'global') prioritySource = 'globalAndPersonal';
      personalAddOpen = false;
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
      const current = $('priorities-personal');
      if (!current) return;
      const wrapper = document.createElement('div');
      wrapper.innerHTML = personalCard(PROJ);
      const next = wrapper.firstElementChild;
      if (!next) return;
      current.replaceWith(next);
      hydrateArt(next);
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
      setNavBack('');
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
        updateFooter();
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

    /// Understated version/attribution line. The version comes from whatever
    /// process is serving the dashboard, so it is simply left out when the
    /// service runs standalone and has no bundle version to report.
    function updateFooter() {
      const el = $('footer-meta');
      if (!el) return;
      const raw = SESSION && typeof SESSION.app_version === 'string' ? SESSION.app_version.trim() : '';
      const version = raw.replace(/^v/i, '');
      // The engine version is compiled into the service, so unlike the bundle
      // version it is always present, standalone or not.
      const engine = SESSION && typeof SESSION.engine_version === 'string' ? SESSION.engine_version.trim() : '';
      el.textContent = `© ${new Date().getFullYear()} SwiftMiner`
        + (version ? ` · v${version}` : '')
        + (engine ? ` · engine ${engine}` : '');
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

    document.addEventListener('click', (e) => {
      if (personalMenuIndex === null) return;
      if (e.target.closest('.row-menu') || e.target.closest('.priority-row-menu-btn')) return;
      personalMenuIndex = null;
      refreshPersonalDOM('', '');
    });

    document.addEventListener('click', async (e) => {
      const btn = e.target.closest('.refresh-btn');
      if (!btn) return;
      e.stopPropagation();
      e.preventDefault();
      
      const accountId = btn.dataset.accountId;
      if (!accountId) return;
      
      // Keep the glyph: only the label swaps while the refresh is in flight.
      const label = btn.querySelector('.refresh-label') || btn;
      const originalText = label.textContent;
      label.textContent = 'Refreshed';
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
        label.textContent = originalText;
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
