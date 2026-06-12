import Testing
@testable import VinduCore

struct ConfigParserTests {
    func parseDoc(_ text: String) -> ConfigDocument {
        ConfigParser().parse(text: text)
    }

    @Test func fullConfig() {
        let doc = parseDoc("""
        $mainMod = SUPER
        $term = kitty

        # a comment
        general {
            gaps_in = 10
            gaps_out = 24
            border_size = 3
            col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
            layout = master
        }

        dwindle {
            preserve_split = true
            default_split_ratio = 1.2
        }

        master {
            new_status = master
            mfact = 0.6
        }

        binds {
            workspace_back_and_forth = true
        }

        bar {
            enabled = true
            position = bottom
            height = 32
            show_workspaces = false
            show_app = true
            show_indicators = false
            indicators = layout, date, sound
            col.background = rgba(111111cc)
            col.foreground = rgba(eeeeeeff)
            col.inactive = rgba(8a8a8aff)
            col.active = rgba(33ccffee)
        }

        bind = $mainMod, Q, exec, $term --single-instance
        bind = $mainMod SHIFT, Q, killactive,
        binde = $mainMod, L, resizeactive, 10 0
        bindm = $mainMod, mouse:272, movewindow
        bind = $mainMod, 1, workspace, 1
        bind = $mainMod, S, togglespecialworkspace, magic

        bind = $mainMod, R, submap, resize
        submap = resize
        binde = , right, resizeactive, 10 0
        bind = , escape, submap, reset
        submap = reset

        windowrule = float, ^(Finder)$
        windowrulev2 = workspace 2 silent, class:^(Safari)$, title:^(GitHub)$
        windowrulev2 = opacity 0.9, class:.*

        exec-once = open -a Terminal
        env = LANG,en_US.UTF-8
        workspace = 1, monitor:Built-in
        monitor = ,preferred,auto,1
        """)

        #expect(doc.errors == [], "unexpected errors: \(doc.errors)")
        #expect(doc.settings.general.gapsIn == 10)
        #expect(doc.settings.general.gapsOut == 24)
        #expect(doc.settings.general.borderSize == 3)
        #expect(doc.settings.general.layout == .master)
        #expect(doc.settings.general.activeBorder.colors.count == 2)
        #expect(doc.settings.general.activeBorder.angleDeg == 45)
        #expect(doc.settings.dwindle.defaultSplitRatio == 1.2)
        #expect(doc.settings.master.newStatus == "master")
        #expect(doc.settings.master.mfact == 0.6)
        #expect(doc.settings.binds.workspaceBackAndForth)
        #expect(doc.settings.bar.enabled)
        #expect(doc.settings.bar.position == .bottom)
        #expect(doc.settings.bar.height == 32)
        #expect(doc.settings.bar.showWorkspaces == false)
        #expect(doc.settings.bar.showApp)
        #expect(doc.settings.bar.showIndicators == false)
        #expect(doc.settings.bar.indicators == [.layout, .date, .volume])
        #expect(doc.settings.bar.background == MLColor.parse("rgba(111111cc)")!)

        #expect(doc.binds.count == 9)
        let execBind = doc.binds[0]
        #expect(execBind.mods == [.cmd])
        #expect(execBind.key == "q")
        #expect(execBind.dispatcher == .exec("kitty --single-instance"))

        #expect(doc.binds[1].mods == [.cmd, .shift])
        #expect(doc.binds[1].dispatcher == .killactive)
        #expect(doc.binds[2].flags.contains(.repeats))
        #expect(doc.binds[3].flags.contains(.mouse))
        #expect(doc.binds[3].dispatcher == .movewindow(.mouse))
        #expect(doc.binds[4].dispatcher == .workspace(.id(1)))
        #expect(doc.binds[5].dispatcher == .togglespecialworkspace("magic"))

        let submapBinds = doc.binds.filter { $0.submap == "resize" }
        #expect(submapBinds.count == 2)
        #expect(submapBinds[1].dispatcher == .submap(""))
        #expect(doc.binds[6].dispatcher == .submap("resize"))
        #expect(doc.binds[6].submap == "")

        #expect(doc.rules.count == 3)
        #expect(doc.rules[0].effect == .float)
        #expect(doc.rules[1].effect == .workspace(.id(2), silent: true))
        #expect(doc.rules[2].effect == .unsupported("opacity"))

        #expect(doc.execOnce == ["open -a Terminal"])
        #expect(doc.envs.count == 1)
        #expect(doc.envs[0].key == "LANG")
        #expect(doc.workspaceRules == [WorkspaceRule(target: .id(1), monitorName: "Built-in")])
        #expect(doc.monitors.count == 1)
    }

