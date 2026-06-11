import Foundation

public enum MasterOrientation: String, Equatable {
    case left, right, top, bottom, center
}

public struct GeneralSettings: Equatable {
    public var gapsIn: Double = 5
    public var gapsOut: Double = 20
    public var borderSize: Double = 2
    public var activeBorder = MLGradient(
        colors: [MLColor.parse("rgba(33ccffee)")!, MLColor.parse("rgba(00ff99ee)")!],
        angleDeg: 45
    )
    public var inactiveBorder = MLGradient(colors: [MLColor.parse("rgba(595959aa)")!])
    public var layout = LayoutKind.dwindle
}

public struct DecorationSettings: Equatable {
    public var rounding: Double = 0
}

public struct DwindleSettings: Equatable {
    /// 0 = orientation from the split target's aspect ratio, 1 = new window first
    /// (left/top), 2 = new window second (right/bottom). Matches Hyprland's force_split.
    public var forceSplit = 0
    /// Hyprland scale: 0.1–1.9 where 1.0 is an even split.
    public var defaultSplitRatio = 1.0
}

public struct MasterSettings: Equatable {
    /// Where new windows go: "master" or "slave".
    public var newStatus = "slave"
    public var newOnTop = false
    public var mfact = 0.55
    public var orientation = MasterOrientation.left
}

public struct InputSettings: Equatable {
    /// 0 = focus on click only, 1 = focus follows mouse (best effort on macOS:
    /// focusing another app's window also activates the app, which may raise it).
    public var followMouse = 0
}

public struct MiscSettings: Equatable {
    public var focusOnActivate = false
}

public struct BindsSettings: Equatable {
    public var workspaceBackAndForth = false
}

public struct Settings: Equatable {
    public var general = GeneralSettings()
    public var decoration = DecorationSettings()
    public var dwindle = DwindleSettings()
    public var master = MasterSettings()
    public var input = InputSettings()
    public var misc = MiscSettings()
    public var binds = BindsSettings()

    public init() {}

    /// Applies one `section:key = value` assignment. Returns an error message,
    /// or nil when the value was applied (or deliberately tolerated).
    public mutating func set(_ keyword: String, _ rawValue: String) -> String? {
        let key = keyword.lowercased()
        let value = rawValue.trimmingCharacters(in: .whitespaces)
        if let option = Settings.options[key] {
            return option.set(&self, value).map { "\($0) for \(keyword): \(rawValue)" }
        }
        if Settings.isTolerated(key) {
            return nil
        }
        return "unknown keyword: \(keyword)"
    }

    /// Reads back a keyword's current value (IPC `getoption`).
    public func get(_ keyword: String) -> String? {
        Settings.options[keyword.lowercased()]?.get(self)
    }

    // MARK: - Option table

    /// One entry per modeled keyword; drives both `set` and `get`.
    private struct Option {
        let get: (Settings) -> String
        /// Returns a short problem description ("invalid number") or nil on success.
        let set: (inout Settings, String) -> String?
    }

    private static let options: [String: Option] = [
        "general:gaps_in": double(\.general.gapsIn),
        "general:gaps_out": double(\.general.gapsOut),
        "general:border_size": double(\.general.borderSize),
        "general:col.active_border": gradient(\.general.activeBorder),
        "general:col.inactive_border": gradient(\.general.inactiveBorder),
        "general:layout": layout(\.general.layout),
        "decoration:rounding": double(\.decoration.rounding),
        "dwindle:force_split": int(\.dwindle.forceSplit, in: 0...2),
        "dwindle:default_split_ratio": double(\.dwindle.defaultSplitRatio, in: 0.1...1.9),
        "master:new_status": choice(\.master.newStatus, allowed: ["master", "slave", "inherit"]),
        "master:new_on_top": bool(\.master.newOnTop),
        "master:mfact": double(\.master.mfact, in: 0.0...1.0),
        "master:orientation": orientation(\.master.orientation),
        "input:follow_mouse": int(\.input.followMouse, in: 0...3),
        "misc:focus_on_activate": bool(\.misc.focusOnActivate),
        "binds:workspace_back_and_forth": bool(\.binds.workspaceBackAndForth),
    ]

    private static func double(_ kp: WritableKeyPath<Settings, Double>,
                               in range: ClosedRange<Double>? = nil) -> Option {
        Option(get: { String($0[keyPath: kp]) }, set: { settings, value in
            guard let n = Double(value) else { return "invalid number" }
            if let range, !range.contains(n) { return "value out of range \(range)" }
            settings[keyPath: kp] = n
            return nil
        })
    }

    private static func int(_ kp: WritableKeyPath<Settings, Int>,
                            in range: ClosedRange<Int>) -> Option {
        Option(get: { String($0[keyPath: kp]) }, set: { settings, value in
            guard let n = Int(value) else { return "invalid integer" }
            guard range.contains(n) else { return "value out of range \(range)" }
            settings[keyPath: kp] = n
            return nil
        })
    }

