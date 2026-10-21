import Foundation

/// The optional 10-band equalizer's bands, presets and saved settings. The audio side is
/// SystemEqualizer.
enum Equalizer {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    static let range: ClosedRange<Double> = -12...12
    static let flat = Array(repeating: 0.0, count: 10)

    struct Preset: Identifiable, Hashable {
        let name: String
        let gains: [Double]
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: String(localized: "Bass Boost", comment: "Equalizer preset"), gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0]),
        Preset(name: String(localized: "Bass Reducer", comment: "Equalizer preset"), gains: [-6, -5, -4, -2, 0, 0, 0, 0, 0, 0]),
        Preset(name: String(localized: "Treble Boost", comment: "Equalizer preset"), gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6]),
        Preset(name: String(localized: "Vocal", comment: "Equalizer preset"), gains: [-2, -2, -1, 1, 3, 3, 2, 1, 0, -1]),
        Preset(name: String(localized: "Acoustic", comment: "Equalizer preset"), gains: [3, 3, 2, 1, 1, 1, 2, 2, 2, 1]),
        Preset(name: String(localized: "Electronic", comment: "Equalizer preset"), gains: [4, 4, 2, 0, -2, 0, 1, 2, 4, 4]),
        Preset(name: String(localized: "Hip-Hop", comment: "Equalizer preset"), gains: [5, 4, 2, 3, -1, -1, 1, 0, 2, 3]),
        Preset(name: String(localized: "Pop", comment: "Equalizer preset"), gains: [-1, 0, 2, 3, 3, 2, 0, -1, -1, -1]),
        Preset(name: String(localized: "Rock", comment: "Equalizer preset"), gains: [4, 3, 2, 0, -1, -1, 1, 2, 3, 4]),
        Preset(name: String(localized: "Late Night", comment: "Equalizer preset"), gains: [3, 2, 1, 0, 0, 0, -1, -2, -3, -4]),
    ]

    static func label(for frequency: Double) -> String {
        frequency >= 1000 ? "\(Int(frequency / 1000))K" : "\(Int(frequency))"
    }

    // MARK: Saved settings

    static let enabledKey = "equalizerEnabled"
    static let gainsKey = "equalizerGains"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var gains: [Double] {
        get {
            let saved = UserDefaults.standard.array(forKey: gainsKey) as? [Double] ?? []
            return saved.count == frequencies.count ? saved : flat
        }
        set { UserDefaults.standard.set(newValue, forKey: gainsKey) }
    }

    /// The preset matching `gains`, or nil for a custom curve.
    static func preset(matching gains: [Double]) -> Preset? {
        presets.first { $0.gains == gains }
    }
}