    @Test func unknownKeywordIsError() {
        let doc = parseDoc("unknownkw = 1")
        #expect(doc.errors.count == 1)
        #expect(doc.errors[0].message.contains("unknown keyword"))
    }

    @Test func toleratedHyprlandSections() {
        let doc = parseDoc("""
        animations {
            enabled = true
            bezier = myBezier, 0.05, 0.9, 0.1, 1.05
            animation = windows, 1, 7, myBezier
        }
        decoration {
            rounding = 8
            blur {
                enabled = true
                size = 3
            }
        }
        input {
            kb_layout = us
            follow_mouse = 1
        }
        """)
        #expect(doc.errors == [], "hyprland config sections must be tolerated: \(doc.errors)")
        #expect(doc.settings.decoration.rounding == 8)
        #expect(doc.settings.input.followMouse == 1)
    }

    @Test func commentEscaping() {
        let doc = parseDoc("exec-once = echo a ## b # trailing comment")
        #expect(doc.execOnce == ["echo a # b"])
    }

    @Test func bannerLinesAreComments() {
        let doc = parseDoc("""
        ###############################################################################
        # vindu — tiling window manager for macOS
        ###############################################################################
            # indented comment
        general {
            gaps_in = 7
        }
        """)
        #expect(doc.errors == [], "banner lines must parse as comments: \(doc.errors)")
        #expect(doc.settings.general.gapsIn == 7)
    }

    @Test func sourceDirective() {
        let parser = ConfigParser(fileLoader: { path in
            #expect(path.hasSuffix("extra.conf"))
            return "general {\n    gaps_in = 99\n}"
        })
        let doc = parser.parse(text: "source = extra.conf")
        #expect(doc.errors == [])
        #expect(doc.settings.general.gapsIn == 99)
    }

    @Test func unbindRemovesBind() {
        let doc = parseDoc("""
        bind = SUPER, T, exec, kitty
        unbind = SUPER, T
        """)
        #expect(doc.errors == [])
        #expect(doc.binds == [])
    }

    @Test func applyKeywordRuntime() {
        var doc = ConfigDocument()
        #expect(ConfigParser.applyKeyword("general:gaps_in", "33", to: &doc) == nil)
        #expect(doc.settings.general.gapsIn == 33)
        #expect(ConfigParser.applyKeyword("bar:enabled", "true", to: &doc) == nil)
        #expect(doc.settings.bar.enabled)
        #expect(ConfigParser.applyKeyword("bar:indicators", "windows,clock,audio", to: &doc) == nil)
        #expect(doc.settings.bar.indicators == [.windows, .date, .volume])
        #expect(ConfigParser.applyKeyword("bind", "SUPER, Y, exec, top", to: &doc) == nil)
        #expect(doc.binds.count == 1)
        #expect(ConfigParser.applyKeyword("general:gaps_in", "abc", to: &doc) != nil)
        #expect(ConfigParser.applyKeyword("nope:nope", "1", to: &doc) != nil)
    }

    @Test func unclosedSectionReported() {
        let doc = parseDoc("general {\n gaps_in = 1\n")
        #expect(doc.errors.count == 1)
        #expect(doc.errors[0].message.contains("unclosed"))
    }
}
