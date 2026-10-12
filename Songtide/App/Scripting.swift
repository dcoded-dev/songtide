import AppKit

// AppleScript support (the terminology is in Resources/Songtide.sdef): playback commands, and
// what's playing as properties of the application.

/// Every Songtide command; which one is told by its name in the scripting definition.
@objc(SongtideScriptCommand)
final class SongtideScriptCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let name = commandDescription.commandName
        let text = directParameter as? String
        // Apple events are handled on the main thread.
        let failure: String? = MainActor.assumeIsolated {
            let music = MusicController.shared
            switch name {
            case "playpause": music.playPause()
            case "play": music.play()
            case "pause": music.pause()
            case "next track": music.next()
            case "previous track": music.previous()
            case "like": music.like()
            case "search":
                guard let text, !text.isEmpty else { return "Say what to search for." }
                music.search(text)
            case "open link":
                guard let text, let url = URL(string: text), music.open(link: url) else {
                    return "That isn't a YouTube Music, YouTube or songtide:// link."
                }
            default: return "Songtide doesn't know that command."
            }
            return nil
        }
        if let failure {
            scriptErrorNumber = errAEEventFailed
            scriptErrorString = failure
        }
        return nil
    }
}

/// What's playing, as properties of the application object.
extension NSApplication {
    @objc var scriptPlaying: Bool { MusicController.shared.state.isPlaying }
    @objc var scriptTrackName: String { MusicController.shared.state.title }
    @objc var scriptTrackArtist: String { MusicController.shared.state.artist }
    @objc var scriptTrackAlbum: String { MusicController.shared.state.album }
    @objc var scriptTrackLink: String { MusicController.shared.songLink?.absoluteString ?? "" }
    @objc var scriptTrackDuration: Double { MusicController.shared.state.duration }

    @objc var scriptPlayerPosition: Double {
        get { MusicController.shared.livePosition }
        set { MusicController.shared.seek(to: max(0, newValue)) }
    }

    @objc var scriptSoundVolume: Int {
        get { Int(MusicController.shared.state.volume.rounded()) }
        set { MusicController.shared.setVolume(Double(min(max(newValue, 0), 100))) }
    }
}
