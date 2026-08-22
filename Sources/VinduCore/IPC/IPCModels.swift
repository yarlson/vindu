import Foundation

public enum VinduVersion {
    public static let string = "0.6.3"
}

public enum VinduPaths {
    public static var runtimeDir: String {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            return xdg + "/vindu"
        }
        // NSTemporaryDirectory is per-user on macOS, mirroring XDG_RUNTIME_DIR's role.
        return (NSTemporaryDirectory() as NSString).appendingPathComponent("vindu")
    }

    public static var commandSocketPath: String { runtimeDir + "/vindu.sock" }
    public static var eventSocketPath: String { runtimeDir + "/vindu.events.sock" }

    public static var configDir: String {
        let env = ProcessInfo.processInfo.environment
        if let xdg = env["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return xdg + "/vindu"
        }
        return NSHomeDirectory() + "/.config/vindu"
    }

    public static var defaultConfigPath: String { configDir + "/vindu.toml" }
    public static var legacyConfigPath: String { configDir + "/vindu.conf" }
}

public enum ConfigDaemonState: String, Codable, Equatable {
    case configurationOnly = "configuration_only"
    case waitingForAccessibility = "waiting_for_accessibility"
    case running
}

public struct LocatedConfigDiagnostic: Codable, Equatable {
    public let file: String
    public let line: Int?
    public let schemaPath: String?
    public let message: String

    public init(file: String, line: Int? = nil, schemaPath: String? = nil, message: String) {
        self.file = file
        self.line = line
        self.schemaPath = schemaPath
        self.message = message
    }

    enum CodingKeys: String, CodingKey {
        case file, line, message
        case schemaPath = "schema_path"
    }
}

public struct ConfigStatus: Codable, Equatable {
    public let path: String
    public let daemonState: ConfigDaemonState
    public let activeSchema: Int?
    public let latestAttemptSucceeded: Bool
    public let rejectedDiagnostics: [LocatedConfigDiagnostic]
    public let runtimeWarnings: [LocatedConfigDiagnostic]

    public init(path: String,
                daemonState: ConfigDaemonState,
                activeSchema: Int?,
                latestAttemptSucceeded: Bool,
                rejectedDiagnostics: [LocatedConfigDiagnostic],
                runtimeWarnings: [LocatedConfigDiagnostic]) {
        self.path = path
        self.daemonState = daemonState
        self.activeSchema = activeSchema
        self.latestAttemptSucceeded = latestAttemptSucceeded
        self.rejectedDiagnostics = rejectedDiagnostics
        self.runtimeWarnings = runtimeWarnings
    }

    enum CodingKeys: String, CodingKey {
        case path
        case daemonState = "daemon_state"
        case activeSchema = "active_schema"
        case latestAttemptSucceeded = "latest_attempt_succeeded"
        case rejectedDiagnostics = "rejected_diagnostics"
        case runtimeWarnings = "runtime_warnings"
    }
}

/// Public IPC renders the CGWindowID as a hexadecimal address.
public func windowAddress(_ id: WindowID) -> String {
    String(format: "0x%x", id)
}

public struct WorkspaceRef: Codable, Equatable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

/// Published JSON shape for one managed window.
public struct ClientInfo: Codable {
    public var address: String
    public var mapped: Bool
    public var hidden: Bool
    public var at: [Int]
    public var size: [Int]
    public var workspace: WorkspaceRef
    public var floating: Bool
    public var pinned: Bool
    public var fullscreen: Int
    public var fakeFullscreen: Bool
    public var monitor: Int
    public var clazz: String
    public var title: String
    public var initialClass: String
    public var initialTitle: String
    public var pid: Int
    public var focusHistoryID: Int

    public init(address: String, mapped: Bool, hidden: Bool, at: [Int], size: [Int],
                workspace: WorkspaceRef, floating: Bool, pinned: Bool, fullscreen: Int,
                fakeFullscreen: Bool, monitor: Int, clazz: String, title: String,
                initialClass: String, initialTitle: String, pid: Int, focusHistoryID: Int) {
        self.address = address
        self.mapped = mapped
        self.hidden = hidden
        self.at = at
        self.size = size
        self.workspace = workspace
        self.floating = floating
        self.pinned = pinned
        self.fullscreen = fullscreen
        self.fakeFullscreen = fakeFullscreen
        self.monitor = monitor
        self.clazz = clazz
        self.title = title
        self.initialClass = initialClass
        self.initialTitle = initialTitle
        self.pid = pid
        self.focusHistoryID = focusHistoryID
    }

    enum CodingKeys: String, CodingKey {
        case address, mapped, hidden, at, size, workspace, floating, pinned,
             fullscreen, fakeFullscreen, monitor, title, initialClass, initialTitle,
             pid, focusHistoryID
        case clazz = "class"
    }
}

public struct WorkspaceInfo: Codable {
    public var id: Int
    public var name: String
    public var monitor: String
    public var monitorID: Int
    public var windows: Int
    public var hasfullscreen: Bool
    public var lastwindow: String
    public var lastwindowtitle: String

