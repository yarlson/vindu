import Foundation

/// Color in Hyprland config notation: `rgba(33ccffee)`, `rgb(11ee11)`, `0xee33ccff` (AARRGGBB).
public struct MLColor: Equatable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1.0) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public static func parse(_ raw: String) -> MLColor? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if let inner = s.removingPrefix("rgba("), inner.hasSuffix(")") {
            return fromHex(String(inner.dropLast()), digits: 8, order: .rgba)
        }
        if let inner = s.removingPrefix("rgb("), inner.hasSuffix(")") {
            return fromHex(String(inner.dropLast()), digits: 6, order: .rgba)
        }
        if let hex = s.removingPrefix("0x") {
            return fromHex(hex, digits: 8, order: .argb)
        }
        return nil
    }

    private enum ByteOrder { case rgba, argb }

    private static func fromHex(_ hex: String, digits: Int, order: ByteOrder) -> MLColor? {
        let h = hex.trimmingCharacters(in: .whitespaces)
        guard h.count == digits, let v = UInt64(h, radix: 16) else { return nil }
        func byte(_ shift: Int) -> Double { Double((v >> shift) & 0xFF) / 255.0 }
        if digits == 6 {
            return MLColor(r: byte(16), g: byte(8), b: byte(0), a: 1.0)
        }
        switch order {
        case .rgba: return MLColor(r: byte(24), g: byte(16), b: byte(8), a: byte(0))
        case .argb: return MLColor(r: byte(16), g: byte(8), b: byte(0), a: byte(24))
        }
    }
}

/// Gradient in Hyprland notation: one or more colors followed by an optional
/// `Ndeg` angle, e.g. `rgba(33ccffee) rgba(00ff99ee) 45deg`.
public struct MLGradient: Equatable {
    public var colors: [MLColor]
    public var angleDeg: Double

    public init(colors: [MLColor], angleDeg: Double = 0) {
        self.colors = colors
        self.angleDeg = angleDeg
    }

    public static func parse(_ raw: String) -> MLGradient? {
        var colors: [MLColor] = []
        var angle = 0.0
        for token in raw.split(separator: " ").map(String.init) {
            if let deg = token.lowercased().removingSuffix("deg"), let v = Double(deg) {
                angle = v
            } else if let c = MLColor.parse(token) {
                colors.append(c)
            } else {
                return nil
            }
        }
        guard !colors.isEmpty else { return nil }
        return MLGradient(colors: colors, angleDeg: angle)
    }
}

