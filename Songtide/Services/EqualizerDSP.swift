import Accelerate
import CoreAudio
import Foundation
import os

// Everything here except construction runs on Core Audio's real-time I/O thread, so it's
// nonisolated, never blocks on a lock, and preallocates its buffers.

/// Biquad coefficients (RBJ Audio EQ Cookbook) for the 10-band curve: a low shelf, eight peaking
/// bands and a high shelf, normalised as [b0, b1, b2, a1, a2] per section.
enum EQDesign {
    static func coefficients(gains: [Double], sampleRate: Double) -> [Double] {
        Equalizer.frequencies.enumerated().flatMap { index, frequency -> [Double] in
            let kind: Kind = index == 0 ? .lowShelf : index == Equalizer.frequencies.count - 1 ? .highShelf : .peaking
            return section(kind, frequency: min(frequency, sampleRate * 0.45), gain: gains[index], sampleRate: sampleRate)
        }
    }

    enum Kind { case lowShelf, peaking, highShelf }

    private static func section(_ kind: Kind, frequency: Double, gain: Double, sampleRate: Double) -> [Double] {
        let a = pow(10, gain / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosW = cos(w0), sinW = sin(w0)
        var b0, b1, b2, a0, a1, a2: Double
        switch kind {
        case .peaking:
            let alpha = sinW / (2 * 1.41) // Q ≈ 1.41: one-octave bands
            b0 = 1 + alpha * a; b1 = -2 * cosW; b2 = 1 - alpha * a
            a0 = 1 + alpha / a; a1 = -2 * cosW; a2 = 1 - alpha / a
        case .lowShelf, .highShelf:
            let alpha = sinW / 2 * sqrt(2) // shelf slope S = 1
            let sqrtA2alpha = 2 * sqrt(a) * alpha
            if kind == .lowShelf {
                b0 = a * ((a + 1) - (a - 1) * cosW + sqrtA2alpha)
                b1 = 2 * a * ((a - 1) - (a + 1) * cosW)
                b2 = a * ((a + 1) - (a - 1) * cosW - sqrtA2alpha)
                a0 = (a + 1) + (a - 1) * cosW + sqrtA2alpha
                a1 = -2 * ((a - 1) + (a + 1) * cosW)
                a2 = (a + 1) + (a - 1) * cosW - sqrtA2alpha
            } else {
                b0 = a * ((a + 1) + (a - 1) * cosW + sqrtA2alpha)
                b1 = -2 * a * ((a - 1) + (a + 1) * cosW)
                b2 = a * ((a + 1) + (a - 1) * cosW - sqrtA2alpha)
                a0 = (a + 1) - (a - 1) * cosW + sqrtA2alpha
                a1 = 2 * ((a - 1) - (a + 1) * cosW)
                a2 = (a + 1) - (a - 1) * cosW - sqrtA2alpha
            }
        }
        return [b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0]
    }
}

/// Per-channel filter chains plus a preamp that pulls the level down by the largest boost, so
/// boosted bands don't clip. Built off the audio thread and swapped in whole.
final class EQProcessor: @unchecked Sendable {
    private var filters: [vDSP.Biquad<Float>]
    private let preampGain: Float

    init?(gains: [Double], sampleRate: Double, channels: Int) {
        let coefficients = EQDesign.coefficients(gains: gains, sampleRate: sampleRate)
        var filters: [vDSP.Biquad<Float>] = []
        for _ in 0..<channels {
            guard let filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1,
                                           sectionCount: vDSP_Length(Equalizer.frequencies.count), ofType: Float.self)
            else { return nil }
            filters.append(filter)
        }
        self.filters = filters
        preampGain = Float(pow(10, -max(0, gains.max() ?? 0) / 20))
    }

    func process(_ samples: UnsafeMutableBufferPointer<Float>, channel: Int) {
        guard channel < filters.count else { return }
        var output = samples // the pointer is a value; the memory it points at is what changes
        let input = UnsafeBufferPointer(samples)
        filters[channel].apply(input: input, output: &output)
        if preampGain != 1 { vDSP.multiply(preampGain, input, result: &output) }
        vDSP.clip(input, to: -1...1, result: &output)
    }
}

/// State shared between the main actor and the I/O thread.
final class EqualizerRenderState: @unchecked Sendable {
    /// When true the tap mutes the original, so the equalised audio must be written to the output.
    let replacesOriginal: Bool
    let tapChannels: Int
    private let eq = OSAllocatedUnfairLock<EQProcessor?>(initialState: nil)

    /// Loudest captured sample since the main thread last reset it (racy by design; only a meter).
    nonisolated(unsafe) var peak: Float = 0

    private let maxFrames = 8192
    private var left: [Float]
    private var right: [Float]

