import Foundation
import Testing
@testable import VinduCore

struct NativeConfigurationTests {
    @Test func compilesCanonicalConfiguration() throws {
        let snapshot = try compile("""
        schema = 1

        [layout]
        kind = "dwindle"
        inner_gap = 5
        outer_gap = 12

        [layout.dwindle]
        new_window_fraction = 0.5
        new_window_position = "after"

        [layout.master]
        primary_fraction = 0.55
        primary_position = "left"
        new_window_position = "stack-end"

        [focus]
        follows_pointer = false
        allow_app_activation = false

        [workspaces]
        back_and_forth = true

        [[workspaces.assignments]]
        id = 1
        monitor = "Built-in Display"

        [ui.menu_bar]
        enabled = true

        [ui.focus_border]
        width = 2
        fallback_corner_radius = 10
        active_colors = ["#33ccffee", "#00ff99ee"]
        active_angle = 45
        mode_colors = ["#ff5555ee"]

        [ui.bar]
        enabled = true
        position = "top"
        height = "auto"
        left = ["workspaces", "application"]
        center = ["layout"]
        right = ["pause", "plugin:mail"]

        [ui.bar.weather]
        latitude = 56.9496
        longitude = 24.1052
        refresh_minutes = 15

        [ui.bar.plugins.mail]
        run = ["~/.config/vindu/bar/mail"]
        refresh_seconds = 300
        events = ["workspace", "activewindow"]
        timeout_ms = 1000

        [keyboard]
        bindings = [
          { chord = "option+return", run = ["/usr/bin/open", "-a", "Terminal"] },
          { chord = "option+h", focus = "left" },
          { chord = "option+r", enter_mode = "resize" },
          { mode = "resize", chord = "l", repeat = true, resize = [30, 0] },
          { mode = "resize", chord = "escape", enter_mode = "default" },
        ]
        pointer_bindings = [
          { modifiers = ["option"], button = "left", drag = "move" },
        ]

        [startup]
        commands = [{ run = ["/usr/bin/open", "-a", "Terminal"] }]

        [[windows.rules]]
        match = { bundle_id = "com.apple.systempreferences" }
        floating = true
        centered = true
        """)

        #expect(snapshot.schema == 1)
        #expect(snapshot.layout.kind == .dwindle)
        #expect(snapshot.layout.innerGap == 5)
        #expect(snapshot.workspaces.assignments == [WorkspaceAssignment(id: 1, monitor: "Built-in Display")])
        #expect(snapshot.ui.bar.left == [.workspaces, .application])
        #expect(snapshot.ui.bar.center == [.layout])
        #expect(snapshot.ui.bar.right == [.pause, .plugin("mail")])
        #expect(snapshot.ui.bar.plugins["mail"]?.command.argv == ["~/.config/vindu/bar/mail"])
        #expect(snapshot.keyboard.bindings.count == 5)
        #expect(snapshot.keyboard.bindings[1].action == .window(.focus(.left)))
        #expect(snapshot.keyboard.pointerBindings == [
            PointerBinding(modifiers: [.option], button: .left, drag: .move),
        ])
        #expect(snapshot.startup.commands.count == 1)
        #expect(snapshot.windows.rules.count == 1)
    }

    @Test func rejectsUnknownAndWrongCaseKeys() {
        expectFailure("schema = 1\n[layout]\ninnerGap = 5", contains: "unknown key 'layout.innerGap'")
        expectFailure("Schema = 1", contains: "unknown key 'Schema'")
        expectFailure("schema = 1\n[keyboard]\nbindings = [{ chord = \"q\", close = true, typo = true }]",
                      contains: "unknown key 'keyboard.bindings[0].typo'")
    }

    @Test func rejectsDuplicateKeysAndWrongTypes() {
        expectFailure("schema = 1\nschema = 1", contains: "invalid TOML")
        expectFailure("schema = \"1\"", contains: "Invalid integer value")
        expectFailure("schema = 1\n[layout]\ninner_gap = \"5\"", contains: "expected")
    }

    @Test func rejectsUnsupportedSchemaAndInvalidInputBytes() {
        expectFailure("schema = 2", contains: "schema must be 1")
        let oversized = Data(repeating: 0x20, count: ConfigurationCompiler.maximumBytes + 1)
        expectFailure(oversized, contains: "larger than 1048576 bytes")
        expectFailure(Data([0xff]), contains: "not valid UTF-8")
    }

    @Test func acceptsConfigurationAtByteLimit() throws {
        let prefix = Data("schema = 1\n".utf8)
        var data = prefix
        data.append(Data(repeating: UInt8(ascii: " "),
                         count: ConfigurationCompiler.maximumBytes - prefix.count))

        let snapshot: ConfigurationSnapshot
        switch ConfigurationCompiler().compile(data) {
        case .success(let compiled): snapshot = compiled
        case .failure(let failure):
            Issue.record("unexpected diagnostics: \(failure.diagnostics)")
            throw failure
        }

        #expect(data.count == ConfigurationCompiler.maximumBytes)
        #expect(snapshot.schema == 1)
    }

    @Test func validatesNumericBoundariesAndFiniteNumbers() {
        expectFailure("schema = 1\n[layout]\ninner_gap = 257", contains: "layout.inner_gap must be between 0 and 256")
        expectFailure("schema = 1\n[layout.dwindle]\nnew_window_fraction = 0.09", contains: "layout.dwindle.new_window_fraction must be between 0.1 and 0.9")
        expectFailure("schema = 1\n[ui.focus_border]\nactive_angle = inf", contains: "finite")
    }

    @Test func validatesBarZonesAndPluginReferences() {
        expectFailure("""
        schema = 1
        [ui.bar]
        left = ["layout"]
        right = ["layout"]
        """, contains: "bar item 'layout' appears more than once")
        expectFailure("""
        schema = 1
        [ui.bar]
        right = ["plugin:Mail"]
        [ui.bar.plugins.Mail]
        run = ["/bin/echo"]
        """, contains: "invalid plugin id 'Mail'")
        expectFailure("schema = 1\n[ui.bar]\ncenter = [\"weather\"]", contains: "weather bar item requires ui.bar.weather coordinates")
        expectFailure("schema = 1\n[ui.bar]\nheight = 15", contains: "between 16 and 96")
        expectFailure("""
        schema = 1
        [ui.bar.plugins.mail]
        run = ["/bin/echo"]
        refresh_seconds = 4
        """, contains: "0 or between 5 and 3600")
    }

    @Test func validatesWorkspaceAssignments() {
        expectFailure("""
        schema = 1
        [[workspaces.assignments]]
        id = 1
        monitor = "Built-in"
        [[workspaces.assignments]]
        id = 1
        monitor = "External"
        """, contains: "workspace assignment id 1 appears more than once")
        expectFailure("schema = 1\n[[workspaces.assignments]]\nid = 0\nmonitor = \"Built-in\"", contains: "workspace assignment id must be positive")
        expectFailure("schema = 1\n[keyboard]\nbindings = [{ chord = \"1\", workspace = 0 }]", contains: "workspace id must be positive")
        expectFailure("schema = 1\n[keyboard]\nbindings = [{ chord = \"1\", workspace = \"name:0\" }]", contains: "named workspace must not use a numeric name")
        expectFailure("""
        schema = 1
        [[windows.rules]]
        match = { bundle_id = "com.example" }
        workspace = 0
        """, contains: "workspace id must be positive")
    }

    @Test func validatesBindingActionsAndModes() {
        expectFailure("""
        schema = 1
        [keyboard]
        bindings = [{ chord = "option+h", focus = "left", move = "left" }]
        """, contains: "must define exactly one action")
        expectFailure("""
        schema = 1
        [keyboard]
        bindings = [{ chord = "option+x", enter_mode = "missing" }]
        """, contains: "enters undefined mode 'missing'")
        expectFailure("""
        schema = 1
        [keyboard]
        bindings = [
          { chord = "option+h", focus = "left" },
          { chord = "option+h", focus = "right" },
        ]
        """, contains: "duplicate binding for mode 'default', chord 'option+h', edge 'press'")
        expectFailure("""
        schema = 1
        [keyboard]
        bindings = [{ chord = "option+h", on = "release", repeat = true, focus = "left" }]
        """, contains: "release binding cannot repeat")
        expectFailure("""
        schema = 1
        [keyboard]
        pointer_bindings = [
          { modifiers = ["option", "shift"], button = "left", drag = "move" },
          { modifiers = ["shift", "option"], button = "left", drag = "resize" },
        ]
        """, contains: "duplicate pointer binding")
    }

    @Test func validatesCommandsAndEnvironment() {
        expectFailure("""
        schema = 1
        [startup]
        commands = [{ run = ["open"] }]
        """, contains: "executable must be an absolute path or start with '~/'")
        expectFailure("""
        schema = 1
        [startup]
        commands = [{ run = ["/bin/echo"], shell = "echo no" }]
        """, contains: "must define exactly one of run or shell")
        expectFailure("""
        schema = 1
        [startup]
        commands = [{ run = ["/bin/echo"], env = { VINDU_SOCKET = "x" } }]
        """, contains: "reserved environment variable 'VINDU_SOCKET'")
    }

    @Test func validatesWindowRules() {
        expectFailure("""
        schema = 1
        [[windows.rules]]
        match = { title = "[" }
        floating = true
        """, contains: "windows.rules[0].match.title is not a valid regular expression")
        expectFailure("""
        schema = 1
        [[windows.rules]]
        match = { bundle_id = "com.example" }
        workspace = 1
        monitor = "Built-in"
        """, contains: "cannot set both workspace and monitor")
    }

    @Test func compilesApprovedActionKinds() throws {
        let snapshot = try compile("""
        schema = 1
        [keyboard]
        bindings = [
          { chord = "q", close = true },
          { chord = "w", quit = true },
          { chord = "e", focus = "left" },
          { chord = "r", move = "right" },
          { chord = "t", swap = "up" },
          { chord = "y", workspace = 2 },
          { chord = "u", move_to_workspace = "name:web" },
          { chord = "i", move_to_workspace_silent = 3 },
          { chord = "o", toggle_special_workspace = "scratch" },
          { chord = "p", toggle_floating = true },
          { chord = "a", set_floating = true },
          { chord = "s", set_tiled = true },
          { chord = "d", fullscreen = "toggle" },
          { chord = "f", maximize = "on" },
          { chord = "g", center = true },
          { chord = "h", pin = true },
          { chord = "j", resize = [30, 0] },
          { chord = "k", move_floating = [-10, 20] },
          { chord = "l", split = "horizontal" },
          { chord = "z", primary = "add" },
          { chord = "x", monitor = "right" },
          { chord = "c", enter_mode = "resize" },
          { chord = "v", raise = true },
          { chord = "b", refresh = true },
          { chord = "n", pause = "off" },
          { chord = "m", run = ["/bin/echo", "ok"] },
          { chord = "1", shell = "echo ok" },
          { mode = "resize", chord = "escape", enter_mode = "default" },
        ]
        """)

        let actions = snapshot.keyboard.bindings.map(\.action)
        #expect(actions.count == 28)
        #expect(actions.contains(.window(.close)))
        #expect(actions.contains(.window(.quit)))
        #expect(actions.contains(.window(.toggleSpecialWorkspace("scratch"))))
        #expect(actions.contains(.window(.fullscreen(.toggle))))
        #expect(actions.contains(.window(.maximize(.on))))
        #expect(actions.contains(.window(.resize(x: 30, y: 0))))
        #expect(actions.contains(.window(.moveFloating(x: -10, y: 20))))
        #expect(actions.contains(.window(.split(.horizontal))))
        #expect(actions.contains(.window(.primary(.add))))
        #expect(actions.contains(.window(.monitor(.direction(.right)))))
        #expect(actions.contains(.window(.raise)))
        #expect(actions.contains(.window(.refresh)))
        #expect(actions.contains(.window(.pause(.off))))
        #expect(actions.contains { if case .command = $0 { true } else { false } })
    }

    @Test func rulePlacementEffectsImplyFloating() throws {
        let snapshot = try compile("""
        schema = 1
        [[windows.rules]]
        match = { bundle_id = "com.example" }
        centered = true
        size = [800, 600]
        """)
        #expect(snapshot.windows.rules[0].floating == true)
        #expect(snapshot.windows.rules[0].size == WindowVector(x: 800, y: 600))
    }

    private func compile(_ text: String) throws -> ConfigurationSnapshot {
        switch ConfigurationCompiler().compile(Data(text.utf8)) {
        case .success(let snapshot): return snapshot
        case .failure(let failure):
            Issue.record("unexpected diagnostics: \(failure.diagnostics)")
            throw failure
        }
    }

    private func expectFailure(_ text: String, contains expected: String) {
        expectFailure(Data(text.utf8), contains: expected)
    }

    private func expectFailure(_ data: Data, contains expected: String) {
        switch ConfigurationCompiler().compile(data) {
        case .success:
            Issue.record("configuration unexpectedly compiled")
        case .failure(let failure):
            #expect(failure.diagnostics.contains { $0.message.contains(expected) },
                    "expected '\(expected)' in \(failure.diagnostics)")
        }
    }
}
