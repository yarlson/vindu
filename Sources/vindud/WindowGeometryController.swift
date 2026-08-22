import CoreGraphics
import Foundation
import VinduCore

enum WindowGeometryAccessError: Error, Equatable {
    case invalidGeometry
    case elementUnavailable
    case attributeUnsupported
    case cannotComplete
    case apiFailure(Int32)

    var retryable: Bool {
        switch self {
        case .cannotComplete, .apiFailure:
            return true
        case .invalidGeometry, .elementUnavailable, .attributeUnsupported:
            return false
        }
    }

    var description: String {
        switch self {
        case .invalidGeometry: return "invalid geometry"
        case .elementUnavailable: return "window is no longer available"
        case .attributeUnsupported: return "window does not support the requested geometry"
        case .cannotComplete: return "Accessibility could not complete the request"
        case .apiFailure(let code): return "Accessibility error \(code)"
        }
    }
}

protocol WindowGeometryBackend: AnyObject {
    func readFrame(_ id: WindowID) -> Result<CGRect, WindowGeometryAccessError>
    func writeSize(_ size: CGSize, to id: WindowID) -> Result<Void, WindowGeometryAccessError>
    func writePosition(_ position: CGPoint,
                       to id: WindowID) -> Result<Void, WindowGeometryAccessError>
}

enum WindowGeometryOutcome: Equatable {
    case converged(CGRect)
    case superseded
    case failed(CGRect?, WindowGeometryAccessError?)
}

enum WindowGeometryObservation: Equatable {
    case inFlight
    case external
    case suppressed
}

final class WindowGeometryController {
    typealias Schedule = (TimeInterval, DispatchWorkItem) -> Void

    private enum Target: Equatable {
        case frame(CGRect)
        case stash(CGPoint)
    }

    private final class ActiveIntent {
        let elementGeneration: UInt64
        let intentGeneration: UInt64
        let target: Target
        var firstVerification: DispatchWorkItem?
        var retryVerification: DispatchWorkItem?
        var finalVerification: DispatchWorkItem?
        var lastError: WindowGeometryAccessError?

        init(elementGeneration: UInt64, intentGeneration: UInt64, target: Target) {
            self.elementGeneration = elementGeneration
            self.intentGeneration = intentGeneration
            self.target = target
        }

        func cancel() {
            firstVerification?.cancel()
            retryVerification?.cancel()
            finalVerification?.cancel()
            firstVerification = nil
            retryVerification = nil
            finalVerification = nil
        }
    }

    private struct Record {
        var elementGeneration: UInt64
        var nextIntentGeneration: UInt64 = 0
        var observedFrame: CGRect
        var failedObservedFrame: CGRect?
        var active: ActiveIntent?
    }

    private static let firstVerificationDelay: TimeInterval = 0.15
    private static let retryVerificationDelay: TimeInterval = 0.75
    private static let finalVerificationDelay: TimeInterval = 0.15
    private static let tolerance: CGFloat = 4

    private let backend: WindowGeometryBackend
    private let schedule: Schedule
    private let onObservedFrame: (WindowID, CGRect) -> Void
    private let onOutcome: (WindowID, WindowGeometryOutcome) -> Void
    private var records: [WindowID: Record] = [:]

    init(
        backend: WindowGeometryBackend,
        schedule: @escaping Schedule = { delay, item in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        },
        onObservedFrame: @escaping (WindowID, CGRect) -> Void = { _, _ in },
        onOutcome: @escaping (WindowID, WindowGeometryOutcome) -> Void = { _, _ in }
    ) {
        self.backend = backend
        self.schedule = schedule
        self.onObservedFrame = onObservedFrame
        self.onOutcome = onOutcome
    }

    func register(_ id: WindowID, observedFrame: CGRect) {
        guard isValidWindowFrame(observedFrame) else { return }
        if records[id] != nil {
            replaceElement(id, observedFrame: observedFrame)
            return
        }
        records[id] = Record(elementGeneration: 1, observedFrame: observedFrame)
    }

