import SwiftUI

/// Shared vertical metrics so the sidebar's account footer lines up with the player bar.
enum PlayerBarMetrics {
    static let seekBarHeight: CGFloat = 10
    static let topPadding: CGFloat = 4
    static let contentHeight: CGFloat = 40
    static let bottomPadding: CGFloat = 10
    static let height = seekBarHeight + topPadding + contentHeight + bottomPadding
}

/// Player bar laid out like YouTube Music's: transport on the left, the current track in the
/// middle, volume / repeat / shuffle / expand on the right, and a seek bar along the top edge.
struct PlayerBarView: View {
    @Environment(MusicController.self) private var music
    @State private var width: CGFloat = 1000
    @State private var leftWidth: CGFloat = 0
    @State private var rightWidth: CGFloat = 0
    /// The right group's width with every button showing, measured while it was.
    @State private var fullRightWidth: CGFloat = 0
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    private var lyrics = Lyrics.shared

    private let sidePadding: CGFloat = 16
    private let gap: CGFloat = 16
    /// The least the track group needs: artwork, a few characters of title, and its menu button.
    private let minCenterWidth: CGFloat = 200

    var body: some View {
        let state = music.state
        // The track group is pinned to the true centre of the bar (YouTube Music only centres it
        // between the side groups, which drifts when they differ), leaving room on both sides for
        // the wider side group. When that's too tight, it centres in the gap between the groups
        // instead; when even that's too tight, sleep timer, output, repeat and shuffle fold into
        // a "more" menu. (The volume slider floats above the bar, so it needs no room here.)
        let gapWidth = { (right: CGFloat) in max(0, width - 2 * (sidePadding + gap) - leftWidth - right) }
        let compact = fullRightWidth > 0 && gapWidth(fullRightWidth) < minCenterWidth
        let centredWidth = max(0, width - 2 * (sidePadding + max(leftWidth, rightWidth) + gap))
        let offCentre = centredWidth < minCenterWidth
        let centerWidth = offCentre ? gapWidth(rightWidth) : centredWidth
        let centerOffset = offCentre ? (leftWidth - rightWidth) / 2 : 0
        let showsTime = width >= 700
        let showsRating = centerWidth >= 300
        VStack(spacing: 0) {
            SeekBar()
                .disabled(!state.hasTrack)
            ZStack {
                HStack(spacing: 0) {
                    HStack(spacing: 6) {
                        iconButton("Previous", "backward.end.fill") { music.previous() }
                        iconButton(state.isPlaying ? "Pause" : "Play", state.isPlaying ? "pause.fill" : "play.fill", minSize: 40) { music.playPause() }
                            .font(.system(size: 30))
                        iconButton("Next", "forward.end.fill") { music.next() }
                        // No time at all until something is loaded; "0:00 / 0:00" describes nothing.
                        if showsTime && state.hasTrack {
                            ElapsedTimeText()
                        }
                    }
                    .font(.title3)
                    .fixedSize()
                    .disabled(!state.hasTrack)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { leftWidth = $0 }

                    Spacer(minLength: 0)

                    HStack(spacing: 6) {
                        // Volume and the equalizer are settings, usable before anything plays; the
                        // rest need a track. (dimmedWhenDisabled: these set their own color, which
                        // would otherwise hide the disabled look.)
                        VolumeControl()
                        if compact {
                            MoreMenu()
                        } else {
                            SleepTimerBadge()
                            OutputMenu()
                            Group {
                                iconButton(state.repeat == .one ? "Repeat One" : "Repeat", state.repeat == .one ? "repeat.1" : "repeat") { music.toggleRepeat() }
                                    .foregroundStyle(state.repeat == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.songtide))
                                iconButton("Shuffle", "shuffle") { music.shuffle() }
                                    .foregroundStyle(state.shuffle ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.secondary))
                            }
                            .dimmedWhenDisabled() // before .disabled, so it sees the disabled state
                            .disabled(!state.hasTrack)
                        }
                        EqualizerMenu()
                        iconButton(lyrics.isWindowOpen ? "Hide Lyrics" : "Show Lyrics", "quote.bubble") {
                            if lyrics.isWindowOpen { dismissWindow(id: LyricsWindowView.windowID) } else { Lyrics.shared.isWindowOpen = true; openWindow(id: LyricsWindowView.windowID) }
                        }
                        .foregroundStyle(lyrics.isWindowOpen ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.primary))
                            .dimmedWhenDisabled()
                            .disabled(!state.hasTrack)
                        // The visualizer works without a track (it idles until something plays).
                        iconButton(visualizerTitle, "waveform") {
                            VisualizerPresenter.toggle(music, open: openWindow, dismiss: dismissWindow)
                        }
                        .foregroundStyle(music.isShowingVisualizer ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.primary))
                        // A warning while it can't hear Songtide (in place of the pop-out arrow).
                        .permissionBadge(visualizerNeedsPermission)
                        // A small arrow while it's popped out into its own window.
                        .overlay(alignment: .topTrailing) {
                            if music.isShowingVisualizer && music.visualizerInWindow && !visualizerNeedsPermission {
                                Image(systemName: "arrow.up.forward")
                                    .font(.system(size: 7, weight: .heavy))
                                    .foregroundStyle(Color.songtide)
                                    .offset(x: 0, y: 3)
                                    .allowsHitTesting(false)
                            }
                        }
                        // Up Next / Now Playing, like Apple Music's "Playing Next" button; tinted
                        // while open. (Clicking the artwork opens it too.)
                        iconButton(music.isNowPlayingVisible ? "Hide Up Next" : "Show Up Next", "list.bullet") { music.toggleNowPlaying() }
                            .foregroundStyle(music.isNowPlayingVisible ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.primary))
                            .dimmedWhenDisabled()
                            .disabled(!state.hasTrack)
                    }
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: {
                        rightWidth = $0
                        if !compact { fullRightWidth = $0 }
                    }
                }
                // Above the track group, so the floating volume panel draws over it and keeps the hover.
                .zIndex(1)

                // Fixed width, so the group doesn't change size with the title. Hidden when nothing
                // is loaded; the side groups don't move either way.
                if state.hasTrack {
                    TrackInfoView(state: state, showsRating: showsRating)
                        .frame(width: min(centerWidth, 480))
                        .offset(x: centerOffset)
                }
            }
            .frame(height: PlayerBarMetrics.contentHeight)
            .buttonStyle(.borderless)
            .padding(.horizontal, sidePadding)
            .padding(.top, PlayerBarMetrics.topPadding)
            .padding(.bottom, PlayerBarMetrics.bottomPadding)
        }
        .frame(height: PlayerBarMetrics.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .background(.bar)
    }
}

