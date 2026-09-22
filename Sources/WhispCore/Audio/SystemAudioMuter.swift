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
public final class SystemAudioMuter {

    private enum Method {
        /// Device supported a real mute switch; `wasMuted` is what we found.
        case mute(wasMuted: Bool)
        /// Device only had volume scalars; we saved `(element, previousVolume)` pairs.
        case volumes([(element: AudioObjectPropertyElement, previous: Float32)])
    }

    private struct SavedState {
        let deviceID: AudioDeviceID
        let method: Method
    }

    private var savedState: SavedState?

    public init() {}

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
            savedState = SavedState(deviceID: device, method: .mute(wasMuted: wasMuted != 0))
            return
        }

        // Volume-scalar fallback: silence every element that has a volume property.
        var savedVolumes: [(element: AudioObjectPropertyElement, previous: Float32)] = []
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
            savedVolumes.append((element, previous))
        }
        if !savedVolumes.isEmpty {
            savedState = SavedState(deviceID: device, method: .volumes(savedVolumes))
        }
    }

    public func restore() {
        guard let state = savedState else { return } // idempotent / nothing to do
        savedState = nil

        switch state.method {
        case .mute(let wasMuted):
            var address = Self.address(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
            var value: UInt32 = wasMuted ? 1 : 0
            AudioObjectSetPropertyData(state.deviceID, &address, 0, nil,
                                       UInt32(MemoryLayout<UInt32>.size), &value)
        case .volumes(let savedVolumes):
            for (element, previous) in savedVolumes {
                var address = Self.address(kAudioDevicePropertyVolumeScalar, element: element)
                var value = previous
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
