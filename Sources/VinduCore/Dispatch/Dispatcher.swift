import Foundation

public enum SplitRatioArg: Equatable {
    case delta(Double)
    case exact(Double)

    public static func parse(_ raw: String) -> SplitRatioArg? {
        let parts = raw.split(separator: " ").map(String.init)
        if parts.count == 2, parts[0] == "exact", let v = Double(parts[1]) {
            return .exact(v)
        }
        if parts.count == 1, let v = Double(parts[0]) {
            return .delta(v)
        }
        return nil
    }

    /// The argument in config syntax; `parse(text)` round-trips.
    public var text: String {
        switch self {
        case .delta(let d): return plainNumber(d)
        case .exact(let v): return "exact \(plainNumber(v))"
        }
    }
}

/// Argument of the `pause` dispatcher (a vindu extension; Hyprland has no
/// equivalent). Pausing suspends all tiling enforcement until resumed.
public enum PauseAction: String, Equatable {
    case toggle, on, off

    public static func parse(_ raw: String) -> PauseAction? {
        switch raw.lowercased() {
        case "", "toggle": return .toggle
        case "on", "1", "true": return .on
        case "off", "0", "false": return .off
        default: return nil
        }
    }
}

public enum MoveWindowArg: Equatable {
    case direction(Direction)
    case monitor(MonitorTarget)
    /// Arg-less `movewindow` from a `bindm` — mouse drag.
    case mouse
}

/// One Hyprland dispatcher invocation, e.g. `movefocus l` or `exec kitty`.
/// Parsed from binds and from the IPC `dispatch` command.
public enum Dispatcher: Equatable {
    case exec(String)
    case killactive
    case closewindow(String)
    case exit
    case workspace(WorkspaceTarget)
    case movetoworkspace(WorkspaceTarget)
    case movetoworkspacesilent(WorkspaceTarget)
    case togglefloating
    case setfloating
    case settiled
    case fullscreen(Int)
    case fakefullscreen
    case movefocus(Direction)
    case movewindow(MoveWindowArg)
    case swapwindow(Direction)
    case centerwindow
    case resizeactive(ResizeParam)
    case moveactive(ResizeParam)
    case splitratio(SplitRatioArg)
    case togglesplit
    case swapsplit
    case layoutmsg(String)
    case togglespecialworkspace(String)
    case pin
    case cyclenext(prev: Bool)
    case swapnext(prev: Bool)
    case focuswindow(String)
    case bringactivetotop
    case alterzorder(String)
    case focusmonitor(MonitorTarget)
    case movecurrentworkspacetomonitor(MonitorTarget)
    case moveworkspacetomonitor(WorkspaceTarget, MonitorTarget)
    case renameworkspace(Int, String)
    case submap(String)
    case focuscurrentorlast
    case forcerendererreload
    /// Mouse-drag resize; meaningful only as a `bindm` dispatcher.
    case resizewindow
    /// Suspend/resume tiling (vindu extension): while paused, frames are not
    /// enforced and non-pause chords pass through to apps.
    case pause(PauseAction)

