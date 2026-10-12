import Foundation
import WidgetKit
import notify

/// Keeps the Now Playing widget current (what's playing, in the shared app group container) and
/// carries out its buttons (Darwin notifications from the widget).
@MainActor
final class WidgetBridge {
    static let shared = WidgetBridge()

    private var last = NowPlayingSnapshot()
    private var artworkSource = ""
    private var tokens: [Int32] = []

    func start() {
        MusicController.shared.observeState { [weak self] state in self?.stateChanged(state) }
        for command in WidgetCommand.allCases {
            var token: Int32 = 0
            notify_register_dispatch(command.notificationName, &token, .main) { _ in
                MainActor.assumeIsolated { Self.perform(command) }
            }
            tokens.append(token)
        }
    }

    private static func perform(_ command: WidgetCommand) {
        let music = MusicController.shared
        switch command {
        case .playPause: music.playPause()
        case .next: music.next()
        case .previous: music.previous()
        }
    }

    private func stateChanged(_ state: PlayerState) {
        var snapshot = NowPlayingSnapshot(title: state.title, artist: state.artist, isPlaying: state.isPlaying,
                                          hasArtwork: last.hasArtwork && state.artwork == artworkSource)
        snapshot.updated = last.updated
        guard snapshot != last else { return }
        snapshot.updated = Date()
        last = snapshot
        write(snapshot)
        if state.artwork != artworkSource {
            artworkSource = state.artwork
            Task { await saveArtwork(from: state.artworkURL, for: state.artwork) }
        }
    }

    private func write(_ snapshot: NowPlayingSnapshot) {
        guard let file = SharedContainer.snapshotURL, let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: file, options: .atomic)
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func saveArtwork(from url: URL?, for source: String) async {
        guard let file = SharedContainer.artworkURL else { return }
        var saved = false
        if let url, let (data, _) = try? await URLSession.shared.data(from: url) {
            saved = (try? data.write(to: file, options: .atomic)) != nil
        }
        guard source == artworkSource else { return } // a newer song arrived meanwhile
        last.hasArtwork = saved
        write(last)
    }
}
