import Foundation
import VinduCore

final class DesktopBarRefreshCoordinator {
    var onChange: (() -> Void)? {
        didSet { systemObserver.onChange = onChange }
    }

    private let systemObserver = DesktopBarSystemObserver()
    private var clockTimer: Timer?

    func sync(settings: BarSettings) {
        guard settings.enabled, settings.showIndicators else {
            stop()
            return
        }

        systemObserver.update(events: Self.systemEvents(for: settings.indicators))

        if settings.indicators.contains(.date) {
            startClockTimer()
        } else {
            stopClockTimer()
        }
    }

    func stop() {
        systemObserver.stop()
        stopClockTimer()
    }

    private func startClockTimer() {
        stopClockTimer()
        scheduleNextClockTick()
    }

    private func scheduleNextClockTick() {
        let seconds = Calendar.current.component(.second, from: Date())
        let interval = TimeInterval(max(1, 60 - seconds))
        clockTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.onChange?()
            self?.scheduleNextClockTick()
        }
    }

    private func stopClockTimer() {
        clockTimer?.invalidate()
        clockTimer = nil
    }

    private static func systemEvents(for indicators: [BarIndicator]) -> DesktopBarSystemEvents {
        var events: DesktopBarSystemEvents = []
        if indicators.contains(.keyboard) { events.insert(.keyboard) }
        if indicators.contains(.battery) { events.insert(.power) }
        if indicators.contains(.network) { events.insert(.network) }
        if indicators.contains(.volume) { events.insert(.audio) }
        return events
    }
}
