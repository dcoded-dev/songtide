import AppKit
import MediaPlayer

/// Publishes the current track to Control Center / the menu bar Now Playing widget
/// and routes media keys (and AirPods / Touch Bar controls) to the web player.
@MainActor
final class NowPlayingService {
    private let music: MusicController
    private var artworkURL: URL?
    private var artwork: MPMediaItemArtwork?
    private var artworkTask: Task<Void, Never>?
    private var lastPublished: PlayerState?
    /// Whether Songtide has made itself the system's Now Playing app this launch.
    private var claimedNowPlaying = false

    init(music: MusicController) {
        self.music = music
        registerCommands()
        music.observeState { [weak self] state in self?.update(state) }
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        let music = music
        Self.on(center.playCommand) { _ in music.play() }
        Self.on(center.pauseCommand) { _ in music.pause() }
        Self.on(center.togglePlayPauseCommand) { _ in music.playPause() }
        Self.on(center.nextTrackCommand) { _ in music.next() }
        Self.on(center.previousTrackCommand) { _ in music.previous() }
        Self.on(center.changePlaybackPositionCommand) { position in music.seek(to: position) }
        Self.on(center.likeCommand) { _ in music.like() }
        Self.on(center.dislikeCommand) { _ in music.dislike() }
    }

    /// Remote command handlers may be invoked off the main thread; hop to the main actor
    /// rather than letting the closure inherit (and trap on) main-actor isolation.
    nonisolated private static func on(_ command: MPRemoteCommand, _ action: @escaping @MainActor @Sendable (Double) -> Void) {
        command.addTarget { event in
            let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in action(position) }
            return .success
        }
    }

    private func update(_ state: PlayerState) {
        let info = MPNowPlayingInfoCenter.default()
        guard state.hasTrack else {
            info.nowPlayingInfo = nil
            info.playbackState = .stopped
            lastPublished = nil
            return
        }

        // Skip redundant progress-only updates: the system extrapolates elapsed time
        // from the playback rate, so only publish on track/state changes or seeks.
        if let last = lastPublished, last.videoId == state.videoId, last.title == state.title,
           last.isPlaying == state.isPlaying, last.like == state.like, last.artwork == state.artwork,
           abs(last.duration - state.duration) < 1,
           abs(state.time - (last.time + (state.isPlaying ? 0.5 : 0))) < 2.5 {
            lastPublished?.time = state.time
            return
        }
        lastPublished = state

        var dict: [String: Any] = [
            MPMediaItemPropertyTitle: state.title,
            MPMediaItemPropertyArtist: state.artist,
            MPMediaItemPropertyAlbumTitle: state.album,
            MPMediaItemPropertyPlaybackDuration: state.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: state.time,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let artwork, artworkURL == state.artworkURL { dict[MPMediaItemPropertyArtwork] = artwork }
        info.nowPlayingInfo = dict
        if !claimedNowPlaying && !state.isPlaying {
            claimNowPlaying()
        } else {
            info.playbackState = state.isPlaying ? .playing : .paused
        }
        if state.isPlaying { claimedNowPlaying = true }
        MPRemoteCommandCenter.shared().likeCommand.isActive = state.like == .like

        if state.artworkURL != artworkURL { loadArtwork(state.artworkURL) }
    }

    /// MediaPlayer calls the request handler on a background queue, so it must not inherit
    /// this class's main-actor isolation (Swift 6 traps on the executor check otherwise).
    nonisolated private static func makeArtwork(_ image: NSImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }

    /// macOS routes the media keys to the app that last reported *playing*; until then the play
    /// key launches Music.app. At launch YouTube Music restores the last track paused, so report
    /// playing for a moment (no audio plays) and then paused, making Songtide the Now Playing app.
    private func claimNowPlaying() {
        claimedNowPlaying = true
        let info = MPNowPlayingInfoCenter.default()
        info.playbackState = .playing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, !self.music.state.isPlaying else { return }
            MPNowPlayingInfoCenter.default().playbackState = .paused
        }
    }

    private func loadArtwork(_ url: URL?) {
        artworkTask?.cancel()
        artworkURL = url
        artwork = nil
        guard let url else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = NSImage(data: data), !Task.isCancelled, let self else { return }
            let art = Self.makeArtwork(image)
            self.artwork = art
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = art
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
    }
}
