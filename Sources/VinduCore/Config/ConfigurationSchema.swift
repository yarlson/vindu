import Foundation

struct ConfigurationFile: Decodable {
    let schema: Int64
    let layout: LayoutFile?
    let focus: FocusFile?
    let workspaces: WorkspacesFile?
    let ui: UIFile?
    let keyboard: KeyboardFile?
    let startup: StartupFile?
    let windows: WindowsFile?
}

struct LayoutFile: Decodable {
    let kind: String?
    let innerGap: NumberValue?
    let outerGap: NumberValue?
    let dwindle: DwindleFile?
    let master: MasterFile?

    enum CodingKeys: String, CodingKey {
        case kind
        case innerGap = "inner_gap"
        case outerGap = "outer_gap"
        case dwindle, master
    }
}

struct DwindleFile: Decodable {
    let newWindowFraction: Double?
    let newWindowPosition: String?

    enum CodingKeys: String, CodingKey {
        case newWindowFraction = "new_window_fraction"
        case newWindowPosition = "new_window_position"
    }
}

struct MasterFile: Decodable {
    let primaryFraction: Double?
    let primaryPosition: String?
    let newWindowPosition: String?

    enum CodingKeys: String, CodingKey {
        case primaryFraction = "primary_fraction"
        case primaryPosition = "primary_position"
        case newWindowPosition = "new_window_position"
    }
}

struct FocusFile: Decodable {
    let followsPointer: Bool?
    let allowAppActivation: Bool?

    enum CodingKeys: String, CodingKey {
        case followsPointer = "follows_pointer"
        case allowAppActivation = "allow_app_activation"
    }
}

struct WorkspacesFile: Decodable {
    let backAndForth: Bool?
    let assignments: [WorkspaceAssignmentFile]?

    enum CodingKeys: String, CodingKey {
        case backAndForth = "back_and_forth"
        case assignments
    }
}

struct WorkspaceAssignmentFile: Decodable {
    let id: Int64
    let monitor: String
}

struct UIFile: Decodable {
    let menuBar: MenuBarFile?
    let focusBorder: FocusBorderFile?
    let bar: NativeBarFile?

    enum CodingKeys: String, CodingKey {
        case menuBar = "menu_bar"
        case focusBorder = "focus_border"
        case bar
    }
}

struct MenuBarFile: Decodable {
    let enabled: Bool?
}

struct FocusBorderFile: Decodable {
    let width: NumberValue?
    let fallbackCornerRadius: NumberValue?
    let activeColors: [String]?
    let activeAngle: Double?
    let modeColors: [String]?

    enum CodingKeys: String, CodingKey {
        case width
        case fallbackCornerRadius = "fallback_corner_radius"
        case activeColors = "active_colors"
        case activeAngle = "active_angle"
        case modeColors = "mode_colors"
    }
}

struct NativeBarFile: Decodable {
    let enabled: Bool?
    let position: String?
    let height: BarHeightValue?
    let left: [String]?
    let center: [String]?
    let right: [String]?
    let colors: BarColorsFile?
    let weather: BarWeatherFile?
    let plugins: [String: BarPluginFile]?
}

struct BarColorsFile: Decodable {
    let background: String?
    let foreground: String?
    let inactive: String?
    let active: String?
}

struct BarWeatherFile: Decodable {
    let latitude: Double
    let longitude: Double
    let refreshMinutes: Int64?

    enum CodingKeys: String, CodingKey {
        case latitude, longitude
        case refreshMinutes = "refresh_minutes"
    }
}

struct BarPluginFile: Decodable {
    let run: [String]?
    let shell: String?
    let env: [String: String]?
    let refreshSeconds: Int64?
    let events: [String]?
    let timeoutMs: Int64?

    enum CodingKeys: String, CodingKey {
        case run, shell, env, events
        case refreshSeconds = "refresh_seconds"
        case timeoutMs = "timeout_ms"
    }
}

struct KeyboardFile: Decodable {
    let bindings: [KeyboardBindingFile]?
    let pointerBindings: [PointerBindingFile]?

    enum CodingKeys: String, CodingKey {
        case bindings
        case pointerBindings = "pointer_bindings"
    }
}

struct KeyboardBindingFile: Decodable {
    let mode: String?
    let chord: String
    let on: String?
    let repeatAction: Bool?
    let run: [String]?
    let shell: String?
    let env: [String: String]?
    let close: Bool?
    let quit: Bool?
    let focus: String?
    let move: String?
    let swap: String?
    let workspace: ScalarTarget?
    let moveToWorkspace: ScalarTarget?
    let moveToWorkspaceSilent: ScalarTarget?
    let toggleSpecialWorkspace: String?
    let toggleFloating: Bool?
    let setFloating: Bool?
    let setTiled: Bool?
    let fullscreen: String?
    let maximize: String?
    let center: Bool?
    let pin: Bool?
    let resize: [NumberValue]?
    let moveFloating: [NumberValue]?
    let split: String?
    let primary: String?
    let monitor: ScalarTarget?
    let enterMode: String?
    let raise: Bool?
    let refresh: Bool?
    let pause: String?

    enum CodingKeys: String, CodingKey {
        case mode, chord, on, run, shell, env, close, quit, focus, move, swap, workspace
        case repeatAction = "repeat"
        case moveToWorkspace = "move_to_workspace"
        case moveToWorkspaceSilent = "move_to_workspace_silent"
        case toggleSpecialWorkspace = "toggle_special_workspace"
        case toggleFloating = "toggle_floating"
        case setFloating = "set_floating"
        case setTiled = "set_tiled"
        case fullscreen, maximize, center, pin, resize
        case moveFloating = "move_floating"
        case split, primary, monitor
        case enterMode = "enter_mode"
        case raise, refresh, pause
    }
}

struct PointerBindingFile: Decodable {
    let modifiers: [String]
    let button: String
    let drag: String
}

struct StartupFile: Decodable {
    let commands: [CommandFile]?
}

struct CommandFile: Decodable {
    let run: [String]?
    let shell: String?
    let env: [String: String]?
}

struct WindowsFile: Decodable {
    let rules: [WindowRuleFile]?
}

struct WindowRuleFile: Decodable {
    let match: WindowMatchFile
    let floating: Bool?
    let centered: Bool?
    let pinned: Bool?
    let fullscreen: Bool?
    let size: [NumberValue]?
    let position: [NumberValue]?
    let workspace: ScalarTarget?
    let monitor: ScalarTarget?
}

struct WindowMatchFile: Decodable {
    let bundleID: String?
    let appName: String?
    let title: String?

    enum CodingKeys: String, CodingKey {
        case bundleID = "bundle_id"
        case appName = "app_name"
        case title
    }
}

enum NumberValue: Decodable {
    case integer(Int64)
    case float(Double)

    var double: Double {
        switch self {
        case .integer(let value): return Double(value)
        case .float(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        self = .float(try container.decode(Double.self))
    }
}

enum ScalarTarget: Decodable {
    case integer(Int64)
    case string(String)

    var text: String {
        switch self {
        case .integer(let value): return String(value)
        case .string(let value): return value
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .integer(value)
            return
        }
        self = .string(try container.decode(String.self))
    }
}

enum BarHeightValue: Decodable {
    case automatic
    case points(Int64)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int64.self) {
            self = .points(value)
            return
        }
        let value = try container.decode(String.self)
        guard value == "auto" else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "bar height must be 'auto' or an integer")
        }
        self = .automatic
    }
}
