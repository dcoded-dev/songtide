import CoreAudio
import Foundation

/// Nudges playback onto the Mac's new output device (AirPods connecting, speakers chosen in
/// Control Center…). WebKit's audio sometimes stays on the device that was current when playback
/// started; a brief pause and resume makes it reopen the output, which picks up the new default.
/// If macOS paused playback itself (AirPods taken out), it's left paused.
@MainActor
final class AudioOutputMonitor {
    private let music: MusicController
    private var resumeTask: Task<Void, Never>?

    init(music: MusicController) {
        self.music = music
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.outputChanged() }
        }
    }

    private func outputChanged() {
        resumeTask?.cancel()
        resumeTask = Task { [music] in
            // Let macOS act first: taking AirPods out pauses playback, and that should stick. Only
            // if music is still playing a moment later (a device was added or picked) do we
            // restart it so the sound moves to the new output. The player state refreshes every
            // half second, so this also avoids acting on a stale "playing".
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, music.state.isPlaying else { return }
            music.pause()
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            music.play()
        }
    }
}
