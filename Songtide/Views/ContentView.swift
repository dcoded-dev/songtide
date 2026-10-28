import SwiftUI

struct ContentView: View {
    @Environment(MusicController.self) private var music
    @State private var searchText = ""
    @State private var pendingSelection: SidebarItem?
    @FocusState private var searchFocused: Bool
    @AppStorage("sidebarVisible") private var sidebarVisible = true
    @State private var isFullScreen = false
    @State private var pageSize = CGSize(width: 1000, height: 800)
    @State private var windowWidth: CGFloat = 1200
    /// The sidebar's width when last shown (it can be dragged between 200 and 320).
    @State private var sidebarWidth: CGFloat = 230

    private var showsInlineVisualizer: Bool { music.isShowingVisualizer && !music.visualizerInWindow }
    /// Full screen with the visualizer filling this window: nothing but the visuals.
    private var immersive: Bool { music.visualizerCoversPage && isFullScreen }
    /// Sidebar shown/hidden via the toolbar button or View › Show/Hide Sidebar; remembered. It
    /// steps aside on its own while the window is too narrow for it and a page wide enough for
    /// YouTube Music's desktop layout (see minPageColumnWidth), and comes back when there's room.
    private var columnVisibility: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { immersive || !sidebarVisible || !sidebarFits ? .detailOnly : .all },
            set: {
                guard !immersive else { return }
                // Hiding while it doesn't fit is the split view following our own step-aside,
                // not a choice to remember.
                let show = $0 != .detailOnly
                guard show || sidebarFits else { return }
                sidebarVisible = show
                if sidebarVisible && !sidebarFits { widenForSidebar() }
            }
        )
    }
    private var sidebarFits: Bool { windowWidth - sidebarWidth - 1 >= Self.minPageColumnWidth }

    /// Showing the sidebar in a window too narrow for it: widen the window (as far as the screen
    /// allows) so the page keeps its room.
    private func widenForSidebar() {
        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true }) else { return }
        let needed = sidebarWidth + 1 + Self.minPageColumnWidth - windowWidth
        guard needed > 0 else { return }
        var frame = window.frame
        frame.size.width += needed
        if let screen = window.screen?.visibleFrame {
            frame.size.width = min(frame.width, screen.width)
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        }
        window.setFrame(frame, display: true, animate: true)
    }
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    private var selection: Binding<SidebarItem?> {
        Binding(
            // No row is current while the visualizer covers the page, so clicking any row (even
            // the one underneath) shows that page beside it.
            get: { music.visualizerCoversPage ? nil : pendingSelection ?? SidebarItem.matching(path: music.path, playlists: music.playlists) },
            set: { item in
                guard let item else { return }
                pendingSelection = item
                music.open(item)
            }
        )
    }

    /// YouTube Music's page, with a cover for its blank first frame while it loads.
    private var page: some View {
        ZStack {
            Self.pageBackground
            MusicWebView(webView: music.webView)
            if music.isLoading && !music.state.hasTrack && music.path == MusicController.launchPath {
                // Covers the web view's blank white first frame as well as showing progress.
                ZStack {
                    Color(red: 3 / 255, green: 3 / 255, blue: 3 / 255)
                    ProgressView().controlSize(.large)
                }
            }
        }
    }

    private enum Split { case none, sideBySide, stacked }

    /// How the visualizer and Now Playing share the page when both are open.
    private var split: Split {
        guard showsInlineVisualizer, !music.visualizerFills else { return .none }
        return splitAxis == .horizontal ? .sideBySide : .stacked
    }

    /// How the visualizer splits with the page (or would, while it fills the page area).
    private var splitAxis: Axis { pageSize.width >= 1080 ? .horizontal : .vertical }

    // Split sizes, adjustable by dragging the divider; remembered.
    @AppStorage("visualizerSplitPageWidth") private var splitPageWidth = ContentView.defaultSplitPageWidth
    @AppStorage("visualizerSplitHeightFraction") private var splitVisualizerFraction = ContentView.defaultSplitVisualizerFraction
    @State private var dragOrigin: Double?
    /// While the divider is being dragged: the page width (side by side) or visualizer fraction
    /// (stacked) under the pointer, saved once when the drag ends rather than on every step.
    @State private var liveSplit: Double?
    /// The page first (left or top) instead of the visualizer.
    @AppStorage(VisualizerView.splitSwappedKey) private var swapped = false
    private static let defaultSplitPageWidth: Double = 640
    private static let defaultSplitVisualizerFraction = 0.42

    /// The page column never goes narrower than YouTube Music's desktop layout: at 615px and
    /// narrower it switches to its phone layout, where Now Playing can't be opened (and stays
    /// broken after widening again).
    private static let minPageColumnWidth: CGFloat = 620

    private func pageColumnWidth(_ width: Double) -> CGFloat {
        min(max(width, Self.minPageColumnWidth), max(Self.minPageColumnWidth, pageSize.width - 420))
    }
    private func visualizerHeight(_ fraction: Double) -> CGFloat {
        pageSize.height * min(max(fraction, 0.2), 0.8)
    }
    private var pageColumnWidth: CGFloat { pageColumnWidth(liveSplit ?? splitPageWidth) }
    private var visualizerHeight: CGFloat { visualizerHeight(liveSplit ?? splitVisualizerFraction) }

    private static let pageBackground = Color(red: 3 / 255, green: 3 / 255, blue: 3 / 255) // YouTube Music's

    /// YouTube Music's page in its split column.
    private var splitPage: some View {
        page.frame(width: split == .sideBySide ? pageColumnWidth : nil)
    }

    /// The line between the visualizer and the page, with a wider invisible grip to drag;
    /// double-click it to go back to the standard sizes.
    private var splitDivider: some View {
        let sideBySide = split == .sideBySide
        return Rectangle().fill(.separator)
            .frame(width: sideBySide ? 1 : nil, height: sideBySide ? nil : 1)
            .overlay {
                Color.clear
                    .frame(width: sideBySide ? 9 : nil, height: sideBySide ? nil : 9)
                    .contentShape(Rectangle())
                    .pointerStyle(sideBySide ? .columnResize : .rowResize)
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { drag in
                            // Dragging toward the page grows the visualizer.
                            let sign: Double = swapped ? -1 : 1
                            if dragOrigin == nil {
                                // Resize the page as a browser window does while it's being resized.
                                (music.webView as? MenuFirstWebView)?.beginDividerResize()
                            }
                            if sideBySide {
                                let origin = dragOrigin ?? Double(pageColumnWidth)
                                dragOrigin = origin
                                liveSplit = min(max(origin - sign * drag.translation.width, Self.minPageColumnWidth), Double(max(Self.minPageColumnWidth, pageSize.width - 420)))
                            } else {
                                let origin = dragOrigin ?? min(max(splitVisualizerFraction, 0.2), 0.8)
                                dragOrigin = origin
                                liveSplit = min(max(origin + sign * drag.translation.height / max(pageSize.height, 1), 0.2), 0.8)
                            }
                        }
                        .onEnded { _ in
                            if let liveSplit {
                                if sideBySide { splitPageWidth = liveSplit } else { splitVisualizerFraction = liveSplit }
                            }
                            liveSplit = nil
                            dragOrigin = nil
                            (music.webView as? MenuFirstWebView)?.endDividerResize()
                        })
                    .onTapGesture(count: 2) {
                        splitPageWidth = Self.defaultSplitPageWidth
                        splitVisualizerFraction = Self.defaultSplitVisualizerFraction
                    }
            }
    }

    /// The page's edge that meets the visualizer.
    private var dividerEdge: Alignment {
        switch (split == .sideBySide, swapped) {
        case (true, false): .leading
        case (true, true): .trailing
        case (false, false): .top
        case (false, true): .bottom
        }
    }

    private var pageLayout: AnyLayout {
        switch split {
        case .none: AnyLayout(ZStackLayout())
        case .sideBySide: AnyLayout(SplitStack(axis: .horizontal, reversed: swapped))
        case .stacked: AnyLayout(SplitStack(axis: .vertical, reversed: swapped))
        }
    }

    /// Brings back the windows that were open when Songtide last quit (the visualizer in the main
    /// window comes back by itself). Once per launch: the main window can reopen later.
    private func reopenWindows() {
        guard !Self.reopenedWindows, !MusicController.isGuestSession else { return }
        Self.reopenedWindows = true
        if music.isShowingVisualizer && music.visualizerInWindow { openWindow(id: VisualizerView.windowID) }
        if UserDefaults.standard.bool(forKey: Lyrics.windowOpenKey) { openWindow(id: LyricsWindowView.windowID) }
    }
    private static var reopenedWindows = false

    private static func isMain(_ note: Notification) -> Bool {
        (note.object as? NSWindow)?.identifier?.rawValue.hasPrefix("main") == true
    }

    var body: some View {
        @Bindable var music = music
        NavigationSplitView(columnVisibility: columnVisibility) {
            SidebarView(selection: selection)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { if $0 > 0 { sidebarWidth = $0 } }
        } detail: {
            VStack(spacing: 0) {
                // The visualizer covers the page, or, with Now Playing open too, sits beside it (page
                // in a narrow column, where YouTube Music stacks artwork over Up Next) or, in a
                // narrow window, above it. One layout that switches, so neither view is rebuilt.
                pageLayout {
                    if showsInlineVisualizer {
                        VisualizerView(placement: .inline, splitAxis: split == .none ? nil : splitAxis, nextSplitAxis: splitAxis)
                            // Any size the split gives it: its own content must never widen the layout
                            // (that would feed back into the page column's size).
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0)
                            .frame(height: split == .stacked ? visualizerHeight : nil)
                            .clipped()
                            .zIndex(1)
                    }
                    splitPage
                        .overlay(alignment: dividerEdge) {
                            if split != .none { splitDivider }
                        }
                }
                .onGeometryChange(for: CGSize.self) { $0.size } action: { pageSize = $0 }
                if !immersive {
                    PlayerBarView()
                }
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Songs, albums, artists, podcasts")
        .searchFocused($searchFocused)
        .searchSuggestions {
            ForEach(music.suggestions) { suggestion in
                Button {
                    if suggestion.kind == .text { searchText = suggestion.title }
                    searchFocused = false
                    music.pick(suggestion)
                } label: {
                    SuggestionRow(suggestion: suggestion)
                }
                .buttonStyle(.plain)
            }
        }
        .onSubmit(of: .search) {
            music.search(searchText)
            searchFocused = false
        }
        .task(id: searchText) {
            // Debounce typing before asking YouTube Music for suggestions.
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { music.suggest(searchText) }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { music.goBack() } label: { Label("Back", systemImage: "chevron.backward") }
                    .disabled(!music.canGoBack)
                Button { music.goForward() } label: { Label("Forward", systemImage: "chevron.forward") }
                    .disabled(!music.canGoForward)
            }
        }
        .navigationTitle(selection.wrappedValue?.title ?? (music.pageTitle.isEmpty ? "Songtide" : music.pageTitle))
        .onChange(of: music.path) { pendingSelection = nil }
        .sheet(isPresented: $music.isShowingSignIn) { SignInSheet() }
        .onAppear {
            // The menu bar item lives outside SwiftUI's scenes; give it SwiftUI's window actions.
            StatusBarController.shared.openMainWindow = { openWindow(id: "main") }
            StatusBarController.shared.openSettings = { openSettings() }
            reopenWindows()
        }
        .focusedSceneValue(\.focusSearch) { searchFocused = true }
        .toolbar(immersive ? .hidden : .automatic, for: .windowToolbar)
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { if Self.isMain($0) { isFullScreen = true } }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { if Self.isMain($0) { isFullScreen = false } }
        .preferredColorScheme(.dark)
        .frame(minWidth: 820, minHeight: 560)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { windowWidth = $0 }
    }

}

