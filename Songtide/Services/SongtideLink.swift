import Foundation

/// Links Songtide opens: its own `songtide://` links (from scripts, launchers and other apps) and
/// YouTube or YouTube Music web links, which it plays in YouTube Music.
///
///     songtide://play?v=VIDEO_ID        (optionally &list=PLAYLIST_ID)
///     songtide://playlist?list=PLAYLIST_ID
///     songtide://search?q=daft+punk
enum SongtideLink {
    static let scheme = "songtide"

    enum Destination: Equatable {
        case page(URL)
        case search(String)
    }

    static func destination(for url: URL) -> Destination? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        func value(_ name: String) -> String? {
            parts.queryItems?.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        let host = (parts.host ?? "").lowercased()
        switch parts.scheme?.lowercased() {
        case scheme:
            switch host {
            case "play": return page("watch", ["v": value("v"), "list": value("list")], requiring: "v")
            case "playlist": return page("playlist", ["list": value("list")], requiring: "list")
            // Typed links often use + for spaces, which URLs only decode in forms.
            case "search": return value("q").map { .search($0.replacingOccurrences(of: "+", with: " ")) }
            default: return nil
            }
        case "https", "http":
            if host == "music.youtube.com" {
                var secure = parts
                secure.scheme = "https"
                return secure.url.map(Destination.page)
            }
            if host == "youtu.be" {
                let id = parts.path.split(separator: "/").first.map(String.init)
                return page("watch", ["v": id, "list": value("list")], requiring: "v")
            }
            guard ["youtube.com", "www.youtube.com", "m.youtube.com"].contains(host) else { return nil }
            switch parts.path {
            case "/watch": return page("watch", ["v": value("v"), "list": value("list")], requiring: "v")
            case "/playlist": return page("playlist", ["list": value("list")], requiring: "list")
            default: return nil
            }
        default:
            return nil
        }
    }

    /// The link to share for a song.
    static func songURL(videoId: String) -> URL? {
        guard !videoId.isEmpty else { return nil }
        guard case .page(let url)? = page("watch", ["v": videoId], requiring: "v") else { return nil }
        return url
    }

    private static func page(_ path: String, _ query: [String: String?], requiring key: String) -> Destination? {
        guard let required = query[key] ?? nil, !required.isEmpty else { return nil }
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "music.youtube.com"
        parts.path = "/" + path
        // The required item first, so links read the usual way (watch?v=…&list=…).
        parts.queryItems = query.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
            .sorted { ($0.name == key ? 0 : 1, $0.name) < ($1.name == key ? 0 : 1, $1.name) }
        return parts.url.map(Destination.page)
    }
}
