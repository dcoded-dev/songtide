import SwiftUI

/// Compact player shown from the menu bar item.
struct MiniPlayerView: View {
    @Environment(MusicController.self) private var music
    var onOpenApp: () -> Void

    var body: some View {
        let state = music.state
        VStack(spacing: 12) {
            Artwork(url: state.artworkURL, size: 220)
            VStack(spacing: 2) {
                Text(state.hasTrack ? state.title : String(localized: "Not Playing")).font(.headline)
                Text(state.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: 220)
            ScrubberView()
            HStack {
                Button { music.dislike() } label: {
                    Image(systemName: state.like == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                }
                Spacer()
                TransportControls(size: .compact)
                Spacer()
                Button { music.like() } label: {
                    Image(systemName: state.like == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                }
            }
            .buttonStyle(.borderless)
            .disabled(!state.hasTrack)
            Divider()
            // Subtle pill, matching the sidebar's New Playlist button.
            Button(action: onOpenApp) {
                HStack(spacing: 5) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Open Songtide")
                }
                .font(.callout)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(.white.opacity(0.08)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 260)
    }
}
