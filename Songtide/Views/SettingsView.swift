import SwiftUI

enum AppInfo {
    static let developerURL = URL(string: "https://dcoded.dev")!
    static let websiteURL = URL(string: "https://songtide.dcoded.dev")!

    /// "1.0.2" (the build number only matters to the updater)
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    }

    /// Credits for the standard About panel: "Developed by DCODED" plus a dcoded.dev link.
    static var aboutCredits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: String(localized: "Developed by DCODED") + "\n", attributes: base)
        var link = base
        link[.link] = developerURL
        credits.append(NSAttributedString(string: "dcoded.dev", attributes: link))
        return credits
    }
}

enum Preferences {
    static let appPresence = "appPresence"
    static let keepPlayingWhenClosed = "keepPlayingWhenClosed"
    static let preferSongOverVideo = "preferSongOverVideo"
    static let scrollLongTitles = "scrollLongTitles"
    static let statusItemClickAction = "statusItemClickAction"
    // Replaced by `appPresence`; read once to carry over earlier choices.
    private static let legacyShowMenuBarPlayer = "showMenuBarPlayer"
    private static let legacyHideDockWhenClosed = "hideDockWhenClosed"

    /// Where Songtide shows itself. There's deliberately no "neither" option, so the app can
    /// never end up running with no Dock icon and no menu bar icon.
    enum Presence: String, CaseIterable {
        case menuBarAndDockWhenOpen, dockAndMenuBar, dockOnly
    }

    static var presence: Presence {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: appPresence), let value = Presence(rawValue: raw) { return value }
        // Carry over the earlier separate switches, if they were ever set.
        if defaults.object(forKey: legacyShowMenuBarPlayer) != nil || defaults.object(forKey: legacyHideDockWhenClosed) != nil {
            if !defaults.bool(forKey: legacyShowMenuBarPlayer, default: true) { return .dockOnly }
            return defaults.bool(forKey: legacyHideDockWhenClosed, default: true) ? .menuBarAndDockWhenOpen : .dockAndMenuBar
        }
        return .menuBarAndDockWhenOpen
    }

    /// Every setting's key (including the sidebar's), for Reset to Defaults. Account data isn't a
    /// setting and is left alone.
    private static let allKeys = [
        appPresence, keepPlayingWhenClosed, preferSongOverVideo, statusItemClickAction, scrollLongTitles, Accent.key,
        legacyShowMenuBarPlayer, legacyHideDockWhenClosed,
        "sidebarVisible", "sidebarPlaylistsExpanded", "sidebarHiddenLibraryItems", MusicController.lastPathKey,
        Equalizer.enabledKey, Equalizer.gainsKey, VisualizerModel.autoChangeKey, "visualizerInWindow", "visualizerFills",
        "visualizerSplitPageWidth", "visualizerSplitHeightFraction", "visualizerSplitSwapped", "visualizerPreset", "NSWindow Frame VisualizerWindow", "notifyOnTrackChange", "discordPresence",
    ]

    static func resetAll() {
        allKeys.forEach(UserDefaults.standard.removeObject(forKey:))
        try? LoginItem.setEnabled(false)
    }

    static var showsMenuBarIcon: Bool { presence != .dockOnly }
    static var hidesDockWhenClosed: Bool { presence == .menuBarAndDockWhenOpen }

    /// What a left-click on the menu bar icon does.
    enum StatusItemClick: String, CaseIterable {
        case miniPlayer, openApp
    }
}

struct SettingsView: View {
    @Environment(MusicController.self) private var music
    @State private var openAtLogin = LoginItem.isEnabled
    @State private var loginItemNeedsApproval = LoginItem.needsApproval
    @State private var loginItemError: String?
    @State private var equalizerResetID = UUID()
    @AppStorage(SettingsTab.key) private var selectedTab = SettingsTab.general.rawValue
    @State private var confirmingReset = false
    @State private var updatesAutomatically = Updater.shared.updatesAutomatically
    @AppStorage(TrackNotifier.enabledKey) private var notifyOnTrackChange = false

