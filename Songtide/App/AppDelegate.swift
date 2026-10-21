import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let music = MusicController.shared
    private var nowPlaying: NowPlayingService?
    private var audioOutput: AudioOutputMonitor?

    /// Only one Songtide at a time (say, one opened from the DMG and one from Applications): a
    /// second copy hands over to the one already running, which opens its window, and quits.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // songtide:// links (and web links other apps hand over) come in as Apple events.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        guard !MusicController.isGuestSession, let id = Bundle.main.bundleIdentifier,
              let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                .first(where: { $0 != .current && !$0.isTerminated }),
              let url = running.bundleURL else { return }
        handingOff = true
        NSApp.setActivationPolicy(.prohibited) // no Dock icon or window flash on the way out
        // Opening the running copy's own bundle reaches that copy as a reopen (it shows its window);
        // this copy, launched in front, hands its turn at the front over first.
        NSApp.yieldActivation(to: running)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    private var handingOff = false

    @objc private func handleURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let text = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue, let url = URL(string: text),
              music.open(link: url) else { return }
        StatusBarController.shared.openMainWindow?()
        NSApp.activate()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !handingOff else { return } // quitting in favour of the copy already running
        nowPlaying = NowPlayingService(music: music)
        audioOutput = AudioOutputMonitor(music: music)
        SystemEqualizer.shared.start()
        Updater.shared.start()
        InstallPing.sendIfFirstLaunch(existingUser: Updater.shared.hasCheckedBefore)
        TrackNotifier.shared.start()
        WidgetBridge.shared.start()
        LastFM.shared.start()
        DiscordPresence.shared.start()
        _ = SleepTimer.shared
        if MusicController.isGuestSession {
            // Screenshot sessions: a standard 1440×900 window (2880×1800 on Retina), centred.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
                window.setContentSize(NSSize(width: 1440, height: 900))
                window.center()
            }
        }
        StatusBarController.shared.install(music: music)
        // Dock icon follows the main window: hidden while it's closed (setting), back when it opens.
        // SwiftUI can hide its window without a close notification, so re-check after each round of
        // events (cheap: a scan of a few windows, and the policy only changes when needed).
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockVisibility() }
        }
        center.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDockVisibility() }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            guard let window = note.object as? NSWindow else { return }
            MainActor.assumeIsolated {
                guard Self.isAppWindow(window) else { return }
                self?.updateDockVisibility(closing: window)
                // "Keep playing when the window is closed" off: pause once the last player window
                // (main or visualizer) closes, not while the other is still showing.
                let lastPlayerWindow = Self.isPlayerWindow(window)
                    && !NSApp.windows.contains { $0 !== window && Self.isPlayerWindow($0) && $0.isVisible }
                if lastPlayerWindow, !UserDefaults.standard.bool(forKey: Preferences.keepPlayingWhenClosed, default: true) {
                    MusicController.shared.pause()
                }
            }
        }
    }

    /// Songtide's own windows a person works in (main, visualizer, Settings), as opposed to the
    /// mini player popover, menus and panels. The Dock icon stays while any is open.
    static func isAppWindow(_ window: NSWindow) -> Bool {
        window.styleMask.contains(.titled) && !(window is NSPanel)
    }

    /// Windows showing the player: the main window and the popped-out visualizer.
    static func isPlayerWindow(_ window: NSWindow) -> Bool {
        let id = window.identifier?.rawValue ?? ""
        return id.hasPrefix("main") || id.hasPrefix(VisualizerView.windowID)
    }

    /// Clicking the Dock icon brings back the main window, even if only the visualizer (or
    /// Settings) is open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        let mainOpen = NSApp.windows.contains { $0.identifier?.rawValue.hasPrefix("main") == true && $0.isVisible }
        guard !mainOpen, let openMain = StatusBarController.shared.openMainWindow else { return true }
        openMain()
        NSApp.activate()
        return false
    }

    /// Hides the Dock icon (and so the ⌘Tab entry) while none of Songtide's windows is open —
    /// main, visualizer or Settings — leaving it in the menu bar, if that setting is on. Never
    /// hides it when the menu bar icon is off, so the app can't end up with no way back to it.
    /// `closing` is a window that's in the middle of closing (it still reports itself visible).
    func updateDockVisibility(closing: NSWindow? = nil) {
        let windowOpen = NSApp.windows.contains { $0 !== closing && $0.isVisible && Self.isAppWindow($0) }
        // `hidesDockWhenClosed` implies the menu bar icon is on, so the app always stays reachable.
        let hide = Preferences.hidesDockWhenClosed && !windowOpen
        let policy: NSApplication.ActivationPolicy = hide ? .accessory : .regular
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular { NSApp.activate() } // bring the Dock icon and menu bar back properly
    }

    /// Closing the window keeps the app (and playback) alive, like Music.app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// From here on, windows closing are the app quitting, not the person closing them: keep
    /// remembering them as open so they come back next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MusicController.isQuitting = true
        return .terminateNow
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let state = music.state
        if state.hasTrack {
            let nowPlaying = NSMenuItem(title: state.title, action: nil, keyEquivalent: "")
            nowPlaying.isEnabled = false
            menu.addItem(nowPlaying)
            if !state.artist.isEmpty {
                let artist = NSMenuItem(title: state.artist, action: nil, keyEquivalent: "")
                artist.isEnabled = false
                menu.addItem(artist)
            }
            menu.addItem(.separator())
        }
        menu.addItem(item(state.isPlaying ? String(localized: "Pause") : String(localized: "Play"), #selector(playPause)))
        menu.addItem(item(String(localized: "Next"), #selector(next)))
        menu.addItem(item(String(localized: "Previous"), #selector(previous)))
        menu.addItem(.separator())
        menu.addItem(item(state.like == .like ? String(localized: "Liked") : String(localized: "Like"), #selector(like)))
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func playPause() { music.playPause() }
    @objc private func next() { music.next() }
    @objc private func previous() { music.previous() }
    @objc private func like() { music.like() }
}

extension UserDefaults {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        object(forKey: key) == nil ? defaultValue : bool(forKey: key)
    }
}
