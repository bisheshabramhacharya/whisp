import Foundation
import WhispCore

// --mic: drives the real MicRecorder the way the app does (start at key down,
// stop at key up) and reports what the capture path costs at release.

func runMicProbe(takes: Int) {
    let recorder = MicRecorder()
    var drains: [Double] = []
    var gaps: [Double] = []
    print("take   held    audio   short  first  arrive-gap(p50/max)  stop-wait")
    for take in 1...takes {
        let holdMs = [700.0, 1300, 2100, 900, 3200][take % 5] + Double.random(in: 0..<100)
        let t0 = DispatchTime.now().uptimeNanoseconds
        do { try recorder.start() } catch {
            print("mic start failed: \(error.localizedDescription)")
            return
        }
        // Watch the take grow: the gap between arrivals is how stale the live
        // loop's view of the audio can be.
        var have = 0
        var lastArrival = 0.0
        var firstMs = -1.0
        var takeGaps: [Double] = []
        while true {
            let now = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
            if now >= holdMs { break }
            let added = recorder.samples(from: have).count
            if added > 0 {
                have += added
                if firstMs < 0 { firstMs = now } else { takeGaps.append(now - lastArrival) }
                lastArrival = now
            }
            usleep(500)
        }
        let s0 = DispatchTime.now().uptimeNanoseconds
        let samples = recorder.stop()
        let stopMs = Double(DispatchTime.now().uptimeNanoseconds - s0) / 1e6
        let heldMs = Double(s0 - t0) / 1e6
        let audioMs = Double(samples.count) / 16
        takeGaps.sort()
        let p50 = takeGaps.isEmpty ? 0 : takeGaps[takeGaps.count / 2]
        let worst = takeGaps.last ?? 0
        drains.append(stopMs)
        gaps += takeGaps
        print(String(format: "%3d  %5.0fms %6.0fms %5.0fms %4.0fms   %5.1f / %5.1f ms      %5.1f ms",
                     take, heldMs, audioMs, heldMs - audioMs, firstMs, p50, worst, stopMs))
        // Past the 0.5 s warm window on odd takes, inside it on even ones.
        usleep(take % 2 == 0 ? 200_000 : 900_000)
    }
    drains.sort()
    gaps.sort()
    guard !drains.isEmpty, !gaps.isEmpty else { return }
    print(String(format: "stop wait: p50 %.1f ms, max %.1f ms   arrival gap: p50 %.1f ms, p99 %.1f ms",
                 drains[drains.count / 2], drains.last!, gaps[gaps.count / 2], gaps[gaps.count * 99 / 100]))
}
