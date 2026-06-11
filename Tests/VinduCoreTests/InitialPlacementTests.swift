import Testing
import CoreGraphics
@testable import VinduCore

struct InitialPlacementTests {
    let usable = CGRect(x: 0, y: 0, width: 1000, height: 800)
    let windowFrame = CGRect(x: 100, y: 100, width: 400, height: 300)

    func evaluate(_ ruleLines: [String], clazz: String = "kitty",
                  defaultFloating: Bool = false) -> InitialPlacement {
        let rules = ruleLines.map { try! WindowRule.parseV2($0).get() }
        return InitialPlacement.evaluate(rules: rules,
                                         target: MatchTarget(clazz: clazz, title: "t"),
                                         defaultFloating: defaultFloating,
                                         windowFrame: windowFrame, usable: usable)
    }

    @Test func noMatchingRulesKeepsDefaults() {
        let p = evaluate(["float, class:^(Finder)$"])
        #expect(p == InitialPlacement(floating: false))
    }

    @Test func laterRuleWins() {
        let p = evaluate(["float, class:kitty", "tile, class:kitty"])
        #expect(!p.floating)
    }

    @Test func sizeAndCenter() {
        let p = evaluate(["size 50% 600, class:kitty", "center, class:kitty"])
        #expect(p.floating)
        let f = p.floatFrame
        #expect(f?.size == CGSize(width: 500, height: 600))
        #expect(f?.midX == usable.midX)
        #expect(f?.midY == usable.midY)
    }

    @Test func moveRule() {
        let p = evaluate(["move 10 20, class:kitty"])
        #expect(p.floating)
        #expect(p.floatFrame?.origin == CGPoint(x: 10, y: 20))
        #expect(p.floatFrame?.size == windowFrame.size)
    }

    @Test func workspaceSilentAndMonitor() {
        let p = evaluate(["workspace 2 silent, class:kitty", "monitor DP-1, class:kitty"])
        #expect(p.workspaceTarget == .id(2))
        #expect(p.silent)
        #expect(p.monitorName == "DP-1")
    }

    @Test func pinAndFullscreen() {
        let pin = evaluate(["pin, class:kitty"])
        #expect(pin.floating && pin.pinned)
        let fs = evaluate(["fullscreen, class:kitty"])
        #expect(fs.wantsFullscreen)
    }

    @Test func unsupportedEffectsAreInert() {
        let p = evaluate(["opacity 0.9, class:kitty", "noborder, class:kitty"])
        #expect(p == InitialPlacement(floating: false))
    }
}
