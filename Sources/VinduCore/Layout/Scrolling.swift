import CoreGraphics

public final class ScrollingLayout {
    public struct Column: Equatable {
        public fileprivate(set) var windows: [WindowID]
        public fileprivate(set) var widthFraction: Double
        fileprivate var widthBeforeFull: Double?
        fileprivate var lastFocused: WindowID?
        fileprivate var heightFractions: [Double]
    }

    public private(set) var columns: [Column] = []
    public private(set) var viewportOffset = 0.0

    public init() {}

    public var windowsInOrder: [WindowID] {
        columns.flatMap(\.windows)
    }

    public func contains(_ window: WindowID) -> Bool {
        columnIndex(containing: window) != nil
    }

    public func insert(_ window: WindowID, after anchor: WindowID?, defaultColumnWidth: Double) {
        guard !contains(window) else { return }
        let column = Column(windows: [window], widthFraction: validWidth(defaultColumnWidth),
                            widthBeforeFull: nil, lastFocused: window, heightFractions: [1])
        guard let anchor, let index = columnIndex(containing: anchor) else {
            columns.append(column)
            return
        }
        columns.insert(column, at: index + 1)
    }

    public func remove(_ window: WindowID) {
        guard let column = columnIndex(containing: window),
              let row = columns[column].windows.firstIndex(of: window) else { return }
        columns[column].windows.remove(at: row)
        columns[column].heightFractions.remove(at: row)
        if columns[column].lastFocused == window {
            columns[column].lastFocused = columns[column].windows.first
        }
        if columns[column].windows.isEmpty {
            columns.remove(at: column)
        } else {
            normalizeHeights(in: column)
        }
        if columns.isEmpty {
            viewportOffset = 0
        }
    }

    public func rebuildSingletons(from windows: [WindowID], defaultColumnWidth: Double) {
        let width = validWidth(defaultColumnWidth)
        columns = windows.map {
            Column(windows: [$0], widthFraction: width, widthBeforeFull: nil,
                   lastFocused: $0, heightFractions: [1])
        }
        viewportOffset = 0
    }

    @discardableResult
    public func consumeNextColumn(into focused: WindowID) -> WindowID? {
        guard let column = columnIndex(containing: focused),
              let focusedRow = columns[column].windows.firstIndex(of: focused),
              column + 1 < columns.count else { return nil }
        let source = column + 1
        let consumed = columns[source].lastFocused ?? columns[source].windows[0]
        guard let row = columns[source].windows.firstIndex(of: consumed) else { return nil }
        columns[source].windows.remove(at: row)
        columns[source].heightFractions.remove(at: row)
        columns[column].windows.insert(consumed, at: focusedRow + 1)
        columns[column].heightFractions.insert(1, at: focusedRow + 1)
        normalizeHeights(in: column)
        if columns[source].windows.isEmpty {
            columns.remove(at: source)
        } else {
            columns[source].lastFocused = columns[source].windows.first
            normalizeHeights(in: source)
        }
        return consumed
    }

    @discardableResult
    public func expel(_ window: WindowID) -> Bool {
        guard let column = columnIndex(containing: window),
              columns[column].windows.count > 1,
              let row = columns[column].windows.firstIndex(of: window) else { return false }
        columns[column].windows.remove(at: row)
        columns[column].heightFractions.remove(at: row)
        if columns[column].lastFocused == window {
            columns[column].lastFocused = columns[column].windows.first
        }
        let expelled = Column(windows: [window], widthFraction: columns[column].widthFraction,
                              widthBeforeFull: columns[column].widthBeforeFull, lastFocused: window,
                              heightFractions: [1])
        normalizeHeights(in: column)
        columns.insert(expelled, at: column + 1)
        return true
    }

    public func noteFocus(_ window: WindowID) {
        guard let column = columnIndex(containing: window) else { return }
        columns[column].lastFocused = window
    }

