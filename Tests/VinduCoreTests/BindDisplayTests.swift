import Testing
@testable import VinduCore

struct BindDisplayTests {
    private func bind(_ mods: Modifiers, _ key: String, _ dispatcher: Dispatcher,
                      flags: BindFlags = [], submap: String = "",
                      description: String? = nil) -> Bind {
        Bind(mods: mods, key: key, flags: flags, submap: submap,
             dispatcher: dispatcher, description: description)
    }

    @Test func chordUsesMacModifierSymbols() {
        #expect(BindDisplay.chord(bind([.alt], "h", .movefocus(.left))) == "⌥ H")
        #expect(BindDisplay.chord(bind([.alt, .shift], "q", .killactive)) == "⌥⇧ Q")
        #expect(BindDisplay.chord(bind([.cmd, .ctrl], "return", .exec("x"))) == "⌃⌘ ↩")
        #expect(BindDisplay.chord(bind([], "escape", .submap(""))) == "⎋")
        #expect(BindDisplay.chord(bind([.alt], "mouse:272", .movewindow(.mouse),
                                       flags: .mouse)) == "⌥ Left drag")
    }

    @Test func actionPrefersDescriptionThenPlainEnglish() {
        #expect(BindDisplay.action(bind([.alt], "t", .exec("kitty"),
                                        description: "Open terminal")) == "Open terminal")
        #expect(BindDisplay.action(bind([.alt], "return", .exec("open -a Terminal"))) == "Open Terminal")
        #expect(BindDisplay.action(bind([.alt], "h", .movefocus(.left))) == "Focus left")
        #expect(BindDisplay.action(bind([.alt, .shift], "q", .killactive)) == "Close window")
        #expect(BindDisplay.action(bind([.alt], "s", .togglespecialworkspace("magic"))) == "Scratchpad")
        // Send binds must read as sends, not as workspace switches.
        #expect(BindDisplay.action(bind([.alt, .shift], "]", .movetoworkspace(.relative(1))))
                == "Send to next workspace")
        #expect(BindDisplay.action(bind([.alt, .shift], "s",
                                        .movetoworkspacesilent(.special("magic"))))
                == "Send to scratchpad (stay)")
        #expect(BindDisplay.action(bind([.alt], "f", .fullscreen(1))) == "Maximize")
        #expect(BindDisplay.action(bind([.alt, .shift], "p", .pause(.toggle))) == "Pause / resume tiling")
        #expect(BindDisplay.action(bind([.alt], "r", .submap("resize"))) == "Resize mode")
        // Uncommon dispatchers fall back to name + config-syntax args.
        #expect(BindDisplay.action(bind([.alt], "z", .alterzorder("top"))) == "alterzorder top")
    }

    @Test func rowsCollapseDigitRunsAndSkipSubmaps() {
        var binds: [Bind] = []
        binds.append(bind([.alt], "v", .togglefloating))
        for d in 1...9 {
            binds.append(bind([.alt], String(d), .workspace(.id(d))))
        }
        for d in 1...9 {
            binds.append(bind([.alt, .shift], String(d), .movetoworkspace(.id(d))))
        }
        binds.append(bind([], "l", .resizeactive(.relative(Delta(value: 30), Delta(value: 0))),
                          submap: "resize"))

        let rows = BindDisplay.rows(binds)
        #expect(rows.count == 3)
        #expect(rows[0].chord == "⌥ V")
        #expect(rows[1].chord == "⌥ 1…9")
        #expect(rows[1].action == "Workspace 1–9")
        #expect(rows[2].chord == "⌥⇧ 1…9")
        #expect(rows[2].action == "Send to workspace 1–9")
    }

    @Test func shortDigitRunsStayExpanded() {
        let binds = [
            bind([.alt], "1", .workspace(.id(1))),
            bind([.alt], "2", .workspace(.id(2))),
        ]
        let rows = BindDisplay.rows(binds)
        #expect(rows.count == 2)
        #expect(rows[0].action == "Workspace 1")
    }
}
