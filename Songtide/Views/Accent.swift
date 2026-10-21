import AppKit
import SwiftUI

/// Songtide's accent color: the Mac's own (the default), or one picked for Songtide alone.
/// It tints the app's controls and replaces YouTube red on the page.
enum Accent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite

    static let key = "accentColor"

    var id: String { rawValue }

    var name: String { rawValue.capitalized }

    /// The color, with the Mac's own resolved for the always-dark app.
    var nsColor: NSColor {
        switch self {
        case .system: .controlAccentColor
        case .blue: .systemBlue
        case .purple: .systemPurple
        case .pink: .systemPink
        case .red: .systemRed
        case .orange: .systemOrange
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .graphite: .systemGray
        }
    }

    var color: Color { Color(nsColor: nsColor) }

    static var current: Accent {
        UserDefaults.standard.string(forKey: key).flatMap(Accent.init) ?? .system
    }
}

/// The chosen accent color, shared by every window, so all of them change the moment it's picked.
@MainActor @Observable
final class AccentStore {
    static let shared = AccentStore()

    var accent: Accent = .current {
        didSet {
            guard accent != oldValue else { return }
            UserDefaults.standard.set(accent.rawValue, forKey: Accent.key)
        }
    }

    private init() {
        // Settings reset clears the key: back to System.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let store = AccentStore.shared
                if store.accent != .current { store.accent = .current }
            }
        }
    }
}

extension View {
    /// Tints the view with the chosen accent color, following changes to it.
    func songtideAccent() -> some View { modifier(AccentTint()) }
}

private struct AccentTint: ViewModifier {
    private var store = AccentStore.shared

    func body(content: Content) -> some View {
        content.tint(store.accent.color)
    }
}

/// The color swatches in Settings, as in System Settings › Appearance: the name of the chosen
/// one underneath it. The choice is saved, and everything follows it, as soon as it's clicked.
struct AccentPicker: View {
    private var store = AccentStore.shared

    var body: some View {
        LabeledContent("Accent color") {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Accent.allCases) { choice in
                    Swatch(choice: choice, selected: store.accent == choice) { store.accent = choice }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private struct Swatch: View {
        let choice: Accent
        let selected: Bool
        let pick: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: pick) {
                VStack(spacing: 5) {
                    Circle()
                        .fill(fill)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
                        .padding(3)
                        .overlay {
                            if selected { Circle().strokeBorder(choice == .system ? Color.secondary : choice.color, lineWidth: 2) }
                        }
                        .scaleEffect(hovering && !selected ? 1.08 : 1)
                    // Every swatch keeps the space, so the row doesn't jump.
                    Text(choice.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .opacity(selected ? 1 : 0)
                        .frame(width: 28)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
            .help(choice.name)
            .accessibilityLabel(choice.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

        /// System (the Mac's own color) shows as a multicolor swatch, as in System Settings.
        private var fill: AnyShapeStyle {
            guard choice == .system else { return AnyShapeStyle(choice.color) }
            return AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
        }
    }
}