    /// The most recent `scopeSize` stereo samples, for the visualizer. Raw memory rather than
    /// arrays: the audio thread writes while the main thread reads, and a torn frame is harmless
    /// here, whereas Swift's exclusivity checks on an array would trap.
    static let scopeSize = 1024
    private let scopeLeft = UnsafeMutablePointer<Float>.allocate(capacity: scopeSize)
    private let scopeRight = UnsafeMutablePointer<Float>.allocate(capacity: scopeSize)
    nonisolated(unsafe) private var scopeIndex = 0

    init(replacesOriginal: Bool, tapChannels: Int) {
        self.replacesOriginal = replacesOriginal
        self.tapChannels = max(1, tapChannels)
        left = [Float](repeating: 0, count: maxFrames)
        right = [Float](repeating: 0, count: maxFrames)
        scopeLeft.initialize(repeating: 0, count: Self.scopeSize)
        scopeRight.initialize(repeating: 0, count: Self.scopeSize)
    }

    deinit {
        scopeLeft.deallocate()
        scopeRight.deallocate()
    }

    /// The latest samples, oldest first, as unsigned bytes (128 = silence): left, then right.
    func scopeBytes() -> [UInt8] {
        var bytes = [UInt8](repeating: 128, count: Self.scopeSize * 2)
        let start = scopeIndex
        for i in 0..<Self.scopeSize {
            let j = (start + i) % Self.scopeSize
            bytes[i] = UInt8(clamping: Int(scopeLeft[j] * 127 + 128))
            bytes[Self.scopeSize + i] = UInt8(clamping: Int(scopeRight[j] * 127 + 128))
        }
        return bytes
    }

    func setEQ(_ processor: EQProcessor?) { eq.withLock { $0 = processor } }

    /// The aggregate device's inputs are its sub-device inputs followed by the tap, so the tap is
    /// the last `tapChannels` input channels. Outputs go to the real output device.
    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputs = channelPointers(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)))
        let outputs = channelPointers(UnsafeMutableAudioBufferListPointer(output))
        let frames = min(inputs.first?.frames ?? 0, maxFrames)
        let tap = inputs.suffix(tapChannels)
        for channel in tap {
            for i in 0..<min(channel.frames, frames) { peak = max(peak, abs(channel.data[i * channel.stride])) }
        }

        // Gather the tap's stereo mixdown into scratch buffers and equalise it.
        let channelCount = min(tap.count, 2)
        if frames > 0, channelCount > 0 {
            for (slot, channel) in tap.prefix(2).enumerated() {
                left.withUnsafeMutableBufferPointer { l in
                    right.withUnsafeMutableBufferPointer { r in
                        let dest = slot == 0 ? l : r
                        for i in 0..<frames { dest[i] = channel.data[i * channel.stride] }
                    }
                }
            }
            if channelCount == 1 { right.withUnsafeMutableBufferPointer { r in left.withUnsafeBufferPointer { l in for i in 0..<frames { r[i] = l[i] } } } }
            left.withUnsafeBufferPointer { l in
                right.withUnsafeBufferPointer { r in
                    var index = scopeIndex
                    for i in 0..<frames {
                        scopeLeft[index] = l[i]
                        scopeRight[index] = r[i]
                        index = (index + 1) % Self.scopeSize
                    }
                    scopeIndex = index
                }
            }
            if replacesOriginal {
                eq.withLockIfAvailable { processor in
                    guard let processor else { return }
                    left.withUnsafeMutableBufferPointer { processor.process(UnsafeMutableBufferPointer(rebasing: $0[0..<frames]), channel: 0) }
                    right.withUnsafeMutableBufferPointer { processor.process(UnsafeMutableBufferPointer(rebasing: $0[0..<frames]), channel: 1) }
                }
            }
        }

        // Write the equalised stereo when replacing the original; otherwise silence (the original
        // is still playing untouched while capture is being verified).
        for (index, channel) in outputs.enumerated() {
            let count = min(channel.frames, frames)
            for i in 0..<channel.frames { channel.data[i * channel.stride] = 0 }
            guard replacesOriginal, index < 2, count > 0 else { continue }
            let source = index == 0 ? left : right
            source.withUnsafeBufferPointer { s in for i in 0..<count { channel.data[i * channel.stride] = s[i] } }
        }
    }

    private struct Channel {
        let data: UnsafeMutablePointer<Float>
        let stride: Int
        let frames: Int
    }

    /// Flattens a buffer list (interleaved or not) into per-channel pointers.
    private func channelPointers(_ list: UnsafeMutableAudioBufferListPointer) -> [Channel] {
        var channels: [Channel] = []
        for buffer in list {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self), buffer.mNumberChannels > 0 else { continue }
            let stride = Int(buffer.mNumberChannels)
            let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * stride)
            for c in 0..<stride { channels.append(Channel(data: data + c, stride: stride, frames: frames)) }
        }
        return channels
    }
}
