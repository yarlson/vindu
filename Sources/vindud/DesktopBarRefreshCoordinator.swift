import Foundation
import VinduCore

final class DesktopBarRefreshCoordinator {
    var onChange: (() -> Void)? {
        didSet {
            systemObserver.onChange = onChange
            weather.onChange = onChange
        }
    }

    private let systemObserver = DesktopBarSystemObserver()
    private let weather = DesktopBarWeatherService()
    private var clockTimer: Timer?

    var currentWeather: DesktopBarWeatherInfo? {
        weather.current
    }

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

        weather.sync(location: settings.weatherLocation,
                     refreshMinutes: settings.weatherRefreshMinutes,
                     enabled: settings.indicators.contains(.weather))
    }

    func stop() {
        systemObserver.stop()
        weather.stop()
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
