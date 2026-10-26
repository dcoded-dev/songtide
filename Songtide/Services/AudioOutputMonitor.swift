import CoreAudio
import Foundation

/// Follows the Mac's output device. Headphones going away (AirPods taken out or disconnected)
/// pause playback straight away, before a moment of the song comes out of the Mac's speakers:
/// macOS asks for a pause too, but that reaches the page a beat after the sound has moved. Any
/// other change (AirPods connecting, speakers chosen in Control Center…) nudges playback onto the
/// new device: WebKit's audio sometimes stays on the device that was current when playback
/// started, and a brief pause and resume makes it reopen the output.
@MainActor
final class AudioOutputMonitor {
    private let music: MusicController
    private var resumeTask: Task<Void, Never>?
    /// The current output and how it's connected, read while it's there (a device that's just
    /// gone can't be asked any more).
    private var device: AudioObjectID
    private var deviceTransport: UInt32

    init(music: MusicController) {
        self.music = music
        device = Self.defaultOutput()
        deviceTransport = Self.transport(device)
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
        let wasHeadphones = deviceTransport == kAudioDeviceTransportTypeBluetooth || deviceTransport == kAudioDeviceTransportTypeBluetoothLE
        device = Self.defaultOutput()
        deviceTransport = Self.transport(device)
        resumeTask?.cancel()
        // From headphones to the Mac's own speakers: stop at once, the way an iPhone does.
        if wasHeadphones, deviceTransport == kAudioDeviceTransportTypeBuiltIn {
            music.pause()
            return
        }
        resumeTask = Task { [music] in
            // Let macOS act first. Only if music is still playing a moment later (a device was
            // added or picked) do we restart it so the sound moves to the new output. The player
            // state refreshes every half second, so this also avoids acting on a stale "playing".
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled, music.state.isPlaying else { return }
            music.pause()
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            music.play()
        }
    }

    private static func defaultOutput() -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return id
    }

    /// How a device is connected (built in, Bluetooth, USB…), or 0 if it can't be read.
    private static func transport(_ device: AudioObjectID) -> UInt32 {
        guard device != kAudioObjectUnknown else { return 0 }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr ? value : 0
    }
}
