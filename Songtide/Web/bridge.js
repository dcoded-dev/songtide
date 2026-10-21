// Injected into music.youtube.com. Hides YouTube Music's own chrome (the native
// app provides sidebar, toolbar and player bar), reports player state to Swift
// and exposes commands on window.__ytmNative.
(() => {
  if (window.__ytmNative || location.hostname !== 'music.youtube.com') return;

  const post = (type, payload) => {
    try { window.webkit.messageHandlers.ytm.postMessage({ type, payload: JSON.stringify(payload) }); } catch (_) {}
  };

  const CSS = `
    ytmusic-app-layout {
      --ytmusic-nav-bar-height: 0px !important;
      --ytmusic-player-bar-height: 0px !important;
      --ytmusic-guide-width: 0px !important;
      --ytmusic-mini-guide-width: 0px !important;
    }
    ytmusic-app-layout > [slot=nav-bar], #nav-bar-background, #nav-bar-divider,
    #guide, #mini-guide, #mini-guide-background,
    ytmusic-player-bar, #player-bar-background,
    ytmusic-mealbar-promo-renderer, ytmusic-statement-banner-renderer { display: none !important; }
    ytmusic-app-layout > #content { margin-left: 0 !important; padding-top: 0 !important; }
    /* YouTube's floating corner video when a video plays off the player page. It stays rendered
       (hiding it with display: none would stop playback), just invisible, unless asked for with
       the video's mini player button. */
    html:not(.ytm-miniplayer) ytmusic-app-layout[player-ui-state=MINIPLAYER] #player,
    html:not(.ytm-miniplayer) ytmusic-player[player-ui-state=MINIPLAYER] { opacity: 0 !important; pointer-events: none !important; }
    /* Asked for: in the bottom corner. YouTube places it above its own player bar, which is
       hidden here, so it would otherwise land off the page. It's positioned within the closed
       player page, which waits one page-height below the view: hence 100% + the margin. */
    html.ytm-miniplayer ytmusic-app-layout[player-ui-state=MINIPLAYER] #player {
      top: auto !important; bottom: calc(100% + 16px) !important; right: 16px !important;
      transform: none !important; opacity: 1 !important;
      border-radius: 10px; overflow: hidden;
      box-shadow: 0 0 0 .5px rgba(255,255,255,.15), 0 12px 40px rgba(0,0,0,.6);
    }

    /* Native look: system font and the macOS accent color instead of YouTube red. The page keeps
       YouTube Music's own near-black background, which its header artwork gradients fade into. */
    html, body, ytmusic-app {
      --ytmusic-color-youtubered: var(--ytm-accent) !important;
      --yt-deprecated-brand-youtube-red: var(--ytm-accent) !important;
      --yt-sys-color-baseline--static-brand-red: var(--ytm-accent) !important;
    }
    html { scrollbar-width: thin; scrollbar-color: rgba(255,255,255,.28) transparent; }
    body, body *:not(svg):not(path) {
      font-family: -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif !important;
    }

    /* Native behaviour: arrow cursor, no text selection or image dragging outside fields. */
    body { -webkit-user-select: none; cursor: default; }
    a, button, [role=button], [role=menuitem], [role=tab], [role=option], .yt-simple-endpoint,
    tp-yt-paper-item, tp-yt-paper-icon-button, yt-icon-button, ytmusic-thumbnail-renderer { cursor: default !important; }
    input, textarea, [contenteditable=true] { -webkit-user-select: text; cursor: text !important; }
    img, a { -webkit-user-drag: none; }
    a:hover, yt-formatted-string a:hover, .yt-simple-endpoint:hover { text-decoration: none !important; }

    /* Native shapes: capsule chips, macOS-style sheets. */
    ytmusic-chip-cloud-chip-renderer .gradient-box,
    ytmusic-chip-cloud-chip-renderer a { border-radius: 999px !important; }
    tp-yt-paper-dialog {
      border-radius: 12px !important;
      background: var(--ytm-raised) !important;
      box-shadow: 0 0 0 .5px rgba(255,255,255,.12), 0 24px 64px rgba(0,0,0,.55) !important;
    }

    /* Toasts ("Saved to Liked Music", "Video not available"…): YouTube lifts them to clear its own
       player bar, which is hidden here, and draws them as a white box in the corner. Instead:
       centred just above Songtide's bar, as a light pill that stands out on the dark page. (Centred with
       margins, not a transform, so YouTube's own show/hide animation still works.) Every toast, not
       just #toast: some ("Starting radio") come from a second toast element. */
    tp-yt-paper-toast {
      left: 0 !important; right: 0 !important; bottom: 16px !important; top: auto !important;
      margin: 0 auto !important; width: fit-content !important; min-width: 0 !important;
      max-width: min(480px, calc(100% - 32px)) !important;
      padding: 11px 20px !important;
      /* YouTube's 48px minimum (and the extra padding inside some toasts) left the one line of text
         sitting high; the padding alone sets the height, so the text is centred. */
      min-height: 0 !important;
      border-radius: 999px !important;
      background: rgba(248, 248, 250, .97) !important;
      color: #111 !important;
      font-size: 14px !important; font-weight: 600 !important;
      box-shadow: 0 0 0 .5px rgba(0,0,0,.2), 0 12px 36px rgba(0,0,0,.6) !important;
    }
    tp-yt-paper-toast #text-container { padding: 0 !important; }
    tp-yt-paper-toast #text, tp-yt-paper-toast #sub-text {
      color: #111 !important; font-size: 14px !important; font-weight: 600 !important;
    }
    tp-yt-paper-toast yt-button-renderer, tp-yt-paper-toast yt-button-shape button {
      color: var(--ytm-accent) !important; background: transparent !important;
    }

    /* Item menus are shown as native NSMenus; keep YouTube's popup invisible but clickable. */
    ytmusic-popup-container tp-yt-iron-dropdown:has(ytmusic-menu-popup-renderer) {
      opacity: 0 !important; pointer-events: none !important;
    }
    html.ytm-native-account ytmusic-popup-container tp-yt-iron-dropdown { opacity: 0 !important; pointer-events: none !important; }
    html.ytm-native-sharing tp-yt-paper-dialog, html.ytm-native-sharing tp-yt-iron-overlay-backdrop { opacity: 0 !important; }

    /* Screenshot mode (switched on only from a Debug build, for App Store screenshots): album and
       video artwork is third-party content, so every cover becomes a plain gradient tile. */
    html.ytm-screenshot img, html.ytm-screenshot video { visibility: hidden !important; }
    html.ytm-screenshot { --shot: linear-gradient(135deg, #5b6cff, #8e44ad); }
    html.ytm-screenshot :is(ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item):nth-child(6n+1) { --shot: linear-gradient(135deg, #ff8a5c, #d63d6c); }
    html.ytm-screenshot :is(ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item):nth-child(6n+2) { --shot: linear-gradient(135deg, #36c2b4, #2466c9); }
    html.ytm-screenshot :is(ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item):nth-child(6n+3) { --shot: linear-gradient(135deg, #f7c948, #e8743b); }
    html.ytm-screenshot :is(ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item):nth-child(6n+4) { --shot: linear-gradient(135deg, #a17cf2, #5b3cc4); }
    html.ytm-screenshot :is(ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item):nth-child(6n+5) { --shot: linear-gradient(135deg, #5fd38d, #1f8a70); }
    html.ytm-screenshot :is(ytmusic-two-row-item-renderer, ytmusic-responsive-list-item-renderer, ytmusic-player-queue-item):nth-child(6n+6) { --shot: linear-gradient(135deg, #ff6fa9, #9b3fd1); }
    html.ytm-screenshot ytmusic-thumbnail-renderer, html.ytm-screenshot yt-img-shadow,
    html.ytm-screenshot ytmusic-player #song-image, html.ytm-screenshot ytmusic-player #movie_player {
      background: var(--shot) !important;
    }
  `;
  const setTheme = (theme) => {
    if (!theme) return;
    let s = document.getElementById('ytm-native-theme');
    if (!s) {
      s = document.createElement('style');
      s.id = 'ytm-native-theme';
      (document.head || document.documentElement).appendChild(s);
    }
    s.textContent = `html { --ytm-accent: ${theme.accent} !important; --ytm-bg: ${theme.bg} !important; --ytm-raised: ${theme.raised} !important; }`;
  };
  setTheme(window.__ytmTheme);
  document.addEventListener('DOMContentLoaded', () => setTheme(window.__ytmTheme));
  const addStyle = () => {
    if (document.getElementById('ytm-native-css')) return;
    const s = document.createElement('style');
    s.id = 'ytm-native-css';
    s.textContent = CSS;
    (document.head || document.documentElement).appendChild(s);
  };
  addStyle();
  document.addEventListener('DOMContentLoaded', addStyle);

  // YouTube Music's own shortcuts (e.g. "f" for its full-screen player) ignore modifiers
  // and mark the event handled, which stops macOS from seeing ⌃⌘F and friends. Hide
  // ⌘/⌃ combos from page scripts; the browser's default actions (copy, paste…) still run.
  window.addEventListener('keydown', (e) => {
    if (e.metaKey || e.ctrlKey) e.stopImmediatePropagation();
  }, true);

  const $ = (sel, root = document) => root.querySelector(sel);
  const app = () => $('ytmusic-app');
  const player = () => document.getElementById('movie_player');
  const video = () => $('video');
  const bar = () => $('ytmusic-player-bar');
  const click = (sel) => { const el = $(sel); if (el) { el.click(); return true; } return false; };
  const runsText = (t) => t?.runs?.map((r) => r.text).join('') || t?.simpleText || '';
  const label = (el) => el ? (el.getAttribute('title') || el.getAttribute('aria-label') || $('button', el)?.getAttribute('aria-label') || '') : '';

  const bestArtwork = (md) => {
    const art = md?.artwork ? [...md.artwork] : [];
    art.sort((a, b) => (parseInt(b.sizes) || 0) - (parseInt(a.sizes) || 0));
    return art[0]?.src || '';
  };

  function snapshot() {
    const s = snapshotBase();
    // Screenshot mode hides artwork on the page; the native player bar shows its placeholder too.
    if (document.documentElement.classList.contains('ytm-screenshot')) s.artwork = '';
    return s;
  }
  function snapshotBase() {
    const v = video(), p = player(), b = bar();
    const md = navigator.mediaSession?.metadata;
    const title = md?.title || $('.title', b || document)?.textContent?.trim() || '';
    const duration = v && isFinite(v.duration) && v.duration > 0 ? v.duration : (p?.getDuration?.() || 0);
    const repeatLabel = label($('.repeat', b || document));
    return {
      title,
      artist: md?.artist || '',
      album: md?.album || '',
      artwork: bestArtwork(md) || (/^https?:\/\/.+\.(ggpht|googleusercontent|ytimg)\./.test($('img.image', b || document)?.getAttribute('src') || '') ? $('img.image', b).getAttribute('src') : ''),
      videoId: p?.getVideoData?.()?.video_id || '',
      isPlaying: !!v && !v.paused && !v.ended,
      time: v?.currentTime || 0,
      duration,
      volume: p?.getVolume?.() ?? 100,
      muted: p?.isMuted?.() ?? false,
      like: $('ytmusic-like-button-renderer', b || document)?.getAttribute('like-status') || 'INDIFFERENT',
      repeat: /one/i.test(repeatLabel) ? 'one' : /all/i.test(repeatLabel) ? 'all' : 'off',
      shuffle: !!b?.hasAttribute('shuffle-on'),
      playerPageOpen: !!$('ytmusic-app-layout')?.hasAttribute('player-page-open'),
    };
  }

  // The account menu (opened invisibly) holds the profile header and, one page in, the list of
  // channels the user can switch between. Nothing here is visible to the user.
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const waitFor = async (find, tries = 40) => {
    for (let i = 0; i < tries; i++) { const found = find(); if (found) return found; await sleep(75); }
    return null;
  };
  // Only elements on the menu page actually showing count; others linger in the DOM hidden.
  // (Walks the ancestors rather than checking for a layout box: these custom elements often have
  // none of their own even while showing.)
  const isDisplayed = (el) => {
    if (!el) return false;
    for (let n = el; n && n !== document.body; n = n.parentElement || n.getRootNode().host) {
      if (n.hidden || getComputedStyle(n).display === 'none') return false;
    }
    return true;
  };
  const visibleChannelItems = () => [...document.querySelectorAll('ytd-account-item-renderer')].filter(isDisplayed);

  // Opens the menu and reports which page it opened on: YouTube Music reopens it on whichever
  // page was last shown ('main' with the profile header, or 'channels'), or null on failure.
  const openAccountMenu = async () => {
    document.documentElement.classList.add('ytm-native-account');
    const button = $('ytmusic-settings-button');
    if (!button) return null;
    ($('button, tp-yt-paper-icon-button, #button', button) || button).click();
    return waitFor(() => isDisplayed($('ytd-active-account-header-renderer')) ? 'main'
                       : visibleChannelItems().length ? 'channels' : null);
  };
  const closeAccountMenu = () => {
    [...document.querySelectorAll('ytmusic-popup-container tp-yt-iron-dropdown')].forEach((dd) => { if (dd.opened) dd.close(); });
    setTimeout(() => document.documentElement.classList.remove('ytm-native-account'), 300);
  };
  const openChannelList = async () => {
    const item = [...document.querySelectorAll('ytmusic-popup-container ytd-compact-link-renderer')].find((el) => {
      const d = el.data || el.__data?.data || {};
      return /SWITCH_ACCOUNT/i.test(d.icon?.iconType || '') || /switch account/i.test(el.textContent);
    });
    if (!item) return false;
    ($('a, tp-yt-paper-item', item) || item).click();
    return !!(await waitFor(() => visibleChannelItems().length));
  };
  const readChannels = () => [...document.querySelectorAll('ytd-account-section-list-renderer')].filter(isDisplayed).flatMap((section) => {
    const header = (section.data || section.__data?.data || {}).header?.googleAccountHeaderRenderer;
    const email = runsText(header?.email);
    return [...section.querySelectorAll('ytd-account-item-renderer')].filter(isDisplayed).map((el) => {
      const d = el.data || el.__data?.data || {};
      return {
        name: runsText(d.accountName),
        byline: runsText(d.accountByline),
        handle: runsText(d.channelHandle),
        photo: d.accountPhoto?.thumbnails?.slice(-1)[0]?.url || '',
        selected: !!d.isSelected,
        email,
      };
    });
  }).map((channel, index) => ({ ...channel, index }));

  let profile = null, profileAttempt = 0;
  const loadProfile = async () => {
    profileAttempt = Date.now();
    const page = await openAccountMenu();
    if (page === 'main') {
      const d = $('ytd-active-account-header-renderer')?.data || $('ytd-active-account-header-renderer')?.__data?.data;
      if (d) {
        profile = {
          name: runsText(d.accountName),
          handle: runsText(d.channelHandle),
          avatar: d.accountPhoto?.thumbnails?.slice(-1)[0]?.url || '',
        };
      }
      if (await openChannelList()) post('channels', readChannels());
    } else if (page === 'channels') {
      // Opened straight on the channel list: the active channel doubles as the profile.
      const channels = readChannels();
      post('channels', channels);
      const active = channels.find((c) => c.selected);
      if (active) profile = { name: active.name, handle: active.handle, avatar: active.photo };
    }
    closeAccountMenu();
  };

  // Switches to the channel at `index`, checking the name still matches in case the list changed.
  const switchChannel = async (index, name) => {
    const page = await openAccountMenu();
    if (page === 'channels' || (page === 'main' && await openChannelList())) {
      const el = visibleChannelItems()[index];
      const d = el?.data || el?.__data?.data || {};
      if (el && runsText(d.accountName) === name) {
        ($('tp-yt-paper-icon-item, a, #contentIcon', el) || el).click();
        profile = null; // the page reloads as the new channel; re-read the profile then
      }
    }
    closeAccountMenu();
  };

  function account() {
    // Until the nav bar has rendered either the avatar button or the sign-in link, the state is
    // unknown; report nothing so the app keeps showing the cached account instead of "Sign in".
    const settings = $('ytmusic-settings-button'), signInLink = $('a.sign-in-link');
    if (!settings && !signInLink) return null;
    const signedIn = !!settings && !signInLink;
    if (!signedIn) profile = null;
    else if (!profile && Date.now() - profileAttempt > 30000 && app()) loadProfile();
    return { signedIn, name: profile?.name || '', handle: profile?.handle || '', avatar: profile?.avatar || '' };
  }

  function playlists() {
    const seen = new Set(), out = [];
    document.querySelectorAll('#guide ytmusic-guide-entry-renderer').forEach((el) => {
      const d = el.data || el.__data?.data;
      const id = d?.navigationEndpoint?.browseEndpoint?.browseId;
      if (!d || d.isPrimary || !id || seen.has(id)) return;
      seen.add(id);
      const title = d.formattedTitle?.runs?.map((r) => r.text).join('') || d.formattedTitle?.simpleText || el.innerText.trim().split('\n')[0];
      const subtitle = d.formattedSubtitle?.runs?.map((r) => r.text).join('') || '';
      out.push({ id, title, subtitle, pinned: !!d.subtitleBadges?.length });
    });
    return out;
  }

  // Only post when something changed; progress ticks at ~2Hz while playing.
  let last = {};
  const send = (type, value) => {
    const json = JSON.stringify(value);
    if (last[type] === json) return;
    last[type] = json;
    post(type, value);
  };
  // YouTube Music defaults to the music video. Switch each new track to "Song" once (so
  // choosing Video by hand sticks for that track), unless disabled in Settings.
  let songModeTrack = '';
  // Picking Song or Video yourself wins for that track. The song and its video are separate
  // items (different IDs), so the one it switches to counts as the same track.
  let chosenMode = null; // { ids: Set, at: time of the click }
  document.addEventListener('click', (e) => {
    if (!e.isTrusted || !e.target.closest?.('ytmusic-av-toggle')) return;
    const id = player()?.getVideoData?.()?.video_id;
    chosenMode = { ids: new Set(id ? [id] : []), at: Date.now() };
  }, true);

  const preferSong = () => {
    if (window.__ytmPrefs?.preferSong === false) return;
    const toggle = $('ytmusic-av-toggle');
    const id = player()?.getVideoData?.()?.video_id;
    if (chosenMode && id) {
      // The switch lands within a few seconds of the click; any later new ID is the next track.
      if (!chosenMode.ids.has(id) && Date.now() - chosenMode.at < 5000) chosenMode.ids.add(id);
      if (chosenMode.ids.has(id)) { songModeTrack = id; return; }
      chosenMode = null;
    }
    if (!toggle || !id || id === songModeTrack) return;
    if (toggle.hasAttribute('toggle-disabled') || toggle.getAttribute('playback-mode') === 'NONE') return; // not ready yet
    songModeTrack = id;
    if (toggle.hasAttribute('audio-only-playback-available') && toggle.getAttribute('is-video-playback-mode-selected') === 'true') {
      $('.song-button', toggle)?.click();
    }
  };

  // State and location are cheap and change often; account and playlists rarely change, so they're
  // re-read every 5s (and straight after navigation).
  // The page's own heading (a playlist, album, artist or mood name), or the query on search pages.
  const pageTitle = () => {
    if (location.pathname === '/search') return new URLSearchParams(location.search).get('q') || 'Search';
    const heading = [...document.querySelectorAll('h1')].find((h) => h.offsetParent);
    return heading?.textContent.trim() || '';
  };

  // The mini player shows only when asked for (its button), until it's closed or expanded again.
  document.addEventListener('click', (e) => {
    const button = e.target.closest?.('button, tp-yt-paper-icon-button, yt-icon-button');
    const name = button && (button.getAttribute('aria-label') || button.title || '');
    if (/mini ?player/i.test(name || '')) {
      document.documentElement.classList.add('ytm-miniplayer');
      miniPlayerAsked = Date.now();
    }
  }, true);
  let miniPlayerAsked = 0;
  // YouTube drops the mini player whenever the page is resized (the visualizer opening beside it,
  // the sidebar, the window), not just when it's closed or expanded.
  let resizedAt = 0;
  addEventListener('resize', () => {
    resizedAt = Date.now();
    setTimeout(syncMiniPlayer, 400);
  });
  const miniPlayerButton = () => [...document.querySelectorAll('ytmusic-player button, ytmusic-player tp-yt-paper-icon-button, ytmusic-player yt-icon-button')]
    .find((b) => /mini ?player/i.test(b.getAttribute('aria-label') || b.title || ''));
  // At 615px and narrower YouTube uses its phone layout, which has no mini player: keep the wish
  // until the page is wide enough again.
  const miniPlayerFits = () => innerWidth > 615;
  let miniPlayerWaiting = false;
  const syncMiniPlayer = () => {
    const html = document.documentElement;
    if (!html.classList.contains('ytm-miniplayer')) return;
    const layout = $('ytmusic-app-layout');
    if (layout?.getAttribute('player-ui-state') === 'MINIPLAYER') { miniPlayerWaiting = false; return; }
    if (Date.now() - miniPlayerAsked < 2000) return; // give the page a moment to switch after the click
    if (layout?.hasAttribute('player-page-open')) { miniPlayerWaiting = false; html.classList.remove('ytm-miniplayer'); return; }
    if (!miniPlayerFits()) { miniPlayerWaiting = true; return; } // (only a resize makes it too narrow)
    if (miniPlayerWaiting || Date.now() - resizedAt < 3000) {
      // Dropped by a resize, not closed or expanded: bring it back.
      miniPlayerWaiting = false;
      miniPlayerAsked = Date.now();
      miniPlayerButton()?.click();
      return;
    }
    html.classList.remove('ytm-miniplayer');
  };

  let ticks = 0;
  const tick = (full = false) => {
    preferSong();
    syncMiniPlayer();
    attachMenuObserver();
    send('state', snapshot());
    send('location', { path: location.pathname + location.search, title: pageTitle() });
    if (full || ticks++ % 10 === 0) {
      const acct = account();
      if (acct) send('account', acct);
      send('playlists', playlists());
    }
  };
  setInterval(tick, 500);
  document.addEventListener('play', () => tick(), true);
  document.addEventListener('pause', () => tick(), true);
  window.addEventListener('yt-navigate-finish', () => tick(true));

  const navigate = (endpoint) => {
    app()?.dispatchEvent(new CustomEvent('yt-navigate', { bubbles: true, composed: true, detail: { endpoint } }));
  };

  // ---- Native menus -------------------------------------------------------
  // YouTube Music opens ytmusic-menu-popup-renderer (from "⋮" or right-click). The popup
  // itself is hidden by CSS; its items are sent to Swift and shown as an NSMenu.
  let pointer = { x: 0, y: 0 };
  const trackPointer = (e) => { pointer = { x: e.clientX, y: e.clientY }; };
  window.addEventListener('mousedown', trackPointer, true);
  window.addEventListener('contextmenu', trackPointer, true);
  // No web context menu (Reload, Back…) where YouTube Music doesn't show one of its own.
  window.addEventListener('contextmenu', (e) => {
    if (!e.defaultPrevented && !e.target.closest?.('input, textarea, [contenteditable=true]')) e.preventDefault();
  });

  let menu = null;  // open web popup already forwarded to Swift: { dropdown, items, interaction }
  let shown = null; // the menu the native NSMenu was built from (kept even if the popup closes)
  // YouTube reuses one dropdown for every menu, so each open is identified by the click that
  // caused it rather than by the dropdown element.
  let interaction = 0;
  window.addEventListener('mousedown', () => { interaction++; }, true);
  window.addEventListener('contextmenu', () => { interaction++; }, true);

  const isOpen = (dd) => typeof dd.opened === 'boolean' ? dd.opened : getComputedStyle(dd).display !== 'none';
  // Read labels from the item data (or textContent): innerText is empty while the popup is hidden.
  const menuItems = (popup) => [...popup.querySelectorAll('#items > *')]
    .filter((el) => !el.hidden && getComputedStyle(el).display !== 'none')
    .map((el) => {
      const d = el.data || el.__data?.data || {};
      const icon = (d.isToggled ? d.toggledIcon : (d.icon || d.defaultIcon))?.iconType || '';
      const title = runsText(d.isToggled ? d.toggledText : (d.text || d.defaultText))
        || el.textContent.replace(/\s+/g, ' ').trim();
      return { el, icon, title, checked: isStatsItem(icon, title) && statsOpen() };
    })
    .filter((item) => item.title);
  // "Stats for nerds" turns a panel on and off: its menu item gets a checkmark while it's showing.
  const isStatsItem = (icon, title) => /^(INFO|STATS|BAR_CHART|ANALYTICS)/.test(icon) && /stat|nerd/i.test(title) || /stats for nerds/i.test(title);
  const statsOpen = () => [...document.querySelectorAll('ytmusic-nerd-stats, #movie_player .html5-video-info-panel')]
    .some((panel) => panel.offsetWidth > 0 && getComputedStyle(panel).display !== 'none');

  const checkMenus = () => {
    const dropdown = [...document.querySelectorAll('ytmusic-popup-container tp-yt-iron-dropdown')]
      .find((dd) => isOpen(dd) && dd.querySelector('ytmusic-menu-popup-renderer'));
    if (!dropdown) { menu = null; return; }
    if (menu?.dropdown === dropdown && menu.interaction === interaction) return;
    const items = menuItems(dropdown.querySelector('ytmusic-menu-popup-renderer'));
    if (!items.length) return; // not populated yet; the next mutation will retry
    menu = shown = { dropdown, items, interaction };
    post('menu', { x: pointer.x, y: pointer.y, viewportHeight: window.innerHeight, items: items.map(({ title, icon, checked }) => ({ title, icon, checked })) });
  };
  // Debounced so the reused popup has swapped in the new menu's items before they're read. Only the
  // popup container is watched: the rest of the page mutates constantly (e.g. the progress bar).
  let menuCheckTimer = 0, menuObserverAttached = false;
  const menuObserver = new MutationObserver(() => {
    clearTimeout(menuCheckTimer);
    menuCheckTimer = setTimeout(checkMenus, 40);
  });
  function attachMenuObserver() {
    if (menuObserverAttached) return;
    const container = $('ytmusic-popup-container');
    if (!container) return;
    menuObserver.observe(container, { subtree: true, childList: true, attributes: true, attributeFilter: ['style', 'aria-hidden', 'opened'] });
    menuObserverAttached = true;
  }

  const activate = (el) => (el.querySelector('a, tp-yt-paper-item, [role=menuitem]') || el).click();
  const closeMenu = (m) => { if (m && isOpen(m.dropdown)) m.dropdown.close?.(); };

  // "Share" opens YouTube's share dialog; grab its link and hand it to the macOS share sheet.
  const share = async (m, el) => {
    const at = { ...pointer };
    document.documentElement.classList.add('ytm-native-sharing');
    activate(el);
    let input = null;
    for (let i = 0; i < 40 && !input?.value; i++) {
      await new Promise((r) => setTimeout(r, 75));
      input = $('yt-copy-link-renderer input#share-url');
    }
    if (input?.value) {
      input.closest('tp-yt-paper-dialog')?.close?.();
      post('share', { url: input.value, x: at.x, y: at.y, viewportHeight: window.innerHeight });
    }
    document.documentElement.classList.remove('ytm-native-sharing'); // fall back to the web dialog
    closeMenu(m);
  };

  // ---- Search suggestions ------------------------------------------------
  // The native search field types into YouTube Music's hidden search box and mirrors the
  // suggestions it renders (query completions plus direct song/album/artist results).
  let suggestQuery = '', suggestItems = [], lastSuggestions = '';
  const readSuggestions = () => {
    const out = [];
    document.querySelectorAll('ytmusic-search-suggestions-section ytmusic-search-suggestion, ytmusic-search-suggestions-section ytmusic-responsive-list-item-renderer').forEach((el) => {
      const d = el.data || el.__data?.data;
      if (!d?.navigationEndpoint) return;
      if (el.tagName === 'YTMUSIC-SEARCH-SUGGESTION') {
        const title = runsText(d.suggestion);
        if (title) out.push({ kind: 'text', title, subtitle: '', thumbnail: '', endpoint: d.navigationEndpoint });
      } else {
        const column = (i) => runsText(d.flexColumns?.[i]?.musicResponsiveListItemFlexColumnRenderer?.text);
        const thumbs = d.thumbnail?.musicThumbnailRenderer?.thumbnail?.thumbnails || [];
        out.push({
          kind: 'result',
          title: column(0),
          subtitle: [column(1), column(2)].filter(Boolean).join(' • '),
          thumbnail: thumbs[thumbs.length - 1]?.url || '',
          endpoint: d.navigationEndpoint,
        });
      }
    });
    return out;
  };
  const sendSuggestions = () => {
    suggestItems = suggestQuery ? readSuggestions() : [];
    const payload = { query: suggestQuery, items: suggestItems.map(({ endpoint, ...item }, index) => ({ ...item, index })) };
    const json = JSON.stringify(payload);
    if (json === lastSuggestions) return;
    lastSuggestions = json;
    post('suggestions', payload);
  };
  // Watches only the search box, and only while a query is being typed.
  let suggestTimer = 0, suggestObserving = false;
  const suggestObserver = new MutationObserver(() => {
    clearTimeout(suggestTimer);
    suggestTimer = setTimeout(sendSuggestions, 80);
  });
  const watchSuggestions = (on) => {
    const box = $('ytmusic-search-box');
    if (on && !suggestObserving && box) {
      suggestObserver.observe(box, { subtree: true, childList: true });
      suggestObserving = true;
    } else if (!on && suggestObserving) {
      suggestObserver.disconnect();
      suggestObserving = false;
    }
  };
  const searchInput = () => $('ytmusic-search-box input');
  const setSearchInput = (value) => {
    const input = searchInput();
    if (!input) return;
    input.value = value;
    input.dispatchEvent(new Event('input', { bubbles: true }));
  };

  let playerPageRequest = 0;
  window.__ytmNative = {
    suggest: (query) => {
      suggestQuery = query;
      if (!query) { watchSuggestions(false); sendSuggestions(); setSearchInput(''); return; }
      watchSuggestions(true);
      searchInput()?.focus();
      setSearchInput(query);
    },
    pickSuggestion: (index) => {
      const item = suggestItems[index];
      watchSuggestions(false);
      suggestQuery = '';
      setSearchInput('');
      searchInput()?.blur();
      if (item) navigate(item.endpoint);
    },
    menuSelect: (index) => {
      const m = shown, item = m?.items[index];
      shown = null;
      if (!item) return;
      if (item.icon === 'SHARE') { share(m, item.el); return; }
      activate(item.el);
      setTimeout(() => closeMenu(m), 150);
    },
    menuCancel: () => { closeMenu(shown); shown = null; },
    setTheme,
    setPrefs: (prefs) => { window.__ytmPrefs = { ...window.__ytmPrefs, ...prefs }; songModeTrack = ''; },
    playPause: () => click('ytmusic-player-bar .play-pause-button') || (video()?.paused ? player()?.playVideo() : player()?.pauseVideo()),
    play: () => { if (video()?.paused) window.__ytmNative.playPause(); },
    // Pause the media element directly (YouTube Music follows it): the fastest path, so audio stops
    // before macOS moves to the speakers when AirPods come out.
    pause: () => { const v = video(); if (v && !v.paused) v.pause(); },
    next: () => click('ytmusic-player-bar .next-button') || player()?.nextVideo(),
    previous: () => click('ytmusic-player-bar .previous-button') || player()?.previousVideo(),
    seek: (t) => player()?.seekTo(t, true),
    setVolume: (v) => {
      const p = player(); if (!p) return;
      if (p.isMuted?.()) p.unMute();
      p.setVolume(v);
      const slider = $('ytmusic-player-bar #volume-slider');
      if (slider) slider.value = v;
    },
    toggleMute: () => { const p = player(); if (p) p.isMuted() ? p.unMute() : p.mute(); },
    like: () => click('ytmusic-player-bar ytmusic-like-button-renderer #button-shape-like button'),
    dislike: () => click('ytmusic-player-bar ytmusic-like-button-renderer #button-shape-dislike button'),
    toggleRepeat: () => click('ytmusic-player-bar .repeat'),
    shuffle: () => click('ytmusic-player-bar .shuffle'),
    // Open, close or toggle Now Playing, judged by the page itself (Swift's copy of the state can be
    // a moment behind, and acting on it could toggle the wrong way).
    setPlayerPage: (open) => {
      const layout = $('ytmusic-app-layout');
      const isOpen = () => !!layout?.hasAttribute('player-page-open');
      const want = open === undefined ? !isOpen() : open;
      const request = ++playerPageRequest; // a newer request cancels this one's retry
      if (isOpen() === want) return;
      click('ytmusic-player-bar .toggle-player-page-button');
      // Retry on the inner button if YouTube Music ignored the first click (e.g. still initialising),
      // judged by the state asked for, so a slow first click is never undone by the retry.
      setTimeout(() => { if (request === playerPageRequest && isOpen() !== want) click('ytmusic-player-bar .toggle-player-page-button button'); }, 800);
    },
    switchChannel: (index, name) => switchChannel(index, name),
    refreshChannels: () => { profileAttempt = 0; profile = null; },
    newPlaylist: () => {
      const button = [...document.querySelectorAll('#guide yt-button-renderer')].find((b) => /new playlist/i.test(b.textContent));
      ($('button', button) || button)?.click();
    },
    openTrackMenu: () => click('ytmusic-player-bar ytmusic-menu-renderer yt-button-shape button') || click('ytmusic-player-bar ytmusic-menu-renderer button'),
    browse: (browseId) => navigate({ browseEndpoint: { browseId } }),
    playPlaylist: (playlistId) => navigate({ watchEndpoint: { playlistId } }),
    search: (query) => navigate({ searchEndpoint: { query } }),
    refresh: () => { last = {}; tick(); },
  };
})();
