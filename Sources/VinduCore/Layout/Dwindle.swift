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

/// Dwindle layout: each new window splits the focused leaf, with the
/// split orientation following the leaf's aspect ratio.
public final class DwindleTree {
    public private(set) var root: DwindleNode?
    private var leaves: [WindowID: DwindleNode] = [:]

    public init() {}

    deinit {
        clear()
    }

    public var isEmpty: Bool { root == nil }
    public var count: Int { leaves.count }
    public func contains(_ w: WindowID) -> Bool { leaves[w] != nil }

    /// Leaf windows in in-order traversal (visual reading order).
    public var windowsInOrder: [WindowID] {
        var out: [WindowID] = []
        var stack = root.map { [$0] } ?? []
        while let node = stack.popLast() {
            if let window = node.window {
                out.append(window)
                continue
            }
            if let second = node.second { stack.append(second) }
            if let first = node.first { stack.append(first) }
        }
        return out
    }

    public func insert(_ w: WindowID, near focused: WindowID?, container: CGRect,
                       configuration: DwindleConfiguration) {
        let newWindowFirst = configuration.newWindowPosition == .before
        let firstFraction = newWindowFirst
            ? configuration.newWindowFraction
            : 1.0 - configuration.newWindowFraction
        insert(w, near: focused, container: container,
               firstFraction: firstFraction, newWindowFirst: newWindowFirst)
    }

    private func insert(_ w: WindowID, near focused: WindowID?, container: CGRect,
                        firstFraction: Double, newWindowFirst: Bool) {
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
        let ratio = clampRatio(firstFraction)
        let firstChild = newWindowFirst ? leaf : target
        let secondChild = newWindowFirst ? target : leaf

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

    public func setSplitOrientation(_ orientation: Orientation, at w: WindowID) {
        leaves[w]?.parent?.orientation = orientation
    }

    /// Swaps the two children of the split above the window (dispatcher `swapsplit`).
    public func swapSplit(at w: WindowID) {
        guard let parent = leaves[w]?.parent else { return }
        let f = parent.first
        parent.first = parent.second
        parent.second = f
    }

    /// The public `splitratio` command uses a 0.1...1.9 scale where 1.0 is an
    /// even split; internal ratios are that value halved.
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
        var stack = root.map { [($0, container)] } ?? []
        while let (node, rect) = stack.popLast() {
            node.lastRect = rect
            if let window = node.window {
                out[window] = rect
                continue
            }
            guard let first = node.first, let second = node.second else { continue }
            let ratio = clampRatio(node.ratio)
            if node.orientation == .horizontal {
                let firstWidth = rect.width * ratio
                stack.append((second, CGRect(x: rect.minX + firstWidth, y: rect.minY,
                                             width: rect.width - firstWidth, height: rect.height)))
                stack.append((first, CGRect(x: rect.minX, y: rect.minY,
                                            width: firstWidth, height: rect.height)))
            } else {
                let firstHeight = rect.height * ratio
                stack.append((second, CGRect(x: rect.minX, y: rect.minY + firstHeight,
                                             width: rect.width, height: rect.height - firstHeight)))
                stack.append((first, CGRect(x: rect.minX, y: rect.minY,
                                            width: rect.width, height: firstHeight)))
            }
        }
        return out
    }

    private func clear() {
        guard let root else {
            leaves.removeAll()
            return
        }
        self.root = nil
        var stack = [root]
        while let node = stack.popLast() {
            if let first = node.first { stack.append(first) }
            if let second = node.second { stack.append(second) }
            node.first = nil
            node.second = nil
            node.parent = nil
        }
        leaves.removeAll()
    }

    /// Rebuilds the tree from an ordered window list (used when switching the
    /// active layout back to dwindle). Recomputes frames between inserts so
    /// aspect-based split orientation behaves as if windows arrived one by one.
    public func rebuild(from order: [WindowID], container: CGRect,
                        configuration: DwindleConfiguration) {
        clear()
        for w in order {
            insert(w, near: nil, container: container, configuration: configuration)
            _ = frames(in: container)
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
