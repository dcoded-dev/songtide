import os
import SwiftUI
import WebKit

/// Shows, hides and moves the visualizer: in the main window by default, or popped out into its own
/// window (remembered). Shared by the player bar, the Controls menu and the visualizer's buttons.
@MainActor
enum VisualizerPresenter {
    static func toggle(_ music: MusicController, open: OpenWindowAction, dismiss: DismissWindowAction) {
        if music.isShowingVisualizer {
            close(music, dismiss: dismiss)
        } else {
            music.isShowingVisualizer = true
            if music.visualizerInWindow { open(id: VisualizerView.windowID) }
        }
    }

    static func close(_ music: MusicController, dismiss: DismissWindowAction) {
        music.isShowingVisualizer = false
        if music.visualizerInWindow { dismiss(id: VisualizerView.windowID) }
    }

    /// Set when a move should land in full screen: the destination enters it once it appears.
    static var enterFullScreenOnArrival = false

    /// Moves the visualizer into its own window. The main window stays as it is; popped out of a
    /// full-screen main window, the new window takes full screen in its own space (a plain window
    /// can't share the main window's).
    static func popOut(_ music: MusicController, open: OpenWindowAction, from host: NSWindow?) {
        enterFullScreenOnArrival = host?.styleMask.contains(.fullScreen) ?? false
        music.visualizerInWindow = true
        open(id: VisualizerView.windowID)
    }

    /// Moves the visualizer back into the main window, which stays as it is (full screen or not).
    static func popIn(_ music: MusicController, dismiss: DismissWindowAction, from host: NSWindow?) {
        music.visualizerInWindow = false // set first, so the closing window doesn't hide it
        dismiss(id: VisualizerView.windowID)
    }
}

/// Butterchurn (MilkDrop), fed with Songtide's own audio, in the main window or its own. Hover to
/// show the preset name and controls; Escape leaves full screen, then closes it.
struct VisualizerView: View {
    enum Placement { case inline, window }

    static let windowID = "visualizer"
    var placement: Placement = .window
    @Environment(MusicController.self) private var music
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var tap = SystemEqualizer.shared
    @State private var model = VisualizerModel()
    @State private var hovering = false
    @State private var isFullScreen = false
    @AppStorage(VisualizerModel.autoChangeKey) private var autoChange = 30
    /// The window this visualizer is in (its own, or the main window), read from the view itself.
    @State private var hostWindow: NSWindow?
    @State private var isRunning = false
    /// Beside the page (horizontal) or above/below it (vertical), when split in the main window.
    var splitAxis: Axis?
    /// How it would split if it stopped filling the page area (for the button's icon).
    var nextSplitAxis: Axis = .horizontal
    @AppStorage(VisualizerView.splitSwappedKey) private var splitSwapped = false
    @AppStorage("visualizerShowsLyrics") private var showsLyrics = false
    static let splitSwappedKey = "visualizerSplitSwapped"

    init(placement: Placement = .window, splitAxis: Axis? = nil, nextSplitAxis: Axis = .horizontal) {
        self.placement = placement
        self.splitAxis = splitAxis
        self.nextSplitAxis = nextSplitAxis
    }

