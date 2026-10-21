import AppKit
import Observation
import SwiftUI

/// Menu bar item: left-click opens the mini player, right-click (or Control-click) shows a menu.
/// AppKit rather than SwiftUI's MenuBarExtra, which can't offer a separate right-click menu.
@MainActor
final class StatusBarController: NSObject {
    static let shared = StatusBarController()

    /// Set from the main scene; SwiftUI owns opening its windows.
    var openMainWindow: (() -> Void)?
    var openSettings: (() -> Void)?

    private var music: MusicController?
    private var statusItem: NSStatusItem?
    private var defaultsObserver: NSObjectProtocol?
    private lazy var popover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        return popover
    }()

    func install(music: MusicController) {
        self.music = music
        let hosting = NSHostingController(
            rootView: MiniPlayerView(onOpenApp: { [weak self] in self?.showApp() })
                .environment(music)
                .preferredColorScheme(.dark)
        )
        // Without this the popover doesn't adopt the SwiftUI view's size and shows up empty.
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        updateVisibility()
        // Follow the "Show mini player in menu bar" setting.
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { StatusBarController.shared.updateVisibility() }
        }
    }

    private var isEnabled: Bool { Preferences.showsMenuBarIcon }

    private func updateVisibility() {
        if isEnabled, statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            item.button?.target = self
            item.button?.action = #selector(clicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            statusItem = item
            trackPlaybackIcon()
        } else if !isEnabled, let item = statusItem {
            popover.performClose(nil)
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    /// Matching play/pause circles so the icon never changes size; re-arms on each change.
    private func trackPlaybackIcon() {
        guard let music, let button = statusItem?.button else { return }
        let playing = withObservationTracking { music.state.isPlaying } onChange: {
            DispatchQueue.main.async { MainActor.assumeIsolated { StatusBarController.shared.trackPlaybackIcon() } }
        }
        button.image = NSImage(systemSymbolName: playing ? "pause.circle" : "play.circle",
                               accessibilityDescription: playing ? String(localized: "Songtide, playing") : String(localized: "Songtide, paused"))
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if UserDefaults.standard.string(forKey: Preferences.statusItemClickAction) == Preferences.StatusItemClick.openApp.rawValue {
            showApp()
        } else if popover.isShown {
            popover.performClose(sender)
        } else {
            showMiniPlayer(from: sender)
        }
    }

    private func showMiniPlayer(from sender: NSStatusBarButton) {
        do {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                // Without this, clicking the icon while another app is full screen can open the
                // mini player on a different Space, where it's invisible.
                window.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
                window.orderFrontRegardless()
                window.makeKey()
            }
        }
    }

    private func showMenu() {
        guard let barItem = statusItem, let music else { return }
        popover.performClose(nil)
        let state = music.state
        let menu = NSMenu()
        // A downloaded update waiting for a restart (also in the sidebar and the app menu).
        if Updater.shared.readyVersion != nil {
            menu.addItem(item(String(localized: "Update Ready: Restart to Update"), symbol: "arrow.down.circle.fill") { Updater.shared.installUpdate() })
            menu.addItem(.separator())
        } else if Updater.shared.availableVersion != nil {
            menu.addItem(item(String(localized: "Update Available: Install…"), symbol: "arrow.down.circle.fill") {
                NSApp.activate()
                Updater.shared.installUpdate()
            })
            menu.addItem(.separator())
        }

        if state.hasTrack {
            menu.addItem(disabled(state.title))
            if !state.artist.isEmpty { menu.addItem(disabled(state.artist)) }
            menu.addItem(.separator())
        }
        menu.addItem(item(state.isPlaying ? String(localized: "Pause") : String(localized: "Play"), symbol: state.isPlaying ? "pause.fill" : "play.fill", enabled: state.hasTrack) { music.playPause() })
        menu.addItem(item(String(localized: "Next"), symbol: "forward.end.fill", enabled: state.hasTrack) { music.next() })
        menu.addItem(item(String(localized: "Previous"), symbol: "backward.end.fill", enabled: state.hasTrack) { music.previous() })
        menu.addItem(.separator())
        menu.addItem(item(state.like == .like ? String(localized: "Liked") : String(localized: "Like"), symbol: state.like == .like ? "hand.thumbsup.fill" : "hand.thumbsup", enabled: state.hasTrack) { music.like() })
        menu.addItem(item(String(localized: "Copy Song Link"), symbol: "link", enabled: music.songLink != nil) { music.copySongLink() })
        menu.addItem(sleepTimerItem(hasTrack: state.hasTrack))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Open Songtide"), symbol: "macwindow") { [weak self] in self?.showApp() })
        // When a click opens the app, keep the mini player reachable from here.
        if UserDefaults.standard.string(forKey: Preferences.statusItemClickAction) == Preferences.StatusItemClick.openApp.rawValue,
           let button = barItem.button {
            menu.addItem(item(String(localized: "Show Mini Player"), symbol: "music.note") { [weak self] in
                DispatchQueue.main.async { self?.showMiniPlayer(from: button) }
            })
        }
        menu.addItem(item(String(localized: "Settings…"), symbol: "gearshape", key: ",") { [weak self] in
            NSApp.activate()
            self?.openSettings?()
        })
        menu.addItem(item(String(localized: "Check for Updates…"), symbol: "arrow.triangle.2.circlepath") {
            NSApp.activate()
            Updater.shared.checkForUpdates()
        })
        let login = item(String(localized: "Open at Login")) { try? LoginItem.setEnabled(!LoginItem.isEnabled) }
        login.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item(String(localized: "Hide Menu Bar Icon"), symbol: "eye.slash") {
            UserDefaults.standard.set(Preferences.Presence.dockOnly.rawValue, forKey: Preferences.appPresence)
        })
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit Songtide"), key: "q") { NSApp.terminate(nil) })

        // Attach the menu just for this click so left-clicks keep opening the popover.
        barItem.menu = menu
        barItem.button?.performClick(nil)
        barItem.menu = nil
    }

    private func showApp() {
        popover.performClose(nil)
        NSApp.setActivationPolicy(.regular) // bring the Dock icon back with the window
        openMainWindow?()
        NSApp.activate()
    }

    // MARK: Menu item helpers

    /// Menus grow to fit their widest item, so long track names are shortened (full text on hover).
    private func disabled(_ title: String, maxLength: Int = 40) -> NSMenuItem {
        let short = title.count > maxLength
            ? String(title.prefix(maxLength - 1)).trimmingCharacters(in: .whitespaces) + "…"
            : title
        let item = NSMenuItem(title: short, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if short != title { item.toolTip = title }
        return item
    }

    /// Sleep Timer submenu, as in Controls › Sleep Timer.
    private func sleepTimerItem(hasTrack: Bool) -> NSMenuItem {
        let timer = SleepTimer.shared
        let parent = NSMenuItem(title: timer.isActive ? String(localized: "Sleep Timer (\(timer.label))") : String(localized: "Sleep Timer"), action: nil, keyEquivalent: "")
        parent.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        let sub = NSMenu()
        if timer.isActive {
            sub.addItem(item(String(localized: "Turn Off")) { timer.cancel() })
            sub.addItem(.separator())
        }
        for minutes in SleepTimer.choices {
            sub.addItem(item(SleepTimer.title(minutes: minutes)) { timer.set(minutes: minutes) })
        }
        sub.addItem(item(String(localized: "End of Current Song"), enabled: hasTrack) { timer.setEndOfTrack() })
        parent.submenu = sub
        return parent
    }

    private func item(_ title: String, symbol: String? = nil, key: String = "", enabled: Bool = true, action: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, keyEquivalent: key, action: action)
        item.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        item.isEnabled = enabled
        return item
    }
}

/// NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, keyEquivalent: String, action handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func run() { handler() }
}
