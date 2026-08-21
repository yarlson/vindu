public struct ActiveBorderState: Equatable {
    public let managedWindowID: UInt32?
    public let systemWindowID: UInt32?
    public let eligible: Bool
    public let paused: Bool
    public let hidden: Bool
    public let minimized: Bool
    public let nativeFullscreen: Bool
    public let managedFullscreen: Bool
    public let width: Double

    public init(managedWindowID: UInt32?,
                systemWindowID: UInt32?,
                eligible: Bool,
                paused: Bool,
                hidden: Bool,
                minimized: Bool,
                nativeFullscreen: Bool,
                managedFullscreen: Bool,
                width: Double) {
        self.managedWindowID = managedWindowID
        self.systemWindowID = systemWindowID
        self.eligible = eligible
        self.paused = paused
        self.hidden = hidden
        self.minimized = minimized
        self.nativeFullscreen = nativeFullscreen
        self.managedFullscreen = managedFullscreen
        self.width = width
    }
}

public enum ActiveBorderPolicy {
    public static func targetWindowID(for state: ActiveBorderState) -> UInt32? {
        guard let managedWindowID = state.managedWindowID,
              state.systemWindowID == managedWindowID,
              state.eligible,
              !state.paused,
              !state.hidden,
              !state.minimized,
              !state.nativeFullscreen,
              !state.managedFullscreen,
              state.width > 0 else {
            return nil
        }
        return managedWindowID
    }
}
