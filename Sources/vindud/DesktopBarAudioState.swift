import CoreAudio
import Foundation

enum DesktopBarAudioState {
    static func defaultOutputDeviceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func currentOutputDevice() -> AudioDeviceID? {
        var address = defaultOutputDeviceAddress()
        var device = AudioDeviceID()
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else {
            return nil
        }
        return device
    }

    static func outputValueAddresses(for device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        [kAudioDevicePropertyMute, kAudioDevicePropertyVolumeScalar].compactMap {
            outputAddress(device: device, selector: $0)
        }
    }

    static func currentVolumeText() -> String? {
        guard let device = currentOutputDevice() else { return nil }
        if let muted = outputMute(for: device), muted {
            return "muted"
        }
        guard let volume = outputVolume(for: device) else { return nil }
        return "\(Int((volume * 100).rounded()))%"
    }

    private static func outputAddress(device: AudioDeviceID,
                                      selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(device, &address) {
            return address
        }
        address.mElement = 1
        return AudioObjectHasProperty(device, &address) ? address : nil
    }

    private static func outputVolume(for device: AudioDeviceID) -> Float32? {
        guard var address = outputAddress(device: device,
                                          selector: kAudioDevicePropertyVolumeScalar) else {
            return nil
        }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr else {
            return nil
        }
        return volume
    }

    private static func outputMute(for device: AudioDeviceID) -> Bool? {
        guard var address = outputAddress(device: device,
                                          selector: kAudioDevicePropertyMute) else {
            return nil
        }
        var muted = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &muted) == noErr else {
            return nil
        }
        return muted != 0
    }
}