    private static func bool(_ kp: WritableKeyPath<Settings, Bool>) -> Option {
        Option(get: { String($0[keyPath: kp]) }, set: { settings, value in
            switch value.lowercased() {
            case "true", "1", "yes", "on": settings[keyPath: kp] = true
            case "false", "0", "no", "off": settings[keyPath: kp] = false
            default: return "invalid bool"
            }
            return nil
        })
    }

    private static func gradient(_ kp: WritableKeyPath<Settings, MLGradient>) -> Option {
        Option(get: { settings in
            let colors = settings[keyPath: kp].colors.map { color in
                String(format: "rgba(%02x%02x%02x%02x)", Int(color.r * 255), Int(color.g * 255),
                       Int(color.b * 255), Int(color.a * 255))
            }
            let angle = settings[keyPath: kp].angleDeg
            return (colors + (angle != 0 ? ["\(Int(angle))deg"] : [])).joined(separator: " ")
        }, set: { settings, value in
            guard let g = MLGradient.parse(value) else { return "invalid color" }
            settings[keyPath: kp] = g
            return nil
        })
    }

    private static func layout(_ kp: WritableKeyPath<Settings, LayoutKind>) -> Option {
        Option(get: { $0[keyPath: kp].rawValue }, set: { settings, value in
            guard let l = LayoutKind(rawValue: value.lowercased()) else { return "invalid layout" }
            settings[keyPath: kp] = l
            return nil
        })
    }

    private static func orientation(_ kp: WritableKeyPath<Settings, MasterOrientation>) -> Option {
        Option(get: { $0[keyPath: kp].rawValue }, set: { settings, value in
            guard let o = MasterOrientation(rawValue: value.lowercased()) else { return "invalid orientation" }
            settings[keyPath: kp] = o
            return nil
        })
    }

    private static func choice(_ kp: WritableKeyPath<Settings, String>,
                               allowed: Set<String>) -> Option {
        Option(get: { $0[keyPath: kp] }, set: { settings, value in
            let v = value.lowercased()
            guard allowed.contains(v) else { return "expected one of \(allowed.sorted())" }
            settings[keyPath: kp] = v
            return nil
        })
    }

    // MARK: - Hyprland compatibility tolerance

    /// Sections that exist in Hyprland but have no macOS counterpart at all.
    /// Every key under them is accepted silently so real configs load cleanly.
    private static let toleratedSectionPrefixes = [
        "animations:", "gestures:", "group:", "cursor:", "debug:", "ecosystem:",
        "xwayland:", "opengl:", "render:", "device:", "plugin:",
        // Nested subsections of modeled sections that we don't model.
        "decoration:blur:", "decoration:shadow:", "input:touchpad:", "input:tablet:",
        "general:snap:",
    ]

    /// Known Hyprland keys inside sections we *do* model (the stock
    /// hyprland.conf set). Tolerated silently; anything else in a modeled
    /// section is reported, so typos like `preserve_splitt` stay visible.
    private static let toleratedKeys: Set<String> = [
        "general:resize_on_border", "general:extend_border_grab_area",
        "general:hover_icon_on_border", "general:allow_tearing",
        "general:no_border_on_floating", "general:no_focus_fallback",
        "decoration:active_opacity", "decoration:inactive_opacity",
        "decoration:fullscreen_opacity", "decoration:drop_shadow",
        "decoration:shadow_range", "decoration:shadow_render_power",
        "decoration:col.shadow", "decoration:dim_inactive", "decoration:dim_strength",
        "decoration:dim_special",
        "dwindle:pseudotile", "dwindle:preserve_split",
        "dwindle:smart_split", "dwindle:smart_resizing", "dwindle:no_gaps_when_only",
        "dwindle:split_width_multiplier", "dwindle:use_active_for_splits",
        "master:allow_small_split", "master:special_scale_factor",
        "master:no_gaps_when_only", "master:inherit_fullscreen", "master:smart_resizing",
        "master:drop_at_cursor",
        "input:kb_layout", "input:kb_variant", "input:kb_model", "input:kb_options",
        "input:kb_rules", "input:kb_file", "input:numlock_by_default",
        "input:repeat_rate", "input:repeat_delay", "input:sensitivity",
        "input:accel_profile", "input:force_no_accel", "input:left_handed",
        "input:scroll_method", "input:scroll_button", "input:natural_scroll",
        "input:float_switch_override_focus", "input:mouse_refocus",
        "input:special_fallthrough",
        "misc:disable_hyprland_logo", "misc:disable_splash_rendering",
        "misc:force_default_wallpaper", "misc:vfr", "misc:vrr",
        "misc:mouse_move_enables_dpms", "misc:key_press_enables_dpms",
        "misc:animate_manual_resizes", "misc:animate_mouse_windowdragging",
        "misc:enable_swallow", "misc:swallow_regex", "misc:mouse_move_focuses_monitor",
        "misc:new_window_takes_over_fullscreen", "misc:background_color",
        "binds:allow_workspace_cycles", "binds:scroll_event_delay",
        "binds:pass_mouse_when_bound", "binds:movefocus_cycles_fullscreen",
        "binds:window_direction_monitor_fallback",
    ]

    private static func isTolerated(_ key: String) -> Bool {
        toleratedKeys.contains(key)
            || toleratedSectionPrefixes.contains { key.hasPrefix($0) }
    }
}
