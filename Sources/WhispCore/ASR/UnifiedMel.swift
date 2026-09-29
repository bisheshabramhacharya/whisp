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
            nFFT: 512,
            hopLength: 160,
            winLength: 400,
            preemph: 0.97,
            padTo: 0,
            windowPeriodic: false
        )
    }

    /// `(mel, melLength)` for one encoder window — same contract as the
    /// CoreML preprocessor outputs the models were exported against.
    func features(window: [Float], validCount: Int) throws -> (mel: MLMultiArray, length: MLMultiArray) {
        var flat = mel.computeFlatTransposed(
            audio: window,
            lastAudioSample: 0,
            paddingMode: .center,
            expectedFrameCount: totalFrames
        ).mel

        // NeMo `get_seq_len` (center padding, stft_pad_amount=0): floor(L/hop),
        // NO +1 — the final tensor frame stays normalized to 0.
        let validFrames = min(validCount / hopLength, totalFrames)
        normalizePerFeature(&flat, frames: totalFrames, validFrames: validFrames)

        let melArray = try MLMultiArray(
            shape: [1, NSNumber(value: nMels), NSNumber(value: totalFrames)], dataType: .float32)
        melArray.withUnsafeMutableBufferPointer(ofType: Float.self) { ptr, _ in
            for t in 0..<totalFrames {
                let base = t * nMels
                for m in 0..<nMels {
                    ptr[m * totalFrames + t] = flat[base + m]
                }
            }
        }

        let lengthArray = try MLMultiArray(shape: [1], dataType: .int32)
        lengthArray[0] = NSNumber(value: validFrames)
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