    func replaceElement(_ id: WindowID, observedFrame: CGRect) {
        guard isValidWindowFrame(observedFrame), var record = records[id] else { return }
        supersede(record.active, for: id)
        record.elementGeneration &+= 1
        record.observedFrame = observedFrame
        record.failedObservedFrame = nil
        record.active = nil
        records[id] = record
        onObservedFrame(id, observedFrame)
    }

    func unregister(_ id: WindowID) {
        guard let record = records.removeValue(forKey: id) else { return }
        supersede(record.active, for: id)
    }

    func cancel(_ id: WindowID) {
        guard var record = records[id] else { return }
        supersede(record.active, for: id)
        record.active = nil
        record.failedObservedFrame = nil
        records[id] = record
    }

    func submitFrame(_ frame: CGRect, for id: WindowID) {
        guard isValidWindowFrame(frame) else {
            onOutcome(id, .failed(records[id]?.observedFrame, .invalidGeometry))
            return
        }
        submit(.frame(frame), for: id)
    }

    func submitStashPosition(_ position: CGPoint, for id: WindowID) {
        guard isValidWindowPoint(position) else {
            onOutcome(id, .failed(records[id]?.observedFrame, .invalidGeometry))
            return
        }
        submit(.stash(position), for: id)
    }

    @discardableResult
    func applyPositionBeforeShutdown(_ position: CGPoint,
                                     for id: WindowID) -> Result<Void, WindowGeometryAccessError> {
        cancel(id)
        guard isValidWindowPoint(position) else { return .failure(.invalidGeometry) }
        return backend.writePosition(position, to: id)
    }

    func observe(_ frame: CGRect, for id: WindowID) -> WindowGeometryObservation {
        guard isValidWindowFrame(frame), var record = records[id] else { return .suppressed }
        record.observedFrame = frame
        records[id] = record
        onObservedFrame(id, frame)
        if record.active != nil {
            return .inFlight
        }
        if let failed = record.failedObservedFrame, framesMatch(failed, frame) {
            return .suppressed
        }
        record.failedObservedFrame = nil
        records[id] = record
        return .external
    }

    func observedFrame(for id: WindowID) -> CGRect? {
        records[id]?.observedFrame
    }

    private func submit(_ target: Target, for id: WindowID) {
        guard var record = records[id] else {
            onOutcome(id, .failed(nil, .elementUnavailable))
            return
        }
        if record.active?.target == target { return }

        supersede(record.active, for: id)
        record.nextIntentGeneration &+= 1
        record.failedObservedFrame = nil
        let active = ActiveIntent(
            elementGeneration: record.elementGeneration,
            intentGeneration: record.nextIntentGeneration,
            target: target
        )
        record.active = active
        records[id] = record

        apply(active, to: id)
        let first = DispatchWorkItem { [weak self] in
            self?.verifyFirst(id, active: active)
        }
        let retry = DispatchWorkItem { [weak self] in
            self?.verifyRetry(id, active: active)
        }
        active.firstVerification = first
        active.retryVerification = retry
        schedule(Self.firstVerificationDelay, first)
        schedule(Self.retryVerificationDelay, retry)
    }

    private func apply(_ active: ActiveIntent, to id: WindowID) {
        active.lastError = nil
        let results: [Result<Void, WindowGeometryAccessError>]
        switch active.target {
        case .frame(let frame):
            results = [
                backend.writeSize(frame.size, to: id),
                backend.writePosition(frame.origin, to: id),
                backend.writeSize(frame.size, to: id),
            ]
        case .stash(let position):
            results = [backend.writePosition(position, to: id)]
        }
        for case .failure(let error) in results {
            active.lastError = error
        }
    }

    private func verifyFirst(_ id: WindowID, active: ActiveIntent) {
        guard let record = currentRecord(for: id, active: active) else { return }

        switch backend.readFrame(id) {
        case .success(let frame):
            guard isValidWindowFrame(frame) else {
                active.lastError = .invalidGeometry
                finishFailure(id, active: active, actual: nil)
                return
            }
            updateObserved(frame, for: id)
            if targetMatches(active.target, frame) {
                finish(id, active: active, outcome: .converged(frame))
            } else if active.lastError?.retryable != false {
                applyPosition(active, to: id)
            } else {
                finishFailure(id, active: active, actual: frame)
            }
        case .failure(let error):
            active.lastError = error
            if error.retryable {
                applyPosition(active, to: id)
            } else {
                finishFailure(id, active: active, actual: record.observedFrame)
            }
        }
    }

