import CoreGraphics

/// Hyprland's master layout: a master area plus a stack, controlled via
/// `layoutmsg` (swapwithmaster, addmaster, orientation…, mfact).
public final class MasterLayout {
    public private(set) var windows: [WindowID] = []
    public private(set) var masterCount = 1
    /// Runtime overrides set via layoutmsg; nil falls back to MasterSettings.
    public private(set) var mfactOverride: Double?
    public private(set) var orientationOverride: MasterOrientation?

    public init() {}

    public var isEmpty: Bool { windows.isEmpty }
    public var count: Int { windows.count }
    public func contains(_ w: WindowID) -> Bool { windows.contains(w) }

    public func insert(_ w: WindowID, settings: MasterSettings) {
        guard !contains(w) else { return }
        if settings.newStatus == "master" {
            windows.insert(w, at: 0)
        } else if settings.newOnTop {
            windows.insert(w, at: min(masterCount, windows.count))
        } else {
            windows.append(w)
        }
    }

    public func remove(_ w: WindowID) {
        windows.removeAll { $0 == w }
        masterCount = min(masterCount, max(1, windows.count))
    }

    public func swap(_ a: WindowID, _ b: WindowID) {
        guard let ia = windows.firstIndex(of: a), let ib = windows.firstIndex(of: b) else { return }
        windows.swapAt(ia, ib)
    }

    public func swapWithMaster(_ focused: WindowID, mode: String) {
        guard let idx = windows.firstIndex(of: focused), windows.count > 1 else { return }
        let isMaster = idx < masterCount
        switch mode {
        case "master":
            if !isMaster { windows.swapAt(idx, 0) }
        case "child":
            if isMaster, windows.count > masterCount { windows.swapAt(idx, masterCount) }
        default: // auto
            if isMaster {
                if windows.count > masterCount { windows.swapAt(idx, masterCount) }
            } else {
                windows.swapAt(idx, 0)
            }
        }
    }

    public func cycle(from w: WindowID, prev: Bool) -> WindowID? {
        guard let idx = windows.firstIndex(of: w), windows.count > 1 else { return nil }
        let n = windows.count
        return windows[((idx + (prev ? -1 : 1)) % n + n) % n]
    }

    public func addMaster() {
        masterCount = min(masterCount + 1, max(1, windows.count))
    }

    public func removeMaster() {
        masterCount = max(1, masterCount - 1)
    }

    public func setMfact(_ arg: SplitRatioArg, settings: MasterSettings) {
        let current = mfactOverride ?? settings.mfact
        switch arg {
        case .delta(let d): mfactOverride = clamp(current + d)
        case .exact(let v): mfactOverride = clamp(v)
        }
    }

    public func setOrientation(_ o: MasterOrientation) {
        orientationOverride = o
    }

    public func cycleOrientation(prev: Bool) {
        let ring: [MasterOrientation] = [.left, .top, .right, .bottom, .center]
        let current = orientationOverride ?? .left
        let idx = ring.firstIndex(of: current) ?? 0
        let n = ring.count
        orientationOverride = ring[((idx + (prev ? -1 : 1)) % n + n) % n]
    }

    public func frames(in rect: CGRect, settings: MasterSettings) -> [WindowID: CGRect] {
        guard !windows.isEmpty else { return [:] }
        let m = min(max(masterCount, 1), windows.count)
        let mfact = clamp(mfactOverride ?? settings.mfact)
        let orient = orientationOverride ?? settings.orientation
        let masters = Array(windows.prefix(m))
        let slaves = Array(windows.dropFirst(m))
        var out: [WindowID: CGRect] = [:]

        func place(_ ids: [WindowID], in area: CGRect, vertical: Bool) {
            for (i, r) in LayoutMath.stackRects(area, count: ids.count, vertical: vertical).enumerated() {
                out[ids[i]] = r
            }
        }

        if slaves.isEmpty {
            place(masters, in: rect, vertical: orient != .top && orient != .bottom)
            return out
        }

        switch orient {
        case .left:
            let mw = rect.width * mfact
            place(masters, in: CGRect(x: rect.minX, y: rect.minY, width: mw, height: rect.height), vertical: true)
            place(slaves, in: CGRect(x: rect.minX + mw, y: rect.minY, width: rect.width - mw, height: rect.height), vertical: true)
        case .right:
            let mw = rect.width * mfact
            place(masters, in: CGRect(x: rect.maxX - mw, y: rect.minY, width: mw, height: rect.height), vertical: true)
            place(slaves, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - mw, height: rect.height), vertical: true)
        case .top:
            let mh = rect.height * mfact
            place(masters, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: mh), vertical: false)
            place(slaves, in: CGRect(x: rect.minX, y: rect.minY + mh, width: rect.width, height: rect.height - mh), vertical: false)
        case .bottom:
            let mh = rect.height * mfact
            place(masters, in: CGRect(x: rect.minX, y: rect.maxY - mh, width: rect.width, height: mh), vertical: false)
            place(slaves, in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - mh), vertical: false)
        case .center:
            let mw = rect.width * mfact
            let leftSlaves = slaves.enumerated().filter { $0.offset % 2 == 1 }.map(\.element)
            let rightSlaves = slaves.enumerated().filter { $0.offset % 2 == 0 }.map(\.element)
            let sideW = (rect.width - mw) / (leftSlaves.isEmpty || rightSlaves.isEmpty ? 1 : 2)
            let leftW = leftSlaves.isEmpty ? 0 : sideW
            place(masters, in: CGRect(x: rect.minX + leftW, y: rect.minY, width: mw, height: rect.height), vertical: true)
            if !leftSlaves.isEmpty {
                place(leftSlaves, in: CGRect(x: rect.minX, y: rect.minY, width: leftW, height: rect.height), vertical: true)
            }
            if !rightSlaves.isEmpty {
                place(rightSlaves, in: CGRect(x: rect.minX + leftW + mw, y: rect.minY,
                                              width: rect.width - leftW - mw, height: rect.height), vertical: true)
            }
        }
        return out
    }

    private func clamp(_ v: Double) -> Double {
        min(max(v, 0.05), 0.95)
    }
}
