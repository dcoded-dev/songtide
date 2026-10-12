import AppKit
import UserNotifications

/// A macOS notification when a new song starts (Settings › Playback; off by default). Not while
/// Songtide is in front: the song is right there.
@MainActor
final class TrackNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = TrackNotifier()
    static let enabledKey = "notifyOnTrackChange"

    private var lastVideoId = ""
    private let center = UNUserNotificationCenter.current()

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    func start() {
        center.delegate = self
        MusicController.shared.observeState { [weak self] state in self?.stateChanged(state) }
    }

    /// Turning it on asks macOS for permission (once); returns whether it's allowed.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert])) ?? false
    }

    private func stateChanged(_ state: PlayerState) {
        guard state.hasTrack, state.videoId != lastVideoId else { return }
        let first = lastVideoId.isEmpty
        lastVideoId = state.videoId
        // Not for whatever was loaded at launch, nor while Songtide is in front.
        guard !first, Self.isEnabled, !NSApp.isActive else { return }
        Task { await post(state) }
    }

    private func post(_ state: PlayerState) async {
        let content = UNMutableNotificationContent()
        content.title = state.title
        content.body = state.subtitle
        if let url = state.artworkURL, let attachment = await artwork(from: url) {
            content.attachments = [attachment]
        }
        // One at a time: each new song replaces the last banner.
        center.removeAllDeliveredNotifications()
        do {
            try await center.add(UNNotificationRequest(identifier: "now-playing", content: content, trigger: nil))
            Self.debug("posted: \(state.title) (artwork: \(!content.attachments.isEmpty))")
        } catch {
            Self.debug("failed: \(error.localizedDescription)")
        }
    }

    private static func debug(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["YTM_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[notify] \(message)\n".utf8))
        }
        #endif
    }

    /// Notification pictures must be local files: save the artwork to a temporary file first.
    private func artwork(from url: URL) async -> UNNotificationAttachment? {
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "songtide-artwork-\(UUID().uuidString).jpg")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "artwork", url: file)
    }

    // Clicking the notification brings Songtide forward.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { StatusBarController.shared.openMainWindow?(); NSApp.activate() }
    }
}