    private func verifyRetry(_ id: WindowID, active: ActiveIntent) {
        guard let record = currentRecord(for: id, active: active) else { return }

        switch backend.readFrame(id) {
        case .success(let frame):
            guard isValidWindowFrame(frame) else {
                active.lastError = .invalidGeometry
                finishFailure(id, active: active, actual: nil)
                return
            }
            updateObserved(frame, for: id)
            if targetMatches(active.target, frame) {
                finish(id, active: active, outcome: .converged(frame))
            } else if active.lastError?.retryable == false {
                finishFailure(id, active: active, actual: frame)
            } else {
                retryOrFinish(id, active: active, actual: frame)
            }
        case .failure(let error):
            active.lastError = error
            if error.retryable {
                retryOrFinish(id, active: active, actual: record.observedFrame)
            } else {
                finishFailure(id, active: active, actual: record.observedFrame)
            }
        }
    }

    private func retryOrFinish(_ id: WindowID, active: ActiveIntent, actual: CGRect) {
        guard case .frame = active.target else {
            finishFailure(id, active: active, actual: actual)
            return
        }
        apply(active, to: id)
        let final = DispatchWorkItem { [weak self] in
            self?.verifyFinal(id, active: active)
        }
        active.finalVerification = final
        schedule(Self.finalVerificationDelay, final)
    }

    private func verifyFinal(_ id: WindowID, active: ActiveIntent) {
        guard let record = currentRecord(for: id, active: active) else { return }

        switch backend.readFrame(id) {
        case .success(let frame):
            guard isValidWindowFrame(frame) else {
                active.lastError = .invalidGeometry
                finishFailure(id, active: active, actual: nil)
                return
            }
            updateObserved(frame, for: id)
            if targetMatches(active.target, frame) {
                finish(id, active: active, outcome: .converged(frame))
            } else {
                finishFailure(id, active: active, actual: frame)
            }
        case .failure(let error):
            active.lastError = error
            finishFailure(id, active: active, actual: record.observedFrame)
        }
    }

    private func currentRecord(for id: WindowID, active: ActiveIntent) -> Record? {
        guard let record = records[id], record.active === active,
              record.elementGeneration == active.elementGeneration,
              record.nextIntentGeneration == active.intentGeneration else { return nil }
        return record
    }

    private func applyPosition(_ active: ActiveIntent, to id: WindowID) {
        active.lastError = nil
        let position: CGPoint
        switch active.target {
        case .frame(let frame): position = frame.origin
        case .stash(let targetPosition): position = targetPosition
        }
        if case .failure(let error) = backend.writePosition(position, to: id) {
            active.lastError = error
        }
    }

    private func updateObserved(_ frame: CGRect, for id: WindowID) {
        guard var record = records[id] else { return }
        record.observedFrame = frame
        records[id] = record
        onObservedFrame(id, frame)
    }

    private func finishFailure(_ id: WindowID, active: ActiveIntent, actual: CGRect?) {
        finish(id, active: active, outcome: .failed(actual, active.lastError))
    }

    private func finish(_ id: WindowID,
                        active: ActiveIntent,
                        outcome: WindowGeometryOutcome) {
        guard var record = records[id], record.active === active else { return }
        active.cancel()
        record.active = nil
        if case .failed(let actual, _) = outcome {
            record.failedObservedFrame = actual
        }
        records[id] = record
        onOutcome(id, outcome)
    }

    private func supersede(_ active: ActiveIntent?, for id: WindowID) {
        guard let active else { return }
        active.cancel()
        onOutcome(id, .superseded)
    }

    private func targetMatches(_ target: Target, _ frame: CGRect) -> Bool {
        switch target {
        case .frame(let targetFrame):
            return framesMatch(targetFrame, frame)
        case .stash(let position):
            return abs(position.x - frame.minX) <= Self.tolerance
        }
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY)
            + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height) <= Self.tolerance
    }
}
