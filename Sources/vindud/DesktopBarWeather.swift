import Foundation
import VinduCore

struct DesktopBarWeatherInfo: Equatable {
    let temperatureC: Double
    let weatherCode: Int

    var text: String {
        "\(Int(temperatureC.rounded()))°C"
    }

    var symbolNames: [String] {
        switch weatherCode {
        case 0:
            return ["sun.max.fill", "sun.max"]
        case 1, 2:
            return ["cloud.sun.fill", "cloud.sun"]
        case 3:
            return ["cloud.fill", "cloud"]
        case 45, 48:
            return ["cloud.fog.fill", "cloud.fog"]
        case 51...57:
            return ["cloud.drizzle.fill", "cloud.drizzle"]
        case 61...67, 80...82:
            return ["cloud.rain.fill", "cloud.rain"]
        case 71...77, 85...86:
            return ["cloud.snow.fill", "snowflake"]
        case 95...99:
            return ["cloud.bolt.rain.fill", "cloud.bolt"]
        default:
            return ["cloud.sun.fill", "cloud.sun"]
        }
    }
}

final class DesktopBarWeatherService {
    var onChange: (() -> Void)?
    private(set) var current: DesktopBarWeatherInfo?

    private struct Configuration: Equatable {
        var location: WeatherLocation
        var refreshMinutes: Int
    }

    private var configuration: Configuration?
    private var refreshTimer: Timer?
    private var request: URLSessionDataTask?
    private var fetching = false

    func sync(location: WeatherLocation?, refreshMinutes: Int, enabled: Bool) {
        guard enabled, let location else {
            stop()
            return
        }

        let next = Configuration(location: location, refreshMinutes: refreshMinutes)
        guard next != configuration else { return }
        stop()
        configuration = next
        fetchNow()
        scheduleNextRefresh()
    }

    func stop() {
        request?.cancel()
        request = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        configuration = nil
        fetching = false
        current = nil
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        guard let configuration else { return }
        let interval = TimeInterval(configuration.refreshMinutes * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchNow()
            self?.scheduleNextRefresh()
        }
    }

    private func fetchNow() {
        guard !fetching,
              let configuration,
              let url = Self.url(for: configuration.location) else {
            return
        }

        fetching = true
        request = URLSession.shared.dataTask(with: url) { [weak self] data, _, _ in
            DispatchQueue.main.async {
                guard let self, self.configuration == configuration else { return }
                self.fetching = false
                self.request = nil
                guard let data,
                      let weather = Self.decode(data) else {
                    return
                }
                if self.current != weather {
                    self.current = weather
                    self.onChange?()
                }
            }
        }
        request?.resume()
    }

    private static func url(for location: WeatherLocation) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(location.latitude)),
            URLQueryItem(name: "longitude", value: String(location.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components?.url
    }

    private static func decode(_ data: Data) -> DesktopBarWeatherInfo? {
        guard let response = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data),
              let current = response.current else {
            return nil
        }
        return DesktopBarWeatherInfo(temperatureC: current.temperature,
                                     weatherCode: current.weatherCode)
    }

    private struct OpenMeteoResponse: Decodable {
        let current: Current?

        struct Current: Decodable {
            let temperature: Double
            let weatherCode: Int

            enum CodingKeys: String, CodingKey {
                case temperature = "temperature_2m"
                case weatherCode = "weather_code"
            }
        }
    }
}