/// Thin horizontal volume track with a round knob; click or drag anywhere on it.
private struct VolumeSlider: View {
    var value: Double
    @Binding var dragging: Bool
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let fraction = min(max(value / 100, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.25)).frame(height: 3)
                Capsule().fill(.primary).frame(width: width * fraction, height: 3)
                Circle().fill(.primary)
                    .frame(width: 12, height: 12)
                    .offset(x: width * fraction - 6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        dragging = true
                        onChange(Double(min(max(drag.location.x / width, 0), 1)) * 100)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(Int(value)) percent")
        .accessibilityAdjustableAction { direction in
            onChange(min(max(value + (direction == .increment ? 10 : -10), 0), 100))
        }
    }
}

/// Borderless icon button with a real accessibility label, a tooltip, and a hit area of at
/// least 28×28pt regardless of how thin the glyph is.
private func iconButton(_ title: String, _ symbol: String, rotation: Angle = .zero, minSize: CGFloat = 28, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Label(title, systemImage: symbol)
            .labelStyle(.iconOnly)
            .rotationEffect(rotation)
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
    }
    .help(title)
}

/// Player bar button for the equalizer: Off, presets, and "Custom…" (Settings › Playback).
/// A plain button that pops up a native menu, so it can be tinted while on like repeat (a SwiftUI
/// menu button always draws its icon plain).
private struct EqualizerMenu: View {
    @Environment(\.openSettings) private var openSettings
    private var equalizer = SystemEqualizer.shared

