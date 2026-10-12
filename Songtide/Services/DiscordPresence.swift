import Foundation

/// Shows what's playing on your Discord profile ("Listening to Songtide": song, artist, artwork,
/// time left), through the Discord app's local connection on this Mac. Settings › Integrations;
/// off by default. Cleared when paused or when Songtide quits.
@MainActor @Observable
final class DiscordPresence {
    static let shared = DiscordPresence()
    static let enabledKey = "discordPresence"
    /// Songtide's Discord application (public; it names the app in your status).
    static let clientID = "1556712088511189022"
    static var isConfigured: Bool { !clientID.hasPrefix("DISCORD_") }

    private(set) var isConnected = false
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            newValue ? update(MusicController.shared.state) : clear()
        }
    }

    @ObservationIgnored private let ipc = DiscordIPC()
    @ObservationIgnored private var lastSent = ""
    @ObservationIgnored private var retry: Timer?

    func start() {
        MusicController.shared.observeState { [weak self] state in self?.update(state) }
        // Discord may be opened after Songtide: try again now and then.
        retry = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isEnabled, !self.ipc.isOpen else { return }
                self.lastSent = ""
                self.update(MusicController.shared.state)
            }
        }
    }

    func clear() {
        guard ipc.isOpen else { return }
        ipc.setActivity(nil)
        lastSent = ""
    }

    private func update(_ state: PlayerState) {
        guard isEnabled, Self.isConfigured else { return }
        guard state.hasTrack, state.isPlaying else { clear(); return }
        let position = MusicController.shared.position
        let key = "\(state.videoId)|\(Int(position / 5))" // resend after a seek, not every tick
        guard key != lastSent else { return }
        if !ipc.isOpen {
            isConnected = ipc.open(clientID: Self.clientID)
            Self.debug("connect: \(isConnected ? "ok" : "failed (\(ipc.lastError))")")
            guard isConnected else { return }
        }
        lastSent = key
        let now = Date().timeIntervalSince1970
        let start = Int((now - position) * 1000)
        var activity: [String: Any] = [
            "type": 2, // "Listening to"
            "details": String(state.title.prefix(128)),
            "state": String((state.artist.isEmpty ? "YouTube Music" : state.artist).prefix(128)),
            "timestamps": state.duration > 0 ? ["start": start, "end": start + Int(state.duration * 1000)] : ["start": start],
            "buttons": [
                ["label": "Listen on YouTube Music", "url": "https://music.youtube.com/watch?v=\(state.videoId)"],
                ["label": "Get Songtide for Mac", "url": "https://songtide.dcoded.dev"],
            ],
        ]
        var assets: [String: Any] = [:]
        if !state.artwork.isEmpty { assets["large_image"] = state.artwork }
        if !state.album.isEmpty { assets["large_text"] = String(state.album.prefix(128)) }
        if !assets.isEmpty { activity["assets"] = assets }
        isConnected = ipc.setActivity(activity)
        Self.debug("set activity \(state.title): \(isConnected ? "ok" : "failed (\(ipc.lastError))")")
    }

    private static func debug(_ message: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["YTM_DEBUG"] != nil {
            FileHandle.standardError.write(Data("[discord] \(message)\n".utf8))
        }
        #endif
    }
}

/// Discord's local IPC: a Unix socket (discord-ipc-0…9 in the user's temporary folder), frames of
/// opcode + length + JSON.
final class DiscordIPC: @unchecked Sendable {
    private var socket: Int32 = -1
    var isOpen: Bool { socket >= 0 }
    /// Why the last attempt failed (for debugging).
    private(set) var lastError = ""


    func open(clientID: String) -> Bool {
        close()
        lastError = "no socket in \(Self.socketDirectories)"
        for directory in Self.socketDirectories {
            for index in 0..<10 {
                let path = directory + "discord-ipc-\(index)"
                guard FileManager.default.fileExists(atPath: path) else { continue }
                let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                var address = sockaddr_un()
                address.sun_family = sa_family_t(AF_UNIX)
                withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                    _ = path.withCString { strncpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), $0, buffer.count - 1) }
                }
                let connected = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                }
                guard connected == 0 else { lastError = "connect \(path): \(String(cString: strerror(errno)))"; Darwin.close(fd); continue }
                var noSigPipe: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                socket = fd
                // Handshake; Discord answers with READY (or an error for an unknown app).
                guard send(op: 0, ["v": 1, "client_id": clientID]), let reply = receive(), reply["evt"] as? String == "READY" else {
                    lastError = "handshake refused"
                    close()
                    return false
                }
                return true
            }
        }
        return false
    }

    @discardableResult
    func setActivity(_ activity: [String: Any]?) -> Bool {
        let args: [String: Any] = ["pid": Int(getpid()), "activity": activity ?? NSNull()]
        let ok = send(op: 1, ["cmd": "SET_ACTIVITY", "args": args, "nonce": UUID().uuidString]) && receive() != nil
        if !ok { close() }
        return ok
    }

    func close() {
        if socket >= 0 { Darwin.close(socket) }
        socket = -1
    }

    /// Discord keeps its sockets in the user's real temporary folder, /private/var/folders/xx/…/T/.
    /// Inside the sandbox the usual ways of asking for it give this app's own folder instead, so
    /// look through /private/var/folders for the one that belongs to this user.
    private static var socketDirectories: [String] {
        var dirs: [String] = []
        let fm = FileManager.default
        let root = "/private/var/folders/"
        for first in (try? fm.contentsOfDirectory(atPath: root)) ?? [] {
            for second in (try? fm.contentsOfDirectory(atPath: root + first)) ?? [] {
                let temp = root + first + "/" + second + "/T/"
                if let owner = (try? fm.attributesOfItem(atPath: temp))?[.ownerAccountID] as? NSNumber, owner.uint32Value == getuid() {
                    dirs.append(temp)
                }
            }
        }
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] { dirs.append(tmp.hasSuffix("/") ? tmp : tmp + "/") }
        return dirs
    }

    private func send(op: UInt32, _ payload: [String: Any]) -> Bool {
        guard socket >= 0, let json = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        var frame = Data()
        withUnsafeBytes(of: op.littleEndian) { frame.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt32(json.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(json)
        return frame.withUnsafeBytes { Darwin.write(socket, $0.baseAddress, frame.count) } == frame.count
    }

    private func receive() -> [String: Any]? {
        guard socket >= 0 else { return nil }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var header = [UInt8](repeating: 0, count: 8)
        guard read(socket, &header, 8) == 8 else { return nil }
        let length = Int(header[4]) | Int(header[5]) << 8 | Int(header[6]) << 16 | Int(header[7]) << 24
        guard length > 0, length < 1 << 20 else { return nil }
        var body = [UInt8](repeating: 0, count: length)
        var got = 0
        while got < length {
            let n = body.withUnsafeMutableBytes { read(socket, $0.baseAddress! + got, length - got) }
            guard n > 0 else { return nil }
            got += n
        }
        return try? JSONSerialization.jsonObject(with: Data(body)) as? [String: Any]
    }
}
