import CoreGraphics

/// One workspace: a master-order list (canonical window order) plus the other
/// layout structures kept in sync, so `layout.kind` can switch at runtime.
///
/// Tiled membership MUST go through `insertTiled`/`removeTiled`/`removeWindow`/
/// `swapTiled` — they are the single place that keeps layout structures in
/// lockstep. Layouts stay exposed for layout-specific operations
/// (ratios, primary fraction, orientation, frames), not membership.
public final class WorkspaceState {
    public let id: Int
    /// Named workspaces share the negative id space; never derive this from the id.
    public let isSpecial: Bool
    public var name: String
    public var monitor: CGDirectDisplayID
    public let dwindle = DwindleTree()
    public let master = MasterLayout()
    public let scrolling = ScrollingLayout()
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
                            dwindleConfiguration: DwindleConfiguration,
                            masterConfiguration: MasterConfiguration,
                            scrollingConfiguration: ScrollingConfiguration = .init(defaultColumnWidth: 0.5),
                            layoutKind: LayoutKind = .dwindle) {
        master.insert(id, configuration: masterConfiguration)
        _ = dwindle.frames(in: container)
        let anchor = near.flatMap { dwindle.contains($0) ? $0 : nil }
        dwindle.insert(id, near: anchor, container: container,
                       configuration: dwindleConfiguration)
        if layoutKind == .scrolling {
            scrolling.insert(id, after: near,
                             defaultColumnWidth: scrollingConfiguration.defaultColumnWidth)
            syncFlatLayoutsFromScrolling(container: container,
                                         dwindleConfiguration: dwindleConfiguration)
        } else {
            scrolling.rebuildSingletons(from: master.windows,
                                        defaultColumnWidth: scrollingConfiguration.defaultColumnWidth)
        }
    }

    /// Removes from the tiled structures only (window stays on the workspace,
    /// e.g. while minimized or when becoming floating).
    public func removeTiled(_ id: WindowID) {
        master.remove(id)
        dwindle.remove(id)
        scrolling.remove(id)
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
        scrolling.swapWindows(a, b)
    }

    public func swapWithMaster(_ focused: WindowID, mode: String, container: CGRect,
                               dwindleConfiguration: DwindleConfiguration) {
        let previousOrder = master.windows
        master.swapWithMaster(focused, mode: mode)
        let changed = previousOrder.indices.filter { previousOrder[$0] != master.windows[$0] }
        if changed.count == 2 {
            scrolling.swapWindows(previousOrder[changed[0]], previousOrder[changed[1]])
        }
        dwindle.rebuild(from: master.windows, container: container,
                        configuration: dwindleConfiguration)
    }

    public func changeLayout(from oldKind: LayoutKind, to newKind: LayoutKind, container: CGRect,
                             dwindleConfiguration: DwindleConfiguration,
                             scrollingConfiguration: ScrollingConfiguration) {
        guard oldKind != newKind else { return }
        if oldKind == .scrolling || newKind == .scrolling {
            scrolling.rebuildSingletons(from: master.windows,
                                        defaultColumnWidth: scrollingConfiguration.defaultColumnWidth)
        }
        dwindle.rebuild(from: master.windows, container: container,
                        configuration: dwindleConfiguration)
    }

    @discardableResult
    public func scrollingConsume(into focused: WindowID, container: CGRect,
                                 dwindleConfiguration: DwindleConfiguration) -> WindowID? {
        let consumed = scrolling.consumeNextColumn(into: focused)
        if consumed != nil {
            syncFlatLayoutsFromScrolling(container: container,
                                         dwindleConfiguration: dwindleConfiguration)
        }
        return consumed
    }

    @discardableResult
    public func scrollingExpel(_ window: WindowID, container: CGRect,
                               dwindleConfiguration: DwindleConfiguration) -> Bool {
        guard scrolling.expel(window) else { return false }
        syncFlatLayoutsFromScrolling(container: container,
                                     dwindleConfiguration: dwindleConfiguration)
        return true
    }

    @discardableResult
    public func scrollingMove(_ window: WindowID, direction: Direction, container: CGRect,
                              dwindleConfiguration: DwindleConfiguration) -> Bool {
        guard scrolling.move(window, direction: direction) else { return false }
        syncFlatLayoutsFromScrolling(container: container,
                                     dwindleConfiguration: dwindleConfiguration)
        return true
    }

    @discardableResult
    public func scrollingSwap(_ window: WindowID, direction: Direction, container: CGRect,
                              dwindleConfiguration: DwindleConfiguration) -> Bool {
        guard scrolling.swap(window, direction: direction) else { return false }
        syncFlatLayoutsFromScrolling(container: container,
                                     dwindleConfiguration: dwindleConfiguration)
        return true
    }

    private func syncFlatLayoutsFromScrolling(container: CGRect,
                                               dwindleConfiguration: DwindleConfiguration) {
        master.replaceOrder(with: scrolling.windowsInOrder)
        dwindle.rebuild(from: master.windows, container: container,
                        configuration: dwindleConfiguration)
    }
}

/// Owns the workspace collection: positive ids for
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
            let (id, overflow) = currentID.addingReportingOverflow(d)
            if overflow { return d < 0 ? 1 : nil }
            return max(1, id)
        case .relativeExisting(let d):
            let ids = byID.keys.filter { $0 > 0 }.sorted()
            guard !ids.isEmpty else { return currentID }
            let idx = ids.firstIndex(of: currentID) ?? 0
            let n = ids.count
            let offset = d % n
            if offset >= 0 {
                let distanceToEnd = n - idx
                return ids[offset < distanceToEnd ? idx + offset : offset - distanceToEnd]
            }
            let magnitude = -offset
            return ids[magnitude <= idx ? idx - magnitude : n - (magnitude - idx)]
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

    /// An empty, invisible, unbound,
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
