import Accelerate
@preconcurrency import CoreML
import Foundation
import WhispKernels

/// The decoder (2-layer LSTM) and joint network of Parakeet Unified, run with
/// Accelerate instead of Core ML.
///
/// Both networks are tiny, and a greedy decode calls them a few hundred times
/// per window. Through Core ML each call costs 0.3-0.8 ms, nearly all of it
/// per-call overhead (feature providers, MLMultiArray allocation, and a softmax
/// plus top-64 sort the decode never reads). The same math done in place is a
/// few matrix-vector products.
///
/// The LSTM is the heavy part: three 2560x640 products per step. As floats
/// those matrices are 20 MB, more than the M1's 12 MB L2 cache, so every step
/// re-read them from RAM (0.47 ms). They stay in the model's own half-float
/// form here (10 MB, fits) and `whisp_gemv_f16` widens them as it reads, which
/// gives the same numbers as a float copy. Products that do not depend on each
/// other run on separate cores.
///
/// Weights are read straight from the installed `.mlmodelc` bundles, so there
/// is nothing extra to download. If a bundle does not look exactly as expected
/// `init` throws and the caller keeps using Core ML.
final class NativeRnnt {
    let hidden: Int
    let encoderDim: Int
    let vocab: Int  // includes blank

    private let embed: [Float]          // [vocab, hidden]
    private let layers: [Lstm]
    private let encW: [Float], encB: [Float]    // [hidden, encoderDim]
    private let predW: [Float], predB: [Float]  // [hidden, hidden]
    private let outW: [Float], outB: [Float]    // [vocab, hidden]

    private struct Lstm {
        let wih: [UInt16]  // [4H, H] half floats, gate order input, forget, output, cell
        let whh: [UInt16]  // [4H, H] half floats
        let bias: [Float]  // [4H]
    }

    /// Decoder state: `h` and `c` hold both layers back to back.
    struct State {
        var h: [Float]
        var c: [Float]
    }

    /// What one decoder step produces: the joint's decoder input (already
    /// projected) and the state to adopt if the step's token is kept.
    struct Step {
        var projected: [Float]
        var state: State
    }

    /// Layer-0 input product per token (`W_ih * embed[token] + bias`): the
    /// input is a table row, so it is the same every time a token repeats.
    private var inputCache: [Int32: [Float]] = [:]
    private var scratch: [Float]
    private var logits: [Float]
    private var mixed: [Float]

    init(decoderBundle: URL, jointBundle: URL) throws {
        let dec = try MilWeights(bundle: decoderBundle)
        let joint = try MilWeights(bundle: jointBundle)

        let (embed, embedShape) = try dec.tensor("module_prediction_embed_weight_to_fp16")
        guard embedShape.count == 2 else { throw NativeRnntError.shape("embed") }
        let hidden = embedShape[1]
        self.embed = embed
        self.hidden = hidden

        var layers: [Lstm] = []
        for op in dec.lstmOps() {
            let (wih, wihShape) = try dec.halves(op.weightIH)
            let (whh, whhShape) = try dec.halves(op.weightHH)
            let (bias, biasShape) = try dec.tensor(op.bias)
            guard wihShape == [4 * hidden, hidden], whhShape == [4 * hidden, hidden],
                  biasShape == [4 * hidden]
            else { throw NativeRnntError.shape("lstm") }
            layers.append(Lstm(wih: wih, whh: whh, bias: bias))
        }
        guard layers.count == 2 else { throw NativeRnntError.shape("lstm layer count") }
        self.layers = layers

        let (encW, encShape) = try joint.tensor("joint_module_enc_weight_to_fp16")
        let (encB, _) = try joint.tensor("joint_module_enc_bias_to_fp16")
        let (predW, predShape) = try joint.tensor("joint_module_pred_weight_to_fp16")
        let (predB, _) = try joint.tensor("joint_module_pred_bias_to_fp16")
        let (outW, outShape) = try joint.tensor("joint_module_joint_net_2_weight_to_fp16")
        let (outB, _) = try joint.tensor("joint_module_joint_net_2_bias_to_fp16")
        guard encShape.count == 2, encShape[0] == hidden, predShape == [hidden, hidden],
              outShape.count == 2, outShape[1] == hidden, embedShape[0] == outShape[0],
              encB.count == hidden, predB.count == hidden, outB.count == outShape[0]
        else { throw NativeRnntError.shape("joint") }
        self.encW = encW; self.encB = encB
        self.predW = predW; self.predB = predB
        self.outW = outW; self.outB = outB
        encoderDim = encShape[1]
        vocab = outShape[0]

        scratch = [Float](repeating: 0, count: 4 * hidden)
        logits = [Float](repeating: 0, count: vocab)
        mixed = [Float](repeating: 0, count: hidden)
    }

    func zeroState() -> State {
        State(h: [Float](repeating: 0, count: 2 * hidden), c: [Float](repeating: 0, count: 2 * hidden))
    }

    // MARK: - Decoder

    /// Threads per matrix product. Four performance cores on every M-series
    /// chip Whisp runs on; the two recurrent products run side by side.
    private static let wide: Int32 = 4

