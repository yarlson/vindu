import Foundation

public struct ConfigurationSnapshot: Equatable {
    public let schema: Int
    public let layout: LayoutConfiguration
    public let focus: FocusConfiguration
    public let workspaces: WorkspacesConfiguration
    public let ui: UIConfiguration
    public let keyboard: KeyboardConfiguration
    public let startup: StartupConfiguration
    public let windows: WindowsConfiguration

    public init(schema: Int,
                layout: LayoutConfiguration,
                focus: FocusConfiguration,
                workspaces: WorkspacesConfiguration,
                ui: UIConfiguration,
                keyboard: KeyboardConfiguration,
                startup: StartupConfiguration,
                windows: WindowsConfiguration) {
        self.schema = schema
        self.layout = layout
        self.focus = focus
        self.workspaces = workspaces
        self.ui = ui
        self.keyboard = keyboard
        self.startup = startup
        self.windows = windows
    }
}

public struct LayoutConfiguration: Equatable {
    public let kind: LayoutKind
    public let innerGap: Double
    public let outerGap: Double
    public let dwindle: DwindleConfiguration
    public let master: MasterConfiguration
}

public struct DwindleConfiguration: Equatable {
    public enum NewWindowPosition: String, Equatable {
        case before, after
    }

    public let newWindowFraction: Double
    public let newWindowPosition: NewWindowPosition
}

public struct MasterConfiguration: Equatable {
    public enum NewWindowPosition: String, Equatable {
        case primary
        case stackStart = "stack-start"
        case stackEnd = "stack-end"
    }

    public let primaryFraction: Double
    public let primaryPosition: MasterOrientation
    public let newWindowPosition: NewWindowPosition
}

public struct FocusConfiguration: Equatable {
    public let followsPointer: Bool
    public let allowAppActivation: Bool
}

public struct WorkspacesConfiguration: Equatable {
    public let backAndForth: Bool
    public let assignments: [WorkspaceAssignment]
}

public struct WorkspaceAssignment: Equatable {
    public let id: Int
    public let monitor: String

    public init(id: Int, monitor: String) {
        self.id = id
        self.monitor = monitor
    }
}

public struct UIConfiguration: Equatable {
    public let menuBar: MenuBarConfiguration
    public let focusBorder: FocusBorderConfiguration
    public let bar: NativeBarConfiguration
}

public struct MenuBarConfiguration: Equatable {
    public let enabled: Bool
}

public struct FocusBorderConfiguration: Equatable {
    public let width: Double
    public let fallbackCornerRadius: Double
    public let activeColors: [ConfigurationColor]
    public let activeAngle: Double
    public let modeColors: [ConfigurationColor]
}

public struct ConfigurationColor: Equatable {
    public let red: Double
    public let green: Double
    public let blue: Double
    public let alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct NativeBarConfiguration: Equatable {
    public let enabled: Bool
    public let position: BarPosition
    public let height: BarHeight
    public let left: [NativeBarItem]
    public let center: [NativeBarItem]
    public let right: [NativeBarItem]
    public let colors: NativeBarColors
    public let weather: NativeBarWeather?
    public let plugins: [String: NativeBarPlugin]

    public var allItems: [NativeBarItem] {
        left + center + right
    }

    public var pluginIDs: [String] {
        allItems.compactMap {
            guard case .plugin(let id) = $0 else { return nil }
            return id
        }
    }

    public func contains(_ item: NativeBarItem) -> Bool {
        allItems.contains(item)
    }
}

public enum BarHeight: Equatable {
    case automatic
    case points(Int)
}

public enum NativeBarItem: Equatable, Hashable {
    case workspaces
    case application
    case pause
    case mode
    case layout
    case windows
    case date
    case battery
    case network
    case keyboard
    case volume
    case weather
    case plugin(String)
}

public struct NativeBarColors: Equatable {
    public let background: ConfigurationColor
    public let foreground: ConfigurationColor
    public let inactive: ConfigurationColor
    public let active: ConfigurationColor
}

public struct NativeBarWeather: Equatable {
    public let latitude: Double
    public let longitude: Double
    public let refreshMinutes: Int
}

public struct NativeBarPlugin: Equatable {
    public let command: CommandSpec
    public let refreshSeconds: Int
    public let events: [String]
    public let timeoutMs: Int
}

public struct KeyboardConfiguration: Equatable {
    public let bindings: [KeyboardBinding]
    public let pointerBindings: [PointerBinding]
}

public struct KeyboardBinding: Equatable {
    public let mode: String
    public let chord: KeyChord
    public let edge: BindingEdge
    public let repeats: Bool
    public let action: ConfiguredAction
}

public struct KeyChord: Equatable, Hashable {
    public let modifiers: [KeyboardModifier]
    public let key: String

