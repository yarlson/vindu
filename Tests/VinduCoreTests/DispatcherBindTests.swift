import Testing
@testable import VinduCore

struct DispatcherTests {
    func parse(_ name: String, _ args: String = "") -> Dispatcher? {
        try? Dispatcher.parse(name: name, args: args).get()
    }

    @Test func workspaceTargets() {
        #expect(parse("workspace", "3") == .workspace(.id(3)))
        #expect(parse("workspace", "+1") == .workspace(.relative(1)))
        #expect(parse("workspace", "-2") == .workspace(.relative(-2)))
        #expect(parse("workspace", "e+1") == .workspace(.relativeExisting(1)))
        #expect(parse("workspace", "previous") == .workspace(.previous))
        #expect(parse("workspace", "empty") == .workspace(.empty))
        #expect(parse("workspace", "name:web") == .workspace(.name("web")))
        #expect(parse("movetoworkspace", "special:magic") == .movetoworkspace(.special("magic")))
        #expect(parse("movetoworkspacesilent", "4") == .movetoworkspacesilent(.id(4)))
    }

    @Test func directionalDispatchers() {
        #expect(parse("movefocus", "l") == .movefocus(.left))
        #expect(parse("movefocus", "up") == .movefocus(.up))
        #expect(parse("swapwindow", "r") == .swapwindow(.right))
        #expect(parse("movewindow", "d") == .movewindow(.direction(.down)))
        #expect(parse("movewindow", "mon:+1") == .movewindow(.monitor(.relative(1))))
        #expect(parse("movewindow") == .movewindow(.mouse))
        #expect(parse("movefocus", "x") == nil)
    }

    @Test func resizeAndRatio() {
        #expect(parse("resizeactive", "10 -20") ==
                .resizeactive(.relative(Delta(value: 10), Delta(value: -20))))
        #expect(parse("resizeactive", "exact 50% 50%") ==
                .resizeactive(.exact(Delta(value: 50, percent: true), Delta(value: 50, percent: true))))
        #expect(parse("splitratio", "0.3") == .splitratio(.delta(0.3)))
        #expect(parse("splitratio", "exact 1.2") == .splitratio(.exact(1.2)))
        #expect(parse("resizeactive", "abc") == nil)
    }

    @Test func miscDispatchers() {
        #expect(parse("fullscreen") == .fullscreen(0))
        #expect(parse("fullscreen", "1") == .fullscreen(1))
        #expect(parse("togglespecialworkspace") == .togglespecialworkspace("special"))
        #expect(parse("cyclenext", "prev") == .cyclenext(prev: true))
        #expect(parse("swapprev") == .swapnext(prev: true))
        #expect(parse("renameworkspace", "3 dev") == .renameworkspace(3, "dev"))
        #expect(parse("moveworkspacetomonitor", "2 +1") == .moveworkspacetomonitor(.id(2), .relative(1)))
        #expect(parse("focusmonitor", "l") == .focusmonitor(.direction(.left)))
        #expect(parse("focusmonitor", "DP-1") == .focusmonitor(.name("DP-1")))
        #expect(parse("submap", "reset") == .submap(""))
        #expect(parse("exec", "kitty -e top") == .exec("kitty -e top"))
        #expect(parse("notarealdispatcher") == nil)
        #expect(parse("exec") == nil)
    }

    @Test func pauseDispatcher() {
        #expect(parse("pause") == .pause(.toggle))
        #expect(parse("pause", "toggle") == .pause(.toggle))
        #expect(parse("pause", "on") == .pause(.on))
        #expect(parse("pause", "1") == .pause(.on))
        #expect(parse("pause", "off") == .pause(.off))
        #expect(parse("pause", "0") == .pause(.off))
        #expect(parse("pause", "maybe") == nil)
    }

    @Test func argTextRoundTripsConfigSyntax() {
        #expect(Dispatcher.workspace(.id(3)).argText == "3")
        #expect(Dispatcher.workspace(.relative(-1)).argText == "-1")
        #expect(Dispatcher.workspace(.relativeExisting(1)).argText == "e+1")
        #expect(Dispatcher.movetoworkspace(.special("magic")).argText == "special:magic")
        #expect(Dispatcher.movefocus(.left).argText == "l")
        #expect(Dispatcher.movewindow(.monitor(.relative(1))).argText == "mon:+1")
        #expect(Dispatcher.resizeactive(.relative(Delta(value: 30), Delta(value: 0))).argText == "30 0")
        #expect(Dispatcher.resizeactive(.exact(Delta(value: 50, percent: true),
                                               Delta(value: 50, percent: true))).argText == "exact 50% 50%")
        #expect(Dispatcher.splitratio(.exact(1.2)).argText == "exact 1.2")
        #expect(Dispatcher.submap("").argText == "reset")
        #expect(Dispatcher.togglespecialworkspace("special").argText == "")
        #expect(Dispatcher.killactive.argText == "")
        #expect(Dispatcher.pause(.toggle).argText == "")
        #expect(Dispatcher.pause(.off).argText == "off")
    }
}

