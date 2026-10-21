import SwiftUI

@main
struct SongtideApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let music = MusicController.shared

    var body: some Scene {
        Window("Songtide", id: "main") {
            ContentView()
                .environment(music)
                .songtideAccent()
        }
        .windowToolbarStyle(.unified)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 820)
        .commands {
            SidebarCommands()
            PlaybackCommands(music: music)
        }

        Settings {
            SettingsView()
                .environment(music)
                .songtideAccent()
        }

        // Floating lyrics for the song that's playing (Controls › Show Lyrics).
        Window("Lyrics", id: LyricsWindowView.windowID) {
            LyricsWindowView()
                .environment(music)
                .songtideAccent()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 360, height: 460)
        .restorationBehavior(.disabled)

        // Its own window, so it can go on another display or full screen by itself while the main
        // window stays usable.
        Window("Visualizer", id: VisualizerView.windowID) {
            VisualizerView()
                .environment(music)
                .songtideAccent()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 960, height: 600)
        .restorationBehavior(.disabled) // never reopen (and start capturing audio) at launch
        // A window in its own right, not a helper of the main one: that's what lets it enter and
        // leave full screen in its own space (e.g. on a TV).
        .windowManagerRole(.principal)
    }
}

struct PlaybackCommands: Commands {
    let music: MusicController
    private var sleepTimer = SleepTimer.shared
    @FocusedValue(\.focusSearch) private var focusSearch
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Songtide") {
                // An empty build version hides the "(8)" after the version number.
                NSApp.orderFrontStandardAboutPanel(options: [.credits: AppInfo.aboutCredits, .version: ""])
                NSApp.activate()
            }
            Button("Check for Updates…") { Updater.shared.checkForUpdates() }
            if Updater.shared.readyVersion != nil {
                Button("Restart to Update") { Updater.shared.installUpdate() }
            } else if Updater.shared.availableVersion != nil {
                Button("Install Update…") { Updater.shared.installUpdate() }
            }
        }
        // ⌘Q closes the window (playback carries on from the menu bar) rather than quitting;
        // ⌥⌘Q, the Dock and the menu bar icon still quit for real.
        CommandGroup(replacing: .appTermination) {
            Button("Close Songtide") { closeMainWindowOrQuit() }
                .keyboardShortcut("q")
            Button("Quit Songtide") { NSApp.terminate(nil) }
                .keyboardShortcut("q", modifiers: [.command, .option])
        }
        CommandGroup(replacing: .help) {
            Button("Songtide Support") { NSWorkspace.shared.open(AppInfo.websiteURL.appending(path: "support/")) }
        }
        CommandGroup(after: .newItem) {
            Button("Open Copied Link") { music.openCopiedLink() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        CommandGroup(after: .textEditing) {
            Button("Search") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
        CommandGroup(after: .toolbar) {
            Button("Back") { music.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { music.goForward() }
                .keyboardShortcut("]")
            Button("Reload") { music.reload() }
                .keyboardShortcut("r")
            Divider()
        }
        CommandMenu("Controls") {
            Button(music.state.isPlaying ? "Pause" : "Play") { music.playPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Button("Next") { music.next() }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Button("Previous") { music.previous() }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Divider()
            Button("Like") { music.like() }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Button("Dislike") { music.dislike() }
                .keyboardShortcut("l", modifiers: [.command, .option, .shift])
                .disabled(!music.state.hasTrack)
            Button("Copy Song Link") { music.copySongLink() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(music.songLink == nil)
            if let link = music.songLink {
                ShareLink("Share Song…", item: link, message: Text(music.state.artist.isEmpty ? music.state.title : "\(music.state.title) by \(music.state.artist)"))
            }
            Divider()
            Button("Shuffle") { music.shuffle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Button("Repeat") { music.toggleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Divider()
            Button("Increase Volume") { music.adjustVolume(by: 10) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
            Button("Decrease Volume") { music.adjustVolume(by: -10) }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
            Button(music.state.muted ? "Unmute" : "Mute") { music.toggleMute() }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option, .shift])
            Divider()
            sleepTimerMenu
            Button(Lyrics.shared.isWindowOpen ? "Hide Lyrics" : "Show Lyrics") {
                if Lyrics.shared.isWindowOpen { dismissWindow(id: LyricsWindowView.windowID) } else { Lyrics.shared.isWindowOpen = true; openWindow(id: LyricsWindowView.windowID) }
            }
                .keyboardShortcut("y", modifiers: [.command, .option])
            Divider()
            Button("Now Playing & Up Next") { music.toggleNowPlaying() }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(!music.state.hasTrack)
            Button(music.isShowingVisualizer ? "Hide Visualizer" : "Show Visualizer") {
                VisualizerPresenter.toggle(music, open: openWindow, dismiss: dismissWindow)
            }
                .keyboardShortcut("v", modifiers: [.command, .option])
        }
    }
}

extension PlaybackCommands {
    /// Controls › Sleep Timer: stop after a while, or at the end of the song.
    @ViewBuilder fileprivate var sleepTimerMenu: some View {
        Menu(sleepTimer.isActive ? "Sleep Timer (\(sleepTimer.label))" : "Sleep Timer") {
            if sleepTimer.isActive {
                Button("Turn Off") { sleepTimer.cancel() }
                Divider()
            }
            ForEach(SleepTimer.choices, id: \.self) { minutes in
                Button(SleepTimer.title(minutes: minutes)) {
                    sleepTimer.set(minutes: minutes)
                }
            }
            Button("End of Current Song") { sleepTimer.setEndOfTrack() }
                .disabled(!music.state.hasTrack)
        }
    }
}

/// Closes the player windows (main and a popped-out visualizer), leaving Songtide running in the
/// menu bar. With none open there's nothing to close, so it quits instead.
@MainActor private func closeMainWindowOrQuit() {
    let windows = NSApp.windows.filter { AppDelegate.isPlayerWindow($0) && $0.isVisible }
    guard !windows.isEmpty else { return NSApp.terminate(nil) }
    windows.forEach { $0.performClose(nil) }
}
