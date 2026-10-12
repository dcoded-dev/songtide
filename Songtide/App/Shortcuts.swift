import AppIntents

// Actions for the Shortcuts app (and so Siri, Spotlight and automations): playback, liking, the
// sleep timer, Liked Music, and what's playing.

struct PlayPauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Play or Pause"
    static let description = IntentDescription("Plays or pauses Songtide.")
    @MainActor func perform() async throws -> some IntentResult {
        MusicController.shared.playPause()
        return .result()
    }
}

struct PlayIntent: AppIntent {
    static let title: LocalizedStringResource = "Play"
    @MainActor func perform() async throws -> some IntentResult {
        MusicController.shared.play()
        return .result()
    }
}

struct PauseIntent: AppIntent {
    static let title: LocalizedStringResource = "Pause"
    @MainActor func perform() async throws -> some IntentResult {
        MusicController.shared.pause()
        return .result()
    }
}

struct NextTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Next Song"
    @MainActor func perform() async throws -> some IntentResult {
        MusicController.shared.next()
        return .result()
    }
}

struct PreviousTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Previous Song"
    @MainActor func perform() async throws -> some IntentResult {
        MusicController.shared.previous()
        return .result()
    }
}

struct LikeTrackIntent: AppIntent {
    static let title: LocalizedStringResource = "Like Current Song"
    static let description = IntentDescription("Likes the song that's playing in Songtide.")
    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let music = MusicController.shared
        guard music.state.hasTrack else { return .result(dialog: "Nothing's playing.") }
        if music.state.like != .like { music.like() }
        return .result(dialog: "Liked \(music.state.title).")
    }
}

struct PlayLikedMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Liked Music"
    static let description = IntentDescription("Plays your Liked Music playlist in Songtide.")
    @MainActor func perform() async throws -> some IntentResult {
        MusicController.shared.playPlaylist("LM")
        return .result()
    }
}

struct CurrentSongIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Current Song"
    static let description = IntentDescription("The song playing in Songtide, as \"Title — Artist\".")
    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let state = MusicController.shared.state
        guard state.hasTrack else { return .result(value: "", dialog: "Nothing's playing.") }
        let text = state.artist.isEmpty ? state.title : "\(state.title) — \(state.artist)"
        return .result(value: text, dialog: "\(text)")
    }
}

struct SleepTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Set Sleep Timer"
    static let description = IntentDescription("Stops Songtide after a number of minutes (0 turns the timer off).")
    @Parameter(title: "Minutes", default: 30, inclusiveRange: (0, 600)) var minutes: Int
    static var parameterSummary: some ParameterSummary { Summary("Stop playing after \(\.$minutes) minutes") }
    @MainActor func perform() async throws -> some IntentResult {
        if minutes == 0 { SleepTimer.shared.cancel() } else { SleepTimer.shared.set(minutes: minutes) }
        return .result()
    }
}

struct SongtideShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PlayPauseIntent(), phrases: ["Pause \(.applicationName)", "Play \(.applicationName)"],
                    shortTitle: "Play or Pause", systemImageName: "playpause.fill")
        AppShortcut(intent: NextTrackIntent(), phrases: ["Next song in \(.applicationName)", "Skip this song in \(.applicationName)"],
                    shortTitle: "Next Song", systemImageName: "forward.fill")
        AppShortcut(intent: LikeTrackIntent(), phrases: ["Like this song in \(.applicationName)"],
                    shortTitle: "Like Song", systemImageName: "hand.thumbsup.fill")
        AppShortcut(intent: PlayLikedMusicIntent(), phrases: ["Play my liked music in \(.applicationName)"],
                    shortTitle: "Liked Music", systemImageName: "heart.fill")
        AppShortcut(intent: CurrentSongIntent(), phrases: ["What's playing in \(.applicationName)"],
                    shortTitle: "Current Song", systemImageName: "music.note")
        AppShortcut(intent: SleepTimerIntent(), phrases: ["Set a sleep timer in \(.applicationName)"],
                    shortTitle: "Sleep Timer", systemImageName: "moon.zzz.fill")
    }
}
