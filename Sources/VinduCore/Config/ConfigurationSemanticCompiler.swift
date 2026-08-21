import Foundation

enum ConfigurationSemanticCompiler {
    static func compile(_ file: ConfigurationFile) throws -> ConfigurationSnapshot {
        guard file.schema == 1 else {
            throw invalid("schema", "schema must be 1")
        }
        return ConfigurationSnapshot(
            schema: 1,
            layout: try compileLayout(file.layout),
            focus: compileFocus(file.focus),
            workspaces: try compileWorkspaces(file.workspaces),
            ui: try compileUI(file.ui),
            keyboard: try compileKeyboard(file.keyboard),
            startup: try compileStartup(file.startup),
            windows: try compileWindows(file.windows)
        )
    }

    private static func compileLayout(_ file: LayoutFile?) throws -> LayoutConfiguration {
        let kindName = file?.kind ?? "dwindle"
        guard let kind = LayoutKind(rawValue: kindName) else {
            throw invalid("layout.kind", "layout.kind must be 'dwindle' or 'master'")
        }
        let innerGap = file?.innerGap?.double ?? 5
        let outerGap = file?.outerGap?.double ?? 12
        try requireFiniteRange(innerGap, 0...256, path: "layout.inner_gap")
        try requireFiniteRange(outerGap, 0...256, path: "layout.outer_gap")

        let dwindleFraction = file?.dwindle?.newWindowFraction ?? 0.5
        try requireFiniteRange(dwindleFraction, 0.1...0.9, path: "layout.dwindle.new_window_fraction")
        let dwindlePositionName = file?.dwindle?.newWindowPosition ?? "after"
        guard let dwindlePosition = DwindleConfiguration.NewWindowPosition(rawValue: dwindlePositionName) else {
            throw invalid("layout.dwindle.new_window_position",
                          "layout.dwindle.new_window_position must be 'before' or 'after'")
        }

        let primaryFraction = file?.master?.primaryFraction ?? 0.55
        try requireFiniteRange(primaryFraction, 0.05...0.95, path: "layout.master.primary_fraction")
        let primaryPositionName = file?.master?.primaryPosition ?? "left"
        guard let primaryPosition = MasterOrientation(rawValue: primaryPositionName) else {
            throw invalid("layout.master.primary_position",
                          "layout.master.primary_position must be left, right, top, bottom, or center")
        }
        let masterNewPositionName = file?.master?.newWindowPosition ?? "stack-end"
        guard let masterNewPosition = MasterConfiguration.NewWindowPosition(rawValue: masterNewPositionName) else {
            throw invalid("layout.master.new_window_position",
                          "layout.master.new_window_position must be primary, stack-start, or stack-end")
        }

        return LayoutConfiguration(
            kind: kind,
            innerGap: innerGap,
            outerGap: outerGap,
            dwindle: DwindleConfiguration(newWindowFraction: dwindleFraction,
                                           newWindowPosition: dwindlePosition),
            master: MasterConfiguration(primaryFraction: primaryFraction,
                                         primaryPosition: primaryPosition,
                                         newWindowPosition: masterNewPosition)
        )
    }

    private static func compileFocus(_ file: FocusFile?) -> FocusConfiguration {
        FocusConfiguration(followsPointer: file?.followsPointer ?? false,
                           allowAppActivation: file?.allowAppActivation ?? false)
    }