    var body: some View {
        iconButton("Equalizer", "slider.vertical.3") { showMenu() }
            .foregroundStyle(equalizer.isEnabled ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.primary))
            // On, but without permission to capture its audio it can't do anything: say so.
            .permissionBadge(needsPermission)
            .accessibilityValue(equalizer.isEnabled ? (equalizer.preset?.name ?? "Custom") : "Off")
    }

    private var needsPermission: Bool {
        guard equalizer.isEnabled, case .needsPermission = equalizer.status else { return false }
        return true
    }

    private func showMenu() {
        let menu = NSMenu()
        if needsPermission {
            // Short lines, so the menu never has to truncate them.
            menu.addItem(.sectionHeader(title: "Audio Access Needed"))
            let allow = ClosureMenuItem(title: "Allow in Privacy Settings…", keyEquivalent: "") {
                NSWorkspace.shared.open(SystemEqualizer.privacySettingsURL)
            }
            allow.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: nil)
            menu.addItem(allow)
            menu.addItem(.separator())
        }
        let off = ClosureMenuItem(title: "Off", keyEquivalent: "") { equalizer.setEnabled(false) }
        off.state = equalizer.isEnabled ? .off : .on
        menu.addItem(off)
        menu.addItem(.separator())
        for preset in Equalizer.presets {
            let item = ClosureMenuItem(title: preset.name, keyEquivalent: "") { equalizer.choose(preset) }
            item.state = equalizer.isEnabled && equalizer.preset == preset ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let custom = ClosureMenuItem(title: "Custom…", keyEquivalent: "") {
            if !equalizer.isEnabled { equalizer.setEnabled(true) }
            UserDefaults.standard.set(SettingsTab.playback.rawValue, forKey: SettingsTab.key)
            openSettings()
        }
        custom.state = equalizer.isEnabled && equalizer.preset == nil ? .on : .off
        menu.addItem(custom)
        // Opens where the button was clicked, like any other pop-up menu.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

/// Where the sound goes: the Mac's outputs (speakers, AirPods, AirPlay…), current one checked.
private struct OutputMenu: View {
    var body: some View {
        iconButton("Output", "airplayaudio") { showMenu() }
    }

    private func showMenu() { Self.menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

    static func menu() -> NSMenu {
        let menu = NSMenu()
        let current = AudioOutputs.currentID
        for device in AudioOutputs.devices {
            let item = ClosureMenuItem(title: device.name, keyEquivalent: "") { AudioOutputs.select(device) }
            item.image = NSImage(systemSymbolName: device.symbol, accessibilityDescription: nil)
            item.state = device.id == current ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Sound Settings…", keyEquivalent: "") {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension")!)
        })
        return menu
    }
}

/// The sleep timer: a moon that opens the timer menu; while it runs, tinted with the time left.
/// Click to set, change or turn it off.
private struct SleepTimerBadge: View {
    private var timer = SleepTimer.shared
    @Environment(MusicController.self) private var music

    var body: some View {
        if timer.isActive {
            Button(action: showMenu) {
                HStack(spacing: 3) {
                    Image(systemName: "moon.zzz.fill")
                    Text(shortLabel).monospacedDigit()
                }
                .font(.caption)
                .foregroundStyle(Color.songtide)
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Sleep timer: \(timer.label)")
        } else {
            iconButton("Sleep Timer", "moon.zzz", action: showMenu)
        }
    }

    /// "23m", "0:45", or "end"
    private var shortLabel: String {
        if case .endOfTrack = timer.mode { return "end" }
        let seconds = Int(timer.remaining.rounded(.up))
        return seconds >= 60 ? "\(Int((timer.remaining / 60).rounded(.up)))m" : "0:\(String(format: "%02d", seconds))"
    }

    private func showMenu() { Self.menu(music: music).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) }

    static func menu(music: MusicController) -> NSMenu {
        let timer = SleepTimer.shared
        let menu = NSMenu()
        if timer.isActive {
            menu.addItem(ClosureMenuItem(title: "Turn Off Sleep Timer", keyEquivalent: "") { timer.cancel() })
            menu.addItem(.separator())
        }
        for minutes in SleepTimer.choices {
            menu.addItem(ClosureMenuItem(title: SleepTimer.title(minutes: minutes), keyEquivalent: "") { timer.set(minutes: minutes) })
        }
        let end = ClosureMenuItem(title: "End of Current Song", keyEquivalent: "") { timer.setEndOfTrack() }
        end.isEnabled = music.state.hasTrack
        menu.addItem(end)
        return menu
    }
}

/// In a narrow window: sleep timer, output, repeat and shuffle in one menu. Tinted while any of
/// them is on, as their own buttons would be.
private struct MoreMenu: View {
    @Environment(MusicController.self) private var music
    private var timer = SleepTimer.shared

