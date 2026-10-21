import Foundation

/// Stops playback after a while, or at the end of the current song. The last few seconds fade the
/// volume out, then it's put back for next time.
@MainActor @Observable
final class SleepTimer {
    static let shared = SleepTimer()

    enum Mode: Equatable {
        case off
        case at(Date)
        case endOfTrack(videoId: String)
    }

    private(set) var mode: Mode = .off
    /// Updated every second while counting down, for "23 min left" labels.
    private(set) var remaining: TimeInterval = 0

    static let choices = [15, 30, 45, 60, 90]

    /// "15 Minutes", "1 Hour", "1½ Hours"
    static func title(minutes: Int) -> String {
        switch minutes {
        case 60: String(localized: "1 Hour")
        case 90: String(localized: "1½ Hours")
        case let m where m % 60 == 0: String(localized: "\(m / 60) Hours")
        default: String(localized: "\(minutes) Minutes")
        }
    }
    private let fadeSeconds: TimeInterval = 10

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var volumeBeforeFade: Double?
    @ObservationIgnored private let music = MusicController.shared

    private init() {
        music.observeState { [weak self] state in self?.stateChanged(state) }
    }

    var isActive: Bool { mode != .off }

    func set(minutes: Int) {
        start(.at(Date().addingTimeInterval(TimeInterval(minutes * 60))))
    }

    func setEndOfTrack() {
        guard music.state.hasTrack else { return }
        start(.endOfTrack(videoId: music.state.videoId))
    }

    func cancel() {
        restoreVolume()
        mode = .off
        remaining = 0
        timer?.invalidate()
        timer = nil
    }

    /// "23 min left", "1:05 left", or "End of song".
    var label: String {
        switch mode {
        case .off: return String(localized: "Off", comment: "Sleep timer is off")
        case .endOfTrack: return String(localized: "End of song", comment: "Sleep timer stops at the end of the current song")
        case .at:
            let seconds = Int(remaining.rounded(.up))
            return seconds >= 60 ? String(localized: "\(Int((remaining / 60).rounded(.up))) min left") : String(localized: "0:\(String(format: "%02d", seconds)) left")
        }
    }

    private func start(_ newMode: Mode) {
        cancel()
        mode = newMode
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    private func tick() {
        switch mode {
        case .off:
            return
        case .at(let deadline):
            remaining = max(0, deadline.timeIntervalSinceNow)
            if remaining <= 0 {
                finish()
            } else if remaining <= fadeSeconds, music.state.isPlaying {
                fade(to: remaining / fadeSeconds)
            }
        case .endOfTrack:
            let state = music.state
            let left = state.duration - music.position
            if state.duration > 0, left <= fadeSeconds, left > 0, state.isPlaying {
                fade(to: left / fadeSeconds)
            }
        }
    }

    private func stateChanged(_ state: PlayerState) {
        guard case .endOfTrack(let videoId) = mode else { return }
        // The song it was waiting for ended: either the next one has just started (stop right
        // away), or nothing came after it and playback stopped at the end.
        let reachedEnd = !state.isPlaying && state.duration > 0 && music.position >= state.duration - 1.5
        if state.videoId != videoId || reachedEnd { finish() }
    }

    private func fade(to fraction: Double) {
        if volumeBeforeFade == nil { volumeBeforeFade = music.state.volume }
        guard let full = volumeBeforeFade else { return }
        music.setVolume(max(0, full * fraction))
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        music.pause()
        // When a new song is just starting, YouTube Music can begin it a moment after reporting the
        // change, undoing the pause: check again, then put the volume back so the next play isn't
        // silent.
        Task { [weak self] in
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self else { return }
                if self.music.state.isPlaying { self.music.pause() }
            }
            self?.cancel()
        }
    }

    private func restoreVolume() {
        if let volume = volumeBeforeFade { music.setVolume(volume) }
        volumeBeforeFade = nil
    }
}
