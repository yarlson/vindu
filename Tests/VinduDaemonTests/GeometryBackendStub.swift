import CoreGraphics
import VinduCore
@testable import vindud

final class GeometryBackendStub: WindowGeometryBackend {
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
