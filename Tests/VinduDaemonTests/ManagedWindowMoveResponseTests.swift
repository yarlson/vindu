import Testing
@testable import vindud

struct ManagedWindowMoveResponseTests {
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let observation: WindowGeometryObservation
        let hidden: Bool
        let floating: Bool
        let expected: ManagedWindowMoveResponse

        var testDescription: String { name }
    }

    @Test(arguments: [
        Case(name: "hidden window moved by its app returns to the stash",
             observation: .external, hidden: true, floating: false, expected: .restoreStash),
        Case(name: "hidden floating window moved by its app returns to the stash",
             observation: .external, hidden: true, floating: true, expected: .restoreStash),
        Case(name: "hidden window echo of Vindu's own write is ignored",
             observation: .inFlight, hidden: true, floating: false, expected: .none),
        Case(name: "hidden window that refused the stash does not retry",
             observation: .suppressed, hidden: true, floating: false, expected: .none),
        Case(name: "visible floating window keeps the user's frame",
             observation: .external, hidden: false, floating: true, expected: .adoptFrame),
        Case(name: "visible tiled window returns to its tile",
             observation: .external, hidden: false, floating: false, expected: .restoreTarget),
    ])
    func externalMoveResponse(_ testCase: Case) {
        let response = ManagedWindowMoveResponse(observation: testCase.observation,
                                                 hidden: testCase.hidden,
                                                 floating: testCase.floating)

        #expect(response == testCase.expected)
    }
}
