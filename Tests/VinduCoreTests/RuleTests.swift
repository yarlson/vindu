import Testing
@testable import VinduCore

struct RuleTests {
    @Test func v2MatchAllFields() throws {
        let rule = try WindowRule.parseV2("float, class:^(Safari)$, title:GitHub").get()
        #expect(rule.effect == .float)
        #expect(rule.matches(MatchTarget(clazz: "Safari", title: "GitHub — vindu")))
        #expect(!rule.matches(MatchTarget(clazz: "Safari", title: "Lobsters")))
        #expect(!rule.matches(MatchTarget(clazz: "Finder", title: "GitHub")))
    }

    @Test func v1ClassOnly() throws {
        let rule = try WindowRule.parseV1("float, ^(Finder)$").get()
        #expect(rule.matches(MatchTarget(clazz: "Finder", title: "Documents")))
        #expect(!rule.matches(MatchTarget(clazz: "FinderClone", title: "x")))
    }

    @Test func floatingMatcher() throws {
        let rule = try WindowRule.parseV2("tile, floating:1").get()
        #expect(rule.matches(MatchTarget(clazz: "x", title: "y", floating: true)))
        #expect(!rule.matches(MatchTarget(clazz: "x", title: "y", floating: false)))
    }

    @Test func effectParsing() {
        #expect((try? WindowRule.parseV2("size 800 600, class:.*").get().effect) ==
                .size(Delta(value: 800), Delta(value: 600)))
        #expect((try? WindowRule.parseV2("move 50% 0, class:.*").get().effect) ==
                .move(Delta(value: 50, percent: true), Delta(value: 0)))
        #expect((try? WindowRule.parseV2("workspace special:magic silent, class:.*").get().effect) ==
                .workspace(.special("magic"), silent: true))
        #expect((try? WindowRule.parseV2("opacity 0.9 0.8, class:.*").get().effect) ==
                .unsupported("opacity"))
        #expect((try? WindowRule.parseV2("teleport, class:.*").get()) == nil)
    }

    @Test func invalidRegexRejected() {
        #expect((try? WindowRule.parseV2("float, class:^(unclosed").get()) == nil)
    }

    @Test func matcherParsingFallsBackToClass() {
        let m = RuleMatcher.parse("^(kitty)$")
        #expect(m?.field == .clazz)
        // Regex chars after a non-field prefix stay part of the pattern.
        let weird = RuleMatcher.parse("title:foo:bar")
        #expect(weird?.field == .title)
        #expect(weird?.pattern == "foo:bar")
    }

    @Test func addressMatcher() throws {
        let m = try #require(RuleMatcher.parse("address:0x2a"))
        #expect(m.matches(MatchTarget(clazz: "", title: ""), address: 42))
        #expect(!m.matches(MatchTarget(clazz: "", title: ""), address: 43))
    }

    @Test func windowAddressFormatting() {
        #expect(windowAddress(42) == "0x2a")
    }

    @Test func eventLines() {
        #expect(WMEvent.workspace("3").line == "workspace>>3")
        #expect(WMEvent.activewindow(clazz: "kitty", title: "vim").line == "activewindow>>kitty,vim")
        #expect(WMEvent.openwindow(42, workspace: "2", clazz: "Safari", title: "t").line ==
                "openwindow>>0x2a,2,Safari,t")
        #expect(WMEvent.configreloaded.line == "configreloaded>>")
    }
}
