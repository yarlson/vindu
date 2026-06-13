import Carbon
import CoreAudio
import CoreWLAN
import Foundation
import IOKit.ps
import Network

private func desktopBarPowerSourceChanged(_ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    Unmanaged<DesktopBarSystemObserver>
        .fromOpaque(context)
        .takeUnretainedValue()
        .systemEventChanged(.power)
}

struct DesktopBarSystemEvents: OptionSet, Equatable {
    let rawValue: Int

    static let keyboard = DesktopBarSystemEvents(rawValue: 1 << 0)
    static let power = DesktopBarSystemEvents(rawValue: 1 << 1)
    static let network = DesktopBarSystemEvents(rawValue: 1 << 2)
    static let audio = DesktopBarSystemEvents(rawValue: 1 << 3)
}

final class DesktopBarSystemObserver: NSObject, CWEventDelegate {
    var onChange: (() -> Void)?

    private var started = false
    private var activeEvents: DesktopBarSystemEvents = []
    private var refreshQueued = false
    private var powerSource: CFRunLoopSource?
    private var networkMonitor: NWPathMonitor?
    private let networkQueue = DispatchQueue(label: "com.vindu.desktopbar.network")
    private let wifiClient = CWWiFiClient.shared()
    private let wifiEventTypes: [CWEventType] = [.powerDidChange, .ssidDidChange, .linkDidChange]

    private var defaultOutputAddress = DesktopBarAudioState.defaultOutputDeviceAddress()
    private lazy var defaultOutputListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, self.started else { return }
        self.refreshOutputDeviceListeners()
        self.systemEventChanged(.audio)
    }
    private lazy var outputValueListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        guard let self, self.started else { return }
        self.systemEventChanged(.audio)
    }
    private var outputDeviceListeners: [(device: AudioDeviceID, address: AudioObjectPropertyAddress)] = []

    func update(events: DesktopBarSystemEvents) {
        guard events != activeEvents else { return }
        stop()

        activeEvents = events
        guard !events.isEmpty else { return }
        started = true

        if events.contains(.keyboard) { startKeyboardObserver() }
        if events.contains(.power) { startPowerObserver() }
        if events.contains(.network) { startNetworkObserver() }
        if events.contains(.audio) { startAudioObserver() }
    }

    func stop() {
        guard started || !activeEvents.isEmpty else { return }
        started = false

        DistributedNotificationCenter.default().removeObserver(self)
        stopPowerObserver()
        stopNetworkObserver()
        stopAudioObserver()
        activeEvents = []
        refreshQueued = false
    }

    func systemEventChanged(_ event: DesktopBarSystemEvents) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.started,
                  self.activeEvents.contains(event),
                  !self.refreshQueued else { return }
            self.refreshQueued = true
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started else { return }
                self.refreshQueued = false
                self.onChange?()
            }
        }
    }

    private func startKeyboardObserver() {
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleSystemNotification(_:)),
            name: name,
            object: nil
        )
    }

    private func startPowerObserver() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource(
            desktopBarPowerSourceChanged,
            context
        )?.takeRetainedValue() else {
            return
        }
        powerSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func stopPowerObserver() {
        guard let powerSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode)
        self.powerSource = nil
    }

    private func startNetworkObserver() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            self?.systemEventChanged(.network)
        }
        monitor.start(queue: networkQueue)
        networkMonitor = monitor

        wifiClient.delegate = self
        for eventType in wifiEventTypes {
            try? wifiClient.startMonitoringEvent(with: eventType)
        }
    }

    private func stopNetworkObserver() {
        networkMonitor?.cancel()
        networkMonitor = nil
        for eventType in wifiEventTypes {
            try? wifiClient.stopMonitoringEvent(with: eventType)
        }
        if wifiClient.delegate === self {
            wifiClient.delegate = nil
        }
    }

    private func startAudioObserver() {
        _ = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            defaultOutputListener
        )
        refreshOutputDeviceListeners()
    }

    private func stopAudioObserver() {
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &defaultOutputAddress,
            DispatchQueue.main,
            defaultOutputListener
        )
        removeOutputDeviceListeners()
    }

    private func refreshOutputDeviceListeners() {
        removeOutputDeviceListeners()

        guard let device = DesktopBarAudioState.currentOutputDevice() else { return }
        for address in DesktopBarAudioState.outputValueAddresses(for: device) {
            var mutable = address
            let status = AudioObjectAddPropertyListenerBlock(
                device,
                &mutable,
                DispatchQueue.main,
                outputValueListener
            )
            if status == noErr {
                outputDeviceListeners.append((device, address))
            }
        }
    }

    private func removeOutputDeviceListeners() {
        for listener in outputDeviceListeners {
            var address = listener.address
            AudioObjectRemovePropertyListenerBlock(
                listener.device,
                &address,
                DispatchQueue.main,
                outputValueListener
            )
        }
        outputDeviceListeners.removeAll()
    }

    @objc private func handleSystemNotification(_ notification: Notification) {
        systemEventChanged(.keyboard)
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        systemEventChanged(.network)
    }

    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        systemEventChanged(.network)
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        systemEventChanged(.network)
    }
}
