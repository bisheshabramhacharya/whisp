import Foundation

/// Accumulates one take's 16 kHz mono samples, appended by the realtime tap
/// thread and read back on the caller's thread at stop.
///
/// `finish()`'s bounded drain is why this is its own type: at key-up there is
/// always one IO buffer in flight holding the end of the last word. Waiting
/// for it — capped at `tailDrainCap`, ~30 ms — keeps that word without paying
/// a full IO quantum (~10-20 ms on M-series, ~100 ms on VMs). Extracted from
/// `MicRecorder` so the drain is testable without audio hardware.
public final class CaptureBuffer {
    /// 16 kHz capacity: `idle` keeps launch light; `take` covers the app's
    /// 10-minute cap (`DictationController.maximumDuration`) so the realtime
    /// tap thread never grows the array mid-recording — a realloc + copy
    /// there can drop buffers and click into the take.
    public static let idleReserve = 16_000 * 120 // ~7.7 MB
    public static let takeReserve = 16_000 * 600 // ~38.4 MB

    /// Longest `finish()` waits for the in-flight IO buffer after key-up.
    /// Covers a full quantum on real hardware; a dead or removed input just
    /// pays the cap once.
    public static let tailDrainCap: TimeInterval = 0.030

    /// One condition guards all capture state: the drain waits on it, and the
    /// `deliveredBuffers` serial means a signal can only ever be claimed by
    /// the drain that observed it — no stale wakeups between takes.
    private let cond = NSCondition()
    private var samples: [Float] = []
    private var recording = false
    /// A `finish()` call is waiting on one more appended buffer.
    private var draining = false
    /// Number of buffers appended while a drain was pending.
    private var deliveredBuffers = 0

    public init() {
        samples.reserveCapacity(Self.idleReserve)
    }

    /// Whether a take is live (begin() called, finish()/discard() not yet).
    /// Read for engine-lifecycle decisions while the take drains.
    public var isRecording: Bool {
        cond.lock()
        defer { cond.unlock() }
        return recording
    }

    /// Reserved capacity of the sample array — introspection for tests.
    public var reservedCapacity: Int {
        cond.lock()
        defer { cond.unlock() }
        return samples.capacity
    }

    /// Grows the array to full-take size on the caller's thread — `begin()`
    /// already does this; exposed so callers can pre-warm before a take.
    public func reserveTake() {
        cond.lock()
        samples.reserveCapacity(Self.takeReserve)
        cond.unlock()
    }

    /// Begins a take: clears prior audio and grows to full-take size on the
    /// caller's thread so the realtime tap thread never reallocates mid-take.
    public func begin() {
        cond.lock()
        samples.reserveCapacity(Self.takeReserve)
        samples.removeAll(keepingCapacity: true)
        recording = true
        cond.unlock()
    }

    /// Realtime-thread append. Returns false when no take is live — buffers
    /// arriving after finish()/discard() (or before begin()) are dropped.
    /// While a drain is pending, bumps the serial and signals so the wait
    /// ends on this buffer instead of the full cap.
    public func append(_ chunk: UnsafeBufferPointer<Float>) -> Bool {
        cond.lock()
        guard recording else {
            cond.unlock()
            return false
        }
        samples.append(contentsOf: chunk)
        if draining {
            deliveredBuffers += 1
            cond.broadcast()
        }
        cond.unlock()
        return true
    }

    /// Copy of the audio captured so far, from sample `start` on — empty when
    /// not recording. Drives the live-decode loop.
    public func tail(from start: Int) -> [Float] {
        cond.lock()
        defer { cond.unlock() }
        guard recording, start < samples.count else { return [] }
        return Array(samples[start...])
    }

    /// Ends the take and returns everything captured. When a take is live,
    /// first waits — up to `drainCap` — for the IO buffer in flight at call
    /// time: it holds the end of the last word, and dropping it truncates
    /// speech the user did say. Never a fixed sleep: returns as soon as the
    /// next appended buffer lands. `drained` reports whether that buffer
    /// arrived inside the window.
    public func finish(drainCap: TimeInterval = CaptureBuffer.tailDrainCap)
        -> (samples: [Float], drained: Bool)
    {
        cond.lock()
        let wasRecording = recording
        draining = wasRecording
        let serialAtStart = deliveredBuffers
        if wasRecording {
            let deadline = Date().addingTimeInterval(drainCap)
            while draining && deliveredBuffers == serialAtStart {
                if !cond.wait(until: deadline) { break } // timed out
            }
        }
        let drained = deliveredBuffers > serialAtStart
        draining = false
        recording = false
        // Move the array out instead of copying: a fresh `samples` makes the
        // caller's array the sole owner (removeAll would copy under COW).
        let captured = samples
        samples = []
        samples.reserveCapacity(Self.idleReserve)
        cond.unlock()
        return (captured, drained)
    }

    /// Abandons the take and drops captured audio (the cancel path). Wakes a
    /// pending finish() so a cancel never waits out the drain cap.
    public func discard() {
        cond.lock()
        recording = false
        samples.removeAll(keepingCapacity: true)
        if samples.capacity > Self.idleReserve {
            samples = []
            samples.reserveCapacity(Self.idleReserve)
        }
        draining = false
        cond.broadcast()
        cond.unlock()
    }
}