    var body: some View {
        let state = music.state
        iconButton("More Controls", "ellipsis.circle", action: showMenu)
            .foregroundStyle(timer.isActive || state.shuffle || state.repeat != .off ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.primary))
    }

    private func showMenu() {
        let state = music.state
        let menu = NSMenu()
        menu.autoenablesItems = false

        let sleep = NSMenuItem(title: timer.isActive ? "Sleep Timer (\(timer.label))" : "Sleep Timer", action: nil, keyEquivalent: "")
        sleep.image = NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: nil)
        sleep.submenu = SleepTimerBadge.menu(music: music)
        menu.addItem(sleep)

        let output = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
        output.image = NSImage(systemSymbolName: "airplayaudio", accessibilityDescription: nil)
        output.submenu = OutputMenu.menu()
        menu.addItem(output)
        menu.addItem(.separator())

        let repeatTitle = switch state.repeat { case .off: "Repeat"; case .all: "Repeat All"; case .one: "Repeat One" }
        let repeatItem = ClosureMenuItem(title: repeatTitle, keyEquivalent: "") { music.toggleRepeat() }
        repeatItem.image = NSImage(systemSymbolName: state.repeat == .one ? "repeat.1" : "repeat", accessibilityDescription: nil)
        repeatItem.state = state.repeat == .off ? .off : .on
        repeatItem.isEnabled = state.hasTrack
        menu.addItem(repeatItem)

        let shuffle = ClosureMenuItem(title: "Shuffle", keyEquivalent: "") { music.shuffle() }
        shuffle.image = NSImage(systemSymbolName: "shuffle", accessibilityDescription: nil)
        shuffle.state = state.shuffle ? .on : .off
        shuffle.isEnabled = state.hasTrack
        menu.addItem(shuffle)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

extension PlayerBarView {
    fileprivate var visualizerNeedsPermission: Bool {
        guard music.isShowingVisualizer, case .needsPermission = SystemEqualizer.shared.status else { return false }
        return true
    }

    fileprivate var visualizerTitle: String {
        guard music.isShowingVisualizer else { return "Show Visualizer" }
        return music.visualizerInWindow ? "Hide Visualizer (open in its own window)" : "Hide Visualizer"
    }
}

extension View {
    /// A small warning triangle on a player bar button whose feature can't hear Songtide's audio.
    fileprivate func permissionBadge(_ shown: Bool) -> some View {
        overlay(alignment: .topTrailing) {
            if shown {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.yellow)
                    .offset(x: 3, y: -1)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct DimmedWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.35) }
}

extension View {
    /// Fades a control that sets its own color, so it still looks disabled when it is.
    func dimmedWhenDisabled() -> some View { modifier(DimmedWhenDisabled()) }
}

/// "0:21 / 2:51". Its own view so position updates redraw just this label, not the whole bar.
private struct ElapsedTimeText: View {
    @Environment(MusicController.self) private var music

