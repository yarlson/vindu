import Foundation

public enum BindDisplay {
    public static func rows(_ bindings: [KeyboardBinding],
                            pointerBindings: [PointerBinding] = [])
        -> [(chord: String, action: String)] {
        let root = bindings.filter { $0.mode == "default" }
        var rows: [(String, String)] = []
        var index = 0
        while index < root.count {
            if let run = digitRun(root, from: index) {
                rows.append(run.row)
                index = run.next
                continue
            }
            rows.append((chord(root[index].chord), action(root[index].action)))
            index += 1
        }
        rows.append(contentsOf: pointerBindings.map { (chord($0), action($0.drag)) })
        return rows
    }

    public static func chord(_ chord: KeyChord) -> String {
        let symbols = modifierSymbols(chord.modifiers)
        let key = keyLabel(chord.key)
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }

    public static func chord(_ binding: PointerBinding) -> String {
        let symbols = modifierSymbols(binding.modifiers)
        let key = keyLabel(pointerKey(binding.button))
        return symbols.isEmpty ? key : "\(symbols) \(key)"
    }

    public static func action(_ action: ConfiguredAction) -> String {
        switch action {
        case .command(let command): return describe(command)
        case .window(let action): return describe(action)
        }
    }

    public static func modifierSymbols(_ modifiers: [KeyboardModifier]) -> String {
        var output = ""
        if modifiers.contains(.control) { output += "⌃" }
        if modifiers.contains(.option) { output += "⌥" }
        if modifiers.contains(.shift) { output += "⇧" }
        if modifiers.contains(.command) { output += "⌘" }
        return output
    }

