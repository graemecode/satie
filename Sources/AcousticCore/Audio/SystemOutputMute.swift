#if os(macOS)
import CoreAudio
import Foundation

/// Instant, zero-permission Core Audio default output device mute control.
/// Gives the user a guaranteed 1-click silence toggle even for apps (Chrome/YouTube)
/// that do not expose AppleScript transport controls without Accessibility permission.
public enum SystemOutputMute {
    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    public static var isMuted: Bool {
        guard let dev = defaultOutputDeviceID() else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        // Fallback: check scalar volume == 0
        var vol: Float32 = 1.0
        var vSize = UInt32(MemoryLayout<Float32>.size)
        addr.mSelector = kAudioDevicePropertyVolumeScalar
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectGetPropertyData(dev, &addr, 0, nil, &vSize, &vol) == noErr {
            return vol <= 0.001
        }
        return false
    }

    @discardableResult
    public static func setMuted(_ mute: Bool) -> Bool {
        guard let dev = defaultOutputDeviceID() else { return false }
        var val: UInt32 = mute ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(dev, &addr),
           AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
           settable.boolValue {
            let status = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &val)
            if status == noErr { return true }
        }
        // Fallback to channel 1 & 2 mute properties on USB DACs/interfaces
        var anySet = false
        for ch: UInt32 in [1, 2] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            var chSettable: DarwinBoolean = false
            if AudioObjectHasProperty(dev, &chAddr),
               AudioObjectIsPropertySettable(dev, &chAddr, &chSettable) == noErr,
               chSettable.boolValue {
                if AudioObjectSetPropertyData(dev, &chAddr, 0, nil, size, &val) == noErr {
                    anySet = true
                }
            }
        }
        return anySet
    }

    @discardableResult
    public static func toggle() -> Bool {
        let next = !isMuted
        _ = setMuted(next)
        return isMuted
    }
}
#endif