    public static func parse(name: String, args: String) -> Result<Dispatcher, ParseError> {
        let a = args.trimmingCharacters(in: .whitespaces)

        func wsTarget(_ make: (WorkspaceTarget) -> Dispatcher) -> Result<Dispatcher, ParseError> {
            guard let t = WorkspaceTarget.parse(a) else {
                return .failure("invalid workspace target: \(a)")
            }
            return .success(make(t))
        }
        func direction(_ make: (Direction) -> Dispatcher) -> Result<Dispatcher, ParseError> {
            guard let d = Direction(parsing: a) else {
                return .failure("invalid direction: \(a)")
            }
            return .success(make(d))
        }
        func monTarget(_ make: (MonitorTarget) -> Dispatcher) -> Result<Dispatcher, ParseError> {
            guard let m = MonitorTarget.parse(a) else {
                return .failure("invalid monitor target: \(a)")
            }
            return .success(make(m))
        }
        func resize(_ make: (ResizeParam) -> Dispatcher) -> Result<Dispatcher, ParseError> {
            guard let p = ResizeParam.parse(a) else {
                return .failure("invalid resize params: \(a)")
            }
            return .success(make(p))
        }

        switch name.lowercased() {
        case "exec", "execr":
            return a.isEmpty ? .failure("exec needs a command") : .success(.exec(a))
        case "killactive":
            return .success(.killactive)
        case "closewindow":
            return a.isEmpty ? .failure("closewindow needs a matcher") : .success(.closewindow(a))
        case "exit", "forceexit":
            return .success(.exit)
        case "workspace":
            return wsTarget { .workspace($0) }
        case "movetoworkspace":
            return wsTarget { .movetoworkspace($0) }
        case "movetoworkspacesilent":
            return wsTarget { .movetoworkspacesilent($0) }
        case "togglefloating":
            return .success(.togglefloating)
        case "setfloating":
            return .success(.setfloating)
        case "settiled":
            return .success(.settiled)
        case "fullscreen":
            let mode = a.isEmpty ? 0 : Int(a)
            guard let m = mode, (0...1).contains(m) else {
                return .failure("fullscreen mode must be 0 or 1")
            }
            return .success(.fullscreen(m))
        case "fakefullscreen":
            return .success(.fakefullscreen)
        case "movefocus":
            return direction { .movefocus($0) }
        case "movewindow":
            if a.isEmpty {
                return .success(.movewindow(.mouse))
            }
            if let mon = a.removingPrefix("mon:") {
                guard let m = MonitorTarget.parse(mon) else {
                    return .failure("invalid monitor target: \(mon)")
                }
                return .success(.movewindow(.monitor(m)))
            }
            guard let d = Direction(parsing: a) else {
                return .failure("invalid direction: \(a)")
            }
            return .success(.movewindow(.direction(d)))
        case "resizewindow":
            return .success(.resizewindow)
        case "swapwindow":
            return direction { .swapwindow($0) }
        case "centerwindow":
            return .success(.centerwindow)
        case "resizeactive":
            return resize { .resizeactive($0) }
        case "moveactive":
            return resize { .moveactive($0) }
        case "splitratio":
            guard let r = SplitRatioArg.parse(a) else {
                return .failure("invalid splitratio: \(a)")
            }
            return .success(.splitratio(r))
        case "togglesplit":
            return .success(.togglesplit)
        case "swapsplit":
            return .success(.swapsplit)
        case "layoutmsg":
            return a.isEmpty ? .failure("layoutmsg needs a message") : .success(.layoutmsg(a))
        case "togglespecialworkspace":
            return .success(.togglespecialworkspace(a.isEmpty ? "special" : a))
        case "pin":
            return .success(.pin)
        case "cyclenext":
            return .success(.cyclenext(prev: a.contains("prev")))
        case "swapnext":
            return .success(.swapnext(prev: a.contains("prev")))
        case "swapprev":
            return .success(.swapnext(prev: true))
        case "focuswindow":
            return a.isEmpty ? .failure("focuswindow needs a matcher") : .success(.focuswindow(a))
        case "bringactivetotop":
            return .success(.bringactivetotop)
        case "alterzorder":
            return a.isEmpty ? .failure("alterzorder needs top/bottom") : .success(.alterzorder(a))
        case "focusmonitor":
            return monTarget { .focusmonitor($0) }
        case "movecurrentworkspacetomonitor":
            return monTarget { .movecurrentworkspacetomonitor($0) }
        case "moveworkspacetomonitor":
            let parts = a.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let ws = WorkspaceTarget.parse(parts[0]),
                  let mon = MonitorTarget.parse(parts[1]) else {
                return .failure("moveworkspacetomonitor needs: <workspace> <monitor>")
            }
            return .success(.moveworkspacetomonitor(ws, mon))
        case "renameworkspace":
            let parts = a.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let id = Int(parts[0]) else {
                return .failure("renameworkspace needs: <id> <new name>")
            }
            return .success(.renameworkspace(id, parts[1]))
        case "submap":
            return .success(.submap(a == "reset" ? "" : a))
        case "focuscurrentorlast":
            return .success(.focuscurrentorlast)
        case "forcerendererreload":
            return .success(.forcerendererreload)
        case "pause":
            guard let action = PauseAction.parse(a) else {
                return .failure("pause takes: toggle, on, or off")
            }
            return .success(.pause(action))
        default:
            return .failure("unknown dispatcher: \(name)")
        }
    }

