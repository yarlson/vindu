import CoreGraphics
import Foundation
import Testing
import VinduCore
@testable import vindud

struct WindowGeometryControllerTests {
    @Test func fullFrameUsesSizePositionSizeAndReadbackCompletesIt() {
        let backend = GeometryBackendStub(frame: CGRect(x: 10, y: 20, width: 300, height: 200))
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)

        controller.register(42, observedFrame: backend.frame)
        controller.submitFrame(target, for: 42)

        #expect(backend.writes == [.size(target.size), .position(target.origin), .size(target.size)])
        scheduler.run(delay: 0.15)
        #expect(outcomes == [.converged(target)])
    }

    @Test func newerTargetSupersedesPendingVerification() {
        let backend = GeometryBackendStub(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )
        let first = CGRect(x: 10, y: 10, width: 400, height: 300)
        let second = CGRect(x: 20, y: 30, width: 700, height: 500)

        controller.register(42, observedFrame: backend.frame)
        controller.submitFrame(first, for: 42)
        controller.submitFrame(second, for: 42)
        scheduler.runAll()

        #expect(outcomes == [.superseded, .converged(second)])
        #expect(backend.frame == second)
    }

    @Test func permanentMismatchStopsAfterOneRetryWithoutChangingTheTarget() {
        let actual = CGRect(x: 948, y: 307, width: 689, height: 1200)
        let target = CGRect(x: 870, y: 45, width: 845, height: 1059)
        let backend = GeometryBackendStub(frame: actual)
        backend.acceptWrites = false
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )

        controller.register(42, observedFrame: actual)
        controller.submitFrame(target, for: 42)
        scheduler.run(delay: 0.15)
        scheduler.run(delay: 0.75)
        scheduler.run(delay: 0.15)

        #expect(backend.writes.count == 7)
        #expect(outcomes == [.failed(actual, nil)])
        #expect(controller.observe(actual, for: 42) == .suppressed)
        #expect(controller.observe(CGRect(x: 953, y: 307, width: 689, height: 1200), for: 42) == .external)
    }

    @Test func replacingElementInvalidatesItsPendingWork() {
        let backend = GeometryBackendStub(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        backend.acceptWrites = false
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )

        controller.register(42, observedFrame: backend.frame)
        controller.submitFrame(CGRect(x: 10, y: 20, width: 500, height: 400), for: 42)
        controller.replaceElement(42, observedFrame: CGRect(x: 50, y: 60, width: 300, height: 200))
        scheduler.runAll()

        #expect(outcomes == [.superseded])
        #expect(controller.observedFrame(for: 42) == CGRect(x: 50, y: 60, width: 300, height: 200))
    }

    @Test func unsupportedGeometryDoesNotRetry() {
        let actual = CGRect(x: 10, y: 20, width: 300, height: 200)
        let backend = GeometryBackendStub(frame: actual)
        backend.writeError = .attributeUnsupported
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )

        controller.register(42, observedFrame: actual)
        controller.submitFrame(CGRect(x: 100, y: 120, width: 800, height: 600), for: 42)
        scheduler.run(delay: 0.15)

        #expect(backend.writes.count == 3)
        #expect(outcomes == [.failed(actual, .attributeUnsupported)])
    }

    @Test func transientReadFailureRetriesAndConverges() {
        let actual = CGRect(x: 10, y: 20, width: 300, height: 200)
        let target = CGRect(x: 100, y: 120, width: 800, height: 600)
        let backend = GeometryBackendStub(frame: actual)
        backend.readErrors = [.cannotComplete]
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )

        controller.register(42, observedFrame: actual)
        controller.submitFrame(target, for: 42)
        scheduler.run(delay: 0.15)
        scheduler.run(delay: 0.75)

        #expect(backend.writes.count == 4)
        #expect(outcomes == [.converged(target)])
    }

    @Test func frameRetryEstablishesPositionBeforeDelayedSizeAttempt() {
        let actual = CGRect(x: 948, y: 307, width: 858, height: 1059)
        let target = CGRect(x: 13, y: 45, width: 1702, height: 1059)
        let backend = GeometryBackendStub(frame: actual)
        backend.rejectedSizeWrites = 2
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )

        controller.register(42, observedFrame: actual)
        controller.submitFrame(target, for: 42)
        scheduler.run(delay: 0.15)
        scheduler.run(delay: 0.75)
        scheduler.run(delay: 0.15)

        #expect(backend.writes == [
            .size(target.size), .position(target.origin), .size(target.size),
            .position(target.origin),
            .size(target.size), .position(target.origin), .size(target.size),
        ])
        #expect(outcomes == [.converged(target)])
    }

    @Test func stashIntentDoesNotReplaceTheLogicalFrame() {
        let target = CGRect(x: 10, y: 20, width: 500, height: 400)
        let backend = GeometryBackendStub(frame: target)
        let scheduler = GeometrySchedulerStub()
        let controller = WindowGeometryController(backend: backend, schedule: scheduler.schedule)

        controller.register(42, observedFrame: target)
        controller.submitFrame(target, for: 42)
        scheduler.run(delay: 0.15)
        controller.submitStashPosition(CGPoint(x: 1918, y: 1078), for: 42)
        scheduler.run(delay: 0.15)

        #expect(backend.writes.last == .position(CGPoint(x: 1918, y: 1078)))
        #expect(controller.observedFrame(for: 42)?.size == target.size)
        #expect(controller.observedFrame(for: 42)?.origin == CGPoint(x: 1918, y: 1078))
    }

    @Test func stashAcceptsThePlatformClampedVerticalPosition() {
        let original = CGRect(x: 13, y: 45, width: 1702, height: 1059)
        let backend = GeometryBackendStub(frame: original)
        let scheduler = GeometrySchedulerStub()
        var outcomes: [WindowGeometryOutcome] = []
        let controller = WindowGeometryController(
            backend: backend,
            schedule: scheduler.schedule,
            onOutcome: { _, outcome in outcomes.append(outcome) }
        )

        controller.register(42, observedFrame: original)
        controller.submitStashPosition(CGPoint(x: 1726, y: 1115), for: 42)
        backend.frame.origin = CGPoint(x: 1726, y: 1065)
        scheduler.run(delay: 0.15)

        #expect(backend.writes == [.position(CGPoint(x: 1726, y: 1115))])
        #expect(outcomes == [.converged(backend.frame)])
        #expect(controller.observedFrame(for: 42) == backend.frame)
    }
}