    private static func compileWorkspaces(_ file: WorkspacesFile?) throws -> WorkspacesConfiguration {
        var ids: Set<Int> = []
        let assignments = try (file?.assignments ?? []).map { assignment -> WorkspaceAssignment in
            guard assignment.id > 0, let id = Int(exactly: assignment.id) else {
                throw invalid("workspaces.assignments", "workspace assignment id must be positive")
            }
            guard ids.insert(id).inserted else {
                throw invalid("workspaces.assignments", "workspace assignment id \(id) appears more than once")
            }
            guard !assignment.monitor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw invalid("workspaces.assignments", "workspace assignment monitor must not be empty")
            }
            return WorkspaceAssignment(id: id, monitor: assignment.monitor)
        }
        return WorkspacesConfiguration(backAndForth: file?.backAndForth ?? true,
                                       assignments: assignments)
    }

    private static func compileUI(_ file: UIFile?) throws -> UIConfiguration {
        UIConfiguration(
            menuBar: MenuBarConfiguration(enabled: file?.menuBar?.enabled ?? true),
            focusBorder: try compileFocusBorder(file?.focusBorder),
            bar: try compileBar(file?.bar)
        )
    }

    private static func compileFocusBorder(_ file: FocusBorderFile?) throws -> FocusBorderConfiguration {
        let width = file?.width?.double ?? 2
        let radius = file?.fallbackCornerRadius?.double ?? 10
        try requireFiniteRange(width, 0...32, path: "ui.focus_border.width")
        try requireFiniteRange(radius, 0...128, path: "ui.focus_border.fallback_corner_radius")
        let angle = file?.activeAngle ?? 45
        guard angle.isFinite else {
            throw invalid("ui.focus_border.active_angle", "ui.focus_border.active_angle must be finite")
        }
        guard (0..<360).contains(angle) else {
            throw invalid("ui.focus_border.active_angle", "ui.focus_border.active_angle must be between 0 and less than 360")
        }
        return FocusBorderConfiguration(
            width: width,
            fallbackCornerRadius: radius,
            activeColors: try compileColors(file?.activeColors ?? ["#33ccffee", "#00ff99ee"],
                                            path: "ui.focus_border.active_colors"),
            activeAngle: angle,
            modeColors: try compileColors(file?.modeColors ?? ["#ff5555ee"],
                                          path: "ui.focus_border.mode_colors")
        )
    }

    private static func compileBar(_ file: NativeBarFile?) throws -> NativeBarConfiguration {
        let positionName = file?.position ?? "top"
        guard let position = BarPosition(rawValue: positionName) else {
            throw invalid("ui.bar.position", "ui.bar.position must be 'top' or 'bottom'")
        }
        let height: BarHeight
        switch file?.height ?? .automatic {
        case .automatic:
            height = .automatic
        case .points(let points):
            guard (16...96).contains(points), let value = Int(exactly: points) else {
                throw invalid("ui.bar.height", "ui.bar.height must be 'auto' or an integer between 16 and 96")
            }
            height = .points(value)
        }

        let plugins = try compilePlugins(file?.plugins ?? [:])
        let left = try compileBarItems(file?.left ?? ["workspaces", "application"], path: "ui.bar.left")
        let center = try compileBarItems(file?.center ?? ["layout"], path: "ui.bar.center")
        let right = try compileBarItems(file?.right ?? ["pause", "mode", "windows", "network", "battery", "volume", "date"],
                                        path: "ui.bar.right")
        var seen: Set<NativeBarItem> = []
        for item in left + center + right {
            guard seen.insert(item).inserted else {
                throw invalid("ui.bar", "bar item '\(barItemName(item))' appears more than once")
            }
            if case .plugin(let id) = item, plugins[id] == nil {
                throw invalid("ui.bar", "bar plugin '\(id)' is not configured")
            }
        }

        let colors = file?.colors
        let weather = try file?.weather.map { value -> NativeBarWeather in
            guard value.latitude.isFinite, (-90...90).contains(value.latitude) else {
                throw invalid("ui.bar.weather.latitude", "ui.bar.weather.latitude must be finite and between -90 and 90")
            }
            guard value.longitude.isFinite, (-180...180).contains(value.longitude) else {
                throw invalid("ui.bar.weather.longitude", "ui.bar.weather.longitude must be finite and between -180 and 180")
            }
            let refresh = value.refreshMinutes ?? 15
            guard (5...180).contains(refresh), let minutes = Int(exactly: refresh) else {
                throw invalid("ui.bar.weather.refresh_minutes", "ui.bar.weather.refresh_minutes must be between 5 and 180")
            }
            return NativeBarWeather(latitude: value.latitude, longitude: value.longitude, refreshMinutes: minutes)
        }
        if seen.contains(.weather), weather == nil {
            throw invalid("ui.bar.weather", "weather bar item requires ui.bar.weather coordinates")
        }

        return NativeBarConfiguration(
            enabled: file?.enabled ?? false,
            position: position,
            height: height,
            left: left,
            center: center,
            right: right,
            colors: NativeBarColors(
                background: try compileColor(colors?.background ?? "#111111cc", path: "ui.bar.colors.background"),
                foreground: try compileColor(colors?.foreground ?? "#eeeeeeff", path: "ui.bar.colors.foreground"),
                inactive: try compileColor(colors?.inactive ?? "#8a8a8aff", path: "ui.bar.colors.inactive"),
                active: try compileColor(colors?.active ?? "#33ccffee", path: "ui.bar.colors.active")
            ),
            weather: weather,
            plugins: plugins
        )
    }

    private static func compilePlugins(_ files: [String: BarPluginFile]) throws -> [String: NativeBarPlugin] {
        var plugins: [String: NativeBarPlugin] = [:]
        for (id, file) in files.sorted(by: { $0.key < $1.key }) {
            guard ConfigurationKeyValidation.isPluginID(id) else {
                throw invalid("ui.bar.plugins.\(id)", "invalid plugin id '\(id)' expected [a-z0-9][a-z0-9_-]*")
            }
            let path = "ui.bar.plugins.\(id)"
            let command = try compileCommand(run: file.run, shell: file.shell,
                                             environment: file.env, path: path)
            let refresh = file.refreshSeconds ?? 60
            guard refresh == 0 || (5...3600).contains(refresh), let refreshSeconds = Int(exactly: refresh) else {
                throw invalid("\(path).refresh_seconds", "\(path).refresh_seconds must be 0 or between 5 and 3600")
            }
            let timeout = file.timeoutMs ?? 1000
            guard (250...5000).contains(timeout), let timeoutMs = Int(exactly: timeout) else {
                throw invalid("\(path).timeout_ms", "\(path).timeout_ms must be between 250 and 5000")
            }
            let events = file.events ?? []
            var seenEvents: Set<String> = []
            for event in events {
                guard allowedPluginEvents.contains(event) else {
                    throw invalid("\(path).events", "unknown bar plugin event '\(event)'")
                }
                guard seenEvents.insert(event).inserted else {
                    throw invalid("\(path).events", "bar plugin event '\(event)' appears more than once")
                }
            }
            plugins[id] = NativeBarPlugin(command: command,
                                          refreshSeconds: refreshSeconds,
                                          events: events,
                                          timeoutMs: timeoutMs)
        }
        return plugins
    }

    private static let allowedPluginEvents: Set<String> = [
        "workspace", "workspacev2", "focusedmon", "activewindow", "activewindowv2",
        "openwindow", "closewindow", "movewindow", "fullscreen", "changefloatingmode",
        "createworkspace", "destroyworkspace", "renameworkspace", "submap",
        "configreloaded", "monitoradded", "monitorremoved", "pause",
    ]

    private static func compileBarItems(_ names: [String], path: String) throws -> [NativeBarItem] {
        try names.map { name in
            switch name {
            case "workspaces": return .workspaces
            case "application": return .application
            case "pause": return .pause
            case "mode": return .mode
            case "layout": return .layout
            case "windows": return .windows
            case "date": return .date
            case "battery": return .battery
            case "network": return .network
            case "keyboard": return .keyboard
            case "volume": return .volume
            case "weather": return .weather
            default:
                if let id = name.removingPrefix("plugin:"), ConfigurationKeyValidation.isPluginID(id) {
                    return .plugin(id)
                }
                throw invalid(path, "unknown bar item '\(name)'")
            }
        }
    }

    private static func barItemName(_ item: NativeBarItem) -> String {
        switch item {
        case .workspaces: return "workspaces"
        case .application: return "application"
        case .pause: return "pause"
        case .mode: return "mode"
        case .layout: return "layout"
        case .windows: return "windows"
        case .date: return "date"
        case .battery: return "battery"
        case .network: return "network"
        case .keyboard: return "keyboard"
        case .volume: return "volume"
        case .weather: return "weather"
        case .plugin(let id): return "plugin:\(id)"
        }
    }

    private static func compileKeyboard(_ file: KeyboardFile?) throws -> KeyboardConfiguration {
        let bindingFiles = file?.bindings ?? []
        var bindings: [KeyboardBinding] = []
        var identities: Set<BindingIdentity> = []
        for (index, bindingFile) in bindingFiles.enumerated() {
            let path = "keyboard.bindings[\(index)]"
            let mode = bindingFile.mode ?? "default"
            guard mode == "default" || ConfigurationKeyValidation.isPluginID(mode) else {
                throw invalid("\(path).mode", "binding mode '\(mode)' must match [a-z0-9][a-z0-9_-]*")
            }
            let chord = try compileChord(bindingFile.chord, path: "\(path).chord")
            let edgeName = bindingFile.on ?? "press"
            guard let edge = BindingEdge(rawValue: edgeName) else {
                throw invalid("\(path).on", "binding edge must be 'press' or 'release'")
            }
            let repeats = bindingFile.repeatAction ?? false
            guard !(edge == .release && repeats) else {
                throw invalid(path, "release binding cannot repeat")
            }
            let identity = BindingIdentity(mode: mode, chord: chord, edge: edge)
            guard identities.insert(identity).inserted else {
                throw invalid(path, "duplicate binding for mode '\(mode)', chord '\(chord.text)', edge '\(edge.rawValue)'")
            }
            bindings.append(KeyboardBinding(mode: mode,
                                            chord: chord,
                                            edge: edge,
                                            repeats: repeats,
                                            action: try compileAction(bindingFile, path: path)))
        }

        let modes = Set(bindings.map(\.mode)).union(["default"])
        for binding in bindings {
            if case .window(.enterMode(let mode)) = binding.action, !modes.contains(mode) {
                throw invalid("keyboard.bindings", "binding enters undefined mode '\(mode)'")
            }
        }

        var pointerBindings: [PointerBinding] = []
        var pointerIdentities: Set<PointerBindingIdentity> = []
        for (index, value) in (file?.pointerBindings ?? []).enumerated() {
            let path = "keyboard.pointer_bindings[\(index)]"
            let binding = try compilePointerBinding(value, path: path)
            let identity = PointerBindingIdentity(modifiers: binding.modifiers,
                                                  button: binding.button)
            guard pointerIdentities.insert(identity).inserted else {
                throw invalid(path, "duplicate pointer binding for \(binding.modifiers.map(\.rawValue).joined(separator: "+"))+\(binding.button.rawValue)")
            }
            pointerBindings.append(binding)
        }
        return KeyboardConfiguration(bindings: bindings, pointerBindings: pointerBindings)
    }

    private static func compileChord(_ value: String, path: String) throws -> KeyChord {
        let parts = value.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let key = parts.last, !key.isEmpty else {
            throw invalid(path, "binding chord needs a key")
        }
        guard key == key.lowercased(), KeyCodes.code(for: key) != nil else {
            throw invalid(path, "unknown lowercase key '\(key)'")
        }
        let modifiers = try compileModifiers(Array(parts.dropLast()), path: path, allowEmpty: true)
        return KeyChord(modifiers: modifiers, key: key)
    }

    private static func compilePointerBinding(_ file: PointerBindingFile, path: String) throws -> PointerBinding {
        let modifiers = try compileModifiers(file.modifiers, path: "\(path).modifiers", allowEmpty: false)
        guard let button = PointerButton(rawValue: file.button) else {
            throw invalid("\(path).button", "pointer button must be left, right, or middle")
        }
        guard let drag = PointerDrag(rawValue: file.drag) else {
            throw invalid("\(path).drag", "pointer drag must be move or resize")
        }
        return PointerBinding(modifiers: modifiers, button: button, drag: drag)
    }

    private static func compileModifiers(_ values: [String], path: String, allowEmpty: Bool) throws -> [KeyboardModifier] {
        guard allowEmpty || !values.isEmpty else {
            throw invalid(path, "pointer binding requires at least one modifier")
        }
        var seen: Set<KeyboardModifier> = []
        for value in values {
            guard let modifier = KeyboardModifier(rawValue: value) else {
                throw invalid(path, "unknown modifier '\(value)'")
            }
            guard seen.insert(modifier).inserted else {
                throw invalid(path, "modifier '\(value)' appears more than once")
            }
        }
        return KeyboardModifier.allCases.filter(seen.contains)
    }

    private static func compileAction(_ file: KeyboardBindingFile, path: String) throws -> ConfiguredAction {
        var actions: [ConfiguredAction] = []
        if file.run != nil || file.shell != nil {
            actions.append(.command(try compileCommand(run: file.run, shell: file.shell,
                                                       environment: file.env, path: path)))
        } else if file.env != nil {
            throw invalid("\(path).env", "binding environment requires run or shell")
        }
        try appendFlag(file.close, name: "close", action: .close, path: path, to: &actions)
        try appendFlag(file.quit, name: "quit", action: .quit, path: path, to: &actions)
        if let value = file.focus { actions.append(.window(.focus(try direction(value, path: "\(path).focus")))) }
        if let value = file.move { actions.append(.window(.move(try direction(value, path: "\(path).move")))) }
        if let value = file.swap { actions.append(.window(.swap(try direction(value, path: "\(path).swap")))) }
        if let value = file.workspace { actions.append(.window(.workspace(try workspace(value, path: "\(path).workspace")))) }
        if let value = file.moveToWorkspace { actions.append(.window(.moveToWorkspace(try workspace(value, path: "\(path).move_to_workspace")))) }
        if let value = file.moveToWorkspaceSilent { actions.append(.window(.moveToWorkspaceSilent(try workspace(value, path: "\(path).move_to_workspace_silent")))) }
        if let value = file.toggleSpecialWorkspace {
            guard !value.isEmpty else { throw invalid("\(path).toggle_special_workspace", "special workspace name must not be empty") }
            actions.append(.window(.toggleSpecialWorkspace(value)))
        }
        try appendFlag(file.toggleFloating, name: "toggle_floating", action: .toggleFloating, path: path, to: &actions)
        try appendFlag(file.setFloating, name: "set_floating", action: .setFloating, path: path, to: &actions)
        try appendFlag(file.setTiled, name: "set_tiled", action: .setTiled, path: path, to: &actions)
        if let value = file.fullscreen { actions.append(.window(.fullscreen(try actionState(value, path: "\(path).fullscreen")))) }
        if let value = file.maximize { actions.append(.window(.maximize(try actionState(value, path: "\(path).maximize")))) }
        try appendFlag(file.center, name: "center", action: .center, path: path, to: &actions)
        try appendFlag(file.pin, name: "pin", action: .pin, path: path, to: &actions)
        if let value = file.resize { actions.append(.window(try vectorAction(value, path: "\(path).resize", resize: true))) }
        if let value = file.moveFloating { actions.append(.window(try vectorAction(value, path: "\(path).move_floating", resize: false))) }
        if let value = file.split {
            guard let action = SplitAction(rawValue: value) else { throw invalid("\(path).split", "invalid split action '\(value)'") }
            actions.append(.window(.split(action)))
        }
        if let value = file.primary {
            guard let action = PrimaryAction(rawValue: value) else { throw invalid("\(path).primary", "invalid primary action '\(value)'") }
            actions.append(.window(.primary(action)))
        }
        if let value = file.monitor { actions.append(.window(.monitor(try monitor(value, path: "\(path).monitor")))) }
        if let value = file.enterMode {
            guard value == "default" || ConfigurationKeyValidation.isPluginID(value) else {
                throw invalid("\(path).enter_mode", "invalid mode '\(value)'")
            }
            actions.append(.window(.enterMode(value)))
        }
        try appendFlag(file.raise, name: "raise", action: .raise, path: path, to: &actions)
        try appendFlag(file.refresh, name: "refresh", action: .refresh, path: path, to: &actions)
        if let value = file.pause {
            guard let action = PauseAction(rawValue: value) else { throw invalid("\(path).pause", "pause must be toggle, on, or off") }
            actions.append(.window(.pause(action)))
        }

        guard actions.count == 1 else {
            throw invalid(path, "binding must define exactly one action")
        }
        return actions[0]
    }

    private static func appendFlag(_ value: Bool?, name: String, action: WindowAction,
                                   path: String, to actions: inout [ConfiguredAction]) throws {
        guard let value else { return }
        guard value else { throw invalid("\(path).\(name)", "action flag '\(name)' must be true") }
        actions.append(.window(action))
    }

    private static func direction(_ value: String, path: String) throws -> Direction {
        switch value {
        case "left": return .left
        case "right": return .right
        case "up": return .up
        case "down": return .down
        default: throw invalid(path, "direction must be left, right, up, or down")
        }
    }

    private static func actionState(_ value: String, path: String) throws -> ActionState {
        guard let state = ActionState(rawValue: value) else {
            throw invalid(path, "action state must be toggle, on, or off")
        }
        return state
    }

    private static func vectorAction(_ values: [NumberValue], path: String, resize: Bool) throws -> WindowAction {
        let vector = try compileVector(values, path: path, positive: false)
        return resize ? .resize(x: vector.x, y: vector.y) : .moveFloating(x: vector.x, y: vector.y)
    }

    private static func compileStartup(_ file: StartupFile?) throws -> StartupConfiguration {
        let commands = try (file?.commands ?? []).enumerated().map { index, command in
            try compileCommand(run: command.run, shell: command.shell, environment: command.env,
                               path: "startup.commands[\(index)]")
        }
        return StartupConfiguration(commands: commands)
    }

    private static func compileCommand(run: [String]?, shell: String?, environment: [String: String]?,
                                       path: String) throws -> CommandSpec {
        let execution: CommandSpec.Execution
        switch (run, shell) {
        case (.some(let run), .none):
            guard let executable = run.first, !executable.isEmpty else {
                throw invalid("\(path).run", "run must contain at least one argument")
            }
            guard executable.hasPrefix("/") || executable.hasPrefix("~/") else {
                throw invalid("\(path).run", "executable must be an absolute path or start with '~/'")
            }
            guard run.allSatisfy({ !$0.contains("\0") }) else {
                throw invalid("\(path).run", "command arguments must not contain NUL")
            }
            execution = .run(run)
        case (.none, .some(let script)):
            guard !script.isEmpty else { throw invalid("\(path).shell", "shell command must not be empty") }
            guard !script.contains("\0") else { throw invalid("\(path).shell", "shell command must not contain NUL") }
            execution = .shell(script)
        case (.some, .some), (.none, .none):
            throw invalid(path, "command must define exactly one of run or shell")
        }
        let environment = try compileEnvironment(environment ?? [:], path: "\(path).env")
        return CommandSpec(execution: execution, environment: environment)
    }

    private static func compileEnvironment(_ environment: [String: String],
                                           path: String) throws -> [String: String] {
        for (name, value) in environment.sorted(by: { $0.key < $1.key }) {
            guard isEnvironmentName(name) else {
                throw invalid(path, "invalid environment variable name '\(name)'")
            }
            guard !name.hasPrefix("VINDU_") else {
                throw invalid(path, "reserved environment variable '\(name)'")
            }
            guard !value.contains("\0") else {
                throw invalid(path, "environment variable '\(name)' contains NUL")
            }
        }
        return environment
    }

    private static func isEnvironmentName(_ name: String) -> Bool {
        guard let first = name.utf8.first,
              (first == 95 || (65...90).contains(first) || (97...122).contains(first)) else { return false }
        return name.utf8.dropFirst().allSatisfy {
            $0 == 95 || (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
        }
    }

    private static func compileWindows(_ file: WindowsFile?) throws -> WindowsConfiguration {
        let rules = try (file?.rules ?? []).enumerated().map { index, rule in
            try compileWindowRule(rule, index: index)
        }
        return WindowsConfiguration(rules: rules)
    }

    private static func compileWindowRule(_ file: WindowRuleFile, index: Int) throws -> NativeWindowRule {
        let path = "windows.rules[\(index)]"
        let matcher = file.match
        guard [matcher.bundleID, matcher.appName, matcher.title].contains(where: { value in
            value.map { !$0.isEmpty } ?? false
        }) else {
            throw invalid("\(path).match", "window rule match must define bundle_id, app_name, or title")
        }
        if let bundleID = matcher.bundleID, bundleID.isEmpty {
            throw invalid("\(path).match.bundle_id", "bundle_id must not be empty")
        }
        try validateRegex(matcher.appName, path: "\(path).match.app_name")
        try validateRegex(matcher.title, path: "\(path).match.title")
        guard file.workspace == nil || file.monitor == nil else {
            throw invalid(path, "window rule cannot set both workspace and monitor")
        }
        let size = try file.size.map { try compileVector($0, path: "\(path).size", positive: true) }
        let position = try file.position.map { try compileVector($0, path: "\(path).position", positive: false) }
        let workspaceTarget = try file.workspace.map { try workspace($0, path: "\(path).workspace") }
        let monitorTarget = try file.monitor.map { try monitor($0, path: "\(path).monitor") }
        let impliesFloating = file.centered == true || file.pinned == true || size != nil || position != nil
        return NativeWindowRule(
            match: NativeWindowMatcher(bundleID: matcher.bundleID, appName: matcher.appName, title: matcher.title),
            floating: impliesFloating ? true : file.floating,
            centered: file.centered,
            pinned: file.pinned,
            fullscreen: file.fullscreen,
            size: size,
            position: position,
            workspace: workspaceTarget,
            monitor: monitorTarget
        )
    }

    private static func validateRegex(_ pattern: String?, path: String) throws {
        guard let pattern else { return }
        guard !pattern.isEmpty else { throw invalid(path, "\(path) must not be empty") }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw invalid(path, "\(path) is not a valid regular expression")
        }
    }

    private static func compileVector(_ values: [NumberValue], path: String, positive: Bool) throws -> WindowVector {
        guard values.count == 2 else { throw invalid(path, "\(path) must contain exactly two numbers") }
        let x = values[0].double
        let y = values[1].double
        guard x.isFinite, y.isFinite else { throw invalid(path, "\(path) values must be finite") }
        if positive, !(x > 0 && y > 0) { throw invalid(path, "\(path) values must be positive") }
        return WindowVector(x: x, y: y)
    }

    private static func workspace(_ value: ScalarTarget, path: String) throws -> WorkspaceTarget {
        guard let target = WorkspaceTarget.parse(value.text) else {
            throw invalid(path, "invalid workspace target '\(value.text)'")
        }
        if case .id(let id) = target, id <= 0 {
            throw invalid(path, "workspace id must be positive")
        }
        if case .name(let name) = target, Int(name) != nil {
            throw invalid(path, "named workspace must not use a numeric name")
        }
        return target
    }

    private static func monitor(_ value: ScalarTarget, path: String) throws -> MonitorTarget {
        if case .string(let name) = value,
           ["left", "right", "up", "down"].contains(name) {
            return .direction(try direction(name, path: path))
        }
        guard let target = MonitorTarget.parse(value.text) else {
            throw invalid(path, "invalid monitor target '\(value.text)'")
        }
        return target
    }

    private static func compileColors(_ values: [String], path: String) throws -> [ConfigurationColor] {
        guard !values.isEmpty else { throw invalid(path, "\(path) must contain at least one color") }
        return try values.enumerated().map { index, value in
            try compileColor(value, path: "\(path)[\(index)]")
        }
    }

    private static func compileColor(_ value: String, path: String) throws -> ConfigurationColor {
        guard value.first == "#", value.count == 7 || value.count == 9,
              let bits = UInt64(value.dropFirst(), radix: 16) else {
            throw invalid(path, "color must use #RRGGBB or #RRGGBBAA")
        }
        let hasAlpha = value.count == 9
        let redShift = hasAlpha ? 24 : 16
        let greenShift = hasAlpha ? 16 : 8
        let blueShift = hasAlpha ? 8 : 0
        func channel(_ shift: Int) -> Double { Double((bits >> shift) & 0xff) / 255 }
        return ConfigurationColor(red: channel(redShift),
                                  green: channel(greenShift),
                                  blue: channel(blueShift),
                                  alpha: hasAlpha ? channel(0) : 1)
    }

    private static func requireFiniteRange(_ value: Double, _ range: ClosedRange<Double>, path: String) throws {
        guard value.isFinite else { throw invalid(path, "\(path) must be finite") }
        guard range.contains(value) else {
            throw invalid(path, "\(path) must be between \(plainNumber(range.lowerBound)) and \(plainNumber(range.upperBound))")
        }
    }

    private static func invalid(_ path: String, _ message: String) -> ConfigurationDiagnosticError {
        ConfigurationDiagnosticError(diagnostic: ConfigurationDiagnostic(keyPath: path, message: message))
    }

    private struct BindingIdentity: Hashable {
        let mode: String
        let chord: KeyChord
        let edge: BindingEdge
    }

    private struct PointerBindingIdentity: Hashable {
        let modifiers: [KeyboardModifier]
        let button: PointerButton
    }
}
