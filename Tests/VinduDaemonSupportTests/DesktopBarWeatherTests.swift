import Foundation
import Testing
import VinduCore
@testable import VinduDaemonSupport

@Suite(.serialized)
struct DesktopBarWeatherTests {
    @Test func successfulResponseUpdatesCurrentWeather() {
        WeatherURLProtocol.response = .success(status: 200, data: Data("""
        {"current":{"temperature_2m":22.4,"weather_code":0}}
        """.utf8))
        let service = DesktopBarWeatherService(session: makeSession())
        var changed = false
        service.onChange = { changed = true }

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { changed }
        #expect(service.current == DesktopBarWeatherInfo(temperatureC: 22.4, weatherCode: 0))
    }

    @Test func nonSuccessStatusLogsAndKeepsWeatherEmpty() {
        WeatherURLProtocol.response = .success(status: 500, data: Data())
        var logs: [String] = []
        let service = DesktopBarWeatherService(session: makeSession(),
                                               log: { logs.append($0) })

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { !logs.isEmpty }
        #expect(service.current == nil)
        #expect(logs == ["weather: http 500"])
    }

    @Test func oversizedResponseIsRejectedBeforeDecode() {
        WeatherURLProtocol.response = .success(
            status: 200,
            data: Data(repeating: UInt8(ascii: "x"),
                       count: DesktopBarWeatherService.maxResponseBytes + 1)
        )
        var logs: [String] = []
        let service = DesktopBarWeatherService(session: makeSession(),
                                               log: { logs.append($0) })

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { !logs.isEmpty }
        #expect(service.current == nil)
        #expect(logs == ["weather: response too large"])
    }

    @Test func stopPreventsLateWeatherUpdate() {
        WeatherURLProtocol.response = .delayedSuccess(
            status: 200,
            data: Data(#"{"current":{"temperature_2m":10,"weather_code":3}}"#.utf8),
            delay: 0.15
        )
        let service = DesktopBarWeatherService(session: makeSession())
        var changed = false
        service.onChange = { changed = true }

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)
        service.stop()

        waitForPhase3Condition(timeout: 0.4) { changed }
        #expect(!changed)
        #expect(service.current == nil)
    }

    @Test func requestErrorLogsWithoutUpdatingWeather() {
        WeatherURLProtocol.response = .failure(URLError(.timedOut))
        var logs: [String] = []
        let service = DesktopBarWeatherService(session: makeSession(),
                                               log: { logs.append($0) })

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { !logs.isEmpty }
        #expect(service.current == nil)
        #expect(logs == ["weather: request failed"])
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [WeatherURLProtocol.self]
        configuration.timeoutIntervalForRequest = 0.2
        configuration.timeoutIntervalForResource = 0.2
        return URLSession(configuration: configuration)
    }
}

private final class WeatherURLProtocol: URLProtocol {
    enum Response {
        case success(status: Int, data: Data)
        case delayedSuccess(status: Int, data: Data, delay: TimeInterval)
        case failure(Error)
    }

    static var response: Response = .success(status: 200, data: Data())
    private var workItem: DispatchWorkItem?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        switch Self.response {
        case .success(let status, let data):
            finish(status: status, data: data)
        case .delayedSuccess(let status, let data, let delay):
            let work = DispatchWorkItem { [weak self] in
                self?.finish(status: status, data: data)
            }
            workItem = work
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        workItem?.cancel()
        workItem = nil
    }

    private func finish(status: Int, data: Data) {
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: status,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