private final class GeometryBackendStub: WindowGeometryBackend {
    enum Write: Equatable {
        case size(CGSize)
        case position(CGPoint)
    }

    var frame: CGRect
    var writes: [Write] = []
    var acceptWrites = true
    var writeError: WindowGeometryAccessError?
    var readErrors: [WindowGeometryAccessError] = []
    var rejectedSizeWrites = 0

    init(frame: CGRect) {
        self.frame = frame
    }

    func readFrame(_ id: WindowID) -> Result<CGRect, WindowGeometryAccessError> {
        if !readErrors.isEmpty { return .failure(readErrors.removeFirst()) }
        return .success(frame)
    }

    func writeSize(_ size: CGSize, to id: WindowID) -> Result<Void, WindowGeometryAccessError> {
        writes.append(.size(size))
        if let writeError { return .failure(writeError) }
        if rejectedSizeWrites > 0 {
            rejectedSizeWrites -= 1
            return .success(())
        }
        if acceptWrites { frame.size = size }
        return .success(())
    }

    func writePosition(_ position: CGPoint,
                       to id: WindowID) -> Result<Void, WindowGeometryAccessError> {
        writes.append(.position(position))
        if let writeError { return .failure(writeError) }
        if acceptWrites { frame.origin = position }
        return .success(())
    }
}

private final class GeometrySchedulerStub {
    private var work: [(delay: TimeInterval, item: DispatchWorkItem)] = []

    lazy var schedule: WindowGeometryController.Schedule = { [weak self] delay, item in
        self?.work.append((delay, item))
    }

    func run(delay: TimeInterval) {
        let matching = work.filter { $0.delay == delay }
        work.removeAll { $0.delay == delay }
        matching.forEach { $0.item.perform() }
    }

    func runAll() {
        while let next = work.first {
            work.removeFirst()
            next.item.perform()
        }
    }
}
