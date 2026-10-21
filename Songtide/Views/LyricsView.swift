import SwiftUI

/// Lyrics for the song that's playing: timed lines follow the song (the current one bright, the
/// rest dim, scrolling along); plain lyrics just scroll. Used by the lyrics window.
struct LyricsView: View {
    @Environment(MusicController.self) private var music
    private var lyrics = Lyrics.shared

    var body: some View {
        Group {
            switch lyrics.content {
            case .synced(let lines): SyncedLines(lines: lines)
            case .plain(let text):
                ScrollView {
                    Text(text)
                        .font(.title3.weight(.semibold))
                        .lineSpacing(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(24)
                        .textSelection(.enabled)
                }
            case .loading: message("Finding lyrics…")
            case .notFound: message("No lyrics available")
            case .none: message(music.state.hasTrack ? "Finding lyrics…" : "Play something to see its lyrics")
            }
        }
        .onAppear { lyrics.viewerAppeared() }
        .onDisappear { lyrics.viewerDisappeared() }
    }

    private func message(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(.title3)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SyncedLines: View {
    let lines: [Lyrics.Line]
    @Environment(MusicController.self) private var music

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            let current = Lyrics.currentIndex(in: lines, at: music.livePosition)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.title2.weight(.bold))
                                .foregroundStyle(index == current ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                                // Click a line to jump there.
                                .onTapGesture { music.seek(to: line.time) }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 80)
                }
                .scrollIndicators(.never)
                .onChange(of: current) { _, index in
                    guard let index else { return }
                    withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
                }
                .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
            }
        }
    }
}

/// The current line (and the next, dimmer) over the visualizer, when Lyrics is switched on there.
struct LyricsOverlay: View {
    @Environment(MusicController.self) private var music
    private var lyrics = Lyrics.shared
    /// When a song has no lyrics to show here, a short note says so, then fades away (it would
    /// otherwise sit over the visuals for the whole song).
    @State private var notice: String?
    /// Each song gets its own note, even when the one before had no lyrics either.
    private struct NoticeKey: Equatable {
        let videoId: String
        let content: Lyrics.Content
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { _ in
            if let notice {
                Text(notice)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.8), radius: 10)
                    .transition(.opacity)
            } else if case .synced(let lines) = lyrics.content, let index = Lyrics.currentIndex(in: lines, at: music.livePosition) {
                VStack(spacing: 6) {
                    Text(lines[index].text)
                        .font(.system(size: 30, weight: .bold))
                    if index + 1 < lines.count {
                        Text(lines[index + 1].text)
                            .font(.system(size: 20, weight: .semibold))
                            .opacity(0.5)
                    }
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.8), radius: 10)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
                .animation(.easeInOut(duration: 0.25), value: index)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: notice)
        .onAppear { lyrics.viewerAppeared() }
        .onDisappear { lyrics.viewerDisappeared() }
        // Once the lookup is done (nothing while it's still searching).
        .task(id: NoticeKey(videoId: music.state.videoId, content: lyrics.content)) {
            let text: String? = switch lyrics.content {
            case .notFound: String(localized: "No lyrics available")
            case .plain(Lyrics.instrumental): Lyrics.instrumental
            case .plain: String(localized: "Lyrics aren't synced for this song")
            default: nil
            }
            guard let text else { notice = nil; return }
            // As a song changes, its video ID arrives before its lyrics are looked up: wait for
            // things to settle so the last song's result doesn't flash up for the new one.
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            notice = text
            try? await Task.sleep(for: .seconds(4))
            notice = nil
        }
    }
}

/// The floating lyrics window: lyrics on a dark, translucent panel; stays above other windows
/// unless that's turned off (pin button).
struct LyricsWindowView: View {
    static let windowID = "lyrics"
    @Environment(MusicController.self) private var music
    @AppStorage("lyricsOnTop") private var onTop = true
    @State private var window: NSWindow?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(music.state.hasTrack ? music.state.title : String(localized: "Lyrics")).font(.headline).lineLimit(1)
                    if !music.state.artist.isEmpty {
                        Text(music.state.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer()
                Button { onTop.toggle() } label: {
                    Image(systemName: onTop ? "pin.fill" : "pin")
                }
                .buttonStyle(.borderless)
                .help(onTop ? "Stop keeping lyrics on top" : "Keep lyrics on top of other windows")
            }
            .padding(.horizontal, 16)
            .padding(.top, 34) // below the window buttons
            .padding(.bottom, 8)
            LyricsView()
        }
        .frame(minWidth: 280, minHeight: 240)
        .background(.ultraThinMaterial)
        .ignoresSafeArea()
        .background(LyricsWindowReader { window = $0; applyLevel() })
        .onChange(of: onTop) { applyLevel() }
        // SwiftUI keeps this view around when the window closes, so follow the window itself.
        .onAppear { Lyrics.shared.isWindowOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if note.object as? NSWindow === window { Lyrics.shared.isWindowOpen = true }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { note in
            if note.object as? NSWindow === window { Lyrics.shared.isWindowOpen = false }
        }
    }

    private func applyLevel() {
        window?.level = onTop ? .floating : .normal
        window?.setFrameAutosaveName("LyricsWindow")
    }
}

private struct LyricsWindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void
    func makeNSView(context: Context) -> NSView { Reader(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class Reader: NSView {
        let onWindow: (NSWindow) -> Void
        init(onWindow: @escaping (NSWindow) -> Void) { self.onWindow = onWindow; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func viewDidMoveToWindow() { if let window { onWindow(window) } }
    }
}