    /// Hyprland dispatcher name, used in `binds` listings.
    public var name: String {
        switch self {
        case .exec: return "exec"
        case .killactive: return "killactive"
        case .closewindow: return "closewindow"
        case .exit: return "exit"
        case .workspace: return "workspace"
        case .movetoworkspace: return "movetoworkspace"
        case .movetoworkspacesilent: return "movetoworkspacesilent"
        case .togglefloating: return "togglefloating"
        case .setfloating: return "setfloating"
        case .settiled: return "settiled"
        case .fullscreen: return "fullscreen"
        case .fakefullscreen: return "fakefullscreen"
        case .movefocus: return "movefocus"
        case .movewindow: return "movewindow"
        case .swapwindow: return "swapwindow"
        case .centerwindow: return "centerwindow"
        case .resizeactive: return "resizeactive"
        case .moveactive: return "moveactive"
        case .splitratio: return "splitratio"
        case .togglesplit: return "togglesplit"
        case .swapsplit: return "swapsplit"
        case .layoutmsg: return "layoutmsg"
        case .togglespecialworkspace: return "togglespecialworkspace"
        case .pin: return "pin"
        case .cyclenext: return "cyclenext"
        case .swapnext: return "swapnext"
        case .focuswindow: return "focuswindow"
        case .bringactivetotop: return "bringactivetotop"
        case .alterzorder: return "alterzorder"
        case .focusmonitor: return "focusmonitor"
        case .movecurrentworkspacetomonitor: return "movecurrentworkspacetomonitor"
        case .moveworkspacetomonitor: return "moveworkspacetomonitor"
        case .renameworkspace: return "renameworkspace"
        case .submap: return "submap"
        case .focuscurrentorlast: return "focuscurrentorlast"
        case .forcerendererreload: return "forcerendererreload"
        case .resizewindow: return "resizewindow"
        case .pause: return "pause"
        }
    }

    /// The argument in config syntax (empty for arg-less dispatchers), used by
    /// the `binds` listing and the keybinding cheat sheet.
    public var argText: String {
        switch self {
        case .exec(let c): return c
        case .closewindow(let m), .focuswindow(let m): return m
        case .workspace(let t), .movetoworkspace(let t), .movetoworkspacesilent(let t):
            return t.text
        case .fullscreen(let m): return String(m)
        case .movefocus(let d), .swapwindow(let d): return d.rawValue
        case .movewindow(let arg):
            switch arg {
            case .mouse: return ""
            case .direction(let d): return d.rawValue
            case .monitor(let m): return "mon:\(m.text)"
            }
        case .resizeactive(let p), .moveactive(let p): return p.text
        case .splitratio(let a): return a.text
        case .layoutmsg(let m): return m
        case .togglespecialworkspace(let s): return s == "special" ? "" : s
        case .cyclenext(let prev), .swapnext(let prev): return prev ? "prev" : ""
        case .alterzorder(let a): return a
        case .focusmonitor(let t), .movecurrentworkspacetomonitor(let t): return t.text
        case .moveworkspacetomonitor(let w, let m): return "\(w.text) \(m.text)"
        case .renameworkspace(let id, let name): return "\(id) \(name)"
        case .submap(let s): return s.isEmpty ? "reset" : s
        case .pause(let a): return a == .toggle ? "" : a.rawValue
        case .killactive, .exit, .togglefloating, .setfloating, .settiled, .fakefullscreen,
             .centerwindow, .togglesplit, .swapsplit, .pin, .bringactivetotop,
             .focuscurrentorlast, .forcerendererreload, .resizewindow:
            return ""
        }
    }
}