    var body: some View {
        ZStack {
            Color.black
            VisualizerWebView(model: model)
                .opacity(model.presetName.isEmpty ? 0 : 1) // hide the web view's blank white first frame
            if showsLyrics {
                LyricsOverlay()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 90)
                    .allowsHitTesting(false)
            }
            if hovering {
                controls.transition(.opacity)
            }
            if case .needsPermission = tap.status { permissionBanner }
        }
        .background(WindowReader { window in
            guard hostWindow !== window else { return }
            hostWindow = window
            if placement == .window {
                // Its own window keeps the size and place you gave it (saved by AppKit under this name).
                window.setFrameAutosaveName("VisualizerWindow")
            }
            isFullScreen = window.styleMask.contains(.fullScreen)
            if placement == .window, VisualizerPresenter.enterFullScreenOnArrival {
                VisualizerPresenter.enterFullScreenOnArrival = false
                if !isFullScreen {
                    // After the window has settled on screen, or the transition is skipped.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { window.toggleFullScreen(nil) }
                }
            }
        })
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.2), value: hovering)
        .frame(minWidth: placement == .window ? 480 : nil, minHeight: placement == .window ? 300 : nil)
        .ignoresSafeArea(edges: placement == .window ? .all : [])
        .onAppear {
            if placement == .window { music.isShowingVisualizer = true }
            setRunning(true)
            isFullScreen = hostWindow?.styleMask.contains(.fullScreen) ?? false
        }
        .onDisappear {
            setRunning(false)
            // The window closing on its own (close button, ⌘W) hides the visualizer; putting it back
            // in the main window doesn't.
            if placement == .window && music.visualizerInWindow { music.isShowingVisualizer = false }
        }
        .onExitCommand {
            if isFullScreen { hostWindow?.toggleFullScreen(nil) } else { VisualizerPresenter.close(music, dismiss: dismissWindow) }
        }
        // Minimized, hidden (⌘H) or covered: stop feeding it (and listening, unless the equalizer
        // needs to) until it can be seen again.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) {
            guard isHost($0), let hostWindow else { return }
            setRunning(hostWindow.occlusionState.contains(.visible))
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { if isHost($0) { isFullScreen = true} }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { if isHost($0) { isFullScreen = false } }
    }

    /// Starts or stops feeding the visuals and counting as a listener for the audio tap, once each.
    private func setRunning(_ run: Bool) {
        guard run != isRunning else { return }
        isRunning = run
        #if DEBUG
        if ProcessInfo.processInfo.environment["YTM_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[visualizer] \(placement) \(run ? "running" : "paused")\n".utf8))
        }
        #endif
        if run {
            tap.visualizerAppeared()
            model.start()
        } else {
            model.stop()
            tap.visualizerDisappeared()
        }
    }

    private func isHost(_ note: Notification) -> Bool {
        guard let hostWindow else { return false }
        return note.object as? NSWindow === hostWindow
    }

    /// All controls sit along the bottom: the top of the window belongs to macOS (the hidden
    /// title bar, and the menu bar that slides down in full screen), which steals the hover there.
    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Spacer()
            if let message = tap.status.message, tap.status != .running, tap.status != .needsPermission {
                Label(message, systemImage: "info.circle")
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Self.controlFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Self.controlStroke))
            }
            HStack(spacing: 6) {
                overlayButton("Previous Preset", "backward.fill") { model.call("previousPreset()") }
                overlayButton("Random Preset", "shuffle") { model.call("randomPreset()") }
                overlayButton("Next Preset", "forward.fill") { model.call("nextPreset()") }
                // The preset name is a menu: choose a visualizer, and how often it changes itself.
                Menu {
                    // Each automatic change picks a random preset, hence "shuffle".
                    Menu("Auto-Shuffle") {
                        ForEach(VisualizerModel.autoChangeChoices, id: \.self) { seconds in
                            Toggle(VisualizerModel.label(forAutoChange: seconds), isOn: Binding(
                                get: { autoChange == seconds },
                                set: { _ in autoChange = seconds }
                            ))
                        }
                    }
                    Divider()
                    ForEach(model.presetNames, id: \.self) { name in
                        Toggle(name, isOn: Binding(get: { model.presetName == name }, set: { _ in model.select(name) }))
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.presetName).lineLimit(1).truncationMode(.middle)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Self.controlFill, in: Capsule())
                    .overlay(Capsule().strokeBorder(Self.controlStroke))
                    .contentShape(Capsule())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: 280, alignment: .leading)
                .help("Choose a visualizer")
                Spacer(minLength: 12)
                if let splitAxis {
                    // Which side of the page the visualizer is on.
                    overlayButton(splitAxis == .horizontal ? "Swap Sides" : "Swap Top and Bottom",
                                  splitAxis == .horizontal ? "arrow.left.arrow.right" : "arrow.up.arrow.down") {
                        splitSwapped.toggle()
                    }
                }
                if placement == .inline {
                    // Fill the page area, or split it with the page. The icon's solid part is where the
                    // visualizer will be after the click.
                    overlayButton(music.visualizerFills ? "Show Page Beside Visualizer" : "Fill Window",
                                  music.visualizerFills ? splitSymbol : "rectangle.inset.filled") {
                        music.visualizerFills.toggle()
                    }
                    overlayButton("Open in Separate Window", "arrow.up.forward.square") {
                        VisualizerPresenter.popOut(music, open: openWindow, from: hostWindow)
                    }
                } else {
                    overlayButton("Show in Main Window", "arrow.down.backward.square") {
                        VisualizerPresenter.popIn(music, dismiss: dismissWindow, from: hostWindow)
                    }
                }
                // Only in its own window; in the main window the window's own control does this.
                if placement == .window {
                    overlayButton(isFullScreen ? "Exit Full Screen" : "Full Screen",
                                  isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        hostWindow?.toggleFullScreen(nil)
                    }
                }
                overlayButton(showsLyrics ? "Hide Lyrics" + lyricsNote : "Show Lyrics", showsLyrics ? "quote.bubble.fill" : "quote.bubble") {
                    showsLyrics.toggle()
                }
                overlayButton("Close Visualizer", "xmark") { VisualizerPresenter.close(music, dismiss: dismissWindow) }
            }
        }
        .padding(16)
        .foregroundStyle(.white)
        // A soft shade behind the controls, so they read over bright visuals.
        .background(alignment: .bottom) {
            LinearGradient(colors: [.black.opacity(0), .black.opacity(0.65)], startPoint: .top, endPoint: .bottom)
                .frame(height: 140)
                .allowsHitTesting(false)
        }
        .buttonStyle(.borderless)
        .frame(minWidth: 0) // never wider than the visualizer; the preset name truncates instead
    }

    /// The half the visualizer takes when split: left or top, or right or bottom when swapped.
    private var splitSymbol: String {
        switch (nextSplitAxis, splitSwapped) {
        case (.horizontal, false): "rectangle.lefthalf.inset.filled"
        case (.horizontal, true): "rectangle.righthalf.inset.filled"
        case (.vertical, false): "rectangle.tophalf.inset.filled"
        case (.vertical, true): "rectangle.bottomhalf.inset.filled"
        }
    }

    /// Why lyrics over the visualizer show nothing for this song, for the button's tooltip.
    private var lyricsNote: String {
        switch Lyrics.shared.content {
        case .notFound: " (none available for this song)"
        case .plain(Lyrics.instrumental): " (instrumental)"
        case .plain: " (not synced for this song)"
        default: ""
        }
    }

    private func overlayButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 32, height: 32)
                .background(Self.controlFill, in: Circle())
                .overlay(Circle().strokeBorder(Self.controlStroke))
                .contentShape(Circle())
        }
        .help(title)
        .accessibilityLabel(title)
    }

    private static let controlFill = Color.black.opacity(0.6)
    private static let controlStroke = Color.white.opacity(0.18)

    private static let permissionPath = ["Privacy & Security", "Screen & System Audio Recording", "System Audio Recording Only"]

    /// Without permission to capture its audio the visuals can't react; says so front and centre.
    private var permissionBanner: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.yellow)
            Text("The visualizer can't hear the music yet")
                .font(.title3.weight(.semibold))
            Text("Turn on Songtide in System Settings:")
                .font(.callout)
                .foregroundStyle(.secondary)
            // The way there, one step per line.
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(Self.permissionPath.enumerated()), id: \.offset) { step, name in
                    HStack(spacing: 6) {
                        Image(systemName: step == 0 ? "gearshape" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 14)
                        Text(name)
                    }
                    .padding(.leading, CGFloat(step) * 12)
                }
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            Button("Open Settings") { NSWorkspace.shared.open(SystemEqualizer.privacySettingsURL) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 4)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 380)
        .background {
            // Blurred and darkened: the visuals still show through, but calmly.
            RoundedRectangle(cornerRadius: 16).fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.6))
        }
        .environment(\.colorScheme, .dark)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.15)))
        .padding(24)
    }
}