    public func focusTarget(from window: WindowID, direction: Direction) -> WindowID? {
        guard let column = columnIndex(containing: window),
              let row = columns[column].windows.firstIndex(of: window) else { return nil }
        switch direction {
        case .left:
            guard column > 0 else { return nil }
            return columns[column - 1].lastFocused ?? columns[column - 1].windows.first
        case .right:
            guard column + 1 < columns.count else { return nil }
            return columns[column + 1].lastFocused ?? columns[column + 1].windows.first
        case .up:
            return row > 0 ? columns[column].windows[row - 1] : nil
        case .down:
            return row + 1 < columns[column].windows.count ? columns[column].windows[row + 1] : nil
        }
    }

    @discardableResult
    public func move(_ window: WindowID, direction: Direction) -> Bool {
        guard let column = columnIndex(containing: window),
              let row = columns[column].windows.firstIndex(of: window) else { return false }
        switch direction {
        case .left:
            guard column > 0 else { return false }
            columns.swapAt(column, column - 1)
        case .right:
            guard column + 1 < columns.count else { return false }
            columns.swapAt(column, column + 1)
        case .up:
            guard row > 0 else { return false }
            columns[column].windows.swapAt(row, row - 1)
            columns[column].heightFractions.swapAt(row, row - 1)
        case .down:
            guard row + 1 < columns[column].windows.count else { return false }
            columns[column].windows.swapAt(row, row + 1)
            columns[column].heightFractions.swapAt(row, row + 1)
        }
        return true
    }

    @discardableResult
    public func swap(_ window: WindowID, direction: Direction) -> Bool {
        guard let column = columnIndex(containing: window),
              let row = columns[column].windows.firstIndex(of: window) else { return false }
        let destination: (column: Int, row: Int)
        switch direction {
        case .left:
            guard column > 0 else { return false }
            destination = (column - 1, rememberedRow(in: column - 1))
        case .right:
            guard column + 1 < columns.count else { return false }
            destination = (column + 1, rememberedRow(in: column + 1))
        case .up:
            guard row > 0 else { return false }
            destination = (column, row - 1)
        case .down:
            guard row + 1 < columns[column].windows.count else { return false }
            destination = (column, row + 1)
        }
        let other = columns[destination.column].windows[destination.row]
        columns[column].windows[row] = other
        columns[destination.column].windows[destination.row] = window
        columns[column].lastFocused = other
        columns[destination.column].lastFocused = window
        return true
    }

    public func swapWindows(_ first: WindowID, _ second: WindowID) {
        guard let firstColumn = columnIndex(containing: first),
              let firstRow = columns[firstColumn].windows.firstIndex(of: first),
              let secondColumn = columnIndex(containing: second),
              let secondRow = columns[secondColumn].windows.firstIndex(of: second) else { return }
        columns[firstColumn].windows[firstRow] = second
        columns[secondColumn].windows[secondRow] = first
        if columns[firstColumn].lastFocused == first { columns[firstColumn].lastFocused = second }
        if columns[secondColumn].lastFocused == second { columns[secondColumn].lastFocused = first }
    }

    @discardableResult
    public func cycleWidth(of window: WindowID, previous: Bool) -> Bool {
        guard let column = columnIndex(containing: window) else { return false }
        let presets = [1.0 / 3.0, 0.5, 2.0 / 3.0]
        let current = validWidth(columns[column].widthFraction)
        if previous {
            columns[column].widthFraction = presets.last { $0 < current - 0.0001 } ?? presets.last!
        } else {
            columns[column].widthFraction = presets.first { $0 > current + 0.0001 } ?? presets[0]
        }
        columns[column].widthBeforeFull = nil
        return true
    }

    @discardableResult
    public func toggleFullWidth(of window: WindowID) -> Bool {
        guard let column = columnIndex(containing: window) else { return false }
        if let previous = columns[column].widthBeforeFull {
            columns[column].widthFraction = previous
            columns[column].widthBeforeFull = nil
        } else {
            columns[column].widthBeforeFull = columns[column].widthFraction
            columns[column].widthFraction = 1
        }
        return true
    }

    @discardableResult
    public func resizeColumn(containing window: WindowID, by delta: Double) -> Bool {
        guard delta.isFinite, let column = columnIndex(containing: window) else { return false }
        columns[column].widthFraction = min(max(columns[column].widthFraction + delta, 0.1), 1)
        columns[column].widthBeforeFull = nil
        return true
    }

