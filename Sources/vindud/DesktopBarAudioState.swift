import CoreAudio
import Foundation

struct DesktopBarVolumeInfo: Equatable {
    let text: String
    let usesHeadset: Bool
}

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

    static func outputChangeAddresses(for device: AudioDeviceID) -> [AudioObjectPropertyAddress] {
        [
            kAudioDevicePropertyMute,
            kAudioDevicePropertyVolumeScalar,
            kAudioDevicePropertyDataSource,
            kAudioDevicePropertyDataSources,
        ].compactMap {
            outputAddress(device: device, selector: $0)
        }
    }

    static func currentVolumeInfo() -> DesktopBarVolumeInfo? {
        guard let device = currentOutputDevice() else { return nil }
        let text: String
        if let muted = outputMute(for: device), muted {
            text = "muted"
        } else {
            guard let volume = outputVolume(for: device) else { return nil }
            text = "\(Int((volume * 100).rounded()))%"
        }
        return DesktopBarVolumeInfo(text: text,
                                    usesHeadset: outputLooksLikeHeadset(device))
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

    private static func outputLooksLikeHeadset(_ device: AudioDeviceID) -> Bool {
        let source = outputDataSource(for: device)
        if let source {
            if let kind = dataSourceKind(source.id, device: device, element: source.element),
               kind == kAudioStreamTerminalTypeHeadphones {
                return true
            }
            if dataSourceCodeLooksLikeHeadset(source.id) {
                return true
            }
        }

        var names: [String] = []
        if let source,
           let name = dataSourceName(source.id, device: device, element: source.element) {
            names.append(name)
        }
        if let name = stringProperty(kAudioObjectPropertyName, for: device) {
            names.append(name)
        }
        if names.contains(where: nameLooksLikeHeadset) {
            return true
        }
        if names.contains(where: nameLooksLikeSpeaker) {
            return false
        }

        guard let transport = transportType(for: device) else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth ||
            transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func outputDataSource(for device: AudioDeviceID)
        -> (id: UInt32, element: AudioObjectPropertyElement)? {
        guard var address = outputAddress(device: device,
                                          selector: kAudioDevicePropertyDataSource) else {
            return nil
        }
        var source = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &source) == noErr else {
            return nil
        }
        return (source, address.mElement)
    }

    private static func dataSourceName(_ source: UInt32, device: AudioDeviceID,
                                       element: AudioObjectPropertyElement) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceNameForIDCFString,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var source = source
        var raw: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &raw) { rawPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(rawPointer),
                    mOutputDataSize: UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
            }
        }
        guard status == noErr, let raw else { return nil }
        return raw.takeRetainedValue() as String
    }

    private static func dataSourceKind(_ source: UInt32, device: AudioDeviceID,
                                       element: AudioObjectPropertyElement) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDataSourceKindForID,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
        var source = source
        var kind = UInt32(0)
        let status = withUnsafeMutablePointer(to: &source) { sourcePointer in
            withUnsafeMutablePointer(to: &kind) { kindPointer in
                var translation = AudioValueTranslation(
                    mInputData: UnsafeMutableRawPointer(sourcePointer),
                    mInputDataSize: UInt32(MemoryLayout<UInt32>.size),
                    mOutputData: UnsafeMutableRawPointer(kindPointer),
                    mOutputDataSize: UInt32(MemoryLayout<UInt32>.size)
                )
                var size = UInt32(MemoryLayout<AudioValueTranslation>.size)
                return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &translation)
            }
        }
        return status == noErr ? kind : nil
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       for device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var raw: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &raw) { rawPointer in
            AudioObjectGetPropertyData(device, &address, 0, nil, &size, rawPointer)
        }
        guard status == noErr, let raw else { return nil }
        return raw.takeRetainedValue() as String
    }

    private static func transportType(for device: AudioDeviceID) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport) == noErr else {
            return nil
        }
        return transport
    }

    private static func dataSourceCodeLooksLikeHeadset(_ source: UInt32) -> Bool {
        switch fourCC(source).lowercased() {
        case "hdph", "hdpn", "hds ":
            return true
        default:
            return false
        }
    }

    private static func fourCC(_ value: UInt32) -> String {
        let bytes = [
            UInt8((value >> 24) & 0xff),
            UInt8((value >> 16) & 0xff),
            UInt8((value >> 8) & 0xff),
            UInt8(value & 0xff),
        ]
        return String(bytes: bytes, encoding: .macOSRoman) ?? ""
    }

    private static func nameLooksLikeHeadset(_ value: String) -> Bool {
        let value = normalizedName(value)
        return [
            "airpod", "earbud", "earphone", "headphone", "headset",
        ].contains { value.contains($0) }
    }

    private static func nameLooksLikeSpeaker(_ value: String) -> Bool {
        let value = normalizedName(value)
        return [
            "speaker", "soundbar",
        ].contains { value.contains($0) }
    }

    private static func normalizedName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: nil)
            .lowercased()
    }
}