struct BindTests {
    @Test func modifierParsing() {
        #expect(Modifiers.parse("SUPER SHIFT") == [.cmd, .shift])
        #expect(Modifiers.parse("ALT+CTRL") == [.alt, .ctrl])
        #expect(Modifiers.parse("") == [])
        #expect(Modifiers.parse("BANANA") == nil)
        #expect(Modifiers([.cmd, .shift]).described == "SUPER SHIFT")
    }

    @Test func flagParsing() {
        #expect(BindFlags.parse("e") == .repeats)
        #expect(BindFlags.parse("eld") == [.repeats, .locked, .hasDescription])
        #expect(BindFlags.parse("z") == nil)
    }

    @Test func bindWithDescription() throws {
        let bind = try BindParser.parse(flagsSuffix: "d",
                                        value: "SUPER, T, Open terminal, exec, kitty",
                                        submap: "").get()
        #expect(bind.description == "Open terminal")
        #expect(bind.dispatcher == .exec("kitty"))
    }

    @Test func invalidKeyRejected() {
        let result = BindParser.parse(flagsSuffix: "", value: "SUPER, notakey, exec, x", submap: "")
        guard case .failure(let err) = result else {
            Issue.record("expected failure, got \(result)")
            return
        }
        #expect(err.message.contains("unknown key"))
    }

    @Test func codeKeyAccepted() throws {
        let bind = try BindParser.parse(flagsSuffix: "", value: "SUPER, code:34, exec, x", submap: "").get()
        #expect(bind.key == "code:34")
        #expect(KeyCodes.code(for: bind.key) == 34)
    }

    @Test func mouseBindNeedsMouseKey() throws {
        let bad = BindParser.parse(flagsSuffix: "m", value: "SUPER, q, movewindow", submap: "")
        guard case .failure = bad else {
            Issue.record("expected failure")
            return
        }
        let bind = try BindParser.parse(flagsSuffix: "m", value: "SUPER, mouse:273, resizewindow", submap: "").get()
        #expect(MouseButton.parse(bindKey: bind.key) == .right)
        #expect(bind.dispatcher == .resizewindow)
    }

    @Test func keyCodeTable() {
        #expect(KeyCodes.code(for: "Q") == 12)
        #expect(KeyCodes.code(for: "return") == 36)
        #expect(KeyCodes.code(for: "left") == 123)
        #expect(KeyCodes.code(for: "f5") == 96)
        #expect(KeyCodes.code(for: "fakekey") == nil)
    }
}

struct ColorTests {
    @Test func colorFormats() throws {
        let c = try #require(MLColor.parse("rgba(33ccffee)"))
        #expect(abs(c.r - Double(0x33) / 255) < 0.001)
        #expect(abs(c.a - Double(0xEE) / 255) < 0.001)

        let rgb = try #require(MLColor.parse("rgb(11ee11)"))
        #expect(rgb.a == 1.0)
        #expect(abs(rgb.g - Double(0xEE) / 255) < 0.001)

        let argb = try #require(MLColor.parse("0xee33ccff"))
        #expect(abs(argb.a - Double(0xEE) / 255) < 0.001)
        #expect(abs(argb.r - Double(0x33) / 255) < 0.001)

        #expect(MLColor.parse("rgba(xyz)") == nil)
        #expect(MLColor.parse("#ffffff") == nil)
    }

    @Test func gradient() {
        let g = MLGradient.parse("rgba(33ccffee) rgba(00ff99ee) 45deg")
        #expect(g?.colors.count == 2)
        #expect(g?.angleDeg == 45)
        let single = MLGradient.parse("rgba(595959aa)")
        #expect(single?.colors.count == 1)
        #expect(single?.angleDeg == 0)
        #expect(MLGradient.parse("notacolor") == nil)
    }
}
