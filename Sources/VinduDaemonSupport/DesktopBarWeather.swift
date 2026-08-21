import Foundation
import VinduCore

public struct DesktopBarWeatherInfo: Equatable {
    public let temperatureC: Double
    public let weatherCode: Int

    public init(temperatureC: Double, weatherCode: Int) {
        self.temperatureC = temperatureC
        self.weatherCode = weatherCode
    }

    public var text: String {
        guard let temperature = Int(exactly: temperatureC.rounded()) else {
            return "—"
        }
        return "\(temperature)°C"
    }

    public var symbolNames: [String] {
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

public final class DesktopBarWeatherService {
    public typealias Logger = (String) -> Void

    public static let maxResponseBytes = 64 * 1024

    public var onChange: (() -> Void)?
    public private(set) var current: DesktopBarWeatherInfo?

    private struct Configuration: Equatable {
        var weather: NativeBarWeather
    }

    private enum FetchResult {
        case success(DesktopBarWeatherInfo)
        case failure(String)
    }

    private enum StreamResult {
        case completed(data: Data?, response: URLResponse?, error: Error?)
        case failure(String)
    }

    private let session: URLSession
    private let decodeQueue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let log: Logger
    private var configuration: Configuration?
    private var refreshTimer: Timer?
    private var request: Task<Void, Never>?
    private var fetching = false
    private var generation = 0

    public init(session: URLSession = DesktopBarWeatherService.defaultSession(),
                decodeQueue: DispatchQueue = DispatchQueue(label: "vindu.weather.decode",
                                                           qos: .utility),
                callbackQueue: DispatchQueue = .main,
                log: @escaping Logger = { _ in }) {
        self.session = session
        self.decodeQueue = decodeQueue
        self.callbackQueue = callbackQueue
        self.log = log
    }

    public func sync(configuration weather: NativeBarWeather?, enabled: Bool) {
        guard enabled, let weather else {
            stop()
            return
        }

        let next = Configuration(weather: weather)
        guard next != configuration else { return }
        stop()
        configuration = next
        fetchNow()
        scheduleNextRefresh()
    }

    public func stop() {
        let hadWeather = current != nil
        generation &+= 1
        request?.cancel()
        request = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        configuration = nil
        fetching = false
        current = nil
        if hadWeather {
            onChange?()
        }
    }

    private func scheduleNextRefresh() {
        refreshTimer?.invalidate()
        guard let configuration else { return }
        let interval = TimeInterval(configuration.weather.refreshMinutes * 60)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.fetchNow()
            self?.scheduleNextRefresh()
        }
    }

    private func fetchNow() {
        guard !fetching,
              let configuration,
              let url = Self.url(for: configuration.weather) else {
            return
        }

        fetching = true
        let generation = generation
        let session = session
        let request = Task { [weak self] in
            let streamResult = await Self.collect(session: session, url: url)
            self?.finish(streamResult,
                         configuration: configuration,
                         generation: generation)
        }
        self.request = request
    }

    private func finish(_ streamResult: StreamResult,
                        configuration: Configuration,
                        generation: Int) {
        decodeQueue.async {
            let result: FetchResult
            switch streamResult {
            case .completed(let data, let response, let error):
                result = Self.result(data: data, response: response, error: error)
            case .failure(let message):
                result = .failure(message)
            }
            self.callbackQueue.async {
                guard self.generation == generation,
                      self.configuration == configuration else {
                    return
                }
                self.fetching = false
                self.request = nil
                switch result {
                case .success(let weather):
                    if self.current != weather {
                        self.current = weather
                        self.onChange?()
                    }
                case .failure(let message):
                    self.log("weather: \(message)")
                }
            }
        }
    }

    public static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }

    private static func url(for weather: NativeBarWeather) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(weather.latitude)),
            URLQueryItem(name: "longitude", value: String(weather.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        return components?.url
    }

    private static func result(data: Data?,
                               response: URLResponse?,
                               error: Error?) -> FetchResult {
        if let error = error as NSError?, error.domain == NSURLErrorDomain,
           error.code == NSURLErrorCancelled {
            return .failure("request cancelled")
        }
        if error != nil {
            return .failure("request failed")
        }
        guard let http = response as? HTTPURLResponse else {
            return .failure("missing http response")
        }
        guard http.statusCode == 200 else {
            return .failure("http \(http.statusCode)")
        }
        guard let data else {
            return .failure("empty response")
        }
        guard data.count <= maxResponseBytes else {
            return .failure("response too large")
        }
        guard let weather = decode(data) else {
            return .failure("invalid response")
        }
        return .success(weather)
    }

    private static func collect(session: URLSession, url: URL) async -> StreamResult {
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard let http = response as? HTTPURLResponse else {
                bytes.task.cancel()
                return .failure("missing http response")
            }
            guard http.statusCode == 200 else {
                bytes.task.cancel()
                return .failure("http \(http.statusCode)")
            }

            var data = Data()
            for try await byte in bytes {
                guard data.count < maxResponseBytes else {
                    bytes.task.cancel()
                    return .failure("response too large")
                }
                data.append(byte)
            }
            return .completed(data: data, response: response, error: nil)
        } catch {
            return .completed(data: nil, response: nil, error: error)
        }
    }

    private static func decode(_ data: Data) -> DesktopBarWeatherInfo? {
        guard let response = try? JSONDecoder().decode(OpenMeteoResponse.self, from: data),
              let current = response.current,
              current.temperature.isFinite,
              Int(exactly: current.temperature.rounded()) != nil else {
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
