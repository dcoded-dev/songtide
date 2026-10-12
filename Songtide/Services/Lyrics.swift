import Foundation

/// Lyrics for the song that's playing, from LRCLIB (lrclib.net, a free, open lyrics database):
/// timed lines when it has them, plain text otherwise. Only asked while lyrics are showing.
@MainActor @Observable
final class Lyrics {
    static let shared = Lyrics()

    struct Line: Equatable {
        let time: TimeInterval
        let text: String
    }

    enum Content: Equatable {
        case none
        case loading
        case synced([Line])
        case plain(String)
        case notFound
    }

    private(set) var content: Content = .none
    /// Whether the floating lyrics window is open (the player bar tints its button while it is).
    var isWindowOpen = false {
        didSet { if !MusicController.isQuitting { UserDefaults.standard.set(isWindowOpen, forKey: Self.windowOpenKey) } }
    }
    /// Whether the lyrics window was open when Songtide last quit (it reopens at launch).
    static let windowOpenKey = "lyricsWindowOpen"
    /// The song the lyrics are for: video ID, title and artist.
    @ObservationIgnored private var trackKey = ""  // video ID, title and artist of the song the lyrics are for
    @ObservationIgnored private var task: Task<Void, Never>?
    /// How many places show lyrics right now (the window, the visualizer overlay).
    @ObservationIgnored private var viewers = 0
    @ObservationIgnored private var cache: [String: Content] = [:]
    @ObservationIgnored private let music = MusicController.shared

    private init() {
        music.observeState { [weak self] state in self?.stateChanged(state) }
    }

    func viewerAppeared() {
        viewers += 1
        stateChanged(music.state)
    }

    func viewerDisappeared() { viewers = max(0, viewers - 1) }

    /// The line being sung at `time`, by index into the synced lines.
    static func currentIndex(in lines: [Line], at time: TimeInterval) -> Int? {
        // Shown a touch early, so the line is up as the singer starts it.
        let t = time + 0.2
        guard let first = lines.first, t >= first.time else { return nil }
        var low = 0, high = lines.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lines[mid].time <= t { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func stateChanged(_ state: PlayerState) {
        // Keyed on the title and artist too: when the song changes, the player can report the new
        // video ID a moment before the new title, and lyrics looked up then belong to the old song.
        let key = "\(state.videoId)|\(state.title)|\(state.artist)"
        guard viewers > 0, state.hasTrack, key != trackKey else {
            if !state.hasTrack { trackKey = ""; content = .none }
            return
        }
        trackKey = key
        Self.debug("looking up \(key)\(cache[key] == nil ? "" : " (cached)")")
        if let cached = cache[key] { content = cached; return }
        content = .loading
        task?.cancel()
        let id = key
        task = Task { [weak self] in
            let found = await Self.fetch(title: state.title, artist: state.artist, album: state.album, duration: state.duration)
            guard let self, !Task.isCancelled, self.trackKey == id else { return }
            self.cache[id] = found
            self.content = found
            if case .synced(let lines) = found { Self.debug("found \(id): \(lines.first(where: { !$0.text.isEmpty })?.text ?? "")") } else { Self.debug("found \(id): \(found)") }
        }
    }

    private static func debug(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["YTM_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[lyrics] \(message)\n".utf8))
        }
        #endif
    }

    // MARK: LRCLIB

    private static let userAgent = "Songtide (https://songtide.dcoded.dev)"

    private static func fetch(title: String, artist: String, album: String, duration: Double) async -> Content {
        let cleanTitle = clean(title), mainArtist = primaryArtist(artist)
        // An exact match first (title, artist and length), then a looser search.
        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [URLQueryItem(name: "track_name", value: cleanTitle), URLQueryItem(name: "artist_name", value: mainArtist)]
        if duration > 0 { exact.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        // The exact match can have only untimed words while other entries for the same song have
        // timed ones; keep it as a fallback and look for timed lyrics of a similar length.
        let exactContent = await request(exact.url!).flatMap { $0 as? [String: Any] }.flatMap(content(from:))
        if case .synced = exactContent { return exactContent! }
        var search = URLComponents(string: "https://lrclib.net/api/search")!
        search.queryItems = [URLQueryItem(name: "track_name", value: cleanTitle), URLQueryItem(name: "artist_name", value: mainArtist)]
        let results = (await request(search.url!) as? [[String: Any]]) ?? []
        let gap = { (result: [String: Any]) in abs(((result["duration"] as? Double) ?? 0) - duration) }
        // Timed lyrics whose length is close enough that the timings line up.
        let synced = results
            .filter { $0["syncedLyrics"] is String && (duration <= 0 || gap($0) <= 4) }
            .sorted { gap($0) < gap($1) }
        for result in synced.prefix(5) {
            if let content = content(from: result), case .synced = content { return content }
        }
        if let exactContent { return exactContent }
        // Otherwise anything usable, timed first, then closest in length.
        let ranked = results.sorted { lhs, rhs in
            let lhsSynced = lhs["syncedLyrics"] is String, rhsSynced = rhs["syncedLyrics"] is String
            if lhsSynced != rhsSynced { return lhsSynced }
            return gap(lhs) < gap(rhs)
        }
        for result in ranked.prefix(5) {
            if let content = content(from: result) { return content }
        }
        return .notFound
    }

    private static func request(_ url: URL) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// What an instrumental (no words to sing) shows as its lyrics.
    static let instrumental = "♪ Instrumental"

    private static func content(from result: [String: Any]) -> Content? {
        if result["instrumental"] as? Bool == true { return .plain(instrumental) }
        if let synced = result["syncedLyrics"] as? String {
            let lines = parse(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = result["plainLyrics"] as? String, !plain.isEmpty { return .plain(plain) }
        return nil
    }

    /// "[01:23.45] words" lines into times and text.
    static func parse(_ lrc: String) -> [Line] {
        let pattern = /\[(\d+):(\d+(?:\.\d+)?)\]/
        var lines: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            let row = String(raw)
            let stamps = row.matches(of: pattern)
            guard let last = stamps.last else { continue }
            let text = row[last.range.upperBound...].trimmingCharacters(in: .whitespaces)
            for stamp in stamps {
                guard let minutes = Double(stamp.1), let seconds = Double(stamp.2) else { continue }
                lines.append(Line(time: minutes * 60 + seconds, text: text))
            }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// "Song (Official Video) [4K]" → "Song"; also drops "feat. …".
    static func clean(_ title: String) -> String {
        var s = title
        s = s.replacing(/\s*[\(\[][^\)\]]*(official|video|audio|lyric|visualizer|remaster|4k|hd|mv)[^\)\]]*[\)\]]/.ignoresCase(), with: "")
        s = s.replacing(/\s*[\(\[]?\s*(feat\.|ft\.|featuring)\s[^\)\]]*[\)\]]?/.ignoresCase(), with: "")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "Artist A & Artist B, C" → "Artist A".
    static func primaryArtist(_ artist: String) -> String {
        let first = artist.split(separator: /\s*(,|&| x | feat\.? )\s*/.ignoresCase()).first.map(String.init) ?? artist
        return first.trimmingCharacters(in: .whitespaces)
    }
}
