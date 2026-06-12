import CoreGraphics
import Foundation

/// CGWindowID of a managed window. The IPC "address" is this value hex-formatted,
/// mirroring Hyprland's window addresses.
public typealias WindowID = UInt32

/// Error for config/dispatcher parsing. String-expressible so parse code can
/// return `.failure("message \(detail)")` directly.
public struct ParseError: Error, Equatable, CustomStringConvertible, ExpressibleByStringInterpolation {
    public let message: String

    public init(_ message: String) { self.message = message }
    public init(stringLiteral value: String) { self.message = value }

    public var description: String { message }
}

public enum Direction: String, CaseIterable, Equatable {
    case left = "l", right = "r", up = "u", down = "d"

    public init?(parsing s: String) {
        switch s.lowercased() {
        case "l", "left": self = .left
        case "r", "right": self = .right
        case "u", "up", "t", "top": self = .up
        case "d", "down", "b", "bottom": self = .down
        default: return nil
        }
    }
}

public enum Orientation: String, Equatable {
    case horizontal, vertical
}

public enum LayoutKind: String, Equatable {
    case dwindle, master
}

/// Workspace selector, mirroring Hyprland's workspace argument syntax:
/// `3`, `+1`, `-1`, `e+1`, `previous`, `empty`, `name:web`, `special`, `special:magic`.
public enum WorkspaceTarget: Equatable {
    case id(Int)
    case relative(Int)
    case relativeExisting(Int)
    case previous
    case name(String)
    case special(String)
    case empty

    public static func parse(_ raw: String) -> WorkspaceTarget? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s == "previous" { return .previous }
        if s == "empty" { return .empty }
        if s == "special" { return .special("special") }
        if let rest = s.removingPrefix("special:") { return .special(rest.isEmpty ? "special" : rest) }
        if let rest = s.removingPrefix("name:") { return rest.isEmpty ? nil : .name(rest) }
        if s.hasPrefix("e+") || s.hasPrefix("e-") {
            guard let n = Int(s.dropFirst(1)) else { return nil }
            return .relativeExisting(n)
        }
        if s.hasPrefix("+") || s.hasPrefix("-") {
            guard let n = Int(s) else { return nil }
            return .relative(n)
        }
        if let n = Int(s) { return .id(n) }
        return .name(s)
    }

    /// The selector in config syntax; `parse(text)` round-trips.
    public var text: String {
        switch self {
        case .id(let n): return String(n)
        case .relative(let d): return d >= 0 ? "+\(d)" : "\(d)"
        case .relativeExisting(let d): return d >= 0 ? "e+\(d)" : "e\(d)"
        case .previous: return "previous"
        case .name(let s): return "name:\(s)"
        case .special(let s): return "special:\(s)"
        case .empty: return "empty"
        }
    }
}

/// Monitor selector: direction, numeric id, `+1`/`-1`, `current`, or name substring.
public enum MonitorTarget: Equatable {
    case direction(Direction)
    case id(Int)
    case relative(Int)
    case current
    case name(String)

    public static func parse(_ raw: String) -> MonitorTarget? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        if s.isEmpty { return nil }
        if s == "current" { return .current }
        if s.count <= 2, let d = Direction(parsing: s) { return .direction(d) }
        if s.hasPrefix("+") || s.hasPrefix("-") {
            guard let n = Int(s) else { return nil }
            return .relative(n)
        }
        if let n = Int(s) { return .id(n) }
        return .name(s)
    }

    /// The selector in config syntax; `parse(text)` round-trips.
    public var text: String {
        switch self {
        case .direction(let d): return d.rawValue
        case .id(let n): return String(n)
        case .relative(let d): return d >= 0 ? "+\(d)" : "\(d)"
        case .current: return "current"
        case .name(let s): return s
        }
    }
}

/// Renders whole doubles without the trailing ".0" (config values are
/// human-typed, so `30` should read back as `30`, not `30.0`).
func plainNumber(_ v: Double) -> String {
    v == v.rounded() && abs(v) < 1e15 ? String(Int(v)) : String(v)
}

/// A pixel or percent dimension, as accepted by `resizeactive`, `moveactive`,
/// and window rule `size`/`move` arguments (e.g. `10`, `-20`, `50%`).
public struct Delta: Equatable {
    public var value: Double
    public var percent: Bool

    public init(value: Double, percent: Bool = false) {
        self.value = value
        self.percent = percent
    }

    public static func parse(_ raw: String) -> Delta? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        var percent = false
        if s.hasSuffix("%") {
            percent = true
            s = String(s.dropLast())
        }
        guard let v = Double(s) else { return nil }
        return Delta(value: v, percent: percent)
    }

    /// Resolves against a reference span: percent of it, or the raw pixel value.
    public func resolved(against span: Double) -> Double {
        percent ? span * value / 100.0 : value
    }

    /// The dimension in config syntax; `parse(text)` round-trips.
    public var text: String {
        plainNumber(value) + (percent ? "%" : "")
    }
}

public enum ResizeParam: Equatable {
    case relative(Delta, Delta)
    case exact(Delta, Delta)

    public static func parse(_ raw: String) -> ResizeParam? {
        var parts = raw.split(separator: " ").map(String.init)
        var isExact = false
        if parts.first == "exact" {
            isExact = true
            parts.removeFirst()
        }
        guard parts.count == 2, let a = Delta.parse(parts[0]), let b = Delta.parse(parts[1]) else {
            return nil
        }
        return isExact ? .exact(a, b) : .relative(a, b)
    }

    /// The parameter in config syntax; `parse(text)` round-trips.
    public var text: String {
        switch self {
        case .relative(let a, let b): return "\(a.text) \(b.text)"
        case .exact(let a, let b): return "exact \(a.text) \(b.text)"
        }
    }
}

extension String {
    /// Returns the remainder if the string starts with `prefix`, else nil.
    public func removingPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }

    /// Returns the remainder if the string ends with `suffix`, else nil.
    func removingSuffix(_ suffix: String) -> String? {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : nil
    }
}