    /// One prediction-network step for `token` from `state`.
    func decoderStep(token: Int32, state: State) -> Step {
        let H = hidden
        let rows = Int32(4 * H), cols = Int32(H)
        var next = state
        if inputCache[token] == nil {
            var product = layers[0].bias
            embed.withUnsafeBufferPointer { e in
                whisp_gemv_f16(layers[0].wih, rows, cols, e.baseAddress! + Int(token) * H, &product, Self.wide)
            }
            inputCache[token] = product
        }
        var gates0 = inputCache[token]!
        var gates1 = layers[1].bias

        // Both recurrent products read only the old state, so they run together.
        state.h.withUnsafeBufferPointer { h in
            gates0.withUnsafeMutableBufferPointer { g0 in
                gates1.withUnsafeMutableBufferPointer { g1 in
                    whisp_gemv2_f16(
                        layers[0].whh, h.baseAddress!, g0.baseAddress!,
                        layers[1].whh, h.baseAddress! + H, g1.baseAddress!,
                        rows, cols, Self.wide / 2)
                }
            }
        }
        lstmCell(layer: 0, gates: &gates0, state: &next)

        // Layer 1's input is layer 0's new h.
        next.h.withUnsafeBufferPointer { h in
            whisp_gemv_f16(layers[1].wih, rows, cols, h.baseAddress!, &gates1, Self.wide)
        }
        lstmCell(layer: 1, gates: &gates1, state: &next)

        // The joint only ever sees the decoder output through its own linear
        // layer, so project it once here instead of on every joint step.
        var projected = predB
        next.h.withUnsafeBufferPointer { h in
            cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(H), Int32(H), 1, predW, Int32(H),
                        h.baseAddress! + H, 1, 1, &projected, 1)
        }
        return Step(projected: projected, state: next)
    }

    /// Turns `gates` (input product + recurrent product + bias) into the
    /// layer's new h and c, in place in `state`.
    private func lstmCell(layer: Int, gates: inout [Float], state: inout State) {
        let H = hidden
        let base = layer * H
        // Gates: [input, forget, output, cell]. Sigmoid on the first three.
        var n3 = Int32(3 * H)
        var nH = Int32(H)
        gates.withUnsafeMutableBufferPointer { g in
            scratch.withUnsafeMutableBufferPointer { s in
                var minusOne: Float = -1
                var one: Float = 1
                vDSP_vsmul(g.baseAddress!, 1, &minusOne, s.baseAddress!, 1, vDSP_Length(3 * H))
                vvexpf(s.baseAddress!, s.baseAddress!, &n3)
                vDSP_vsadd(s.baseAddress!, 1, &one, s.baseAddress!, 1, vDSP_Length(3 * H))
                vvrecf(g.baseAddress!, s.baseAddress!, &n3)
                vvtanhf(g.baseAddress! + 3 * H, g.baseAddress! + 3 * H, &nH)
            }
            let i = g.baseAddress!, f = g.baseAddress! + H, o = g.baseAddress! + 2 * H, z = g.baseAddress! + 3 * H
            state.c.withUnsafeMutableBufferPointer { c in
                let cell = c.baseAddress! + base
                // c = f * c + i * z
                vDSP_vmul(f, 1, cell, 1, cell, 1, vDSP_Length(H))
                vDSP_vma(i, 1, z, 1, cell, 1, cell, 1, vDSP_Length(H))
                state.h.withUnsafeMutableBufferPointer { h in
                    let out = h.baseAddress! + base
                    // h = o * tanh(c)
                    vvtanhf(out, cell, &nH)
                    vDSP_vmul(o, 1, out, 1, out, 1, vDSP_Length(H))
                }
            }
        }
    }

    // MARK: - Joint

    /// The joint's encoder-side linear layer for every frame in `frames` at
    /// once: `[frames.count, hidden]`, row per frame.
    func projectEncoder(_ encoded: MLMultiArray, frames: Range<Int>) -> [Float] {
        let T = frames.count
        let D = encoderDim
        guard T > 0 else { return [] }
        let src = encoded.dataPointer.bindMemory(to: Float.self, capacity: encoded.count)
        let stride1 = encoded.strides[1].intValue
        let stride2 = encoded.strides[2].intValue
        var rows = [Float](repeating: 0, count: T * D)
        rows.withUnsafeMutableBufferPointer { dst in
            for c in 0..<D {
                cblas_scopy(Int32(T), src + c * stride1 + frames.lowerBound * stride2, Int32(stride2),
                            dst.baseAddress! + c, Int32(D))
            }
        }
        var out = [Float](repeating: 0, count: T * hidden)
        cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasTrans, Int32(T), Int32(hidden), Int32(D), 1,
                    rows, Int32(D), encW, Int32(D), 0, &out, Int32(hidden))
        out.withUnsafeMutableBufferPointer { o in
            for t in 0..<T {
                vDSP_vadd(o.baseAddress! + t * hidden, 1, encB, 1, o.baseAddress! + t * hidden, 1,
                          vDSP_Length(hidden))
            }
        }
        return out
    }

    /// Best token for one (frame, decoder step) pair. `encoderRow` points at
    /// one row of `projectEncoder`'s result.
    func bestToken(encoderRow: UnsafePointer<Float>, decoder: [Float]) -> Int32 {
        score(encoderRow: encoderRow, decoder: decoder)
        var best: Float = 0
        var index: vDSP_Length = 0
        vDSP_maxvi(logits, 1, &best, &index, vDSP_Length(vocab))
        return Int32(index)
    }

    /// Every token's score for one pair. Only the load-time check reads these.
    func scores(encoderRow: UnsafePointer<Float>, decoder: [Float]) -> [Float] {
        score(encoderRow: encoderRow, decoder: decoder)
        return logits
    }

    private func score(encoderRow: UnsafePointer<Float>, decoder: [Float]) {
        let H = hidden
        var zero: Float = 0
        vDSP_vadd(encoderRow, 1, decoder, 1, &mixed, 1, vDSP_Length(H))
        vDSP_vthres(mixed, 1, &zero, &mixed, 1, vDSP_Length(H))  // ReLU
        logits = outB
        cblas_sgemv(CblasRowMajor, CblasNoTrans, Int32(vocab), Int32(H), 1, outW, Int32(H),
                    mixed, 1, 1, &logits, 1)
    }
}

