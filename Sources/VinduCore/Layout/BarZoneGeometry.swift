public enum BarZoneGeometry {
    public static func centerIsVisible(barWidth: Double,
                                       horizontalPadding: Double,
                                       minimumGap: Double,
                                       leftWidth: Double,
                                       centerWidth: Double,
                                       rightWidth: Double,
                                       position: BarPosition,
                                       topObstruction: Range<Double>?) -> Bool {
        let values = [barWidth, horizontalPadding, minimumGap,
                      leftWidth, centerWidth, rightWidth]
        guard values.allSatisfy(\.isFinite),
              barWidth > 0,
              horizontalPadding >= 0,
              minimumGap >= 0,
              leftWidth >= 0,
              centerWidth > 0,
              rightWidth >= 0 else {
            return false
        }

        let centerStart = (barWidth - centerWidth) / 2
        let centerEnd = centerStart + centerWidth
        let leftEnd = horizontalPadding + leftWidth
        let rightStart = barWidth - horizontalPadding - rightWidth
        guard leftEnd + minimumGap <= centerStart,
              centerEnd + minimumGap <= rightStart else {
            return false
        }

        guard position == .top, let topObstruction else { return true }
        return centerEnd <= topObstruction.lowerBound || centerStart >= topObstruction.upperBound
    }
}
