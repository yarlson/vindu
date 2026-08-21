import Foundation
import VinduCore
import VinduDaemonSupport

final class DesktopBarRefreshCoordinator {
    var onChange: (() -> Void)? {
        didSet {
            systemObserver.onChange = onChange
            weather.onChange = onChange
            plugins.onChange = onChange
        }
    }

    private let systemObserver = DesktopBarSystemObserver()
    private let weather = DesktopBarWeatherService(log: log)
    private let plugins = DesktopBarPluginService(log: log)
    private var clockTimer: Timer?

    var currentWeather: DesktopBarWeatherInfo? {
        weather.current
    }

    var currentPlugins: [String: BarPluginValue] {
        plugins.current
    }

    @discardableResult
    func sync(configuration: NativeBarConfiguration) -> Set<String> {
        guard configuration.enabled else {
            stop()
            return []
        }

        systemObserver.update(events: Self.systemEvents(for: configuration))

        if configuration.contains(.date) {
            startClockTimer()
        } else {
            stopClockTimer()
        }

        weather.sync(configuration: configuration.weather,
                     enabled: configuration.contains(.weather))
        return plugins.sync(configuration: configuration, enabled: true)
    }

    func refreshPlugin(id: String) -> Bool {
        plugins.refresh(id: id)
    }

    func handle(event: WMEvent, excludingPlugins: Set<String> = []) {
        plugins.handle(event: event, excluding: excludingPlugins)
    }

    func stop() {
        systemObserver.stop()
        weather.stop()
        plugins.stop()
        stopClockTimer()
    }

    func shutdown() {
        systemObserver.stop()
        weather.stop()
        plugins.shutdown()
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

    private static func systemEvents(for configuration: NativeBarConfiguration)
        -> DesktopBarSystemEvents {
        var events: DesktopBarSystemEvents = []
        if configuration.contains(.keyboard) { events.insert(.keyboard) }
        if configuration.contains(.battery) { events.insert(.power) }
        if configuration.contains(.network) { events.insert(.network) }
        if configuration.contains(.volume) { events.insert(.audio) }
        return events
    }
}