/// One row in the search suggestions list: a query completion, or a direct result with artwork.
/// Every row has the same set width: the list's window sizes itself to its rows, and a row whose
/// width follows the window's (a long title cut short) could resize it back and forth until
/// AppKit gave up and crashed the app.
private struct SuggestionRow: View {
    let suggestion: SearchSuggestion

    var body: some View {
        content
            .lineLimit(1)
            .frame(width: 300, alignment: .leading)
    }

    @ViewBuilder private var content: some View {
        switch suggestion.kind {
        case .text:
            Label(suggestion.title, systemImage: "magnifyingglass")
        case .result:
            HStack(spacing: 10) {
                Artwork(url: suggestion.thumbnailURL, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(suggestion.title)
                    Text(suggestion.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(1)
            }
        }
    }
}

/// Two views in a row or column, in either order: the one with a set length gets it, the other
/// the rest. Reordering this way (rather than in the view builder) keeps both views alive.
private struct SplitStack: Layout {
    var axis: Axis
    var reversed: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let total = axis == .horizontal ? bounds.width : bounds.height
        let full = ProposedViewSize(bounds.size)
        var lengths = subviews.map { view in
            let size = view.sizeThatFits(full)
            return min(axis == .horizontal ? size.width : size.height, total)
        }
        if lengths.count == 2 {
            // The shorter one is the fixed one; the other fills what's left.
            let flexible = lengths[0] < lengths[1] ? 1 : 0
            lengths[flexible] = max(0, total - lengths[1 - flexible])
        }
        var offset: CGFloat = 0
        for index in reversed ? Array(subviews.indices.reversed()) : Array(subviews.indices) {
            let length = lengths[index]
            let origin = axis == .horizontal
                ? CGPoint(x: bounds.minX + offset, y: bounds.minY)
                : CGPoint(x: bounds.minX, y: bounds.minY + offset)
            let size = axis == .horizontal
                ? CGSize(width: length, height: bounds.height)
                : CGSize(width: bounds.width, height: length)
            subviews[index].place(at: origin, proposal: ProposedViewSize(size))
            offset += length
        }
    }
}

struct FocusSearchKey: FocusedValueKey { typealias Value = () -> Void }

extension FocusedValues {
    var focusSearch: (() -> Void)? {
        get { self[FocusSearchKey.self] }
        set { self[FocusSearchKey.self] = newValue }
    }
}