    public var text: String {
        (modifiers.map(\.rawValue) + [key]).joined(separator: "+")
    }
}

public enum KeyboardModifier: String, CaseIterable, Equatable, Hashable {
    case command, option, control, shift
}

public enum BindingEdge: String, Equatable, Hashable {
    case press, release
}

public struct PointerBinding: Equatable {
    public let modifiers: [KeyboardModifier]
    public let button: PointerButton
    public let drag: PointerDrag

    public init(modifiers: [KeyboardModifier], button: PointerButton, drag: PointerDrag) {
        self.modifiers = modifiers
        self.button = button
        self.drag = drag
    }
}

public enum PointerButton: String, Equatable, Hashable {
    case left, right, middle
}

public enum PointerDrag: String, Equatable {
    case move, resize
}

public enum ConfiguredAction: Equatable {
    case window(WindowAction)
    case command(CommandSpec)
}

public enum WindowAction: Equatable {
    case close
    case quit
    case focus(Direction)
    case move(Direction)
    case swap(Direction)
    case workspace(WorkspaceTarget)
    case moveToWorkspace(WorkspaceTarget)
    case moveToWorkspaceSilent(WorkspaceTarget)
    case toggleSpecialWorkspace(String)
    case toggleFloating
    case setFloating
    case setTiled
    case fullscreen(ActionState)
    case maximize(ActionState)
    case center
    case pin
    case resize(x: Double, y: Double)
    case moveFloating(x: Double, y: Double)
    case split(SplitAction)
    case primary(PrimaryAction)
    case monitor(MonitorTarget)
    case enterMode(String)
    case raise
    case refresh
    case pause(PauseAction)
}

public enum ActionState: String, Equatable {
    case toggle, on, off
}

public enum SplitAction: String, Equatable {
    case toggle
    case horizontal
    case vertical
    case swap
}

public enum PrimaryAction: String, Equatable {
    case focus
    case swap
    case add
    case remove
}

public struct CommandSpec: Equatable {
    public enum Execution: Equatable {
        case run([String])
        case shell(String)
    }

    public let execution: Execution
    public let environment: [String: String]

    public var argv: [String]? {
        guard case .run(let argv) = execution else { return nil }
        return argv
    }

    public var shell: String? {
        guard case .shell(let script) = execution else { return nil }
        return script
    }
}

public struct StartupConfiguration: Equatable {
    public let commands: [CommandSpec]
}

public struct WindowsConfiguration: Equatable {
    public let rules: [NativeWindowRule]
}

public struct NativeWindowRule: Equatable {
    public let match: NativeWindowMatcher
    public let floating: Bool?
    public let centered: Bool?
    public let pinned: Bool?
    public let fullscreen: Bool?
    public let size: WindowVector?
    public let position: WindowVector?
    public let workspace: WorkspaceTarget?
    public let monitor: MonitorTarget?

    public init(match: NativeWindowMatcher,
                floating: Bool? = nil,
                centered: Bool? = nil,
                pinned: Bool? = nil,
                fullscreen: Bool? = nil,
                size: WindowVector? = nil,
                position: WindowVector? = nil,
                workspace: WorkspaceTarget? = nil,
                monitor: MonitorTarget? = nil) {
        self.match = match
        self.floating = floating
        self.centered = centered
        self.pinned = pinned
        self.fullscreen = fullscreen
        self.size = size
        self.position = position
        self.workspace = workspace
        self.monitor = monitor
    }
}

public struct NativeWindowMatcher: Equatable {
    public let bundleID: String?
    public let appName: String?
    public let title: String?

    public init(bundleID: String? = nil, appName: String? = nil, title: String? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
    }
}

public struct WindowVector: Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct ConfigurationDiagnostic: Equatable, CustomStringConvertible {
    public let line: Int?
    public let keyPath: String?
    public let message: String

    public init(line: Int? = nil, keyPath: String? = nil, message: String) {
        self.line = line
        self.keyPath = keyPath
        self.message = message
    }

    public var description: String {
        let location = [line.map { "line \($0)" }, keyPath].compactMap { $0 }.joined(separator: ", ")
        return location.isEmpty ? message : "\(location): \(message)"
    }
}

public struct ConfigurationFailure: Error, Equatable {
    public let diagnostics: [ConfigurationDiagnostic]

    public init(_ diagnostics: [ConfigurationDiagnostic]) {
        self.diagnostics = diagnostics
    }
}