/// Owns the Butterchurn page and the timer that feeds it audio.
@MainActor @Observable
final class VisualizerModel: NSObject, WKScriptMessageHandler {
    private(set) var presetName = ""
    private(set) var presetNames: [String] = []

    /// How often it shuffles to a random preset on its own, in seconds (0 = off). Set in the
    /// visualizer's preset menu (Auto-Shuffle).
    nonisolated static let autoChangeKey = "visualizerAutoChange"
    nonisolated static let autoChangeChoices = [0, 15, 30, 60, 120]
    static var autoChange: Int { UserDefaults.standard.object(forKey: autoChangeKey) as? Int ?? 30 }
    @ObservationIgnored private var sentAutoChange: Int?
    /// The preset last shown, kept across launches so the visualizer picks up where it left off.
    nonisolated static let lastPresetKey = "visualizerPreset"
    private static var lastPreset: String? {
        get { UserDefaults.standard.string(forKey: lastPresetKey) }
        set { UserDefaults.standard.set(newValue, forKey: lastPresetKey) }
    }
    @ObservationIgnored private(set) var webView: WKWebView?
    @ObservationIgnored private var timer: Timer?

    func makeWebView() -> WKWebView {
        if let webView { return webView }
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "visualizer")
        // Menu shortcuts (and ⌃⌘F full screen) win over the page, as in the main window.
        let webView = MenuFirstWebView(frame: .zero, configuration: config)
        webView.underPageBackgroundColor = .black
        if let page = Bundle.main.url(forResource: "visualizer", withExtension: "html") {
            webView.loadFileURL(page, allowingReadAccessTo: page.deletingLastPathComponent())
        }
        self.webView = webView
        return webView
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.feed() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func call(_ js: String) { webView?.evaluateJavaScript(js) }

