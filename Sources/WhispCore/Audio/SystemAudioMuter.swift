import CoreAudio
import Foundation

/// Mutes the default output device while dictating (so TTS/system sounds don't leak
/// into the mic) and restores exactly what it changed afterwards.
///
/// Strategy:
///  1. Prefer `kAudioDevicePropertyMute` on the master output element — remembers the
///     previous mute state and puts it back.
///  2. If the device has no mute property, fall back to `kAudioDevicePropertyVolumeScalar`
///     on every element that supports it (main element, then channels 1/2): save each
///     previous volume, set 0, restore on `restore()`.
///
/// Both `mute()` and `restore()` are idempotent, and `restore()` only ever writes to
/// the device/elements/properties that `mute()` touched.
///
/// `mute()` also leaves a JSON sentinel on disk recording what it changed; `restore()`
/// deletes it. If Whisp crashes or is force-quit while muted, the sentinel survives
/// and `repairAfterCrash()` (called at launch) puts the device back — otherwise the
/// user's audio would stay muted forever.
public final class SystemAudioMuter {

    /// One silenced element's previous volume (the volume-scalar path).
    private struct SavedVolume: Codable {
        let element: AudioObjectPropertyElement
        let previous: Float32
    }

    private enum Method: Codable {
        /// Device supported a real mute switch; `wasMuted` is what we found.
        case mute(wasMuted: Bool)
        /// Device only had volume scalars; we saved each element's previous volume.
        case volumes([SavedVolume])
    }

    private struct SavedState: Codable {
        let deviceID: AudioDeviceID
        let method: Method
    }

    private var savedState: SavedState?
    /// Where the "muted state" record lives between mute() and restore().
    private let sentinelURL: URL

    public init(sentinelURL: URL = AppPaths.root.appendingPathComponent("muted-device.json")) {
        self.sentinelURL = sentinelURL
    }

    public func mute() {
        guard savedState == nil else { return } // idempotent
        guard let device = Self.defaultOutputDevice() else { return }

        var muteAddress = Self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(device, &muteAddress) {
            var wasMuted: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &wasMuted) == noErr else {
                return
            }
            var muted: UInt32 = 1
            guard AudioObjectSetPropertyData(device, &muteAddress, 0, nil, size, &muted) == noErr else {
                return
            }
            didSave(SavedState(deviceID: device, method: .mute(wasMuted: wasMuted != 0)))
            return
        }

        // Volume-scalar fallback: silence every element that has a volume property.
        var savedVolumes: [SavedVolume] = []
        for element: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            var volumeAddress = Self.address(kAudioDevicePropertyVolumeScalar, element: element)
            guard AudioObjectHasProperty(device, &volumeAddress) else { continue }
            var previous: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectGetPropertyData(device, &volumeAddress, 0, nil, &size, &previous) == noErr else {
                continue
            }
            var zero: Float32 = 0
            guard AudioObjectSetPropertyData(device, &volumeAddress, 0, nil, size, &zero) == noErr else {
                continue
            }
            savedVolumes.append(SavedVolume(element: element, previous: previous))
        }
        if !savedVolumes.isEmpty {
            didSave(SavedState(deviceID: device, method: .volumes(savedVolumes)))
        }
    }

    public func restore() {
        guard let state = savedState else { return } // idempotent / nothing to do
        savedState = nil
        Self.removeSentinel(at: sentinelURL)
        Self.apply(state)
    }

    /// Repairs a device left muted by a crash or force-quit: reads the sentinel
    /// `mute()` left behind, puts the device back, removes the file. Call once at
    /// launch. Best-effort: a missing/corrupt file or a dead device ID is a no-op.
    public static func repairAfterCrash(sentinelURL: URL = AppPaths.root.appendingPathComponent("muted-device.json")) {
        guard let data = try? Data(contentsOf: sentinelURL) else { return } // nothing to repair
        let state = try? JSONDecoder().decode(SavedState.self, from: data)
        removeSentinel(at: sentinelURL)
        if let state { apply(state) }
    }

    private func didSave(_ state: SavedState) {
        savedState = state
        Self.writeSentinel(state, to: sentinelURL)
    }

    private static func writeSentinel(_ state: SavedState, to url: URL) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static func removeSentinel(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Writes back whatever `mute()` recorded. Shared by `restore()` (this instance)
    /// and `repairAfterCrash()` (sentinel from a dead previous run).
    private static func apply(_ state: SavedState) {
        switch state.method {
        case .mute(let wasMuted):
            var address = Self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
            var value: UInt32 = wasMuted ? 1 : 0
            AudioObjectSetPropertyData(state.deviceID, &address, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &value)
        case .volumes(let savedVolumes):
            for saved in savedVolumes {
                var address = Self.address(kAudioDevicePropertyVolumeScalar, element: saved.element)
                var value = saved.previous
                AudioObjectSetPropertyData(state.deviceID, &address, 0, nil,
                                           UInt32(MemoryLayout<Float32>.size), &value)
            }
        }
    }

    // MARK: - CoreAudio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                                element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }
}
