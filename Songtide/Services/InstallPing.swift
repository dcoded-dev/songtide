import Foundation

/// The first time Songtide opens on a Mac it tells songtide.dcoded.dev, once, so the site can count
/// installs. The request carries only the app's version (in its user agent): no identifier, nothing
/// about the Mac or the person, and the site keeps just a daily total.
@MainActor
enum InstallPing {
    private static let sentKey = "installPingSent"
    private static let url = URL(string: "https://songtide.dcoded.dev/installed")!

    /// `existingUser`: Songtide ran here before this feature (the updater has checked before), so
    /// this launch is an update, not a new install.
    static func sendIfFirstLaunch(existingUser: Bool) {
        #if DEBUG
        return
        #else
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: sentKey), !MusicController.isGuestSession else { return }
        if existingUser { defaults.set(true, forKey: sentKey); return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("Songtide/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        Task {
            // Marked as sent only once it got through, so a first launch while offline counts later.
            guard let (_, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 204 else { return }
            defaults.set(true, forKey: sentKey)
        }
        #endif
    }
}
