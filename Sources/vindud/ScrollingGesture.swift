import CoreGraphics
import VinduCore

enum ScrollingGestureAction: Equatable {
    case pending
    case horizontal(Double)
    case workspace(Int)
    case consumed
}

struct ScrollingGestureSession {
    enum Axis {
        case horizontal
        case vertical
    }

    let monitorID: CGDirectDisplayID
    let workspaceID: Int
    private var axis: Axis?
    private var pendingX = 0.0
    private var pendingY = 0.0
    private var verticalDistance = 0.0
    private var switchedWorkspace = false

    init(monitorID: CGDirectDisplayID, workspaceID: Int) {
        self.monitorID = monitorID
        self.workspaceID = workspaceID
    }

    mutating func update(deltaX: Double, deltaY: Double) -> ScrollingGestureAction {
        guard deltaX.isFinite, deltaY.isFinite else { return .consumed }
        if axis == nil {
            pendingX += deltaX
            pendingY += deltaY
            guard max(abs(pendingX), abs(pendingY)) >= 6 else { return .pending }
            axis = abs(pendingX) > abs(pendingY) ? .horizontal : .vertical
        }
        switch axis {
        case .horizontal:
            let output = pendingX == 0 ? deltaX : pendingX
            pendingX = 0
            pendingY = 0
            return .horizontal(output)
        case .vertical:
            guard !switchedWorkspace else { return .consumed }
            verticalDistance += pendingY == 0 ? deltaY : pendingY
            pendingX = 0
            pendingY = 0
            guard abs(verticalDistance) >= 80 else { return .pending }
            switchedWorkspace = true
            return .workspace(verticalDistance > 0 ? -1 : 1)
        case nil:
            return .pending
        }
    }
}

func cubicEaseOut(_ progress: Double) -> Double {
    let bounded = min(max(progress, 0), 1)
    return 1 - pow(1 - bounded, 3)
}