    func select(_ name: String) { call("selectPreset(\(jsString(name)))") }

    static func label(forAutoChange seconds: Int) -> String {
        switch seconds {
        case 0: "Off"
        case ..<60: "Every \(seconds) Seconds"
        case 60: "Every Minute"
        default: "Every \(seconds / 60) Minutes"
        }
    }

    @ObservationIgnored private var frozen = false

    private func feed() {
        // Pick up a new auto-change interval from the menu or Settings.
        let autoChange = Self.autoChange
        if autoChange != sentAutoChange {
            sentAutoChange = autoChange
            call("setAutoChange(\(autoChange))")
        }
        // Idle (dimmed, drifting very slowly) while playback is paused.
        let freeze = !MusicController.shared.state.isPlaying
        if freeze != frozen {
            frozen = freeze
            call("setFrozen(\(freeze))")
        }
        guard !freeze, let bytes = SystemEqualizer.shared.scopeBytes() else { return }
        call("feed('\(Data(bytes).base64EncodedString())')")
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let name = body["name"] as? String
        let names = body["names"] as? [String]
        MainActor.assumeIsolated {
            switch type {
            case "presets":
                // The page just loaded: give it the current state.
                presetNames = names ?? []
                // Popping out or back in carries on with the same visuals.
                if let last = Self.lastPreset { call("selectPreset(\(jsString(last)), 0)") }
                call("setFrozen(\(frozen))")
                sentAutoChange = nil
            case "preset":
                presetName = name ?? ""
                Self.lastPreset = name
                #if DEBUG
                if ProcessInfo.processInfo.environment["YTM_DEBUG"] != nil {
                    FileHandle.standardError.write(Data("[visualizer preset] \(name ?? "")\n".utf8))
                }
                #endif
            case "error":
                Logger(subsystem: "dev.dcoded.songtide", category: "visualizer").error("Visualizer page error: \(body["message"] as? String ?? "", privacy: .public)")
            default:
                break
            }
        }
    }

    private func jsString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        return data.flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "''"
    }
}

private struct VisualizerWebView: NSViewRepresentable {
    let model: VisualizerModel
    func makeNSView(context: Context) -> WKWebView { model.makeWebView() }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

/// Hands back the NSWindow a SwiftUI view is in, once it's in one.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { WindowReaderView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowReaderView: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.onWindow(window) } }
        }
    }
}
