/// Human-readable rendering of binds for the keybinding cheat sheet.
/// Chords use macOS modifier symbols; actions prefer the `bindd` description,
/// then a plain-English name for common dispatchers, then `name args`.
public enum BindDisplay {
    /// Cheat-sheet rows for the root keymap, in config order. Mouse binds are
    /// included; submap binds are not (submaps explain themselves while
    /// active). Consecutive digit binds like `1…9 → workspace 1…9` collapse
    /// into one row.
    public static func rows(_ binds: [Bind]) -> [(chord: String, action: String)] {
        let root = binds.filter { $0.submap.isEmpty }
        var out: [(String, String)] = []
        var i = 0
        while i < root.count {
            if let run = digitRun(root, from: i) {
                out.append(run.row)
                i = run.next
                continue
            }
            out.append((chord(root[i]), action(root[i])))
            i += 1
        }
        return out
    }

    /// "⌥⇧ H", "⌥ Left drag", "⎋" — modifiers as macOS symbols plus the key.
    public static func chord(_ bind: Bind) -> String {
        let symbols = modifierSymbols(bind.mods)
        let key = keyLabel(bind.key)
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }

    /// One short action label; the `bindd` description wins when present.
    public static func action(_ bind: Bind) -> String {
        if let d = bind.description, !d.isEmpty { return d }
        return describe(bind.dispatcher)
    }

    public static func modifierSymbols(_ mods: Modifiers) -> String {
        var out = ""
        if mods.contains(.ctrl) { out += "⌃" }
        if mods.contains(.alt) { out += "⌥" }
        if mods.contains(.shift) { out += "⇧" }
        if mods.contains(.cmd) { out += "⌘" }
        return out
    }

    public static func keyLabel(_ key: String) -> String {
        if let glyph = keyGlyphs[key] { return glyph }
        if let code = key.removingPrefix("code:") { return "key \(code)" }
        if key.count == 1 { return key.uppercased() }
        return key.prefix(1).uppercased() + key.dropFirst()
    }

    private static let keyGlyphs: [String: String] = [
        "return": "↩", "enter": "↩", "tab": "⇥", "space": "Space",
        "escape": "⎋", "esc": "⎋", "backspace": "⌫", "delete": "⌫",
        "forwarddelete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓",
        "home": "↖", "end": "↘", "pageup": "⇞", "prior": "⇞", "pagedown": "⇟", "next": "⇟",
        "bracketleft": "[", "bracketright": "]", "comma": ",", "period": ".",
        "slash": "/", "backslash": "\\", "semicolon": ";", "apostrophe": "'",
        "grave": "`", "minus": "-", "equal": "=",
        "mouse:272": "Left drag", "mouse:273": "Right drag", "mouse:274": "Middle drag",
    ]

    private static func describe(_ d: Dispatcher) -> String {
        switch d {
        case .exec(let cmd):
            if let app = cmd.removingPrefix("open -a ") {
                return "Open \(app.trimmingCharacters(in: .init(charactersIn: "\"'")))"
            }
            return "Run: \(cmd)"
        case .killactive: return "Close window"
        case .exit: return "Quit vindu"
        case .workspace(let t): return switchLabel(t)
        case .movetoworkspace(let t): return sendLabel(t)
        case .movetoworkspacesilent(let t): return sendLabel(t) + " (stay)"
        case .togglefloating: return "Float / tile"
        case .fullscreen(let mode): return mode == 1 ? "Maximize" : "Fullscreen"
        case .movefocus(let dir): return "Focus \(word(dir))"
        case .movewindow(.direction(let dir)): return "Move window \(word(dir))"
        case .movewindow(.monitor(let m)): return "Move window to monitor \(m.text)"
        case .movewindow(.mouse): return "Move window"
        case .resizewindow: return "Resize window"
        case .swapwindow(let dir): return "Swap \(word(dir))"
        case .centerwindow: return "Center window"
        case .togglesplit: return "Toggle split direction"
        case .swapsplit: return "Swap split"
        case .pin: return "Pin to all workspaces"
        case .cyclenext(let prev): return prev ? "Previous window" : "Next window"
        case .swapnext(let prev): return prev ? "Swap with previous" : "Swap with next"
        case .togglespecialworkspace(let name):
            return scratchpadLabel(name)
        case .layoutmsg(let msg):
            return msg.hasPrefix("swapwithmaster") ? "Swap with master" : "Layout: \(msg)"
        case .submap(let name): return name.isEmpty ? "Exit submap" : "\(name.capitalized) mode"
        case .pause: return "Pause / resume tiling"
        default:
            let arg = d.argText
            return arg.isEmpty ? d.name : "\(d.name) \(arg)"
        }
    }

    /// Label for `workspace` — the bind switches what you look at.
    private static func switchLabel(_ t: WorkspaceTarget) -> String {
        switch t {
        case .relative(1): return "Next workspace"
        case .relative(-1): return "Previous workspace"
        case .previous: return "Last workspace"
        case .special(let s): return scratchpadLabel(s)
        default: return "Workspace \(t.text)"
        }
    }

    /// Label for `movetoworkspace*` — the bind moves the focused window.
    private static func sendLabel(_ t: WorkspaceTarget) -> String {
        switch t {
        case .relative(1): return "Send to next workspace"
        case .relative(-1): return "Send to previous workspace"
        case .special: return "Send to scratchpad"
        default: return "Send to workspace \(t.text)"
        }
    }

    private static func scratchpadLabel(_ name: String) -> String {
        name == "special" || name == "magic" ? "Scratchpad" : "Scratchpad \(name)"
    }

    private static func word(_ d: Direction) -> String {
        switch d {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }

    /// Detects runs like `mods+1 → workspace 1` … `mods+9 → workspace 9` and
    /// folds them into a single "1…9" row. Requires at least three consecutive
    /// digits whose target id matches the key.
    private static func digitRun(_ binds: [Bind], from start: Int)
        -> (row: (String, String), next: Int)? {
        func digitTarget(_ b: Bind) -> (digit: Int, send: Bool)? {
            guard b.key.count == 1, let d = Int(b.key), d >= 1 else { return nil }
            switch b.dispatcher {
            case .workspace(.id(d)): return (d, false)
            case .movetoworkspace(.id(d)), .movetoworkspacesilent(.id(d)): return (d, true)
            default: return nil
            }
        }
        guard let first = digitTarget(binds[start]) else { return nil }
        let mods = binds[start].mods
        var end = start
        var last = first
        while end + 1 < binds.count, binds[end + 1].mods == mods,
              let next = digitTarget(binds[end + 1]),
              next.send == first.send, next.digit == last.digit + 1 {
            end += 1
            last = next
        }
        guard end - start >= 2 else { return nil }
        let symbols = modifierSymbols(mods)
        let keys = "\(first.digit)…\(last.digit)"
        let chord = symbols.isEmpty ? keys : "\(symbols) \(keys)"
        let action = first.send ? "Send to workspace \(first.digit)–\(last.digit)"
                                : "Workspace \(first.digit)–\(last.digit)"
        return ((chord, action), end + 1)
    }
}
