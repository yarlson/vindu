import Foundation

public enum VinduVersion {
    public static let string = "0.1.0"
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

    public static var defaultConfigPath: String { configDir + "/vindu.conf" }
}

/// Hyprland formats window addresses as hex; we use the CGWindowID.
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

/// Shape mirrors `hyprctl clients -j` where macOS has an equivalent field.
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

    public init(_ b: Bind, arg: String) {
        self.locked = b.flags.contains(.locked)
        self.mouse = b.flags.contains(.mouse)
        self.release = b.flags.contains(.release)
        self.repeats = b.flags.contains(.repeats)
        self.modmask = Int(b.mods.rawValue)
        self.submap = b.submap
        self.key = b.key
        self.dispatcher = b.dispatcher.name
        self.arg = arg
        self.description = b.description ?? ""
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

/// Events broadcast on the event socket, wire-compatible with Hyprland's
/// socket2 format: `EVENT>>DATA\n`.
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

    public var line: String {
        switch self {
        case .workspace(let name):
            return "workspace>>\(name)"
        case .workspacev2(let id, let name):
            return "workspacev2>>\(id),\(name)"
        case .focusedmon(let mon, let ws):
            return "focusedmon>>\(mon),\(ws)"
        case .activewindow(let clazz, let title):
            return "activewindow>>\(clazz),\(title)"
        case .activewindowv2(let id):
            return "activewindowv2>>\(id.map(windowAddress) ?? "")"
        case .openwindow(let id, let ws, let clazz, let title):
            return "openwindow>>\(windowAddress(id)),\(ws),\(clazz),\(title)"
        case .closewindow(let id):
            return "closewindow>>\(windowAddress(id))"
        case .movewindow(let id, let ws):
            return "movewindow>>\(windowAddress(id)),\(ws)"
        case .fullscreen(let on):
            return "fullscreen>>\(on ? 1 : 0)"
        case .changefloatingmode(let id, let floating):
            return "changefloatingmode>>\(windowAddress(id)),\(floating ? 1 : 0)"
        case .createworkspace(let name):
            return "createworkspace>>\(name)"
        case .destroyworkspace(let name):
            return "destroyworkspace>>\(name)"
        case .renameworkspace(let id, let name):
            return "renameworkspace>>\(id),\(name)"
        case .submap(let name):
            return "submap>>\(name)"
        case .configreloaded:
            return "configreloaded>>"
        case .monitoradded(let name):
            return "monitoradded>>\(name)"
        case .monitorremoved(let name):
            return "monitorremoved>>\(name)"
        }
    }
}
