import Testing
@testable import VinduCore

struct RuleTests {
    @Test func matcherParsingDefaultsToApplicationName() {
        let matcher = RuleMatcher.parse("^(Terminal)$")
        #expect(matcher?.field == .clazz)
        #expect(matcher?.matches(MatchTarget(clazz: "Terminal", title: "Shell")) == true)
        #expect(matcher?.matches(MatchTarget(clazz: "Terminal Preview", title: "Shell")) == false)

        let title = RuleMatcher.parse("title:foo:bar")
        #expect(title?.field == .title)
        #expect(title?.pattern == "foo:bar")
    }

    @Test func addressMatcherUsesHexWindowIdentifiers() throws {
        let matcher = try #require(RuleMatcher.parse("address:0x2a"))
        #expect(matcher.matches(MatchTarget(clazz: "", title: ""), address: 42))
        #expect(!matcher.matches(MatchTarget(clazz: "", title: ""), address: 43))
        #expect(windowAddress(42) == "0x2a")
    }

    @Test func eventLinesReplaceLineBreaksInPayloads() {
        #expect(WMEvent.workspace("3").line == "workspace>>3")
        #expect(WMEvent.activewindow(clazz: "kitty", title: "vim").line == "activewindow>>kitty,vim")
        #expect(WMEvent.openwindow(42, workspace: "2", clazz: "Safari", title: "t").line ==
                "openwindow>>0x2a,2,Safari,t")
        #expect(WMEvent.configreloaded.line == "configreloaded>>")
        #expect(WMEvent.activewindow(clazz: "term\nx", title: "vim\ry").line ==
                "activewindow>>term x,vim y")
    }
}