    /// Turning notifications on asks macOS first; it stays off if they aren't allowed.
    private func setNotifyOnTrackChange(_ on: Bool) {
        guard on else { notifyOnTrackChange = false; return }
        Task {
            let allowed = await TrackNotifier.shared.requestPermission()
            notifyOnTrackChange = allowed
            if !allowed, let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                NSWorkspace.shared.open(url)
            }
        }
    }
    @AppStorage(Preferences.keepPlayingWhenClosed) private var keepPlayingWhenClosed = true
    @AppStorage(Preferences.preferSongOverVideo) private var preferSongOverVideo = true
    @AppStorage(Preferences.appPresence) private var presence = Preferences.presence.rawValue
    @AppStorage(Preferences.statusItemClickAction) private var statusItemClick = Preferences.StatusItemClick.miniPlayer.rawValue
    @AppStorage(Preferences.scrollLongTitles) private var scrollLongTitles = true

    var body: some View {
        // Our own tab bar rather than the window toolbar's, so the chosen tab takes Songtide's accent
        // color (the toolbar's always uses the Mac's).
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Open at login", isOn: Binding(get: { openAtLogin }, set: setOpenAtLogin))
                    if loginItemNeedsApproval {
                        HStack {
                            Text("Allow Songtide in Login Items to finish turning this on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Open Login Items") { LoginItem.openSystemSettings() }
                        }
                    }
                    if let loginItemError {
                        Text(loginItemError).font(.caption).foregroundStyle(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("Show Songtide in", selection: $presence) {
                            Text("Menu bar, plus Dock while open").tag(Preferences.Presence.menuBarAndDockWhenOpen.rawValue)
                            Text("Dock and menu bar").tag(Preferences.Presence.dockAndMenuBar.rawValue)
                            Text("Dock only").tag(Preferences.Presence.dockOnly.rawValue)
                        }
                        Text(presenceDescription)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Clicking the menu bar icon", selection: $statusItemClick) {
                        Text("Shows the mini player").tag(Preferences.StatusItemClick.miniPlayer.rawValue)
                        Text("Opens Songtide").tag(Preferences.StatusItemClick.openApp.rawValue)
                    }
                    .disabled(presence == Preferences.Presence.dockOnly.rawValue)
                    Toggle("Keep playing when the window is closed", isOn: $keepPlayingWhenClosed)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle("Scroll long song titles", isOn: $scrollLongTitles)
                        Text("Titles and artists too long for the player bar scroll to show the rest. Off: they're cut short.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    AccentPicker()
                }
                Section {
                    HStack {
                        Toggle("Update automatically", isOn: $updatesAutomatically)
                            .onChange(of: updatesAutomatically) { Updater.shared.updatesAutomatically = updatesAutomatically }
                        Spacer()
                        Button("Check Now") { Updater.shared.checkForUpdates() }
                    }
                    Text("New versions install when you quit Songtide. Version \(AppInfo.version).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // Plain footer row outside the panels: app-wide actions and credit.
                HStack {
                    Button("Reset All Settings…") { confirmingReset = true }
                        .buttonStyle(.link)
                        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmingReset) {
                            Button("Reset All Settings", role: .destructive, action: resetToDefaults)
                        } message: {
                            Text("General, playback and sidebar settings go back to their defaults, and Open at Login turns off. You'll stay signed in.")
                        }
                    Spacer()
                    HStack(spacing: 4) {
                        Text("Developed by DCODED")
                        Text("·")
                        Link("dcoded.dev", destination: AppInfo.developerURL)
                    }
                    .foregroundStyle(.secondary)
                }
                .font(.caption)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            .formStyle(.grouped)
            .settingsPage(.general, showing: selectedTab)

            Form {
                Section {
                    Picker("Preferred playback", selection: $preferSongOverVideo) {
                        Text("Song").tag(true)
                        Text("As Listed").tag(false)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: preferSongOverVideo) { music.setPreferSongOverVideo(preferSongOverVideo) }
                    Text(preferSongOverVideo
                         ? "Tracks start as audio whenever there's a song version, even music videos. Switch any track to Video on the player page."
                         : "Each track plays as what you picked: songs as audio, music videos as video. Switch any track on the player page.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Notify when a new song starts", isOn: Binding(get: { notifyOnTrackChange }, set: setNotifyOnTrackChange))
                    Text("A notification with the song and artwork, only while Songtide isn't in front.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                EqualizerSettings()
                    .id(equalizerResetID)
            }
            .formStyle(.grouped)
            .settingsPage(.playback, showing: selectedTab)

            Form {
                Section {
                    if music.account.signedIn {
                        // Same identity as the sidebar's account footer.
                        HStack(spacing: 10) {
                            Group {
                                if let avatar = music.avatarImage {
                                    Image(nsImage: avatar).resizable().scaledToFill()
                                } else {
                                    Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 34, height: 34)
                            .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(music.account.name.isEmpty ? String(localized: "Google Account") : music.account.name)
                                    .font(.headline)
                                Text(music.account.handle.isEmpty ? String(localized: "Signed in") : music.account.handle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .lineLimit(1)
                        }
                    } else {
                        LabeledContent("Google account", value: String(localized: "Not signed in"))
                    }
                    HStack {
                        if music.account.signedIn {
                            if !music.channels.isEmpty {
                                Menu("Switch Channel") { ChannelMenuItems() }
                                    .fixedSize()
                            }
                        } else {
                            Button("Sign In…") { music.isShowingSignIn = true }
                        }
                        if music.account.signedIn {
                            Button("Sign Out", role: .destructive) { Task { await music.signOut() } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .settingsPage(.account, showing: selectedTab)

            IntegrationsSettings()
                .settingsPage(.integrations, showing: selectedTab)
        }
        .onAppear(perform: refreshLoginItem)
        // Pick up changes made in System Settings while this window was open.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshLoginItem() }
        .frame(width: 540)
        .fixedSize()
        .toolbar {
            // Without the glass capsule macOS 26 puts behind toolbar items: plain, like native tabs.
            if #available(macOS 26, *) {
                ToolbarItem(placement: .principal) { SettingsTabBar(selection: $selectedTab) }
                    .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem(placement: .principal) { SettingsTabBar(selection: $selectedTab) }
            }
        }
    }

    private var presenceDescription: LocalizedStringKey {
        switch Preferences.Presence(rawValue: presence) ?? .menuBarAndDockWhenOpen {
        case .menuBarAndDockWhenOpen: "Closing the window hides the Dock icon; Songtide keeps running in the menu bar."
        case .dockAndMenuBar: "Always in the Dock, with the mini player in the menu bar."
        case .dockOnly: "No menu bar icon; closing the window keeps Songtide in the Dock."
        }
    }

    private func resetToDefaults() {
        Preferences.resetAll()
        SystemEqualizer.shared.setEnabled(false)
        equalizerResetID = UUID()
        // Refresh values that aren't live-bound to UserDefaults.
        presence = Preferences.presence.rawValue
        music.setPreferSongOverVideo(true)
        loginItemError = nil
        refreshLoginItem()
    }

    private func setOpenAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.setEnabled(enabled)
            loginItemError = nil
        } catch {
            loginItemError = String(localized: "Couldn't change the login item: \(error.localizedDescription)")
        }
        refreshLoginItem()
    }

    private func refreshLoginItem() {
        openAtLogin = LoginItem.isEnabled
        loginItemNeedsApproval = LoginItem.needsApproval
    }
}

/// Settings' tabs; stored so other parts of the app can open Settings on a particular one.
enum SettingsTab: String, CaseIterable {
    case general, playback, account, integrations
    static let key = "settingsTab"

    var title: String {
        switch self {
        case .general: String(localized: "General")
        case .playback: String(localized: "Playback")
        case .account: String(localized: "Account")
        case .integrations: String(localized: "Integrations")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .playback: "play.circle"
        case .account: "person.crop.circle"
        case .integrations: "puzzlepiece.extension"
        }
    }
}

/// The row of tabs at the top of Settings, drawn like the window toolbar's own.
private struct SettingsTabBar: View {
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab in
                let chosen = selection == tab.rawValue
                Button { selection = tab.rawValue } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.symbol)
                            .font(.system(size: 20, weight: .regular))
                            .frame(height: 24)
                        Text(tab.title)
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(chosen ? AnyShapeStyle(Color.songtide) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 8)
                    .frame(minWidth: 60)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(.primary.opacity(chosen ? 0.1 : 0)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .navigationTitle((SettingsTab(rawValue: selection) ?? .general).title)
    }
}

private extension View {
    /// One of Settings' pages, shown only while its tab is chosen.
    @ViewBuilder func settingsPage(_ tab: SettingsTab, showing selected: String) -> some View {
        if selected == tab.rawValue || (tab == .general && SettingsTab(rawValue: selected) == nil) { self }
    }
}
