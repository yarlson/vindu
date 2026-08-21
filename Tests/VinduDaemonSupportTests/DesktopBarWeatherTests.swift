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

    @Test func responseAtByteLimitIsDecoded() {
        var data = Data(#"{"current":{"temperature_2m":18.5,"weather_code":2}}"#.utf8)
        data.append(Data(repeating: UInt8(ascii: " "),
                         count: DesktopBarWeatherService.maxResponseBytes - data.count))
        WeatherURLProtocol.response = .success(status: 200, data: data)
        let service = DesktopBarWeatherService(session: makeSession())

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { service.current != nil }
        #expect(service.current == DesktopBarWeatherInfo(temperatureC: 18.5, weatherCode: 2))
    }

    @Test func streamingResponseStopsAfterCrossingByteLimit() {
        WeatherURLProtocol.response = .chunked(
            status: 200,
            chunks: [
                (0.01, Data(repeating: UInt8(ascii: "x"),
                            count: DesktopBarWeatherService.maxResponseBytes)),
                (0.05, Data([UInt8(ascii: "x")])),
                (0.5, Data(#"{"current":{"temperature_2m":30,"weather_code":0}}"#.utf8)),
            ]
        )
        var logs: [String] = []
        let service = DesktopBarWeatherService(session: makeSession(),
                                               log: { logs.append($0) })

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { !logs.isEmpty }
        waitForPhase3Condition { WeatherURLProtocol.wasStopped }
        #expect(logs == ["weather: response too large"])
        #expect(WeatherURLProtocol.deliveredChunks == 2)
        #expect(service.current == nil)
    }

    @Test func hugeFiniteTemperatureIsRejected() {
        WeatherURLProtocol.response = .success(
            status: 200,
            data: Data(#"{"current":{"temperature_2m":1e308,"weather_code":0}}"#.utf8)
        )
        var logs: [String] = []
        let service = DesktopBarWeatherService(session: makeSession(),
                                               log: { logs.append($0) })

        service.sync(location: WeatherLocation(latitude: 56.9496, longitude: 24.1052),
                     refreshMinutes: 5,
                     enabled: true)

        waitForPhase3Condition { !logs.isEmpty }
        #expect(logs == ["weather: invalid response"])
        #expect(service.current == nil)
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
        waitForPhase3Condition { WeatherURLProtocol.wasStopped }
        #expect(!changed)
        #expect(WeatherURLProtocol.wasStopped)
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
        WeatherURLProtocol.resetTracking()
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
        case chunked(status: Int, chunks: [(delay: TimeInterval, data: Data)])
        case failure(Error)
    }

    static var response: Response = .success(status: 200, data: Data())
    private static let trackingLock = NSLock()
    private static var stopped = false
    private static var chunkCount = 0
    private var workItems: [DispatchWorkItem] = []

    static var wasStopped: Bool {
        trackingLock.withLock { stopped }
    }

    static var deliveredChunks: Int {
        trackingLock.withLock { chunkCount }
    }

    static func resetTracking() {
        trackingLock.withLock {
            stopped = false
            chunkCount = 0
        }
    }

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
            workItems = [work]
            DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: work)
        case .chunked(let status, let chunks):
            sendResponse(status: status)
            for chunk in chunks {
                let reference = WeakDispatchWorkItem()
                let work = DispatchWorkItem { [weak self] in
                    guard reference.item?.isCancelled == false, let self else { return }
                    Self.trackingLock.withLock { Self.chunkCount += 1 }
                    self.client?.urlProtocol(self, didLoad: chunk.data)
                }
                reference.item = work
                workItems.append(work)
                DispatchQueue.global().asyncAfter(deadline: .now() + chunk.delay,
                                                  execute: work)
            }
            let finishReference = WeakDispatchWorkItem()
            let finishWork = DispatchWorkItem { [weak self] in
                guard finishReference.item?.isCancelled == false, let self else { return }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            finishReference.item = finishWork
            workItems.append(finishWork)
            let finishDelay = (chunks.map(\.delay).max() ?? 0) + 0.05
            DispatchQueue.global().asyncAfter(deadline: .now() + finishDelay,
                                              execute: finishWork)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        workItems.forEach { $0.cancel() }
        workItems.removeAll()
        Self.trackingLock.withLock { Self.stopped = true }
    }

    private func finish(status: Int, data: Data) {
        sendResponse(status: status)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private func sendResponse(status: Int) {
        let response = HTTPURLResponse(url: request.url!,
                                       statusCode: status,
                                       httpVersion: nil,
                                       headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    }
}

private final class WeakDispatchWorkItem {
    weak var item: DispatchWorkItem?
}