    @discardableResult
    public func resizeWindow(_ window: WindowID, by delta: Double) -> Bool {
        guard delta.isFinite, let column = columnIndex(containing: window),
              let row = columns[column].windows.firstIndex(of: window),
              columns[column].windows.count > 1 else { return false }
        let other = row + 1 < columns[column].windows.count ? row + 1 : row - 1
        let signedDelta = other > row ? delta : -delta
        let current = columns[column].heightFractions[row]
        let neighbor = columns[column].heightFractions[other]
        let applied = min(max(signedDelta, 0.1 - current), neighbor - 0.1)
        guard applied != 0 else { return false }
        columns[column].heightFractions[row] += applied
        columns[column].heightFractions[other] -= applied
        return true
    }

    public func frames(in container: CGRect) -> [WindowID: CGRect] {
        viewportOffset = clampedOffset(viewportOffset, in: container)
        var frames: [WindowID: CGRect] = [:]
        var x = container.minX - viewportOffset
        for column in columns {
            let width = container.width * validWidth(column.widthFraction)
            var y = container.minY
            for (row, window) in column.windows.enumerated() {
                let height = container.height * column.heightFractions[row]
                frames[window] = CGRect(x: x, y: y, width: width, height: height)
                y += height
            }
            x += width
        }
        return frames
    }

    @discardableResult
    public func scroll(by delta: Double, in container: CGRect) -> Double {
        let previous = viewportOffset
        viewportOffset = clampedOffset(previous + delta, in: container)
        return viewportOffset - previous
    }

    public func setViewportOffset(_ offset: Double, in container: CGRect) {
        guard offset.isFinite else { return }
        viewportOffset = clampedOffset(offset, in: container)
    }

    @discardableResult
    public func reveal(_ window: WindowID, in container: CGRect) -> Double {
        guard let range = horizontalRange(of: window, containerWidth: container.width) else { return 0 }
        let previous = viewportOffset
        if range.upperBound - range.lowerBound >= container.width {
            viewportOffset = range.lowerBound
        } else if range.lowerBound < viewportOffset {
            viewportOffset = range.lowerBound
        } else if range.upperBound > viewportOffset + container.width {
            viewportOffset = range.upperBound - container.width
        }
        viewportOffset = clampedOffset(viewportOffset, in: container)
        return viewportOffset - previous
    }

    @discardableResult
    public func center(_ window: WindowID, in container: CGRect) -> Double {
        guard let range = horizontalRange(of: window, containerWidth: container.width) else { return 0 }
        let previous = viewportOffset
        viewportOffset = (range.lowerBound + range.upperBound - container.width) / 2
        viewportOffset = clampedOffset(viewportOffset, in: container)
        return viewportOffset - previous
    }

    private func columnIndex(containing window: WindowID) -> Int? {
        columns.firstIndex { $0.windows.contains(window) }
    }

    private func rememberedRow(in column: Int) -> Int {
        guard let focused = columns[column].lastFocused,
              let row = columns[column].windows.firstIndex(of: focused) else { return 0 }
        return row
    }

    private func horizontalRange(of window: WindowID, containerWidth: Double) -> Range<Double>? {
        guard let column = columnIndex(containing: window) else { return nil }
        let start = columns[..<column].reduce(0) { $0 + containerWidth * validWidth($1.widthFraction) }
        return start..<(start + containerWidth * validWidth(columns[column].widthFraction))
    }

    private func clampedOffset(_ offset: Double, in container: CGRect) -> Double {
        let contentWidth = columns.reduce(0) { $0 + container.width * validWidth($1.widthFraction) }
        return min(max(offset, 0), max(0, contentWidth - container.width))
    }

    private func validWidth(_ width: Double) -> Double {
        width.isFinite && width > 0 && width <= 1 ? width : 0.5
    }

    private func normalizeHeights(in column: Int) {
        let total = columns[column].heightFractions.reduce(0, +)
        guard total > 0 else {
            columns[column].heightFractions = Array(
                repeating: 1 / Double(columns[column].windows.count),
                count: columns[column].windows.count
            )
            return
        }
        columns[column].heightFractions = columns[column].heightFractions.map { $0 / total }
    }
}
