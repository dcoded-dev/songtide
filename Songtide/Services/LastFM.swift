import AppKit
import CryptoKit
import Foundation
import Security

/// Last.fm scrobbling: "now playing" when a song starts, and a scrobble once half of it (or four
/// minutes) has played, per Last.fm's rules. Connected in Settings › Integrations through Last.fm's
/// own approval page; only the session key is kept (in the Keychain).
@MainActor @Observable
final class LastFM {
    static let shared = LastFM()

    // Songtide's Last.fm API account (identifies the app, not a person). Set at build time from
    // Config/Secrets.xcconfig, which isn't in the repo; a build without it has no Last.fm.
    private static let apiKey = Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String ?? ""
    private static let secret = Bundle.main.object(forInfoDictionaryKey: "LastFMSecret") as? String ?? ""
    static var isConfigured: Bool { !apiKey.isEmpty && !secret.isEmpty }

    private(set) var username: String?
    private(set) var isConnecting = false
    var isConnected: Bool { username != nil }

    @ObservationIgnored private var sessionKey: String?
    @ObservationIgnored private var pendingToken: String?
    // The song being listened to, and how much of it has actually played.
    @ObservationIgnored private var current: (videoId: String, title: String, artist: String, album: String, duration: Double, started: Date)?
    @ObservationIgnored private var listened: TimeInterval = 0
    @ObservationIgnored private var lastTick: Date?
    @ObservationIgnored private var scrobbled = false
    @ObservationIgnored private var timer: Timer?

    private init() {
        if let stored = Keychain.read() { sessionKey = stored.key; username = stored.user }
    }

    func start() {
        MusicController.shared.observeState { [weak self] state in self?.stateChanged(state) }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    // MARK: Connecting

    /// Opens Last.fm's approval page; finishConnecting() completes it once approved.
    func connect() async {
        guard Self.isConfigured else { return }
        isConnecting = true
        guard let response = await call("auth.getToken", [:], signed: true), let token = response["token"] as? String else {
            isConnecting = false
            return
        }
        pendingToken = token
        NSWorkspace.shared.open(URL(string: "https://www.last.fm/api/auth/?api_key=\(Self.apiKey)&token=\(token)")!)
        // Approval happens in the browser; check back for the session for five minutes.
        for _ in 0..<150 {
            try? await Task.sleep(for: .seconds(2))
            guard isConnecting, pendingToken == token else { return }
            if let session = await call("auth.getSession", ["token": token], signed: true)?["session"] as? [String: Any],
               let key = session["key"] as? String, let name = session["name"] as? String {
                sessionKey = key
                username = name
                Keychain.save(key: key, user: name)
                break
            }
        }
        isConnecting = false
        pendingToken = nil
    }

    func cancelConnecting() { isConnecting = false; pendingToken = nil }

    func disconnect() {
        sessionKey = nil
        username = nil
        Keychain.delete()
    }

    // MARK: Scrobbling

    private func stateChanged(_ state: PlayerState) {
        guard isConnected else { return }
        if state.hasTrack, state.videoId != current?.videoId {
            current = (state.videoId, state.title, state.artist, state.album, state.duration, Date())
            listened = 0
            scrobbled = false
            lastTick = state.isPlaying ? Date() : nil
            if state.isPlaying { Task { await updateNowPlaying() } }
        } else if let tick = lastTick, !state.isPlaying {
            listened += Date().timeIntervalSince(tick) // paused: count up to here
            lastTick = nil
        } else if lastTick == nil, state.isPlaying {
            lastTick = Date()
        }
        if current?.duration == 0, state.duration > 0 { current?.duration = state.duration }
    }

    private func tick() {
        guard isConnected, let song = current, !scrobbled, let tick = lastTick else { return }
        let now = Date()
        listened += now.timeIntervalSince(tick)
        lastTick = now
        // Last.fm: tracks over 30 seconds, once half has played or four minutes, whichever is first.
        guard song.duration > 30, listened >= min(song.duration / 2, 240) else { return }
        scrobbled = true
        Task { await scrobble(song) }
    }

    private func updateNowPlaying() async {
        guard let song = current else { return }
        var params = ["track": song.title, "artist": song.artist]
        if !song.album.isEmpty { params["album"] = song.album }
        if song.duration > 0 { params["duration"] = String(Int(song.duration)) }
        _ = await call("track.updateNowPlaying", params, signed: true, session: true)
    }

    private func scrobble(_ song: (videoId: String, title: String, artist: String, album: String, duration: Double, started: Date)) async {
        var params = ["track": song.title, "artist": song.artist, "timestamp": String(Int(song.started.timeIntervalSince1970))]
        if !song.album.isEmpty { params["album"] = song.album }
        if song.duration > 0 { params["duration"] = String(Int(song.duration)) }
        _ = await call("track.scrobble", params, signed: true, session: true, post: true)
    }

    // MARK: API

    private func call(_ method: String, _ params: [String: String], signed: Bool, session: Bool = false, post: Bool = false) async -> [String: Any]? {
        var all = params
        all["method"] = method
        all["api_key"] = Self.apiKey
        if session {
            guard let sessionKey else { return nil }
            all["sk"] = sessionKey
        }
        if signed {
            let base = all.keys.sorted().map { $0 + all[$0]! }.joined() + Self.secret
            all["api_sig"] = Insecure.MD5.hash(data: Data(base.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        all["format"] = "json"
        // Every value fully escaped ("&", "=" and "+" are common in song and artist names).
        let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let form = all.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "")" }.joined(separator: "&")
        let endpoint = "https://ws.audioscrobbler.com/2.0/"
        var request: URLRequest
        if post {
            request = URLRequest(url: URL(string: endpoint)!)
            request.httpMethod = "POST"
            request.httpBody = Data(form.utf8)
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        } else {
            request = URLRequest(url: URL(string: endpoint + "?" + form)!)
        }
        request.setValue("Songtide (https://songtide.dcoded.dev)", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], json["error"] == nil else { return nil }
        return json
    }

    /// The session key in the Keychain (it's a credential, so not in plain settings).
    private enum Keychain {
        static let service = "dev.dcoded.songtide.lastfm"

        static func save(key: String, user: String) {
            delete()
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                       kSecAttrAccount as String: user, kSecValueData as String: Data(key.utf8)]
            SecItemAdd(item as CFDictionary, nil)
        }

        static func read() -> (key: String, user: String)? {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecReturnData as String: true, kSecReturnAttributes as String: true]
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let item = result as? [String: Any],
                  let data = item[kSecValueData as String] as? Data, let user = item[kSecAttrAccount as String] as? String else { return nil }
            return (String(decoding: data, as: UTF8.self), user)
        }

        static func delete() {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
        }
    }
}