    var body: some View {
        Text("\(formatTime(music.position)) / \(formatTime(music.state.duration))")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize()
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds > 0 else { return "0:00" }
    let total = Int(seconds)
    let h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

/// YouTube Music-style progress line along the top edge: constant thickness, a knob while
/// hovering or dragging, and a bubble showing the time under the pointer. Click or drag to seek.
private struct SeekBar: View {
    private var accentStore = AccentStore.shared
    private var accent: Color { accentStore.accent.color }
    @Environment(MusicController.self) private var music
    @State private var hoverX: CGFloat?
    @State private var dragTime: Double?

    private let lineHeight: CGFloat = 3
    private let knobSize: CGFloat = 13

    var body: some View {
        let state = music.state
        let duration = max(state.duration, 1)
        let progress = min(max((dragTime ?? music.position) / duration, 0), 1)
        GeometryReader { geo in
            let width = geo.size.width
            let time = { (x: CGFloat) in Double(min(max(x / width, 0), 1)) * duration }
            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(.primary.opacity(0.18))
                    .frame(height: lineHeight)
                Rectangle()
                    .fill(LinearGradient(colors: [accent, accent.mix(with: .pink, by: 0.35)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * progress, height: lineHeight)
                if hoverX != nil || dragTime != nil {
                    Circle()
                        .fill(accent)
                        .frame(width: knobSize, height: knobSize)
                        .offset(x: width * progress - knobSize / 2, y: (lineHeight - knobSize) / 2)
                    // Bubble follows the pointer while hovering, the knob while dragging.
                    let bubbleX = dragTime != nil ? width * progress : (hoverX ?? 0)
                    Text(formatTime(dragTime ?? time(bubbleX)))
                        .font(.callout.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color(white: 0.13)))
                        .fixedSize()
                        .position(x: min(max(bubbleX, 28), width - 28), y: -20)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hoverX = point.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in dragTime = time(value.location.x) }
                    .onEnded { _ in
                        if let dragTime { music.seek(to: dragTime) }
                        dragTime = nil
                    }
            )
        }
        .frame(height: PlayerBarMetrics.seekBarHeight)
        .zIndex(1)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue("\(formatTime(music.position)) of \(formatTime(state.duration))")
        .accessibilityAdjustableAction { direction in
            music.seek(to: music.position + (direction == .increment ? 10 : -10))
        }
    }
}

private struct TrackInfoView: View {
    @Environment(MusicController.self) private var music
    let state: PlayerState
    var showsRating = true

    var body: some View {
        HStack(spacing: 12) {
            Button { music.toggleNowPlaying() } label: { Artwork(url: state.artworkURL, size: 40) }
                .buttonStyle(.plain)
                .help("Open Player")
            // Fills the space between the artwork and the buttons; long titles scroll.
            VStack(alignment: .leading, spacing: 2) {
                MarqueeText(text: state.hasTrack ? state.title : "Not Playing", font: .headline)
                MarqueeText(text: state.subtitle, font: .subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                if showsRating {
                    iconButton("Like", state.like == .like ? "hand.thumbsup.fill" : "hand.thumbsup") { music.like() }
                    iconButton("Dislike", state.like == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown") { music.dislike() }
                }
                iconButton("More", "ellipsis", rotation: .degrees(90)) { music.showTrackMenu() }
            }
            .fixedSize()
        }
    }
}

/// One line of text that, when it doesn't fit, scrolls sideways to show the rest: a pause at the
/// start, then round in a loop. Truncated instead with Reduce Motion on or the setting off.
struct MarqueeText: View {
    let text: String
    var font: Font
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(Preferences.scrollLongTitles) private var scrollLongTitles = true
    @State private var textWidth: CGFloat = 0
    @State private var boxWidth: CGFloat = 0
    @State private var offset: CGFloat = 0

    private let gap: CGFloat = 36
    private let speed: CGFloat = 55 // points per second
    private let pause: Duration = .seconds(2.5)

    var body: some View {
        let scrolls = scrollLongTitles && !reduceMotion && boxWidth > 0 && textWidth > boxWidth + 1
        // The plain line sizes the box (and is what shows, and what VoiceOver reads, when it fits).
        Text(text)
            .font(font)
            .lineLimit(1)
            .opacity(scrolls ? 0 : 1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { boxWidth = $0 }
            .background(alignment: .leading) {
                Text(text).font(font).fixedSize().hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            }
            .overlay(alignment: .leading) {
                if scrolls {
                    MarqueeStrip(text: text, font: font, offset: offset, textWidth: textWidth, boxWidth: boxWidth, gap: gap)
                        .accessibilityHidden(true)
                }
            }
            .task(id: "\(text)|\(scrolls)|\(Int(textWidth))") { await scroll(scrolls) }
    }

    /// Pause, scroll one copy's width (the second copy then sits where the first began), jump
    /// back unseen, repeat. Restarts whenever the text or whether it fits changes.
    private func scroll(_ scrolls: Bool) async {
        withTransaction(Transaction(animation: nil)) { offset = 0 }
        guard scrolls else { return }
        let distance = textWidth + gap
        let duration = Double(distance / speed)
        while !Task.isCancelled {
            try? await Task.sleep(for: pause)
            guard !Task.isCancelled else { return }
            withAnimation(.linear(duration: duration)) { offset = -distance }
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            withTransaction(Transaction(animation: nil)) { offset = 0 }
        }
    }
}

/// The moving copies of a marquee line. Animatable, so the edge fades follow every frame: the
/// left edge fades only while text is passing it (not at rest, and not in the gap as the start
/// comes back round); the right edge fades where the text runs on.
private struct MarqueeStrip: View, Animatable {
    let text: String
    let font: Font
    var offset: CGFloat
    let textWidth: CGFloat
    let boxWidth: CGFloat
    let gap: CGFloat

    nonisolated var animatableData: CGFloat {
        get { offset }
        set { offset = newValue }
    }

    var body: some View {
        let passed = -offset // how far the line has moved
        let leftFade = max(0, min(12, passed, textWidth - passed))
        HStack(spacing: gap) { Text(text); Text(text) }
            .font(font)
            .fixedSize()
            .offset(x: offset)
            .frame(width: boxWidth, alignment: .leading)
            .clipped()
            .mask {
                HStack(spacing: 0) {
                    LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: leftFade)
                    Color.black
                    LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 16)
                }
            }
    }
}

struct Artwork: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            ZStack {
                Rectangle().fill(.quaternary)
                Image(systemName: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 8, style: .continuous))
    }
}

struct TransportControls: View {
    enum Size { case regular, compact }
    @Environment(MusicController.self) private var music
    var size: Size

