import Foundation

struct ConditionTimedOut: Error {}

private let pollingTimeout: Duration = .seconds(5)
private let pollingInterval: TimeInterval = 0.01

func waitUntil(_ condition: () -> Bool) throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: pollingTimeout)
    while !condition() {
        guard clock.now < deadline else { throw ConditionTimedOut() }
        Thread.sleep(forTimeInterval: pollingInterval)
    }
}

func waitUntil(_ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: pollingTimeout)
    while !condition() {
        guard clock.now < deadline else { throw ConditionTimedOut() }
        try await Task.sleep(for: .seconds(pollingInterval))
    }
}