enum NativeRnntError: Error {
    case missing(String)
    case shape(String)
    case blob(String)
}

/// Reads half-float constants out of a compiled ML Program bundle: `model.mil`
/// names each tensor, its shape and its offset into `weights/weight.bin`.
private struct MilWeights {
    private let lines: [Substring]
    private let blob: Data

    init(bundle: URL) throws {
        let text = try String(contentsOf: bundle.appendingPathComponent("model.mil"), encoding: .utf8)
        lines = text.split(separator: "\n")
        blob = try Data(contentsOf: bundle.appendingPathComponent("weights/weight.bin"), options: .mappedIfSafe)
    }

    /// Where a named half-float tensor lives in the blob.
    private func locate(_ name: String) throws -> (offset: Int, count: Int, shape: [Int]) {
        guard let line = lines.first(where: { $0.contains("> \(name) = const()") }),
              let shapeMatch = line.firstMatch(of: #/tensor<fp16, \[([0-9, ]+)\]>/#),
              let offsetMatch = line.firstMatch(of: #/offset = tensor<uint64, \[\]>\((\d+)\)/#),
              let header = Int(offsetMatch.1)
        else { throw NativeRnntError.missing(name) }
        let shape = shapeMatch.1.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let count = shape.reduce(1, *)
        // Blob header: sentinel (u32), dtype (u32), byte size (u64), data offset (u64).
        guard header >= 0, header + 64 <= blob.count else { throw NativeRnntError.blob(name) }
        let (sentinel, bytes, dataOffset): (UInt32, UInt64, UInt64) = blob.withUnsafeBytes { raw in
            (raw.loadUnaligned(fromByteOffset: header, as: UInt32.self),
             raw.loadUnaligned(fromByteOffset: header + 8, as: UInt64.self),
             raw.loadUnaligned(fromByteOffset: header + 16, as: UInt64.self))
        }
        guard sentinel == 0xDEAD_BEEF, count > 0, bytes == UInt64(count * 2),
              dataOffset <= UInt64(blob.count), UInt64(blob.count) - dataOffset >= bytes
        else { throw NativeRnntError.blob(name) }
        return (Int(dataOffset), count, shape)
    }

    /// The tensor as stored: raw half floats.
    func halves(_ name: String) throws -> (values: [UInt16], shape: [Int]) {
        let (offset, count, shape) = try locate(name)
        var values = [UInt16](repeating: 0, count: count)
        values.withUnsafeMutableBytes { dst in
            blob.withUnsafeBytes { raw in
                dst.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[offset..<offset + count * 2]))
            }
        }
        return (values, shape)
    }

    /// The tensor widened to single precision.
    func tensor(_ name: String) throws -> (values: [Float], shape: [Int]) {
        let (offset, count, shape) = try locate(name)
        var values = [Float](repeating: 0, count: count)
        blob.withUnsafeBytes { raw in
            values.withUnsafeMutableBufferPointer { dst in
                var source = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: raw.baseAddress! + offset),
                    height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                var dest = vImage_Buffer(
                    data: dst.baseAddress!, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                vImageConvert_Planar16FtoPlanarF(&source, &dest, 0)
            }
        }
        return (values, shape)
    }

    /// The tensors each `lstm` op uses, in the order the layers run.
    func lstmOps() -> [(bias: String, weightHH: String, weightIH: String)] {
        lines.compactMap { line in
            guard line.contains("= lstm("),
                  let bias = line.firstMatch(of: #/bias = ([A-Za-z0-9_]+)/#),
                  let hh = line.firstMatch(of: #/weight_hh = ([A-Za-z0-9_]+)/#),
                  let ih = line.firstMatch(of: #/weight_ih = ([A-Za-z0-9_]+)/#)
            else { return nil }
            return (String(bias.1), String(hh.1), String(ih.1))
        }
    }
}
