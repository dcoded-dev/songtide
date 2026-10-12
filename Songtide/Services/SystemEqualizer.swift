import AppKit
import CoreAudio
import Observation
import os

private let log = Logger(subsystem: "dev.dcoded.songtide", category: "equalizer")

/// The optional equalizer, and the audio feed for the visualizer. WebKit won't let the page's own Web Audio read YouTube Music's
/// streaming media, so this taps the audio of Songtide's WebKit GPU helper with a Core Audio
/// process tap (macOS 14.2+), mutes the original and plays an equalised copy through a private
/// aggregate device. It needs the "System Audio Recording Only" permission, which is why it's opt-in.
///
/// Safety: the original is never muted until the tap has delivered real audio, and a watchdog
/// unmutes it straight away if capture goes silent while music plays (e.g. permission revoked).
@MainActor @Observable
final class SystemEqualizer {
    static let shared = SystemEqualizer()

    enum Status: Equatable {
        case off
        case waitingForAudio
        case verifying
        case running
        case needsPermission
        case failed(String)

        var message: String? {
            switch self {
            case .off, .running: nil
            case .waitingForAudio: "Starts when music plays."
            case .verifying: "Checking that Songtide can hear the music…"
            case .needsPermission: "Songtide needs permission to hear the music. Allow it in System Settings › Privacy & Security › Screen & System Audio Recording, under System Audio Recording Only."
            case .failed(let reason): reason
            }
        }
    }

    private(set) var status: Status = .off {
        didSet {
            // Remembered, so a missing permission shows at once next time rather than only after
            // a few seconds of silent capture (macOS offers no way to ask).
            if status == .needsPermission { Self.permissionMissing = true }
            if status == .running { Self.permissionMissing = false }
        }
    }
    private static let permissionMissingKey = "audioCapturePermissionMissing"
    private static var permissionMissing: Bool {
        get { UserDefaults.standard.bool(forKey: permissionMissingKey) }
        set { UserDefaults.standard.set(newValue, forKey: permissionMissingKey) }
    }
    /// Shared by Settings and the player bar's menu, so a change in one shows in the other.
    private(set) var isEnabled = Equalizer.isEnabled
    private(set) var gains = Equalizer.gains
    /// How many visualizers are on screen; the tap runs (listening only) while any is. A count
    /// because popping the visualizer in or out briefly has two on screen.
    private var visualizers = 0 {
        didSet { if (visualizers > 0) != (oldValue > 0) { reconfigure() } }
    }
    private var visualizerShown: Bool { visualizers > 0 }
    func visualizerAppeared() { visualizers += 1 }
    func visualizerDisappeared() { visualizers = max(0, visualizers - 1) }

    /// The latest audio for the visualizer, or nil if nothing's being captured yet.
    func scopeBytes() -> [UInt8]? { render?.scopeBytes() }

    /// The preset matching the current curve, or nil for a custom one.
    var preset: Equalizer.Preset? { Equalizer.preset(matching: gains) }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!

    // MARK: Core Audio objects

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var render: EqualizerRenderState?
    private var tappedProcess = AudioObjectID(kAudioObjectUnknown)
    private var listenersInstalled = false
    private var timer: Timer?
    /// Set once the tap has delivered real (non-silent) audio. Until then the original is never
    /// muted: a tap without permission delivers silence, and muting would leave no sound at all.
    private var captureVerified = false
    private var silentChecks = 0

    private init() {
        // "On" with every band at 0 was the old Flat preset; that's now simply Off.
        if isEnabled && gains == Equalizer.flat {
            isEnabled = false
            UserDefaults.standard.set(false, forKey: Equalizer.enabledKey)
        }
    }