    public init(id: Int, name: String, monitor: String, monitorID: Int, windows: Int,
                hasfullscreen: Bool, lastwindow: String, lastwindowtitle: String) {
        self.id = id
        self.name = name
        self.monitor = monitor
        self.monitorID = monitorID
        self.windows = windows
        self.hasfullscreen = hasfullscreen
        self.lastwindow = lastwindow
        self.lastwindowtitle = lastwindowtitle
    }
}

public struct MonitorInfo: Codable {
    public var id: Int
    public var name: String
    public var width: Int
    public var height: Int
    public var x: Int
    public var y: Int
    public var activeWorkspace: WorkspaceRef
    public var specialWorkspace: WorkspaceRef
    public var scale: Double
    public var focused: Bool

    public init(id: Int, name: String, width: Int, height: Int, x: Int, y: Int,
                activeWorkspace: WorkspaceRef, specialWorkspace: WorkspaceRef,
                scale: Double, focused: Bool) {
        self.id = id
        self.name = name
        self.width = width
        self.height = height
        self.x = x
        self.y = y
        self.activeWorkspace = activeWorkspace
        self.specialWorkspace = specialWorkspace
        self.scale = scale
        self.focused = focused
    }
}

public struct BindInfo: Codable {
    public var locked: Bool
    public var mouse: Bool
    public var release: Bool
    public var repeats: Bool
    public var modmask: Int
    public var submap: String
    public var key: String
    public var dispatcher: String
    public var arg: String
    public var description: String

    public init(locked: Bool, mouse: Bool, release: Bool, repeats: Bool,
                modmask: Int, submap: String, key: String, dispatcher: String,
                arg: String, description: String) {
        self.locked = locked
        self.mouse = mouse
        self.release = release
        self.repeats = repeats
        self.modmask = modmask
        self.submap = submap
        self.key = key
        self.dispatcher = dispatcher
        self.arg = arg
        self.description = description
    }
}

public struct VersionInfo: Codable {
    public var version: String
    public var branch: String
    public var system: String

    public init(version: String, branch: String = "main", system: String) {
        self.version = version
        self.branch = branch
        self.system = system
    }
}

public func encodeJSON<T: Encodable>(_ value: T) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(value) else { return "{}" }
    return String(data: data, encoding: .utf8) ?? "{}"
}

/// Events broadcast on the public event socket as `EVENT>>DATA\n`.
public enum WMEvent {
    case workspace(String)
    case workspacev2(Int, String)
    case focusedmon(monitor: String, workspace: String)
    case activewindow(clazz: String, title: String)
    case activewindowv2(WindowID?)
    case openwindow(WindowID, workspace: String, clazz: String, title: String)
    case closewindow(WindowID)
    case movewindow(WindowID, workspace: String)
    case fullscreen(Bool)
    case changefloatingmode(WindowID, Bool)
    case createworkspace(String)
    case destroyworkspace(String)
    case renameworkspace(Int, String)
    case submap(String)
    case configreloaded
    case monitoradded(String)
    case monitorremoved(String)
    /// Tiling suspended or resumed.
    case pause(Bool)

    public var name: String {
        switch self {
        case .workspace: return "workspace"
        case .workspacev2: return "workspacev2"
        case .focusedmon: return "focusedmon"
        case .activewindow: return "activewindow"
        case .activewindowv2: return "activewindowv2"
        case .openwindow: return "openwindow"
        case .closewindow: return "closewindow"
        case .movewindow: return "movewindow"
        case .fullscreen: return "fullscreen"
        case .changefloatingmode: return "changefloatingmode"
        case .createworkspace: return "createworkspace"
        case .destroyworkspace: return "destroyworkspace"
        case .renameworkspace: return "renameworkspace"
        case .submap: return "submap"
        case .configreloaded: return "configreloaded"
        case .monitoradded: return "monitoradded"
        case .monitorremoved: return "monitorremoved"
        case .pause: return "pause"
        }
    }

    public var payload: String {
        switch self {
        case .workspace(let name):
            return name
        case .workspacev2(let id, let name):
            return "\(id),\(name)"
        case .focusedmon(let mon, let ws):
            return "\(mon),\(ws)"
        case .activewindow(let clazz, let title):
            return "\(clazz),\(title)"
        case .activewindowv2(let id):
            return id.map(windowAddress) ?? ""
        case .openwindow(let id, let ws, let clazz, let title):
            return "\(windowAddress(id)),\(ws),\(clazz),\(title)"
        case .closewindow(let id):
            return windowAddress(id)
        case .movewindow(let id, let ws):
            return "\(windowAddress(id)),\(ws)"
        case .fullscreen(let on):
            return on ? "1" : "0"
        case .changefloatingmode(let id, let floating):
            return "\(windowAddress(id)),\(floating ? 1 : 0)"
        case .createworkspace(let name):
            return name
        case .destroyworkspace(let name):
            return name
        case .renameworkspace(let id, let name):
            return "\(id),\(name)"
        case .submap(let name):
            return name
        case .configreloaded:
            return ""
        case .monitoradded(let name):
            return name
        case .monitorremoved(let name):
            return name
        case .pause(let on):
            return on ? "1" : "0"
        }
    }

    public var line: String {
        "\(name)>>\(WMEvent.lineSafe(payload))"
    }

    private static func lineSafe(_ value: String) -> String {
        String(value.map { $0 == "\n" || $0 == "\r" ? " " : $0 })
    }
}
