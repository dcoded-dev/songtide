import AppKit
import Observation
import WebKit

/// Owns the single YouTube Music web view and mirrors its player state for the native UI.
/// Lives for the whole app lifetime so playback continues when the window is closed.
@MainActor @Observable
final class MusicController: NSObject {
    static let shared = MusicController()

    static let homeURL = URL(string: "https://music.youtube.com/")!

    /// The page open when Songtide last quit, reopened on launch. Only for a signed-in account (a
    /// guest's saved page may be a library page they can no longer see); anything else opens Home.
    nonisolated static let lastPathKey = "lastPath"
    /// A throwaway signed-out session (SONGTIDE_GUEST=1, set only from a terminal, e.g. for website
    /// screenshots); the real session is left untouched.
    nonisolated static let isGuestSession = ProcessInfo.processInfo.environment["SONGTIDE_GUEST"] != nil

    static let launchPath: String = {
        guard !isGuestSession, AccountCache.load().signedIn,
              let saved = UserDefaults.standard.string(forKey: lastPathKey),
              saved.hasPrefix("/"), !saved.hasPrefix("/watch") else { return "/" }
        return saved
    }()
    /// Bridge traffic logging, enabled with YTM_DEBUG=1 (read once rather than per message).
    private static let debugLogging = ProcessInfo.processInfo.environment["YTM_DEBUG"] != nil
    static let signInURL = URL(string: "https://accounts.google.com/ServiceLogin?ltmpl=music&service=youtube&uilel=3&passive=true&continue=https%3A%2F%2Fwww.youtube.com%2Fsignin%3Faction_handle_signin%3Dtrue%26app%3Ddesktop%26hl%3Den%26next%3Dhttps%253A%252F%252Fmusic.youtube.com%252F&hl=en")!
    /// Google refuses sign-in from embedded browsers it doesn't recognize; present as Safari.
    static let applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"

    /// Passkeys (WebAuthn) are unavailable to third-party WKWebViews, so Google's passkey
    /// prompt always fails with a Bluetooth error. Hiding WebAuthn from Google's sign-in
    /// pages makes it go straight to password + 2-Step Verification.
    static let disablePasskeysScript = WKUserScript(source: """
        if (/(^|\\.)accounts\\.google\\./.test(location.hostname)) {
          try { Object.defineProperty(window, 'PublicKeyCredential', { value: undefined, configurable: true }); } catch (_) {}
          if (navigator.credentials) {
            const unsupported = () => Promise.reject(new DOMException('Passkeys are not supported here', 'NotSupportedError'));
            try { navigator.credentials.get = unsupported; navigator.credentials.create = unsupported; } catch (_) {}
          }
        }
        """, injectionTime: .atDocumentStart, forMainFrameOnly: false)

