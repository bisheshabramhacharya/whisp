@preconcurrency import CoreML
import FluidAudio
import Foundation

/// Native-Swift log-mel features for Parakeet Unified, bit-exact port of
/// FluidAudio's internal `UnifiedMelExtractor` (kept in sync by construction:
/// same `AudioMelSpectrogram` configuration and the same per_feature
/// normalization). `AudioMelSpectrogram` supplies the spectrogram; this type
/// adds the NeMo `normalize: per_feature` standardization and packs the
/// fixed-shape encoder input.
///
/// Unlike FluidAudio's extractor (created once at the model's 15 s window),
/// this one is parameterized by `windowSamples` so short-window encoder
/// bundles can be driven at their native window length.
struct UnifiedMel {
    private let mel: AudioMelSpectrogram
    private let nMels: Int
    private let hopLength = 160
    private let nFFT = 512

    /// Total samples in the (zero-padded) encoder window.
    let windowSamples: Int
    /// Fixed mel frame count the encoder expects (`windowSamples / hop + 1`).
    let totalFrames: Int

    init(windowSamples: Int, nMels: Int = 128) {
        self.windowSamples = windowSamples
        self.nMels = nMels
        self.totalFrames = windowSamples / hopLength + 1
        self.mel = AudioMelSpectrogram(
            sampleRate: 16000,
            nMels: nMels,
            nFFT: nFFT,
            hopLength: hopLength,
            winLength: 400,
            preemph: 0.97,
            padTo: 0,
            windowPeriodic: false
        )
    }

    /// `(mel, melLength)` for one encoder window — same contract as the
    /// CoreML preprocessor outputs the models were exported against.
    ///
    /// Only the frames that hold speech are computed. Normalization sets every
    /// frame past `validFrames` to zero anyway, so the spectrogram of the
    /// window's silent padding was work thrown away: most of the cost of a
    /// short take on the 5 s window, and of a 6 s take on the 15 s one.
    func features(window: [Float], validCount: Int) throws -> (mel: MLMultiArray, length: MLMultiArray) {
        try features(window: window, validCount: validCount, wholeWindow: false)
    }

    /// `wholeWindow` computes every frame first, the way this used to work.
    /// Kept so the tests can prove the shortcut gives the same numbers.
    func features(
        window: [Float], validCount: Int, wholeWindow: Bool
    ) throws -> (mel: MLMultiArray, length: MLMultiArray) {
        // NeMo `get_seq_len` (center padding, stft_pad_amount=0): floor(L/hop),
        // NO +1 — the final tensor frame stays normalized to 0.
        let validFrames = min(validCount / hopLength, totalFrames)
        let computed = wholeWindow ? totalFrames : validFrames

        let melArray = try MLMultiArray(
            shape: [1, NSNumber(value: nMels), NSNumber(value: totalFrames)], dataType: .float32)
        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: validFrames)

        var flat: [Float] = []
        if computed > 0 {
            // A frame reads nFFT/2 samples either side of its centre, so the
            // last speech frame needs that much audio past it and no more.
            let needed = wholeWindow ? window.count : min(window.count, validFrames * hopLength + nFFT / 2)
            flat = mel.computeFlatTransposed(
                audio: needed == window.count ? window : Array(window[0..<needed]),
                lastAudioSample: 0,
                paddingMode: .center,
                expectedFrameCount: computed
            ).mel
            normalizePerFeature(&flat, frames: computed, validFrames: validFrames)
        }
        let frames = totalFrames
        let bins = nMels
        melArray.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            ptr.update(repeating: 0)
            guard validFrames > 0 else { return }
            for t in 0..<validFrames {
                let base = t * bins
                for m in 0..<bins {
                    ptr[m * frames + t] = flat[base + m]
                }
            }
        }
        return (melArray, lengthArray)
    }

    /// NeMo `normalize_batch(..., normalize_type="per_feature")`.
    private func normalizePerFeature(_ x: inout [Float], frames: Int, validFrames: Int) {
        guard validFrames > 0 else {
            for i in x.indices { x[i] = 0 }
            return
        }
        let denom = Float(validFrames > 1 ? validFrames - 1 : 1)
        for m in 0..<nMels {
            var mean: Float = 0
            for t in 0..<validFrames { mean += x[t * nMels + m] }
            mean /= Float(validFrames)

            var varSum: Float = 0
            for t in 0..<validFrames {
                let d = x[t * nMels + m] - mean
                varSum += d * d
            }
            let std = (varSum / denom).squareRoot() + 1e-5

            for t in 0..<frames {
                x[t * nMels + m] = t < validFrames ? (x[t * nMels + m] - mean) / std : 0
            }
        }
    }
}

/// Lets `whisp-tests` check the speech-frames-only shortcut against the whole
/// window computation without a model.
public enum UnifiedMelProbe {
    /// True when both ways give bit-identical encoder input for a window of
    /// `windowSamples` holding `validCount` samples of noise.
    public static func shortcutMatchesWholeWindow(windowSamples: Int, validCount: Int) -> Bool {
        let mel = UnifiedMel(windowSamples: windowSamples)
        var window = [Float](repeating: 0, count: windowSamples)
        var seed: UInt32 = 99
        for i in 0..<min(validCount, windowSamples) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            window[i] = (Float(seed >> 8) / Float(1 << 24) - 0.5) * 0.6
        }
        guard let fast = try? mel.features(window: window, validCount: validCount, wholeWindow: false),
              let whole = try? mel.features(window: window, validCount: validCount, wholeWindow: true),
              fast.mel.count == whole.mel.count, fast.length[0] == whole.length[0]
        else { return false }
        let a = fast.mel.dataPointer.bindMemory(to: Float.self, capacity: fast.mel.count)
        let b = whole.mel.dataPointer.bindMemory(to: Float.self, capacity: whole.mel.count)
        for i in 0..<fast.mel.count where a[i].bitPattern != b[i].bitPattern { return false }
        return true
    }
}