    public static func bindInfoProjection(_ bindings: [KeyboardBinding],
                                          pointerBindings: [PointerBinding] = []) -> [BindInfo] {
        let keyboard = bindings.map { binding in
            let identity = actionIdentity(binding.action)
            return BindInfo(locked: false,
                            mouse: false,
                            release: binding.edge == .release,
                            repeats: binding.repeats,
                            modmask: modifierMask(binding.chord.modifiers),
                            submap: binding.mode == "default" ? "" : binding.mode,
                            key: binding.chord.key,
                            dispatcher: identity.name,
                            arg: identity.argument,
                            description: action(binding.action))
        }
        let pointer = pointerBindings.map { binding in
            BindInfo(locked: false,
                     mouse: true,
                     release: false,
                     repeats: false,
                     modmask: modifierMask(binding.modifiers),
                     submap: "",
                     key: pointerKey(binding.button),
                     dispatcher: binding.drag.rawValue,
                     arg: "",
                     description: action(binding.drag))
        }
        return keyboard + pointer
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

    private static func describe(_ command: CommandSpec) -> String {
        switch command.execution {
        case .run(let arguments):
            if arguments.count >= 3,
               ["open", "/usr/bin/open"].contains(arguments[0]),
               arguments[1] == "-a" {
                return "Open \(arguments[2])"
            }
            return "Run: \(arguments.joined(separator: " "))"
        case .shell:
            return "Run shell command"
        }
    }

    private static func describe(_ action: WindowAction) -> String {
        switch action {
        case .close: return "Close window"
        case .quit: return "Quit vindu"
        case .focus(let direction): return "Focus \(word(direction))"
        case .move(let direction): return "Move window \(word(direction))"
        case .swap(let direction): return "Swap \(word(direction))"
        case .workspace(let target): return switchLabel(target)
        case .moveToWorkspace(let target): return sendLabel(target)
        case .moveToWorkspaceSilent(let target): return sendLabel(target) + " (stay)"
        case .toggleSpecialWorkspace(let name): return scratchpadLabel(name)
        case .toggleFloating: return "Float / tile"
        case .setFloating: return "Set floating"
        case .setTiled: return "Set tiled"
        case .fullscreen(let state): return stateLabel(state, noun: "fullscreen")
        case .maximize(let state): return stateLabel(state, noun: "maximize")
        case .center: return "Center window"
        case .pin: return "Pin to all workspaces"
        case .resize(let x, let y): return "Resize window \(plainNumber(x)) \(plainNumber(y))"
        case .moveFloating(let x, let y): return "Move floating window \(plainNumber(x)) \(plainNumber(y))"
        case .split(.toggle): return "Toggle split direction"
        case .split(.horizontal): return "Split horizontally"
        case .split(.vertical): return "Split vertically"
        case .split(.swap): return "Swap split"
        case .primary(.focus): return "Focus primary window"
        case .primary(.swap): return "Swap with primary window"
        case .primary(.add): return "Add primary window"
        case .primary(.remove): return "Remove primary window"
        case .monitor(let target): return "Focus monitor \(target.text)"
        case .enterMode(let mode): return mode == "default" ? "Exit mode" : "\(mode.capitalized) mode"
        case .raise: return "Raise window"
        case .refresh: return "Refresh"
        case .pause(.toggle): return "Pause / resume tiling"
        case .pause(.on): return "Pause tiling"
        case .pause(.off): return "Resume tiling"
        }
    }

    private static func stateLabel(_ state: ActionState, noun: String) -> String {
        switch (state, noun) {
        case (.toggle, "maximize"): return "Maximize"
        case (.on, "maximize"): return "Maximize window"
        case (.off, "maximize"): return "Restore window"
        case (.toggle, _): return "Fullscreen"
        case (.on, _): return "Enter fullscreen"
        case (.off, _): return "Exit fullscreen"
        }
    }

    private static func action(_ drag: PointerDrag) -> String {
        drag == .move ? "Move window" : "Resize window"
    }

    private static func actionIdentity(_ action: ConfiguredAction) -> (name: String, argument: String) {
        switch action {
        case .command(let command):
            switch command.execution {
            case .run(let arguments):
                let data = try? JSONEncoder().encode(arguments)
                return ("run", data.flatMap { String(data: $0, encoding: .utf8) } ?? "[]")
            case .shell(let script): return ("shell", script)
            }
        case .window(let action): return actionIdentity(action)
        }
    }

    private static func actionIdentity(_ action: WindowAction) -> (name: String, argument: String) {
        switch action {
        case .close: return ("close", "")
        case .quit: return ("quit", "")
        case .focus(let direction): return ("focus", word(direction))
        case .move(let direction): return ("move", word(direction))
        case .swap(let direction): return ("swap", word(direction))
        case .workspace(let target): return ("workspace", target.text)
        case .moveToWorkspace(let target): return ("move_to_workspace", target.text)
        case .moveToWorkspaceSilent(let target): return ("move_to_workspace_silent", target.text)
        case .toggleSpecialWorkspace(let name): return ("toggle_special_workspace", name)
        case .toggleFloating: return ("toggle_floating", "")
        case .setFloating: return ("set_floating", "")
        case .setTiled: return ("set_tiled", "")
        case .fullscreen(let state): return ("fullscreen", state.rawValue)
        case .maximize(let state): return ("maximize", state.rawValue)
        case .center: return ("center", "")
        case .pin: return ("pin", "")
        case .resize(let x, let y): return ("resize", "\(plainNumber(x)) \(plainNumber(y))")
        case .moveFloating(let x, let y): return ("move_floating", "\(plainNumber(x)) \(plainNumber(y))")
        case .split(let split): return ("split", split.rawValue)
        case .primary(let primary): return ("primary", primary.rawValue)
        case .monitor(let target): return ("monitor", target.text)
        case .enterMode(let mode): return ("enter_mode", mode)
        case .raise: return ("raise", "")
        case .refresh: return ("refresh", "")
        case .pause(let pause): return ("pause", pause.rawValue)
        }
    }

    private static func switchLabel(_ target: WorkspaceTarget) -> String {
        switch target {
        case .relative(1): return "Next workspace"
        case .relative(-1): return "Previous workspace"
        case .previous: return "Last workspace"
        case .special(let name): return scratchpadLabel(name)
        default: return "Workspace \(target.text)"
        }
    }

    private static func sendLabel(_ target: WorkspaceTarget) -> String {
        switch target {
        case .relative(1): return "Send to next workspace"
        case .relative(-1): return "Send to previous workspace"
        case .special: return "Send to scratchpad"
        default: return "Send to workspace \(target.text)"
        }
    }

    private static func scratchpadLabel(_ name: String) -> String {
        name == "special" || name == "magic" ? "Scratchpad" : "Scratchpad \(name)"
    }

    private static func word(_ direction: Direction) -> String {
        switch direction {
        case .left: return "left"
        case .right: return "right"
        case .up: return "up"
        case .down: return "down"
        }
    }

    private static func modifierMask(_ modifiers: [KeyboardModifier]) -> Int {
        var mask = 0
        if modifiers.contains(.shift) { mask |= 1 << 0 }
        if modifiers.contains(.control) { mask |= 1 << 1 }
        if modifiers.contains(.option) { mask |= 1 << 2 }
        if modifiers.contains(.command) { mask |= 1 << 3 }
        return mask
    }

    private static func pointerKey(_ button: PointerButton) -> String {
        switch button {
        case .left: return "mouse:272"
        case .right: return "mouse:273"
        case .middle: return "mouse:274"
        }
    }

    private static func digitRun(_ bindings: [KeyboardBinding], from start: Int)
        -> (row: (String, String), next: Int)? {
        func target(_ binding: KeyboardBinding) -> (digit: Int, action: DigitAction)? {
            guard binding.chord.key.count == 1,
                  let digit = Int(binding.chord.key), digit >= 1 else { return nil }
            switch binding.action {
            case .window(.workspace(.id(let value))) where value == digit: return (digit, .workspace)
            case .window(.moveToWorkspace(.id(let value))) where value == digit: return (digit, .send)
            case .window(.moveToWorkspaceSilent(.id(let value))) where value == digit: return (digit, .sendSilent)
            default: return nil
            }
        }
        guard let first = target(bindings[start]) else { return nil }
        let modifiers = bindings[start].chord.modifiers
        let edge = bindings[start].edge
        let repeats = bindings[start].repeats
        var end = start
        var last = first
        while end + 1 < bindings.count,
              bindings[end + 1].chord.modifiers == modifiers,
              bindings[end + 1].edge == edge,
              bindings[end + 1].repeats == repeats,
              let next = target(bindings[end + 1]),
              next.action == first.action,
              next.digit == last.digit + 1 {
            end += 1
            last = next
        }
        guard end - start >= 2 else { return nil }
        let symbols = modifierSymbols(modifiers)
        let keys = "\(first.digit)…\(last.digit)"
        let chord = symbols.isEmpty ? keys : "\(symbols) \(keys)"
        let action: String
        switch first.action {
        case .workspace: action = "Workspace \(first.digit)–\(last.digit)"
        case .send: action = "Send to workspace \(first.digit)–\(last.digit)"
        case .sendSilent: action = "Send to workspace \(first.digit)–\(last.digit) (stay)"
        }
        return ((chord, action), end + 1)
    }

    private enum DigitAction {
        case workspace, send, sendSilent
    }
}