    private(set) var state = PlayerState()
    /// Playback position in seconds. Kept apart from `state` (whose `time` isn't kept current) so
    /// the twice-a-second position updates only redraw the views that show the position.
    private(set) var position: Double = 0
    /// When the reported position last changed (it stops while loading, stalled or between tracks).
    @ObservationIgnored private(set) var positionDate = Date()
    /// The position right now, moving on smoothly between the page's twice-a-second updates (for
    /// lyrics that follow the song).
    var livePosition: Double {
        guard state.isPlaying else { return position }
        let now = position + Date().timeIntervalSince(positionDate)
        return state.duration > 0 ? min(now, state.duration) : now
    }
    @ObservationIgnored private var lastReceivedState = PlayerState()
    /// Starts from the last known account so a signed-in user sees their name and avatar immediately.
    private(set) var account = AccountCache.load()
    /// Cached avatar image, shown before (and instead of re-downloading) the remote photo.
    private(set) var avatarImage: NSImage? = AccountCache.loadAvatar()
    private(set) var playlists: [PlaylistEntry] = []
    private(set) var path = MusicController.launchPath
    /// The current page's heading, for the window title on pages without a sidebar entry.
    private(set) var pageTitle = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = true
    var isShowingSignIn = false
    /// Set once Songtide starts quitting, so windows closing then aren't remembered as closed.
    static var isQuitting = false
    /// Whether the visualizer is showing, in the main window or its own; remembered, so it's back
    /// after a relaunch (e.g. an update).
    var isShowingVisualizer = !MusicController.isGuestSession && UserDefaults.standard.bool(forKey: "visualizerShowing") {
        didSet {
            visualizerPage = pagePath
            if !Self.isQuitting { UserDefaults.standard.set(isShowingVisualizer, forKey: "visualizerShowing") }
        }
    }
    /// In the main window the visualizer either fills the page area or sits beside the page
    /// (split); remembered.
    var visualizerFills = UserDefaults.standard.object(forKey: "visualizerFills") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(visualizerFills, forKey: "visualizerFills")
            visualizerPage = pagePath
        }
    }
    /// Whether the visualizer is covering the page right now (in the main window, filling it).
    var visualizerCoversPage: Bool { isShowingVisualizer && !visualizerInWindow && visualizerFills }
    /// The page under the visualizer when it started covering it. Coming back to it (Now Playing
    /// closing) changes nothing; landing anywhere else means a link was followed.
    @ObservationIgnored private var visualizerPage: String?
    /// The current page, ignoring the player page (which overlays it).
    @ObservationIgnored private var pagePath = MusicController.launchPath
    /// Whether the visualizer is popped out into its own window; remembered for next time.
    var visualizerInWindow = UserDefaults.standard.bool(forKey: "visualizerInWindow") {
        didSet { UserDefaults.standard.set(visualizerInWindow, forKey: "visualizerInWindow") }
    }
    private(set) var suggestions: [SearchSuggestion] = []
    /// Channels the signed-in account can switch between, and their menu-sized avatars by URL.
    private(set) var channels: [ChannelAccount] = []
    private(set) var channelAvatars: [String: NSImage] = [:]
    @ObservationIgnored private var suggestionQuery = ""

    /// Emits whenever the track or playback state changes; used by Now Playing.
    /// Everyone who follows playback (Now Playing, sleep timer, notifications, Discord, Last.fm,
    /// lyrics, the widget): called with each new player state.
    @ObservationIgnored private var stateObservers: [(PlayerState) -> Void] = []
    func observeState(_ observer: @escaping (PlayerState) -> Void) { stateObservers.append(observer) }
    private func notifyState(_ state: PlayerState) { stateObservers.forEach { $0(state) } }

    @ObservationIgnored let webView: WKWebView
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    /// Screen point of a native button that asked the page for a menu; that menu opens there.
    @ObservationIgnored private var pendingMenuAnchor: (point: NSPoint, date: Date)?

    override private init() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = Self.isGuestSession ? .nonPersistent() : .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.applicationNameForUserAgent = Self.applicationNameForUserAgent
        config.preferences.isElementFullscreenEnabled = true

        let source = Bundle.main.url(forResource: "bridge", withExtension: "js").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        config.userContentController.addUserScript(WebTheme.script)
        let preferSong = UserDefaults.standard.bool(forKey: Preferences.preferSongOverVideo, default: true)
        config.userContentController.addUserScript(WKUserScript(source: "window.__ytmPrefs = { preferSong: \(preferSong) };", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.userContentController.addUserScript(Self.disablePasskeysScript)

        webView = MenuFirstWebView(frame: .zero, configuration: config)
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = NSColor(srgbRed: 3 / 255, green: 3 / 255, blue: 3 / 255, alpha: 1)
        #if DEBUG
        webView.isInspectable = true
        #endif
        super.init()

        config.userContentController.add(WeakMessageHandler(self), name: "ytm")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        observations = [
            webView.observe(\.canGoBack) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoBack = wv.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] wv, _ in MainActor.assumeIsolated { self?.canGoForward = wv.canGoForward } },
            webView.observe(\.isLoading) { [weak self] wv, _ in MainActor.assumeIsolated { self?.isLoading = wv.isLoading } },
        ]
        webView.load(URLRequest(url: URL(string: Self.launchPath, relativeTo: Self.homeURL) ?? Self.homeURL))

        #if DEBUG
        // Development hook: evaluate JS in the page and print the result to stderr, e.g.
        //   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("dev.dcoded.songtide.eval"), object: "document.title", deliverImmediately: true)'
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.dcoded.songtide.eval"), object: nil, queue: .main) { note in
            guard let js = note.object as? String else { return }
            MainActor.assumeIsolated {
                MusicController.shared.webView.evaluateJavaScript(js) { result, error in
                    FileHandle.standardError.write(Data("[eval] \(result.map { "\($0)" } ?? "nil") \(error.map { "error: \($0)" } ?? "")\n".utf8))
                }
            }
        }
        // Development hook: resize the main window to a content width (testing narrow layouts),
        // e.g. scripts/ytm-resize 820, or scripts/ytm-resize 1440x900
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.dcoded.songtide.resize"), object: nil, queue: .main) { note in
            // "820" (width only) or "1440x900".
            let parts = (note.object as? String)?.split(separator: "x").compactMap { Double($0) } ?? []
            guard let width = parts.first else { return }
            MainActor.assumeIsolated {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
                window.setContentSize(NSSize(width: width, height: parts.count > 1 ? parts[1] : window.contentLayoutRect.height))
                FileHandle.standardError.write(Data("[resize] \(Int(window.contentLayoutRect.width))\n".utf8))
            }
        }
        // Development hook: bring a window to the front, active (for screenshots): the main window,
        // or the one with the given title, e.g. scripts/ytm-activate Playback
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.dcoded.songtide.activate"), object: nil, queue: .main) { note in
            let title = note.object as? String
            MainActor.assumeIsolated {
                NSApp.activate()
                let window = title.map { title in NSApp.windows.first { $0.title == title } }
                    ?? NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("main") == true }
                window?.makeKeyAndOrderFront(nil)
            }
        }
        // Development hook: set a true/false setting (or "delete" it), e.g. scripts/ytm-default sidebarVisible true
        DistributedNotificationCenter.default().addObserver(forName: .init("dev.dcoded.songtide.default"), object: nil, queue: .main) { note in
            let parts = (note.object as? String)?.split(separator: "=").map(String.init) ?? []
            guard parts.count == 2 else { return }
            if parts[1] == "delete" { UserDefaults.standard.removeObject(forKey: parts[0]) } else {
                UserDefaults.standard.set(parts[1] == "true", forKey: parts[0])
            }
            FileHandle.standardError.write(Data("[default] \(parts[0]) \(parts[1] == "delete" ? "deleted" : "= \(parts[1] == "true")")\n".utf8))
        }
        #endif

        NotificationCenter.default.addObserver(forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MusicController.shared.call("setTheme(\(WebTheme.json))") }
        }
    }

    // MARK: Commands

    fileprivate func call(_ js: String) {
        if Self.debugLogging { FileHandle.standardError.write(Data("[call] \(js.prefix(120))\n".utf8)) }
        webView.evaluateJavaScript("window.__ytmNative && window.__ytmNative.\(js)", completionHandler: nil)
    }

    private func jsString(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s])
        let array = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(array.dropFirst().dropLast())
    }

    func playPause() { state.isPlaying.toggle(); call("playPause()") }
    func play() { call("play()") }
    /// Starts a playlist from the top (e.g. "LM", Liked Music).
    func playPlaylist(_ playlistId: String) { call("playPlaylist(\(jsString(playlistId)))") }
    func pause() { call("pause()") }
    func next() { call("next()") }
    func previous() { call("previous()") }
    func like() { call("like()") }
    func dislike() { call("dislike()") }
    func toggleRepeat() { call("toggleRepeat()") }
    func shuffle() { call("shuffle()") }
    func toggleMute() { call("toggleMute()") }
    /// Shows or hides Now Playing. While the visualizer covers the page, Now Playing may be open
    /// underneath it; asking for it then brings it into view beside the visualizer.
    func toggleNowPlaying() {
        if visualizerCoversPage {
            visualizerFills = false
            setPlayerPage(open: true)
        } else {
            setPlayerPage(open: nil)
        }
    }

    /// Opens (true), closes (false) or toggles (nil) YouTube Music's player page.
    private func setPlayerPage(open: Bool?) {
        call("setPlayerPage(\(open.map { "\($0)" } ?? "undefined"))")
    }

    /// Now Playing is showing (open and not covered by the visualizer).
    var isNowPlayingVisible: Bool { state.playerPageOpen && !visualizerCoversPage }
    func newPlaylist() { call("newPlaylist()") }

    /// Opens YouTube Music's menu for the current track as a native menu at the mouse location.
    func showTrackMenu() {
        pendingMenuAnchor = (NSEvent.mouseLocation, Date())
        call("openTrackMenu()")
    }

    func seek(to time: Double) {
        position = time
        call("seek(\(time))")
    }

    func setVolume(_ volume: Double) {
        let clamped = min(max(volume, 0), 100)
        state.volume = clamped
        state.muted = false
        call("setVolume(\(Int(clamped)))")
    }

    func adjustVolume(by delta: Double) { setVolume(state.volume + delta) }

    func setPreferSongOverVideo(_ enabled: Bool) { call("setPrefs({ preferSong: \(enabled) })") }

    /// Asking for content (sidebar, search, back/forward, Up Next, a link) while the visualizer
    /// covers the page switches it to split, so the content shows beside it.
    private func showPageBesideVisualizer() {
        if visualizerCoversPage { visualizerFills = false }
    }

    func open(_ item: SidebarItem) {
        showPageBesideVisualizer()
        setPlayerPage(open: false)
        if webView.url?.host() == "music.youtube.com" {
            call("browse(\(jsString(item.browseId)))")
        } else {
            webView.load(URLRequest(url: Self.homeURL))
        }
    }

    /// Switches the active YouTube Music channel; the page reloads as that channel.
    func switchChannel(_ channel: ChannelAccount) {
        guard !channel.selected else { return }
        call("switchChannel(\(channel.index), \(jsString(channel.name)))")
    }

    private func loadChannelAvatars() {
        for url in Set(channels.map(\.photo)) where !url.isEmpty && channelAvatars[url] == nil {
            guard let source = URL(string: url) else { continue }
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: source),
                      let image = NSImage(data: data) else { return }
                self?.channelAvatars[url] = image.circularThumbnail(size: 20)
            }
        }
    }

    /// Asks YouTube Music for suggestions for `query`; results arrive via the bridge.
    func suggest(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        suggestionQuery = trimmed
        if trimmed.isEmpty { suggestions = [] }
        call("suggest(\(jsString(trimmed)))")
    }

    /// Runs a suggestion: a text suggestion searches, a result plays or opens it.
    func pick(_ suggestion: SearchSuggestion) {
        showPageBesideVisualizer()
        if suggestion.kind == .text { setPlayerPage(open: false) }
        suggestions = []
        call("pickSuggestion(\(suggestion.index))")
    }

    func search(_ query: String) {
        showPageBesideVisualizer()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        setPlayerPage(open: false)
        call("search(\(jsString(trimmed)))")
    }

    func goBack() {
        showPageBesideVisualizer()
        webView.goBack()
    }

    func goForward() {
        showPageBesideVisualizer()
        webView.goForward()
    }
    func reload() { webView.reload() }

    // MARK: Account

    func signInCompleted() {
        isShowingSignIn = false
        webView.load(URLRequest(url: Self.homeURL))
    }

    func signOut() async {
        let store = WKWebsiteDataStore.default()
        let records = await store.dataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes())
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records)
        account = AccountInfo()
        avatarImage = nil
        channels = []
        UserDefaults.standard.removeObject(forKey: Self.lastPathKey)
        AccountCache.save(account)
        AccountCache.saveAvatar(nil)
        playlists = []
        state = PlayerState()
        notifyState(state)
        webView.load(URLRequest(url: Self.homeURL))
    }

    private func loadAvatar(_ url: URL?) {
        guard let url else { return }
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url), let image = NSImage(data: data) else { return }
            self?.avatarImage = image
            AccountCache.saveAvatar(data)
        }
    }

    // MARK: Bridge

    fileprivate func receive(type: String, json: String) {
        let data = Data(json.utf8)
        let decoder = JSONDecoder()
        if Self.debugLogging { FileHandle.standardError.write(Data("[bridge] \(type) \(json.prefix(300))\n".utf8)) }
        switch type {
        case "state":
            guard let new = try? decoder.decode(PlayerState.self, from: data), new != lastReceivedState else { return }
            lastReceivedState = new
            if new.time != position { position = new.time; positionDate = Date() }
            var comparable = new
            comparable.time = state.time
            if comparable != state { state = new } // skip when only the position moved
            notifyState(new)
        case "account":
            guard var new = try? decoder.decode(AccountInfo.self, from: data) else { return }
            // The profile (name/photo) arrives a moment after sign-in state; keep the cached one meanwhile.
            if new.signedIn, new.name.isEmpty, account.signedIn {
                new.name = account.name
                new.handle = account.handle
                new.avatar = account.avatar
            }
            guard new != account else { return }
            let avatarChanged = new.avatar != account.avatar
            account = new
            AccountCache.save(new)
            if !new.signedIn {
                avatarImage = nil
                AccountCache.saveAvatar(nil)
            } else if avatarChanged || avatarImage == nil {
                loadAvatar(new.avatarURL)
            }
        case "playlists":
            if let new = try? decoder.decode([PlaylistEntry].self, from: data), new != playlists { playlists = new }
        case "menu":
            guard let request = try? decoder.decode(WebMenuRequest.self, from: data) else { return }
            var anchor: NSPoint?
            if let pending = pendingMenuAnchor, Date().timeIntervalSince(pending.date) < 2, let window = webView.window {
                anchor = webView.convert(window.convertPoint(fromScreen: pending.point), from: nil)
            }
            pendingMenuAnchor = nil
            NativeMenu.present(request, in: webView, anchor: anchor) { [weak self] index in
                if let index { self?.call("menuSelect(\(index))") } else { self?.call("menuCancel()") }
            }
        case "share":
            if let request = try? decoder.decode(WebShareRequest.self, from: data) { NativeShare.present(request, in: webView) }
        case "channels":
            if let new = try? decoder.decode([ChannelAccount].self, from: data), new != channels {
                channels = new
                loadChannelAvatars()
            }
        case "suggestions":
            // Ignore late results for a query the user has already moved past.
            if let new = try? decoder.decode(SearchSuggestions.self, from: data), new.query == suggestionQuery {
                suggestions = new.items
            }
        case "location":
            if let new = try? decoder.decode(LocationInfo.self, from: data) {
                if new.path != path {
                    path = new.path
                    // The player page is an overlay, not a place to come back to.
                    if !new.path.hasPrefix("/watch") {
                        pagePath = new.path
                        if !Self.isGuestSession { UserDefaults.standard.set(new.path, forKey: Self.lastPathKey) }
                        // A new page while the visualizer covers the page (a link, a page opened
                        // from Now Playing…): show it beside the visualizer rather than hidden.
                        if visualizerCoversPage, new.path != visualizerPage { visualizerFills = false }
                    }
                }
                if let title = new.title, title != pageTitle { pageTitle = title }
            }
        default:
            break
        }
    }

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return url.scheme == "about" || url.scheme == "blob" }
        let domains = ["youtube.com", "google.com", "gstatic.com", "googleusercontent.com", "youtube-nocookie.com"]
        return domains.contains { host == $0 || host.hasSuffix("." + $0) } || host.hasPrefix("accounts.google.")
    }
}

