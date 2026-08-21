import Foundation

enum ConfigurationKeyValidation {
    static func diagnostics(in root: [String: Any]) -> [ConfigurationDiagnostic] {
        validate(root, path: [])
    }

    private static func validate(_ table: [String: Any], path: [String]) -> [ConfigurationDiagnostic] {
        if path == ["ui", "bar", "plugins"] {
            return table.keys.sorted().flatMap { id -> [ConfigurationDiagnostic] in
                let keyPath = display(path + [id])
                var diagnostics: [ConfigurationDiagnostic] = []
                if !isPluginID(id) {
                    diagnostics.append(ConfigurationDiagnostic(keyPath: keyPath,
                                                               message: "invalid plugin id '\(id)' expected [a-z0-9][a-z0-9_-]*"))
                }
                if let plugin = table[id] as? [String: Any] {
                    diagnostics += validate(plugin, path: path + [id])
                }
                return diagnostics
            }
        }

        if isEnvironment(path) {
            return []
        }

        guard let allowed = allowedKeys(at: path) else { return [] }
        var diagnostics = table.keys.sorted().compactMap { key -> ConfigurationDiagnostic? in
            guard !allowed.contains(key) else { return nil }
            let keyPath = display(path + [key])
            return ConfigurationDiagnostic(keyPath: keyPath, message: "unknown key '\(keyPath)'")
        }

        for key in table.keys.sorted() where allowed.contains(key) {
            diagnostics += validateValue(table[key]!, path: path + [key])
        }
        return diagnostics
    }

    private static func validateValue(_ value: Any, path: [String]) -> [ConfigurationDiagnostic] {
        if let table = value as? [String: Any] {
            return validate(table, path: path)
        }
        guard let array = value as? [Any] else { return [] }
        return array.enumerated().flatMap { index, element -> [ConfigurationDiagnostic] in
            guard let table = element as? [String: Any] else { return [] }
            return validate(table, path: path + ["[\(index)]"])
        }
    }

    private static func allowedKeys(at path: [String]) -> Set<String>? {
        switch normalized(path) {
        case "": return ["schema", "layout", "focus", "workspaces", "ui", "keyboard", "startup", "windows"]
        case "layout": return ["kind", "inner_gap", "outer_gap", "dwindle", "master"]
        case "layout.dwindle": return ["new_window_fraction", "new_window_position"]
        case "layout.master": return ["primary_fraction", "primary_position", "new_window_position"]
        case "focus": return ["follows_pointer", "allow_app_activation"]
        case "workspaces": return ["back_and_forth", "assignments"]
        case "workspaces.assignments.[]": return ["id", "monitor"]
        case "ui": return ["menu_bar", "focus_border", "bar"]
        case "ui.menu_bar": return ["enabled"]
        case "ui.focus_border": return ["width", "fallback_corner_radius", "active_colors", "active_angle", "mode_colors"]
        case "ui.bar": return ["enabled", "position", "height", "left", "center", "right", "colors", "weather", "plugins"]
        case "ui.bar.colors": return ["background", "foreground", "inactive", "active"]
        case "ui.bar.weather": return ["latitude", "longitude", "refresh_minutes"]
        case let value where value.hasPrefix("ui.bar.plugins."):
            return ["run", "shell", "env", "refresh_seconds", "events", "timeout_ms"]
        case "keyboard": return ["bindings", "pointer_bindings"]
        case "keyboard.pointer_bindings.[]": return ["modifiers", "button", "drag"]
        case "keyboard.bindings.[]": return bindingKeys
        case "startup": return ["commands"]
        case "startup.commands.[]": return ["run", "shell", "env"]
        case "windows": return ["rules"]
        case "windows.rules.[]": return ["match", "floating", "centered", "pinned", "fullscreen", "size", "position", "workspace", "monitor"]
        case "windows.rules.[].match": return ["bundle_id", "app_name", "title"]
        default: return nil
        }
    }

    private static let bindingKeys: Set<String> = [
        "mode", "chord", "on", "repeat", "run", "shell", "env", "close", "quit", "focus",
        "move", "swap", "workspace", "move_to_workspace", "move_to_workspace_silent",
        "toggle_special_workspace", "toggle_floating", "set_floating", "set_tiled", "fullscreen",
        "maximize", "center", "pin", "resize", "move_floating", "split", "primary", "monitor",
        "enter_mode", "raise", "refresh", "pause",
    ]

    private static func normalized(_ path: [String]) -> String {
        path.map { $0.first == "[" ? "[]" : $0 }.joined(separator: ".")
    }

    private static func display(_ path: [String]) -> String {
        path.reduce(into: "") { result, component in
            if component.first == "[" {
                result += component
            } else {
                result += result.isEmpty ? component : ".\(component)"
            }
        }
    }

    private static func isEnvironment(_ path: [String]) -> Bool {
        normalized(path).hasSuffix(".env")
    }

    static func isPluginID(_ id: String) -> Bool {
        guard let first = id.utf8.first, isLowercaseLetter(first) || isDigit(first) else { return false }
        return id.utf8.dropFirst().allSatisfy { isLowercaseLetter($0) || isDigit($0) || $0 == 95 || $0 == 45 }
    }

    private static func isLowercaseLetter(_ value: UInt8) -> Bool {
        (97...122).contains(value)
    }

    private static func isDigit(_ value: UInt8) -> Bool {
        (48...57).contains(value)
    }
}
