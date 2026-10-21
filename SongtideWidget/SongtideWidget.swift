import AppIntents
import SwiftUI
import WidgetKit

// Songtide's Now Playing widget (desktop and Notification Center) and Control Center control.
// They read what's playing from the app group container and send commands back to the app.

struct NowPlayingEntry: TimelineEntry {
    let date: Date
    let snapshot: NowPlayingSnapshot
    let artwork: NSImage?
}

struct NowPlayingProvider: TimelineProvider {
    func placeholder(in context: Context) -> NowPlayingEntry {
        NowPlayingEntry(date: .now, snapshot: NowPlayingSnapshot(title: String(localized: "Song Title"), artist: String(localized: "Artist"), isPlaying: true), artwork: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (NowPlayingEntry) -> Void) { completion(current()) }

    // Songtide asks for a reload whenever the song or play state changes, so no schedule is needed.
    func getTimeline(in context: Context, completion: @escaping (Timeline<NowPlayingEntry>) -> Void) {
        completion(Timeline(entries: [current()], policy: .never))
    }

    private func current() -> NowPlayingEntry {
        let snapshot = SharedContainer.readSnapshot()
        let artwork = snapshot.hasArtwork ? SharedContainer.artworkURL.flatMap { NSImage(contentsOf: $0) } : nil
        return NowPlayingEntry(date: .now, snapshot: snapshot, artwork: artwork)
    }
}

// MARK: Buttons (sent on to Songtide)

struct WidgetPlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    func perform() async throws -> some IntentResult { WidgetCommand.playPause.send(); return .result() }
}

struct WidgetNextIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Song"
    func perform() async throws -> some IntentResult { WidgetCommand.next.send(); return .result() }
}

struct WidgetPreviousIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Song"
    func perform() async throws -> some IntentResult { WidgetCommand.previous.send(); return .result() }
}

// MARK: Views

struct NowPlayingWidgetView: View {
    let entry: NowPlayingEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            if entry.snapshot.hasTrack {
                if family == .systemSmall { small } else { medium }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "music.note").font(.title)
                    Text("Nothing playing").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
        }
        .containerBackground(for: .widget) {
            ZStack {
                Color(red: 0.08, green: 0.06, blue: 0.12)
                if let artwork = entry.artwork {
                    Image(nsImage: artwork).resizable().aspectRatio(contentMode: .fill).blur(radius: 30).opacity(0.55)
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// Square artwork, cropped to fill (video thumbnails are 16:9). Kept in full color when the
    /// desktop shows widgets tinted, which would otherwise paint it a solid block.
    private func artwork(size: CGFloat) -> some View {
        Group {
            if let image = entry.artwork {
                Image(nsImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.fullColor)
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.12).overlay(Image(systemName: "music.note").foregroundStyle(.white.opacity(0.6)))
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.snapshot.title).font(.headline).lineLimit(2)
            Text(entry.snapshot.artist).font(.caption).opacity(0.75).lineLimit(1)
        }
    }

    private var playPause: some View {
        Button(intent: WidgetPlayPauseIntent()) {
            Image(systemName: entry.snapshot.isPlaying ? "pause.fill" : "play.fill")
        }
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                artwork(size: 52)
                Spacer()
                playPause.buttonStyle(.plain).font(.title2)
            }
            Spacer(minLength: 0)
            titles
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            artwork(size: 110)
            VStack(alignment: .leading, spacing: 10) {
                titles
                Spacer(minLength: 0)
                HStack(spacing: 22) {
                    Button(intent: WidgetPreviousIntent()) { Image(systemName: "backward.fill") }
                    playPause
                    Button(intent: WidgetNextIntent()) { Image(systemName: "forward.fill") }
                }
                .buttonStyle(.plain)
                .font(.title3)
            }
            Spacer(minLength: 0)
        }
    }
}

struct NowPlayingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NowPlaying", provider: NowPlayingProvider()) { entry in
            NowPlayingWidgetView(entry: entry)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing in Songtide, with playback controls.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// Control Center (macOS 26 and later): play or pause Songtide.
@available(macOS 26.0, *)
struct PlayPauseControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "dev.dcoded.songtide.playpause") {
            ControlWidgetButton(action: WidgetPlayPauseIntent()) {
                Label("Songtide", systemImage: "playpause.fill")
            }
        }
        .displayName("Play or Pause")
        .description("Plays or pauses Songtide.")
    }
}

@main
struct SongtideWidgets: WidgetBundle {
    var body: some Widget {
        NowPlayingWidget()
        if #available(macOS 26.0, *) {
            PlayPauseControl()
        }
    }
}
