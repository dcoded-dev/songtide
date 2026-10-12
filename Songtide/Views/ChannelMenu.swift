import SwiftUI

/// Menu content for switching channels, with a checkmark on the active one. Used by the
/// sidebar's account menu and by Settings.
struct ChannelMenuItems: View {
    @Environment(MusicController.self) private var music

    var body: some View {
        if !music.channels.isEmpty {
            Picker(music.channels.first?.email ?? "Channels", selection: Binding(
                get: { music.channels.first(where: \.selected)?.id ?? "" },
                set: { id in
                    if let channel = music.channels.first(where: { $0.id == id }) { music.switchChannel(channel) }
                }
            )) {
                ForEach(music.channels) { channel in
                    Label {
                        Text(channel.name)
                        Text(channel.byline)
                    } icon: {
                        if let avatar = music.channelAvatars[channel.photo] {
                            Image(nsImage: avatar)
                        } else {
                            Image(systemName: "person.crop.circle")
                        }
                    }
                    .tag(channel.id)
                }
            }
            .pickerStyle(.inline)
        }
    }
}
