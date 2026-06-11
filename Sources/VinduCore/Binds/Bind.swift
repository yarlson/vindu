import Foundation

public struct Modifiers: OptionSet, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let shift = Modifiers(rawValue: 1 << 0)
    public static let ctrl = Modifiers(rawValue: 1 << 1)
    public static let alt = Modifiers(rawValue: 1 << 2)
    public static let cmd = Modifiers(rawValue: 1 << 3)

    /// Parses Hyprland modifier strings: `SUPER SHIFT`, `ALT+CTRL`, or empty.
    /// SUPER maps to ⌘ on macOS; ALT to ⌥.
    public static func parse(_ raw: String) -> Modifiers? {
        var mods = Modifiers()
        let cleaned = raw.replacingOccurrences(of: "+", with: " ")
        for tok in cleaned.split(separator: " ") {
            switch tok.uppercased() {
            case "SUPER", "CMD", "COMMAND", "MOD4", "WIN": mods.insert(.cmd)
            case "ALT", "OPT", "OPTION", "META", "MOD1": mods.insert(.alt)
            case "CTRL", "CONTROL": mods.insert(.ctrl)
            case "SHIFT": mods.insert(.shift)
            default: return nil
            }
        }
        return mods
    }

    public var described: String {
        var parts: [String] = []
        if contains(.cmd) { parts.append("SUPER") }
        if contains(.alt) { parts.append("ALT") }
        if contains(.ctrl) { parts.append("CTRL") }
        if contains(.shift) { parts.append("SHIFT") }
        return parts.joined(separator: " ")
    }
}

public struct BindFlags: OptionSet, Equatable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    /// `binde` — fires on key autorepeat too.
    public static let repeats = BindFlags(rawValue: 1 << 0)
    /// `bindm` — mouse drag bind (movewindow / resizewindow).
    public static let mouse = BindFlags(rawValue: 1 << 1)
    /// `bindr` — fires on key release.
    public static let release = BindFlags(rawValue: 1 << 2)
    /// `bindl` — works when screen is locked (accepted; macOS taps stop at the lock screen).
    public static let locked = BindFlags(rawValue: 1 << 3)
    /// `bindd` — a human description precedes the dispatcher.
    public static let hasDescription = BindFlags(rawValue: 1 << 4)

    public static func parse(_ suffix: String) -> BindFlags? {
        var flags = BindFlags()
        for ch in suffix.lowercased() {
            switch ch {
            case "e": flags.insert(.repeats)
            case "m": flags.insert(.mouse)
            case "r": flags.insert(.release)
            case "l": flags.insert(.locked)
            case "d": flags.insert(.hasDescription)
            case "n", "t", "i", "s", "p", "o", "c", "g":
                continue // valid in Hyprland, no macOS meaning; tolerated
            default:
                return nil
            }
        }
        return flags
    }
}

public enum MouseButton: String, Equatable {
    case left, right, middle

    /// Hyprland uses evdev codes: mouse:272 left, mouse:273 right, mouse:274 middle.
    public static func parse(bindKey: String) -> MouseButton? {
        switch bindKey.lowercased() {
        case "mouse:272", "mouse_left": return .left
        case "mouse:273", "mouse_right": return .right
        case "mouse:274", "mouse_middle": return .middle
        default: return nil
        }
    }
}

public struct Bind: Equatable {
    public var mods: Modifiers
    /// Normalized lowercase key name (`q`, `left`, `code:34`, `mouse:272`).
    public var key: String
    public var flags: BindFlags
    /// Submap this bind belongs to; "" is the root keymap.
    public var submap: String
    public var dispatcher: Dispatcher
    public var description: String?

    public init(mods: Modifiers, key: String, flags: BindFlags, submap: String,
                dispatcher: Dispatcher, description: String? = nil) {
        self.mods = mods
        self.key = key
        self.flags = flags
        self.submap = submap
        self.dispatcher = dispatcher
        self.description = description
    }
}

public enum BindParser {
    /// Parses the value of `bind[flags] = MODS, key, dispatcher[, args]`.
    public static func parse(flagsSuffix: String, value: String, submap: String) -> Result<Bind, ParseError> {
        guard let flags = BindFlags.parse(flagsSuffix) else {
            return .failure("unknown bind flags: \(flagsSuffix)")
        }
        let head = splitCSV(value, limit: 3)
        guard head.count == 3 else {
            return .failure("bind needs at least: mods, key, dispatcher")
        }
        guard let mods = Modifiers.parse(head[0]) else {
            return .failure("unknown modifiers: \(head[0])")
        }
        let key = head[1].lowercased()
        guard !key.isEmpty else {
            return .failure("bind key is empty")
        }

        var rest = head[2]
        var description: String?
        if flags.contains(.hasDescription) {
            let d = splitCSV(rest, limit: 2)
            guard d.count == 2 else {
                return .failure("bindd needs: mods, key, description, dispatcher")
            }
            description = d[0]
            rest = d[1]
        }

        let d = splitCSV(rest, limit: 2)
        let dispatcherName = d[0]
        let args = d.count > 1 ? d[1] : ""

        switch Dispatcher.parse(name: dispatcherName, args: args) {
        case .success(let dispatcher):
            if flags.contains(.mouse), MouseButton.parse(bindKey: key) == nil {
                return .failure("bindm key must be mouse:272/273/274")
            }
            if !flags.contains(.mouse), !key.hasPrefix("code:"), KeyCodes.code(for: key) == nil {
                return .failure("unknown key name: \(key)")
            }
            return .success(Bind(mods: mods, key: key, flags: flags, submap: submap,
                                 dispatcher: dispatcher, description: description))
        case .failure(let err):
            return .failure(err)
        }
    }
}
