import AppKit
import SwiftUI

/// Songtide's accent colour: the Mac's own (the default), or one picked for Songtide alone.
/// It tints the app's controls and replaces YouTube red on the page.
enum Accent: String, CaseIterable, Identifiable {
    case system, blue, purple, pink, red, orange, yellow, green, graphite

    static let key = "accentColour"

    var id: String { rawValue }

    var name: String { self == .system ? "Mac's accent colour" : rawValue.capitalized }

    /// The colour, with the Mac's own resolved for the always-dark app.
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

extension View {
    /// Tints the view with the chosen accent colour, following changes to it.
    func songtideAccent() -> some View { modifier(AccentTint()) }
}

private struct AccentTint: ViewModifier {
    @AppStorage(Accent.key) private var accent = Accent.system.rawValue

    func body(content: Content) -> some View {
        content.tint((Accent(rawValue: accent) ?? .system).color)
    }
}

/// The colour swatches in Settings, like the ones in System Settings › Appearance.
struct AccentPicker: View {
    @AppStorage(Accent.key) private var accent = Accent.system.rawValue

    var body: some View {
        LabeledContent("Accent colour") {
            HStack(spacing: 8) {
                ForEach(Accent.allCases) { choice in
                    Swatch(choice: choice, selected: accent == choice.rawValue) { accent = choice.rawValue }
                }
            }
        }
    }

    private struct Swatch: View {
        let choice: Accent
        let selected: Bool
        let pick: () -> Void

        var body: some View {
            Button(action: pick) {
                Circle()
                    .fill(fill)
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(.black.opacity(0.25), lineWidth: 0.5))
                    .overlay {
                        if selected { Circle().fill(.white).frame(width: 6, height: 6) }
                    }
                    .padding(2)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(choice.name)
            .accessibilityLabel(choice.name)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }

        /// The Mac's own colour shows as a multicolour swatch, as in System Settings.
        private var fill: AnyShapeStyle {
            guard choice == .system else { return AnyShapeStyle(choice.color) }
            return AnyShapeStyle(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
        }
    }
}
