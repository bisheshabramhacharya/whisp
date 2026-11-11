import AVFoundation
import Accelerate
import Foundation
import os

/// Carries audio from the realtime IO thread to the converter thread.
///
/// The IO thread calls `write` once per hardware quantum (512 frames, ~10.7 ms
/// on the built-in mic); the converter thread calls `read`. Storage is
/// allocated once, so the IO thread never allocates, and the lock is only ever
/// held for one memcpy.
public final class AudioRing {
    public let channels: Int
    /// Frames per channel the ring can hold.
    public let capacity: Int

    private let storage: UnsafeMutablePointer<Float>
    private let lock = OSAllocatedUnfairLock()
    private var readIndex = 0
    private var count = 0
    private var written: UInt64 = 0
    private var lost = 0

    public init(channels: Int, capacity: Int) {
        self.channels = max(1, channels)
        self.capacity = max(1, capacity)
        storage = .allocate(capacity: self.channels * self.capacity)
        storage.initialize(repeating: 0, count: self.channels * self.capacity)
    }

    deinit { storage.deallocate() }

    /// Number of `write` calls so far. A reader that has consumed the ring up to
    /// count N has every quantum the hardware delivered before N.
    public var quanta: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    /// Frames dropped because the reader fell a whole ring behind.
    public var droppedFrames: Int {
        lock.lock()
        defer { lock.unlock() }
        return lost
    }

    /// Realtime-thread write of one IO quantum. Accepts the engine's standard
    /// layout (one buffer per channel) and a single interleaved buffer.
    public func write(_ list: UnsafePointer<AudioBufferList>, frames: Int) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        lock.lock()
        defer { lock.unlock() }
        written &+= 1
        guard frames > 0, buffers.count > 0 else { return }
        let room = capacity - count
        guard frames <= room else {
            lost += frames
            return
        }
        let writeIndex = (readIndex + count) % capacity
        let first = min(frames, capacity - writeIndex)
        let interleaved = buffers.count == 1 && Int(buffers[0].mNumberChannels) > 1
        for channel in 0..<channels {
            let lane = storage + channel * capacity
            if interleaved {
                let stride = Int(buffers[0].mNumberChannels)
                guard let source = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                      Int(buffers[0].mDataByteSize) >= frames * stride * MemoryLayout<Float>.size else { continue }
                let offset = min(channel, stride - 1)
                for frame in 0..<frames {
                    lane[(writeIndex + frame) % capacity] = source[frame * stride + offset]
                }
            } else {
                // Fewer hardware buffers than channels: repeat the last one.
                let buffer = buffers[min(channel, buffers.count - 1)]
                guard let source = buffer.mData?.assumingMemoryBound(to: Float.self),
                      Int(buffer.mDataByteSize) >= frames * MemoryLayout<Float>.size else { continue }
                (lane + writeIndex).update(from: source, count: first)
                if first < frames { lane.update(from: source + first, count: frames - first) }
            }
        }
        count += frames
    }

    /// Moves up to `buffer.frameCapacity` frames into `buffer`. Returns the
    /// frames moved, the quantum count at this read, and whether the ring is
    /// now empty (so every quantum up to that count has been handed over).
    public func read(into buffer: AVAudioPCMBuffer) -> (frames: Int, quanta: UInt64, empty: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let frames = min(count, Int(buffer.frameCapacity))
        guard frames > 0, let lanes = buffer.floatChannelData else {
            buffer.frameLength = 0
            return (0, written, count == 0)
        }
        let first = min(frames, capacity - readIndex)
        for channel in 0..<min(channels, Int(buffer.format.channelCount)) {
            let lane = storage + channel * capacity
            lanes[channel].update(from: lane + readIndex, count: first)
            if first < frames { (lanes[channel] + first).update(from: lane, count: frames - first) }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        readIndex = (readIndex + frames) % capacity
        count -= frames
        return (frames, written, count == 0)
    }
}

/// Everything capture needs for one input format: the ring the IO thread fills
/// and the converter that turns it into 16 kHz mono on the converter thread.
/// Rebuilt whenever the input device (and so its format) changes.
public final class CapturePipeline {
    public let ring: AudioRing
    public let inputFormat: AVAudioFormat

    private let converter: AVAudioConverter
    private let input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    /// Frames converted per pass: several quanta, so a converter thread that
    /// fell behind catches up fast. Never above 4096: the converter takes input
    /// in 4096-frame blocks and holds back the rest of a bigger buffer until
    /// more arrives (a 4800-frame buffer left up to 85 ms of the newest audio
    /// stuck inside it). At 4096 or less it returns everything it was given.
    private static let passFrames: AVAudioFrameCount = 4096

    public init?(inputFormat: AVAudioFormat, outputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: Self.passFrames)
        else { return nil }
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let outFrames = AVAudioFrameCount(Double(Self.passFrames) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outFrames) else { return nil }
        self.inputFormat = inputFormat
        self.converter = converter
        self.input = input
        self.output = output
        // Two seconds of headroom: the converter thread normally empties the
        // ring within a millisecond of each quantum.
        ring = AudioRing(channels: Int(inputFormat.channelCount), capacity: Int(inputFormat.sampleRate * 2))
    }

    /// Converts everything waiting in the ring, handing each 16 kHz block to
    /// `emit` (clipped to [-1, 1], valid only during the call). Returns the
    /// ring's quantum count once it was seen empty. Converter thread only.
    @discardableResult
    public func drain(_ emit: (UnsafeBufferPointer<Float>) -> Void) -> UInt64 {
        while true {
            let (frames, quanta, _) = ring.read(into: input)
            guard frames > 0 else { return quanta }
            var fed = false
            var error: NSError?
            output.frameLength = 0
            let source = input
            let status = converter.convert(to: output, error: &error) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return source
            }
            guard status != .error, output.frameLength > 0, let data = output.floatChannelData else { continue }
            let count = Int(output.frameLength)
            // Resampling can overshoot beyond [-1, 1]; the ASR contract requires that range.
            var lo: Float = -1, hi: Float = 1
            vDSP_vclip(data[0], 1, &lo, &hi, data[0], 1, vDSP_Length(count))
            emit(UnsafeBufferPointer(start: data[0], count: count))
        }
    }
}
