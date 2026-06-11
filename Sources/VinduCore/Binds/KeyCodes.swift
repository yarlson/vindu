import Foundation

/// Maps Hyprland-style key names to macOS virtual key codes (ANSI layout).
/// Key names in binds are matched case-insensitively. `code:NN` bypasses the table.
public enum KeyCodes {
    public static func code(for name: String) -> UInt16? {
        let n = name.lowercased()
        if let raw = n.removingPrefix("code:") {
            return UInt16(raw)
        }
        return table[n]
    }

    private static let table: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "equal": 24, "minus": 27,
        "bracketright": 30, "o": 31, "u": 32, "bracketleft": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36,
        "l": 37, "j": 38, "apostrophe": 39, "k": 40, "semicolon": 41, "backslash": 42,
        "comma": 43, "slash": 44, "n": 45, "m": 46, "period": 47,
        "tab": 48, "space": 49, "grave": 50,
        "backspace": 51, "delete": 51, "escape": 53, "esc": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "left": 123, "right": 124, "down": 125, "up": 126,
        "home": 115, "end": 119, "prior": 116, "pageup": 116, "next": 121, "pagedown": 121,
        "forwarddelete": 117,
    ]
}
