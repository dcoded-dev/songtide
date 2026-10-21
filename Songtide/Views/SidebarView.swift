import SwiftUI

/// Sidebar laid out like Apple Music's: browse items without a heading, a Library section whose
/// items can be chosen with Edit, and a collapsible Playlists section.
struct SidebarView: View {
    @Environment(MusicController.self) private var music
    @Binding var selection: SidebarItem?
    @AppStorage("sidebarPlaylistsExpanded") private var playlistsExpanded = true
    /// Browse IDs of Library items the user turned off in Edit mode (comma-separated).
    @AppStorage("sidebarHiddenLibraryItems") private var hiddenLibraryItems =
        SidebarItem.defaultHiddenLibraryItems.sorted().joined(separator: ",")
    @State private var editingLibrary = false
    @State private var hoveringLibraryHeader = false

    private var hidden: Set<String> { Set(hiddenLibraryItems.split(separator: ",").map(String.init)) }

    var body: some View {
        // The selected row is drawn here, not by macOS, so it takes Songtide's accent color.
        List {
            Section {
                row(.home)
                row(.explore)
                row(.library)
            }

            // Sidebar section headings always get a collapse arrow, so Library's heading is a plain,
            // unselectable row styled like one (Library shouldn't collapse; only Playlists does).
            Section {
                HStack {
                    Text("Your Music")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    // Like Apple Music: Edit appears while hovering the heading (and stays while editing).
                    Button(editingLibrary ? "Done" : "Edit") { editingLibrary.toggle() }
                        .buttonStyle(.borderless)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .opacity(hoveringLibraryHeader || editingLibrary ? 1 : 0)
                        .padding(.trailing, 8)
                }
                .padding(.top, 10)
                .contentShape(Rectangle())
                .onHover { hoveringLibraryHeader = $0 }
                .selectionDisabled()
                .accessibilityAddTraits(.isHeader)

                if editingLibrary {
                    ForEach(SidebarItem.libraryItems) { item in
                        Toggle(isOn: shownBinding(for: item)) {
                            Label(item.title, systemImage: item.symbol)
                        }
                        .toggleStyle(.checkbox)
                        .selectionDisabled()
                    }
                } else {
                    ForEach(SidebarItem.libraryItems.filter { !hidden.contains($0.browseId) }) { row($0) }
                }
            }

            if music.account.signedIn {
                Section(isExpanded: $playlistsExpanded) {
                    ForEach(music.playlists) { playlist in
                        let item = SidebarItem.playlist(playlist)
                        PlaylistRow(playlist: playlist, chosen: selection == item)
                            .sidebarSelection(selection == item) { selection = item }
                    }
                    Button { music.newPlaylist() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .semibold))
                            Text("New Playlist")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.08)))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .selectionDisabled()
                } header: {
                    Text("Playlists")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Blurred footer (same material as the player bar) so rows scrolling under it stay legible.
            // The update card floats above the footer on its own background.
            VStack(spacing: 0) {
                UpdateReadyCard()
                AccountView()
                    .background(.bar)
            }
        }
    }

    private func row(_ item: SidebarItem) -> some View {
        let chosen = selection == item
        return Label {
            Text(item.title)
        } icon: {
            Image(systemName: item.symbol)
                .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.tint))
        }
        .lineLimit(1)
        .sidebarSelection(chosen) { selection = item }
    }

    private func shownBinding(for item: SidebarItem) -> Binding<Bool> {
        Binding(
            get: { !hidden.contains(item.browseId) },
            set: { shown in
                var set = hidden
                if shown { set.remove(item.browseId) } else { set.insert(item.browseId) }
                hiddenLibraryItems = set.sorted().joined(separator: ",")
            }
        )
    }
}

/// A downloaded update waiting for a restart: a quiet card above the account, rather than a popup
/// (restarting stops the music, so it's left to the person to pick the moment). Without a click it
/// still installs the next time Songtide quits.
private struct UpdateReadyCard: View {
    private var updater = Updater.shared
    @State private var hovering = false

    var body: some View {
        if updater.hasUpdate {
            let ready = updater.readyVersion != nil
            // The whole card is the button.
            Button { updater.installUpdate() } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tint)
                    Text(ready ? "Update ready" : "Update available")
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .layoutPriority(1)
                    Spacer(minLength: 2)
                    Text(ready ? "Restart" : "Update")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tint)
                        .fixedSize()
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 10)
                .background(.tint.opacity(hovering ? 0.26 : 0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.tint.opacity(0.3)))
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
            .help(ready ? "Installs the update and reopens Songtide. Otherwise it installs the next time you quit."
                        : "Shows the new version, to install it.")
            .accessibilityLabel(ready ? "Update ready. Restart to update." : "Update available. Install the update.")
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Two-line playlist row like YouTube Music's guide: title, then a subtitle with a pin if pinned.
private struct PlaylistRow: View {
    let playlist: PlaylistEntry
    var chosen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(playlist.title)
                .font(.body.weight(.medium))
            HStack(spacing: 4) {
                if playlist.pinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .accessibilityLabel("Pinned")
                }
                Text(playlist.subtitle)
            }
            .font(.callout)
            .foregroundStyle(chosen ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
        }
        .lineLimit(1)
        .padding(.vertical, 3)
    }
}

private struct AccountView: View {
    @Environment(MusicController.self) private var music

    var body: some View {
        Group {
            if music.account.signedIn {
                Menu {
                    if !music.channels.isEmpty {
                        ChannelMenuItems()
                        Divider()
                    }
                    Button("Sign Out", role: .destructive) { Task { await music.signOut() } }
                } label: {
                    HStack(spacing: 8) {
                        Group {
                            if let avatar = music.avatarImage {
                                Image(nsImage: avatar).resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(music.account.name.isEmpty ? "Google Account" : music.account.name)
                                .font(.headline)
                            if !music.account.handle.isEmpty {
                                Text(music.account.handle)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .lineLimit(1)
                        Spacer()
                    }
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
            } else {
                Button {
                    music.isShowingSignIn = true
                } label: {
                    Label("Sign in with Google", systemImage: "person.crop.circle.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
            }
        }
        // Same height as the player bar, with the content centred on the same line as its controls
        // (the 1pt divider stands in for the top of the seek bar strip).
        .frame(height: PlayerBarMetrics.contentHeight)
        .padding(.horizontal, 12)
        .padding(.top, PlayerBarMetrics.seekBarHeight + PlayerBarMetrics.topPadding - 1)
        .padding(.bottom, PlayerBarMetrics.bottomPadding)
        .overlay(alignment: .top) { Divider() }
        .frame(height: PlayerBarMetrics.height)
    }
}

private extension View {
    /// A sidebar row that's chosen with a click, its selection drawn in the accent color the way
    /// macOS draws its own.
    func sidebarSelection(_ chosen: Bool, choose: @escaping () -> Void) -> some View {
        self
            .foregroundStyle(chosen ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: choose)
            .listRowBackground(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                    .padding(.horizontal, 10)
            )
            .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { choose() }
    }
}
