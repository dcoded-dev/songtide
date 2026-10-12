import AppKit

/// Snapshot of the web player, decoded from bridge.js `state` messages.
struct PlayerState: Codable, Equatable {
    enum LikeStatus: String, Codable { case like = "LIKE", dislike = "DISLIKE", indifferent = "INDIFFERENT" }
    enum RepeatMode: String, Codable { case off, all, one }

    var title = ""
    var artist = ""
    var album = ""
    var artwork = ""
    var videoId = ""
    var isPlaying = false
    var time: Double = 0
    var duration: Double = 0
    var volume: Double = 100
    var muted = false
    var like: LikeStatus = .indifferent
    var `repeat`: RepeatMode = .off
    var shuffle = false
    var playerPageOpen = false

    var hasTrack: Bool { !title.isEmpty }
    var artworkURL: URL? { URL(string: artwork) }
    var subtitle: String { [artist, album].filter { !$0.isEmpty }.joined(separator: " • ") }
}

struct AccountInfo: Codable, Equatable {
    var signedIn = false
    var name = ""
    var handle = ""
    var avatar = ""
    var avatarURL: URL? { URL(string: avatar) }
}

/// Persists the signed-in account between launches (UserDefaults; the avatar is ~10 KB).
enum AccountCache {
    private static let accountKey = "cachedAccount"
    private static let avatarKey = "cachedAvatar"

    // A guest session (screenshots) neither shows nor overwrites the real account.
    private static var guest: Bool { MusicController.isGuestSession }

    static func load() -> AccountInfo {
        if guest { return AccountInfo() }
        return UserDefaults.standard.data(forKey: accountKey).flatMap { try? JSONDecoder().decode(AccountInfo.self, from: $0) } ?? AccountInfo()
    }

    static func save(_ account: AccountInfo) {
        guard !guest else { return }
        UserDefaults.standard.set(try? JSONEncoder().encode(account), forKey: accountKey)
    }

    static func loadAvatar() -> NSImage? {
        if guest { return nil }
        return UserDefaults.standard.data(forKey: avatarKey).flatMap(NSImage.init(data:))
    }

    static func saveAvatar(_ data: Data?) {
        guard !guest else { return }
        UserDefaults.standard.set(data, forKey: avatarKey)
    }
}

struct PlaylistEntry: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var pinned = false
}

/// A channel (brand account) the signed-in Google account can switch to.
struct ChannelAccount: Codable, Equatable, Identifiable {
    var index: Int
    var name: String
    var byline: String
    var handle: String
    var photo: String
    var selected: Bool
    var email: String

    var id: String { "\(index)-\(name)" }
}

/// A search suggestion mirrored from YouTube Music's search box.
struct SearchSuggestion: Codable, Equatable, Identifiable {
    enum Kind: String, Codable { case text, result }
    var index: Int
    var kind: Kind
    var title: String
    var subtitle: String
    var thumbnail: String

    var id: String { "\(kind.rawValue)-\(index)-\(title)" }
    var thumbnailURL: URL? { URL(string: thumbnail) }
}

struct SearchSuggestions: Codable, Equatable {
    var query: String
    var items: [SearchSuggestion]
}

struct LocationInfo: Codable, Equatable {
    var path: String
    var title: String?
}

enum SidebarItem: Hashable, Identifiable {
    case home, explore, library, history
    case playlists, songs, albums, artists, podcasts, profiles
    case playlist(PlaylistEntry)

    var id: String { browseId }

    /// Everything the Library section can show, in order; Edit lets the user pick which.
    static let libraryItems: [SidebarItem] = [.playlists, .songs, .albums, .artists, .podcasts, .profiles, .history]
    static let defaultHiddenLibraryItems: Set<String> = [SidebarItem.podcasts.browseId, SidebarItem.profiles.browseId]

    var browseId: String {
        switch self {
        case .home: "FEmusic_home"
        case .explore: "FEmusic_explore"
        case .library: "FEmusic_library_landing"
        case .history: "FEmusic_history"
        case .playlists: "FEmusic_liked_playlists"
        case .songs: "FEmusic_liked_videos"
        case .albums: "FEmusic_liked_albums"
        case .artists: "FEmusic_library_corpus_track_artists"
        case .podcasts: "FEmusic_library_non_music_audio_list"
        case .profiles: "FEmusic_library_user_profile_channels_list"
        case .playlist(let p): p.id
        }
    }

    var title: String {
        switch self {
        case .home: "Home"
        case .explore: "Explore"
        case .library: "Library"
        case .history: "History"
        case .playlists: "Playlists"
        case .songs: "Songs"
        case .albums: "Albums"
        case .artists: "Artists"
        case .podcasts: "Podcasts"
        case .profiles: "Profiles"
        case .playlist(let p): p.title
        }
    }

    var symbol: String {
        switch self {
        case .home: "house"
        case .explore: "safari"
        case .library: "books.vertical"
        case .history: "clock"
        case .playlists: "music.note.list"
        case .songs: "music.note"
        case .albums: "square.stack"
        case .artists: "music.microphone"
        case .podcasts: "antenna.radiowaves.left.and.right"
        case .profiles: "person.2"
        case .playlist(let p): p.id == "VLLM" ? "hand.thumbsup" : "music.note.list"
        }
    }

    /// Matches a YouTube Music path (pathname + search) to the sidebar entry it represents.
    static func matching(path: String, playlists: [PlaylistEntry]) -> SidebarItem? {
        let components = URLComponents(string: "https://music.youtube.com" + path)
        switch components?.path ?? path {
        case "/", "": return .home
        case "/explore": return .explore
        case "/library": return .library
        case "/history": return .history
        case "/library/playlists": return .playlists
        case "/library/songs": return .songs
        case "/library/albums": return .albums
        case "/library/artists": return .artists
        case "/library/podcasts": return .podcasts
        case "/library/profiles": return .profiles
        case "/playlist":
            guard let list = components?.queryItems?.first(where: { $0.name == "list" })?.value else { return nil }
            return playlists.first { $0.id == "VL" + list }.map(SidebarItem.playlist)
        default: return nil
        }
    }
}
