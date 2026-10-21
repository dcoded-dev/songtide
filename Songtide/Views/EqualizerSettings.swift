import SwiftUI

/// Settings › Playback: the equalizer (Off or a preset) and, when on, its ten band sliders.
struct EqualizerSettings: View {
    private static let off = "off", custom = "custom"
    private var equalizer = SystemEqualizer.shared
    private var enabled: Bool { equalizer.isEnabled }
    private var gains: [Double] { equalizer.gains }

    var body: some View {
        Section {
            // "Off" is the first choice rather than a separate switch; any preset turns it on.
            Picker("Equalizer", selection: Binding(
                get: { enabled ? (equalizer.preset?.name ?? Self.custom) : Self.off },
                set: { name in
                    if name == Self.off {
                        equalizer.setEnabled(false)
                    } else if let preset = Equalizer.presets.first(where: { $0.name == name }) {
                        equalizer.choose(preset)
                    }
                }
            )) {
                Text("Off").tag(Self.off)
                Divider()
                ForEach(Equalizer.presets) { Text($0.name).tag($0.name) }
                if enabled && equalizer.preset == nil {
                    Divider()
                    Text("Custom").tag(Self.custom)
                }
            }
            Text("Songtide equalizes its own playback. macOS asks once for permission to capture Songtide's audio; nothing is recorded or saved, and other apps aren't affected.")
                .font(.caption)
                .foregroundStyle(.secondary)
            // Not in guest (screenshot) sessions, where it would only describe the session's own state.
            if enabled, !MusicController.isGuestSession, let message = equalizer.status.message {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: equalizer.status == .needsPermission ? "exclamationmark.triangle" : "info.circle")
                        .font(.caption)
                        .foregroundStyle(equalizer.status == .needsPermission ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        .fixedSize(horizontal: false, vertical: true)
                    if equalizer.status == .needsPermission {
                        Button("Open Privacy Settings") { NSWorkspace.shared.open(SystemEqualizer.privacySettingsURL) }
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            if enabled {
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(Equalizer.frequencies.indices, id: \.self) { band in
                        VStack(spacing: 6) {
                            Text(gains[band] > 0 ? "+\(Int(gains[band]))" : "\(Int(gains[band]))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            VerticalSlider(value: gains[band], range: Equalizer.range) { value in
                                var new = gains
                                new[band] = value.rounded()
                                apply(new)
                            }
                            .frame(width: 20, height: 120)
                            Text(Equalizer.label(for: Equalizer.frequencies[band]))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func apply(_ new: [Double]) { equalizer.setGains(new) }
}

/// A vertical track with a round knob, matching the player bar's volume slider.
private struct VerticalSlider: View {
    var value: Double
    var range: ClosedRange<Double>
    var onChange: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            let zero = (0 - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .bottom) {
                Capsule().fill(.primary.opacity(0.2)).frame(width: 3)
                // The filled part runs from the 0 dB line to the knob.
                Capsule().fill(Color.songtide)
                    .frame(width: 3, height: abs(fraction - zero) * height)
                    .offset(y: -min(fraction, zero) * height)
                Rectangle().fill(.primary.opacity(0.35)).frame(width: 9, height: 1)
                    .offset(y: -zero * height)
                Circle().fill(.primary)
                    .frame(width: 12, height: 12)
                    .offset(y: -fraction * height + 6)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max(1 - drag.location.y / height, 0), 1)
                onChange(range.lowerBound + f * (range.upperBound - range.lowerBound))
            })
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(value)) decibels")
        .accessibilityAdjustableAction { direction in
            onChange(min(max(value + (direction == .increment ? 1 : -1), range.lowerBound), range.upperBound))
        }
    }
}
