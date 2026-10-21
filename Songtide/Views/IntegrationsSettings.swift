import SwiftUI

/// Settings › Integrations: Last.fm scrobbling and Discord status.
struct IntegrationsSettings: View {
    private var lastFM = LastFM.shared
    private var discord = DiscordPresence.shared
    @State private var discordOn = DiscordPresence.shared.isEnabled

    var body: some View {
        Form {
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last.fm")
                        Text(lastFM.username.map { String(localized: "Scrobbling as \($0)") } ?? String(localized: "Keep a record of what you listen to."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if lastFM.isConnected {
                        Button("Disconnect") { lastFM.disconnect() }
                    } else if lastFM.isConnecting {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { lastFM.cancelConnecting() }
                    } else {
                        Button("Connect…") { Task { await lastFM.connect() } }
                            .disabled(!LastFM.isConfigured)
                    }
                }
                if lastFM.isConnecting {
                    Text("Approve Songtide on the Last.fm page that opened in your browser.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("Songs count once you've heard half (or four minutes), as Last.fm asks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $discordOn) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show what I'm listening to on Discord")
                        Text("Your Discord status shows the song, artist and artwork while music plays. Needs the Discord app open.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .disabled(!DiscordPresence.isConfigured)
                .onChange(of: discordOn) { discord.isEnabled = discordOn }
            }
        }
        .formStyle(.grouped)
    }
}