    /// Call once at launch so a saved "equalizer on" setting takes effect.
    func start() { reconfigure() }

    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Equalizer.enabledKey)
        captureVerified = false
        reconfigure()
    }

    /// Picks a preset, turning the equalizer on if it's off.
    func choose(_ preset: Equalizer.Preset) {
        setGains(preset.gains)
        if !isEnabled { setEnabled(true) }
    }

    func setGains(_ gains: [Double]) {
        guard gains != self.gains else { return }
        self.gains = gains
        Equalizer.gains = gains
        pushEQ()
    }

    // MARK: Lifecycle

    /// Starts, restarts or stops the tap to match what's needed right now.
    private func reconfigure() {
        guard isEnabled || visualizerShown else {
            stopTap()
            timer?.invalidate()
            timer = nil
            status = .off
            return
        }
        installListeners()
        startTimer()
        guard let process = findPlayerProcess() else {
            if render == nil { status = status == .needsPermission || Self.permissionMissing ? .needsPermission : .waitingForAudio }
            return
        }
        // Only mute the original (and play the equalised copy) when the equalizer is on and the
        // tap is proven to hear real audio; the visualizer alone just listens.
        let replaces = isEnabled && captureVerified
        // The tap's mute behaviour is fixed when it's created, so switching needs a new tap.
        if let render, render.replacesOriginal == replaces, process == tappedProcess {
            pushEQ()
            return
        }
        stopTap()
        do {
            try startTap(process: process, replacesOriginal: replaces)
            status = replaces || captureVerified ? .running : Self.permissionMissing ? .needsPermission : .verifying
            log.notice("Tap on process \(process) (pid \(self.pid(of: process))), replacing original: \(replaces)")
        } catch {
            log.error("Tap failed: \(error.localizedDescription, privacy: .public)")
            stopTap()
            status = .failed(error.localizedDescription)
        }
    }

    private func pushEQ() {
        guard let render, render.replacesOriginal else { return }
        let sampleRate = tapFormat(tapID)?.mSampleRate ?? 48000
        render.setEQ(gains.allSatisfy { $0 == 0 } ? nil : EQProcessor(gains: gains, sampleRate: sampleRate, channels: 2))
    }

    private func startTap(process: AudioObjectID, replacesOriginal: Bool) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: [process])
        description.name = "Songtide"
        description.isPrivate = true
        description.muteBehavior = replacesOriginal ? .mutedWhenTapped : .unmuted
        try check(AudioHardwareCreateProcessTap(description, &tapID), "Couldn't capture Songtide's audio")

        guard let outputUID = defaultOutputDeviceUID() else { throw EqualizerError("No audio output device.") }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Songtide Equalizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "Couldn't create the equalizer's audio device")

        let format = tapFormat(tapID)
        let render = EqualizerRenderState(replacesOriginal: replacesOriginal, tapChannels: Int(format?.mChannelsPerFrame ?? 2))
        self.render = render
        tappedProcess = process
        silentChecks = 0
        pushEQ()
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, Self.ioBlock(render)), "Couldn't start the equalizer")
        try check(AudioDeviceStart(aggregateID, ioProcID), "Couldn't start the equalizer")
    }

    /// Built outside the main actor: Core Audio calls it on its real-time thread.
    private nonisolated static func ioBlock(_ render: EqualizerRenderState) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in render.render(input: input, output: output) }
    }

    private func stopTap() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        tappedProcess = AudioObjectID(kAudioObjectUnknown)
        render = nil
    }

    private func startTimer() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            MainActor.assumeIsolated { SystemEqualizer.shared.tick() }
        }
    }

    /// Twice a second: pick up the player once music starts, confirm the tap hears real audio,
    /// and stop muting the original immediately if it doesn't.
    private func tick() {
        guard let render else {
            if MusicController.shared.state.isPlaying { reconfigure() }
            return
        }
        let peak = render.peak
        render.peak = 0
        // Muted or at zero volume there's nothing to hear; that silence says nothing about the permission.
        let state = MusicController.shared.state
        guard state.isPlaying, !state.muted, state.volume > 0 else {
            silentChecks = 0
            if status == .verifying { status = .waitingForAudio }
            return
        }
        if status == .waitingForAudio { status = captureVerified ? .running : .verifying }
        if peak > 0.0001 {
            silentChecks = 0
            if status == .verifying || status == .needsPermission { status = .running }
            if !captureVerified {
                captureVerified = true
                reconfigure() // now safe to replace the original with the equalised copy
            }
            return
        }
        // Silence only counts while the song is really moving: a track that's loading, stalled or
        // finished (and the gap before the next) is "playing" too, but quiet for its own reasons.
        guard Date().timeIntervalSince(MusicController.shared.positionDate) < 1.5 else {
            silentChecks = 0
            return
        }
        silentChecks += 1
        if render.replacesOriginal && silentChecks >= 3 {
            // Muted original + silent capture = no sound at all. Unmute right away.
            log.error("Capture went silent while muting; restoring the original audio")
            captureVerified = false
            stopTap()
            reconfigure()
            status = .needsPermission
        } else if silentChecks >= 8 {
            status = .needsPermission
        }
    }

    // MARK: Finding the player's audio process

    /// WebKit plays web media in a "com.apple.WebKit.GPU" helper, one per app. Songtide's is the one
    /// started after Songtide that's producing sound while Songtide plays. If that's ambiguous (for
    /// example Safari also started later and is playing too), wait rather than tap the wrong app.
    private func findPlayerProcess() -> AudioObjectID? {
        let me = getpid()
        let helpers = processObjects().filter { bundleID(of: $0) == "com.apple.WebKit.GPU" && pid(of: $0) > me }
        if tappedProcess != kAudioObjectUnknown, helpers.contains(tappedProcess) { return tappedProcess }
        guard MusicController.shared.state.isPlaying else { return nil }
        let playing = helpers.filter(isRunningOutput)
        if playing.count > 1 { log.notice("\(playing.count) WebKit audio helpers playing; waiting to tell which is Songtide's") }
        return playing.count == 1 ? playing[0] : nil
    }

    /// Re-check when processes start or stop making sound, or the output device changes.
    private func installListeners() {
        guard !listenersInstalled else { return }
        listenersInstalled = true
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultOutputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in
                MainActor.assumeIsolated {
                    let eq = SystemEqualizer.shared
                    // A new output device needs a new aggregate device built on it.
                    if selector == kAudioHardwarePropertyDefaultOutputDevice { eq.stopTap() }
                    eq.reconfigure()
                }
            }
        }
    }

    // MARK: Core Audio helpers

    private func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private func pid(of process: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid)
        return pid
    }

    private func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running)
        return running != 0
    }

    private func bundleID(of process: AudioObjectID) -> String? {
        stringProperty(process, kAudioProcessPropertyBundleID)
    }

    private func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return stringProperty(device, kAudioDevicePropertyDeviceUID)
    }

    private func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        guard tap != kAudioObjectUnknown else { return nil }
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    private func check(_ status: OSStatus, _ message: String) throws {
        guard status == noErr else { throw EqualizerError("\(message) (error \(status)).") }
    }
}

struct EqualizerError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
