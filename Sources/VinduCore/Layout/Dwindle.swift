import CoreGraphics

/// Node in the dwindle binary tree: either a leaf holding a window, or a split
/// with exactly two children. All rects are top-left-origin global coordinates.
public final class DwindleNode {
    public internal(set) var window: WindowID?
    public internal(set) var orientation: Orientation = .horizontal
    /// Fraction of the split given to `first`, clamped to 0.1…0.9.
    public internal(set) var ratio: Double = 0.5
    public internal(set) var first: DwindleNode?
    public internal(set) var second: DwindleNode?
    public internal(set) weak var parent: DwindleNode?
    public internal(set) var lastRect = CGRect.zero

    init(window: WindowID) {
        self.window = window
    }

    init(orientation: Orientation, ratio: Double, first: DwindleNode, second: DwindleNode) {
        self.orientation = orientation
        self.ratio = ratio
        self.first = first
        self.second = second
    }

    public var isLeaf: Bool { window != nil }
}

/// Hyprland's dwindle layout: each new window splits the focused leaf, with the
/// split orientation following the leaf's aspect ratio.
public final class DwindleTree {
    public private(set) var root: DwindleNode?
    private var leaves: [WindowID: DwindleNode] = [:]

    public init() {}

    public var isEmpty: Bool { root == nil }
    public var count: Int { leaves.count }
    public func contains(_ w: WindowID) -> Bool { leaves[w] != nil }

    /// Leaf windows in in-order traversal (visual reading order).
    public var windowsInOrder: [WindowID] {
        var out: [WindowID] = []
        func walk(_ n: DwindleNode?) {
            guard let n else { return }
            if let w = n.window { out.append(w); return }
            walk(n.first)
            walk(n.second)
        }
        walk(root)
        return out
    }

    public func insert(_ w: WindowID, near focused: WindowID?, container: CGRect, settings: DwindleSettings) {
        guard leaves[w] == nil else { return }
        let leaf = DwindleNode(window: w)
        leaves[w] = leaf
        guard let root else {
            self.root = leaf
            return
        }
        let target = focused.flatMap { leaves[$0] } ?? lastLeaf(of: root)
        let rect = target.lastRect.isEmpty ? container : target.lastRect
        let orientation: Orientation = rect.width >= rect.height ? .horizontal : .vertical
        let ratio = clampRatio(settings.defaultSplitRatio / 2.0)
        let firstChild = settings.forceSplit == 1 ? leaf : target
        let secondChild = settings.forceSplit == 1 ? target : leaf

        let oldParent = target.parent
        let split = DwindleNode(orientation: orientation, ratio: ratio, first: firstChild, second: secondChild)
        split.lastRect = target.lastRect
        firstChild.parent = split
        secondChild.parent = split
        attach(split, to: oldParent, replacing: target)
    }

    public func remove(_ w: WindowID) {
        guard let node = leaves.removeValue(forKey: w) else { return }
        guard let parent = node.parent else {
            root = nil
            return
        }
        let sibling = parent.first === node ? parent.second! : parent.first!
        sibling.lastRect = parent.lastRect
        attach(sibling, to: parent.parent, replacing: parent)
    }

    public func swap(_ a: WindowID, _ b: WindowID) {
        guard a != b, let na = leaves[a], let nb = leaves[b] else { return }
        na.window = b
        nb.window = a
        leaves[a] = nb
        leaves[b] = na
    }

    /// Transposes the split orientation above the window (dispatcher `togglesplit`).
    public func toggleSplit(at w: WindowID) {
        guard let parent = leaves[w]?.parent else { return }
        parent.orientation = parent.orientation == .horizontal ? .vertical : .horizontal
    }

    /// Swaps the two children of the split above the window (dispatcher `swapsplit`).
    public func swapSplit(at w: WindowID) {
        guard let parent = leaves[w]?.parent else { return }
        let f = parent.first
        parent.first = parent.second
        parent.second = f
    }

    /// `splitratio` uses Hyprland's 0.1–1.9 scale where 1.0 is an even split;
    /// internal ratios are that value halved.
    public func setRatio(_ arg: SplitRatioArg, at w: WindowID) {
        guard let parent = leaves[w]?.parent else { return }
        switch arg {
        case .delta(let d): parent.ratio = clampRatio(parent.ratio + d / 2.0)
        case .exact(let v): parent.ratio = clampRatio(v / 2.0)
        }
    }

    /// Drags the window's nearest split edges by pixel deltas (dispatcher `resizeactive`).
    public func resize(_ w: WindowID, dx: Double, dy: Double) {
        guard let leaf = leaves[w] else { return }
        if dx != 0 { adjust(axis: .horizontal, delta: dx, from: leaf) }
        if dy != 0 { adjust(axis: .vertical, delta: dy, from: leaf) }
    }

    private func adjust(axis: Orientation, delta: Double, from leaf: DwindleNode) {
        var child: DwindleNode = leaf
        while let parent = child.parent {
            if parent.orientation == axis {
                let span = axis == .horizontal ? parent.lastRect.width : parent.lastRect.height
                guard span > 1 else { return }
                let sign: Double = parent.first === child ? 1 : -1
                parent.ratio = clampRatio(parent.ratio + sign * delta / span)
                return
            }
            child = parent
        }
    }

    /// Computes tile rects (no gaps applied) and caches each node's rect for
    /// later aspect/resize decisions.
    public func frames(in container: CGRect) -> [WindowID: CGRect] {
        var out: [WindowID: CGRect] = [:]
        if let root {
            walk(root, container, into: &out)
        }
        return out
    }

    /// Rebuilds the tree from an ordered window list (used when switching the
    /// active layout back to dwindle). Recomputes frames between inserts so
    /// aspect-based split orientation behaves as if windows arrived one by one.
    public func rebuild(from order: [WindowID], container: CGRect, settings: DwindleSettings) {
        root = nil
        leaves.removeAll()
        for w in order {
            insert(w, near: nil, container: container, settings: settings)
            _ = frames(in: container)
        }
    }

    private func walk(_ node: DwindleNode, _ rect: CGRect, into out: inout [WindowID: CGRect]) {
        node.lastRect = rect
        if let w = node.window {
            out[w] = rect
            return
        }
        guard let f = node.first, let s = node.second else { return }
        let r = clampRatio(node.ratio)
        if node.orientation == .horizontal {
            let w1 = rect.width * r
            walk(f, CGRect(x: rect.minX, y: rect.minY, width: w1, height: rect.height), into: &out)
            walk(s, CGRect(x: rect.minX + w1, y: rect.minY, width: rect.width - w1, height: rect.height), into: &out)
        } else {
            let h1 = rect.height * r
            walk(f, CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h1), into: &out)
            walk(s, CGRect(x: rect.minX, y: rect.minY + h1, width: rect.width, height: rect.height - h1), into: &out)
        }
    }

    private func attach(_ node: DwindleNode, to parent: DwindleNode?, replacing old: DwindleNode) {
        node.parent = parent
        guard let parent else {
            root = node
            return
        }
        if parent.first === old {
            parent.first = node
        } else {
            parent.second = node
        }
    }

    private func lastLeaf(of node: DwindleNode) -> DwindleNode {
        var n = node
        while !n.isLeaf {
            n = n.second ?? n.first!
        }
        return n
    }

    private func clampRatio(_ r: Double) -> Double {
        min(max(r, 0.1), 0.9)
    }
}
