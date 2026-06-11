import CoreGraphics

/// One workspace: a master-order list (canonical window order) plus a dwindle
/// tree kept in sync, so `general:layout` can switch at runtime.
///
/// Tiled membership MUST go through `insertTiled`/`removeTiled`/`removeWindow`/
/// `swapTiled` — they are the single place that keeps both layout structures in
/// lockstep. `dwindle`/`master` stay exposed for layout-specific operations
/// (ratios, mfact, orientation, frames), not membership.
public final class WorkspaceState {
    public let id: Int
    /// Named workspaces share the negative id space; never derive this from the id.
    public let isSpecial: Bool
    public var name: String
    public var monitor: CGDirectDisplayID
    public let dwindle = DwindleTree()
    public let master = MasterLayout()
    public var floating: [WindowID] = []
    public var fullscreen: WindowID?
    public var fullscreenMode = 0
    public var lastFocused: WindowID?

    public var tiled: [WindowID] { master.windows }
    public var allWindows: [WindowID] { master.windows + floating }

    public init(id: Int, name: String, monitor: CGDirectDisplayID, isSpecial: Bool = false) {
        self.id = id
        self.isSpecial = isSpecial
        self.name = name
        self.monitor = monitor
    }

    public func insertTiled(_ id: WindowID, near: WindowID?, container: CGRect,
                            dwindleSettings: DwindleSettings, masterSettings: MasterSettings) {
        master.insert(id, settings: masterSettings)
        let anchor = near.flatMap { dwindle.contains($0) ? $0 : nil }
        dwindle.insert(id, near: anchor, container: container, settings: dwindleSettings)
    }

    /// Removes from the tiled structures only (window stays on the workspace,
    /// e.g. while minimized or when becoming floating).
    public func removeTiled(_ id: WindowID) {
        master.remove(id)
        dwindle.remove(id)
    }

    /// Removes the window from the workspace entirely.
    public func removeWindow(_ id: WindowID) {
        removeTiled(id)
        floating.removeAll { $0 == id }
        if fullscreen == id { fullscreen = nil }
        if lastFocused == id { lastFocused = nil }
    }

    public func swapTiled(_ a: WindowID, _ b: WindowID) {
        dwindle.swap(a, b)
        master.swap(a, b)
    }
}

/// Owns the workspace collection and Hyprland's id scheme: positive ids for
/// regular workspaces, names allocated downward from -1337, specials from -99.
public final class WorkspaceRegistry {
    public private(set) var byID: [Int: WorkspaceState] = [:]
    private var namedIDs: [String: Int] = [:]
    private var specialIDs: [String: Int] = [:]
    private var nextNamedID = -1337
    private var nextSpecialID = -99

    public var onCreate: ((WorkspaceState) -> Void)?
    public var onDestroy: ((WorkspaceState) -> Void)?

    public init() {}

    public func existing(_ id: Int) -> WorkspaceState? {
        byID[id]
    }

    public var sorted: [WorkspaceState] {
        byID.values.sorted { $0.id < $1.id }
    }

    public func specialName(forID id: Int) -> String? {
        specialIDs.first { $0.value == id }?.key
    }

    /// Fetches or creates. New workspaces land on `monitor`.
    public func workspace(forID id: Int, monitor: CGDirectDisplayID) -> WorkspaceState {
        if let ws = byID[id] { return ws }
        let ws = WorkspaceState(id: id, name: String(id), monitor: monitor)
        byID[id] = ws
        onCreate?(ws)
        return ws
    }

    /// Resolves a workspace target to an id. `create` allows allocating ids for
    /// new named/special workspaces; plain numeric ids resolve regardless and
    /// materialize later via `workspace(forID:monitor:)`.
    public func resolveID(_ target: WorkspaceTarget, currentID: Int, previousID: Int?,
                          monitor: CGDirectDisplayID, create: Bool) -> Int? {
        switch target {
        case .id(let n):
            return (byID[n] != nil || create) ? n : nil
        case .relative(let d):
            return max(1, currentID + d)
        case .relativeExisting(let d):
            let ids = byID.keys.filter { $0 > 0 }.sorted()
            guard !ids.isEmpty else { return currentID }
            let idx = ids.firstIndex(of: currentID) ?? 0
            let n = ids.count
            return ids[((idx + d) % n + n) % n]
        case .previous:
            return previousID
        case .name(let s):
            if let id = namedIDs[s] { return id }
            if let n = Int(s) { return n }
            guard create else { return nil }
            nextNamedID -= 1
            namedIDs[s] = nextNamedID
            let ws = workspace(forID: nextNamedID, monitor: monitor)
            ws.name = s
            return nextNamedID
        case .special(let s):
            if let id = specialIDs[s] { return id }
            guard create else { return nil }
            nextSpecialID -= 1
            specialIDs[s] = nextSpecialID
            let ws = WorkspaceState(id: nextSpecialID, name: "special:\(s)",
                                    monitor: monitor, isSpecial: true)
            byID[ws.id] = ws
            onCreate?(ws)
            return nextSpecialID
        case .empty:
            for id in 1...1000 where (byID[id]?.allWindows.isEmpty ?? true) {
                return id
            }
            return nil
        }
    }

    /// Hyprland's dynamic workspace lifecycle: an empty, invisible, unbound,
    /// non-special workspace disappears. Returns true if destroyed.
    @discardableResult
    public func destroyIfEmpty(_ ws: WorkspaceState, isVisible: Bool, isBound: Bool) -> Bool {
        guard ws.allWindows.isEmpty, !isVisible, !ws.isSpecial, !isBound,
              byID[ws.id] != nil else { return false }
        byID.removeValue(forKey: ws.id)
        namedIDs = namedIDs.filter { $0.value != ws.id }
        onDestroy?(ws)
        return true
    }
}
