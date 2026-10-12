import AppKit
import WebKit

// MARK: - Bridge payloads

struct WebMenuRequest: Decodable {
    struct Item: Decodable {
        var title: String
        var icon: String
    }
    var x: Double
    var y: Double
    var viewportHeight: Double
    var items: [Item]
}

struct WebShareRequest: Decodable {
    var url: String
    var x: Double
    var y: Double
    var viewportHeight: Double
}

// MARK: - Theme

/// System colors handed to bridge.js so the page matches the native chrome.
@MainActor
enum WebTheme {
    static var script: WKUserScript {
        WKUserScript(source: "window.__ytmTheme = \(json);", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    static var json: String {
        var accent = "#0a84ff", background = "#1e1e1e", raised = "#2d2d2d"
        // The app is always dark, so resolve dynamic colors against the dark appearance.
        NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
            accent = hex(.controlAccentColor)
            background = hex(.windowBackgroundColor)
            raised = hex(.underPageBackgroundColor)
        }
        return #"{"accent":"\#(accent)","bg":"\#(background)","raised":"\#(raised)"}"#
    }

    private static func hex(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02x%02x%02x", Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
    }
}

// MARK: - Menus

@MainActor
enum NativeMenu {
    /// Shows YouTube Music's item menu as an NSMenu at the point the page reported.
    /// `onSelect` receives the chosen index, or nil when the menu was dismissed.
    /// `anchor` overrides the page position (a point in `view`), e.g. for menus opened from native buttons.
    static func present(_ request: WebMenuRequest, in view: NSView, anchor: NSPoint? = nil, onSelect: @escaping (Int?) -> Void) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let handler = Handler(onSelect: onSelect)
        var previousGroup: Group?
        for (index, item) in request.items.enumerated() {
            let group = Group(icon: item.icon)
            if let previousGroup, previousGroup != group { menu.addItem(.separator()) }
            previousGroup = group

            let menuItem = NSMenuItem(title: item.title, action: #selector(Handler.choose(_:)), keyEquivalent: "")
            menuItem.target = handler
            menuItem.tag = index
            menuItem.image = symbol(for: item.icon).flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            menu.addItem(menuItem)
        }

        let point = anchor ?? pagePoint(x: request.x, y: request.y, viewportHeight: request.viewportHeight, in: view)
        // popUp runs a nested tracking loop; defer it so the script message callback returns first.
        DispatchQueue.main.async {
            let chose = menu.popUp(positioning: nil, at: point, in: view)
            if !chose { onSelect(nil) }
            withExtendedLifetime(handler) {}
        }
    }

    /// Converts page (CSS pixel) coordinates to the web view's coordinate space. The web view
    /// extends under the toolbar and WebKit insets the page below it, so the page's origin is
    /// offset by whatever part of the view the viewport doesn't cover.
    static func pagePoint(x: Double, y: Double, viewportHeight: Double, in view: NSView) -> NSPoint {
        let scale = (view as? WKWebView)?.pageZoom ?? 1
        let topInset = max(0, view.bounds.height - viewportHeight * scale)
        let px = x * scale, py = topInset + y * scale
        return view.isFlipped ? NSPoint(x: px, y: py) : NSPoint(x: px, y: view.bounds.height - py)
    }

    private final class Handler: NSObject {
        let onSelect: (Int?) -> Void
        init(onSelect: @escaping (Int?) -> Void) { self.onSelect = onSelect }
        @objc func choose(_ sender: NSMenuItem) { onSelect(sender.tag) }
    }

    /// Separators go between these groups, like native context menus.
    private enum Group: Equatable {
        case play, library, navigate, share, other, negative

        init(icon: String) {
            switch icon {
            case "MUSIC_SHUFFLE", "MIX", "QUEUE_PLAY_NEXT", "ADD_TO_REMOTE_QUEUE", "PLAY_ARROW", "RADIO": self = .play
            case "ARTIST", "ALBUM", "MUSIC_ARTIST", "MUSIC_ALBUM", "SUBSCRIPTIONS", "PODCAST": self = .navigate
            case "SHARE": self = .share
            case "NOT_INTERESTED", "REMOVE", "DELETE", "FLAG", "REMOVE_FROM_HISTORY", "DISMISS_QUEUE": self = .negative
            case let i where i.contains("LIBRARY") || i.contains("BOOKMARK") || i.contains("PLAYLIST")
                || i.contains("FAVORITE") || i.contains("THUMB") || i.contains("DOWNLOAD") || i.contains("KEEP"): self = .library
            default: self = .other
            }
        }
    }

    /// Maps YouTube Music icon types to SF Symbols.
    static func symbol(for icon: String) -> String? {
        switch icon {
        case "MUSIC_SHUFFLE": "shuffle"
        case "MIX", "RADIO": "dot.radiowaves.left.and.right"
        case "QUEUE_PLAY_NEXT": "text.line.first.and.arrowtriangle.forward"
        case "ADD_TO_REMOTE_QUEUE": "text.line.last.and.arrowtriangle.forward"
        case "PLAY_ARROW": "play"
        case "BOOKMARK_BORDER", "LIBRARY_ADD": "plus.square.on.square"
        case "BOOKMARK", "LIBRARY_SAVED", "LIBRARY_REMOVE": "checkmark.square"
        case "ADD_TO_PLAYLIST", "PLAYLIST_ADD": "text.badge.plus"
        case "SHARE": "square.and.arrow.up"
        case "NOT_INTERESTED": "nosign"
        case "FAVORITE", "THUMB_UP", "LIKE": "hand.thumbsup"
        case "UNFAVORITE", "THUMB_UP_FILLED": "hand.thumbsup.fill"
        case "OFFLINE_DOWNLOAD", "DOWNLOAD": "arrow.down.circle"
        case "OFFLINE_REMOVE": "arrow.down.circle.dotted"
        case "ARTIST", "MUSIC_ARTIST": "music.microphone"
        case "ALBUM", "MUSIC_ALBUM": "square.stack"
        case "SUBSCRIPTIONS", "PODCAST": "antenna.radiowaves.left.and.right"
        case "KEEP": "pin"
        case "KEEP_OFF": "pin.slash"
        case "REMOVE", "DISMISS_QUEUE": "minus.circle"
        case "DELETE": "trash"
        case "REMOVE_FROM_HISTORY": "clock.arrow.circlepath"
        case "FLAG": "flag"
        case "EDIT": "pencil"
        case "INFO": "info.circle"
        default: nil
        }
    }
}

// MARK: - Sharing

@MainActor
enum NativeShare {
    static func present(_ request: WebShareRequest, in view: NSView) {
        guard let url = URL(string: request.url) else { return }
        let point = NativeMenu.pagePoint(x: request.x, y: request.y, viewportHeight: request.viewportHeight, in: view)
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(origin: point, size: NSSize(width: 1, height: 1)), of: view, preferredEdge: .minY)
    }
}
