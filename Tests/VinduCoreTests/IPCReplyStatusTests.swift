import Testing
@testable import VinduCore

struct IPCReplyStatusTests {
    @Test(arguments: [
        ("ok", false),
        ("err: no such workspace", true),
        ("err", true),
        ("unknown request: frobnicate", true),
        ("workspace ID 2 (errands) on monitor Main:", false),
        ("errands", false),
        ("", false),
    ])
    func failureFollowsTheReplyPrefix(_ reply: String, _ isFailure: Bool) {
        #expect(ipcReplyIsFailure(reply) == isFailure)
    }
}
