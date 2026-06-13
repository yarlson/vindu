import Carbon
import CoreWLAN
import Darwin
import Foundation
import IOKit.ps

struct DesktopBarSystemInfo {
    var date: String
    var battery: String?
    var network: String?
    var keyboard: String?
    var volume: String?

    static func current() -> DesktopBarSystemInfo {
        DesktopBarSystemInfo(
            date: currentDate(),
            battery: currentBattery(),
            network: currentNetwork(),
            keyboard: currentKeyboard(),
            volume: currentVolume()
        )
    }

    private static func currentDate() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "EEE HH:mm"
        return formatter.string(from: Date())
    }

    private static func currentBattery() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in list {
            guard let raw = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                    as? [String: Any],
                  let present = raw[kIOPSIsPresentKey] as? Bool, present,
                  let capacity = raw[kIOPSCurrentCapacityKey] as? Int else {
                continue
            }
            let charging = (raw[kIOPSIsChargingKey] as? Bool) == true
            return "\(capacity)%\(charging ? "+" : "")"
        }
        return nil
    }

    private static func currentNetwork() -> String? {
        if let ssid = CWWiFiClient.shared().interface()?.ssid(), !ssid.isEmpty {
            return ssid
        }
        if let name = activeInterfaceName() {
            return name
        }
        return "offline"
    }

    private static func activeInterfaceName() -> String? {
        var cursor: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&cursor) == 0, let first = cursor else { return nil }
        defer { freeifaddrs(first) }

        var seen: Set<String> = []
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            defer { node = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let address = current.pointee.ifa_addr else {
                continue
            }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let name = String(cString: current.pointee.ifa_name)
            guard seen.insert(name).inserted else { continue }
            return name
        }
        return nil
    }

    private static func currentKeyboard() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }
        if let name = inputSourceString(source, kTISPropertyLocalizedName) {
            return shortKeyboardName(name)
        }
        if let id = inputSourceString(source, kTISPropertyInputSourceID) {
            return shortKeyboardName(id)
        }
        return nil
    }

    private static func inputSourceString(_ source: TISInputSource,
                                          _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    private static func shortKeyboardName(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.localizedCaseInsensitiveContains("U.S.") { return "US" }
        if trimmed.count <= 8 { return trimmed }
        return String(trimmed.prefix(8))
    }

    private static func currentVolume() -> String? {
        DesktopBarAudioState.currentVolumeText()
    }
}