    var body: some View {
        let state = music.state
        HStack(spacing: size == .regular ? 22 : 16) {
            if size == .regular {
                Button { music.shuffle() } label: { Image(systemName: "shuffle") }
                    .help("Shuffle")
            }
            Button { music.previous() } label: { Image(systemName: "backward.end.fill") }
                .help("Previous")
            Button { music.playPause() } label: {
                Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                    .font(size == .regular ? .title : .title2)
                    .frame(width: 28)
            }
            .help(state.isPlaying ? "Pause" : "Play")
            Button { music.next() } label: { Image(systemName: "forward.end.fill") }
                .help("Next")
            if size == .regular {
                Button { music.toggleRepeat() } label: {
                    Image(systemName: state.repeat == .one ? "repeat.1" : "repeat")
                        .foregroundStyle(state.repeat == .off ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.songtide))
                }
                .help("Repeat")
            }
        }
        .font(size == .regular ? .title3 : .body)
        .buttonStyle(.borderless)
        .disabled(!state.hasTrack)
    }
}

struct ScrubberView: View {
    @Environment(MusicController.self) private var music
    @State private var scrubValue: Double?

    var body: some View {
        let state = music.state
        HStack(spacing: 8) {
            Text(formatTime(scrubValue ?? music.position)).frame(width: 44, alignment: .trailing)
            Slider(
                value: Binding(get: { scrubValue ?? music.position }, set: { scrubValue = $0 }),
                in: 0...max(state.duration, 1)
            ) { editing in
                if !editing, let value = scrubValue {
                    music.seek(to: value)
                    scrubValue = nil
                }
            }
            .controlSize(.mini)
            Text(formatTime(state.duration)).frame(width: 44, alignment: .leading)
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

/// Speaker button that shows a horizontal volume slider in a small floating panel to its left on
/// hover. The panel overlays whatever is there, so it never takes space in or moves anything in the bar.
private struct VolumeControl: View {
    @Environment(MusicController.self) private var music
    @State private var hoveringButton = false
    @State private var hoveringSlider = false
    @State private var dragging = false
    @State private var showsSlider = false
    @State private var closeTask: Task<Void, Never>?  // the pending open or close

    var body: some View {
        let state = music.state
        Button { music.toggleMute() } label: {
            Label(state.muted ? "Unmute" : "Mute", systemImage: icon(state))
                .labelStyle(.iconOnly)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .help(state.muted ? "Unmute" : "Mute")
        .onHover { hoveringButton = $0; updateVisibility() }
        .overlay(alignment: .trailing) {
            if showsSlider {
                VolumeSlider(value: state.muted ? 0 : state.volume, dragging: $dragging) { music.setVolume($0) }
                    .frame(width: 110, height: 16)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(white: 0.22))
                            .shadow(color: .black.opacity(0.5), radius: 12, y: 4)
                    )
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.14)))
                    .compositingGroup()
                    // Sits just left of the button, vertically centred on it; the small gap stays
                    // hoverable so moving across from the button doesn't close it.
                    .padding(.trailing, 6)
                    .contentShape(Rectangle())
                    .onHover { hoveringSlider = $0; updateVisibility() }
                    .fixedSize()
                    .offset(x: -28)
            }
        }
        .onChange(of: dragging) { updateVisibility() }
    }

    /// Opens once the pointer rests on the button (hover intent), so passing over it on the way
    /// to another control doesn't flash the slider; closes after a short grace period so the
    /// pointer can move from the button onto the slider without it disappearing.
    private func updateVisibility() {
        closeTask?.cancel()
        if hoveringButton || hoveringSlider || dragging {
            guard !showsSlider else { return }
            closeTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled, hoveringButton || hoveringSlider || dragging { showsSlider = true }
            }
        } else {
            closeTask = Task {
                try? await Task.sleep(for: .milliseconds(400))
                if !Task.isCancelled { showsSlider = false }
            }
        }
    }

    private func icon(_ state: PlayerState) -> String {
        if state.muted || state.volume == 0 { return "speaker.slash.fill" }
        if state.volume < 34 { return "speaker.wave.1.fill" }
        if state.volume < 67 { return "speaker.wave.2.fill" }
        return "speaker.wave.3.fill"
    }
}