// MARK: - WebKit delegates

extension MusicController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard navigationAction.targetFrame?.isMainFrame ?? true, let url = navigationAction.request.url else { return .allow }
        if Self.isInternal(url) || url.scheme == "about" { return .allow }
        NSWorkspace.shared.open(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // target=_blank / window.open: open external links in the browser, keep YouTube links in-app.
        if let url = navigationAction.request.url {
            if Self.isInternal(url) { webView.load(navigationAction.request) } else { NSWorkspace.shared.open(url) }
        }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }
}

/// WKWebView sends key equivalents to the page before the menu bar, and YouTube Music
/// swallows some of them (e.g. its "f" full-screen shortcut eats ⌃⌘F). Give the app's
/// menus first pick at any ⌘ combo so system shortcuts always behave natively; editing
/// commands (⌘C/⌘V/⌘A…) still reach the page through the Edit menu's responder actions.
final class MenuFirstWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return true }
        // ⌃⌘F is AppKit's legacy full-screen shortcut (the menu item now shows 🌐F). It only
        // fires for unhandled events, so the web view must not forward it to the page.
        if flags.subtracting([.function, .numericPad]) == [.command, .control],
           event.charactersIgnoringModifiers?.lowercased() == "f", let window {
            window.toggleFullScreen(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Resizing by a split divider rather than the window: WebKit keeps the page's drawing in step
    /// with the view's size during a window's live resize, so it's told this is one too.
    private var isDividerResizing = false
    override var inLiveResize: Bool { isDividerResizing || super.inLiveResize }

    func beginDividerResize() {
        guard !isDividerResizing else { return }
        isDividerResizing = true
        viewWillStartLiveResize()
    }

    func endDividerResize() {
        guard isDividerResizing else { return }
        isDividerResizing = false
        viewDidEndLiveResize()
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: MusicController?
    init(_ target: MusicController) { self.target = target }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String,
              let payload = body["payload"] as? String else { return }
        MainActor.assumeIsolated { target?.receive(type: type, json: payload) }
    }
}

extension NSImage {
    /// A small round copy, for menu items.
    func circularThumbnail(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSBezierPath(ovalIn: rect).addClip()
            self.draw(in: rect)
            return true
        }
    }
}
