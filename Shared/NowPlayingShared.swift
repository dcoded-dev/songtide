import Foundation

/// What's playing, shared between Songtide and its widget through their app group container.
/// Songtide writes it on every change; the widget reads it.
struct NowPlayingSnapshot: Codable, Equatable {
    var title = ""
    var artist = ""
    var isPlaying = false
    var hasArtwork = false
    var updated = Date()

    var hasTrack: Bool { !title.isEmpty }
}

enum SharedContainer {
    /// Team-prefixed, so it needs no provisioning profile for a Developer ID app.
    static let groupID = "YQ9V6SFRL4.dev.dcoded.songtide"

    static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID) }
    static var snapshotURL: URL? { url?.appending(path: "now-playing.json") }
    static var artworkURL: URL? { url?.appending(path: "artwork.jpg") }

    static func readSnapshot() -> NowPlayingSnapshot {
        guard let file = snapshotURL, let data = try? Data(contentsOf: file),
              let snapshot = try? JSONDecoder().decode(NowPlayingSnapshot.self, from: data) else { return NowPlayingSnapshot() }
        return snapshot
    }
}

/// Commands from the widget (and Control Center) to Songtide, as Darwin notifications: they work
/// between sandboxed processes and need no payload.
enum WidgetCommand: String, CaseIterable {
    case playPause, next, previous

    var notificationName: String { "dev.dcoded.songtide.command.\(rawValue)" }

    func send() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(notificationName as CFString), nil, nil, true)
    }
}
