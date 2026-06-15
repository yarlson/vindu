import Foundation
import VinduCore

final class DesktopBarRefreshCoordinator {
    var onChange: (() -> Void)? {
        didSet {
            systemObserver.onChange = onChange
            weather.onChange = onChange
            plugins.onChange = onChange
        }
    }

    private let systemObserver = DesktopBarSystemObserver()
    private let weather = DesktopBarWeatherService()
    private let plugins = DesktopBarPluginService()
    private var clockTimer: Timer?

    var currentWeather: DesktopBarWeatherInfo? {
        weather.current
    }

    var currentPlugins: [String: BarPluginValue] {
        plugins.current
    }

    func sync(settings: BarSettings) {
        guard settings.enabled, settings.showIndicators else {
            stop()
            return
        }

        systemObserver.update(events: Self.systemEvents(for: settings))

        if settings.contains(.date) {
            startClockTimer()
        } else {
            stopClockTimer()
        }

        weather.sync(location: settings.weatherLocation,
                     refreshMinutes: settings.weatherRefreshMinutes,
                     enabled: settings.contains(.weather))
        plugins.sync(settings: settings, enabled: true)
    }

    func refreshPlugin(id: String) -> Bool {
        plugins.refresh(id: id)
    }

    func handle(event: WMEvent) {
        plugins.handle(event: event)
    }

    func stop() {
        systemObserver.stop()
        weather.stop()
        plugins.stop()
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

    private static func systemEvents(for settings: BarSettings) -> DesktopBarSystemEvents {
        var events: DesktopBarSystemEvents = []
        if settings.contains(.keyboard) { events.insert(.keyboard) }
        if settings.contains(.battery) { events.insert(.power) }
        if settings.contains(.network) { events.insert(.network) }
        if settings.contains(.volume) { events.insert(.audio) }
        return events
    }
}
