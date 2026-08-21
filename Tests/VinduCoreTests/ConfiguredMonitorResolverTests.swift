import Testing
@testable import VinduCore

@Suite struct ConfiguredMonitorResolverTests {
    @Test func exactNameWinsBeforePartialMatches() {
        #expect(ConfiguredMonitorResolver.resolve(
            "studio display",
            in: ["Studio Display", "Studio Display Wide"]
        ) == .matched(0))
    }

    @Test func onePartialNameMatches() {
        #expect(ConfiguredMonitorResolver.resolve(
            "built-in",
            in: ["Built-in Retina Display", "Studio Display"]
        ) == .matched(0))
    }

    @Test func missingAndAmbiguousNamesStayUnresolved() {
        #expect(ConfiguredMonitorResolver.resolve(
            "display",
            in: ["Studio Display", "Built-in Display"]
        ) == .ambiguous)
        #expect(ConfiguredMonitorResolver.resolve(
            "projector",
            in: ["Studio Display"]
        ) == .missing)
    }
}
