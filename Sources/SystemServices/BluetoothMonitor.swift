import EspazioCore
import Foundation
import IOBluetooth

/// Bluetooth connect / disconnect notifications (opt-in; requires the Bluetooth permission).
///
/// IOBluetooth may call back on a thread of its own: the callbacks are nonisolated and only hop
/// to the main actor with plain values. A main-actor `@objc` callback invoked off the main thread
/// is a fatal isolation error in Swift 6, which killed the app as soon as permission was granted.
@MainActor
public final class BluetoothMonitor: NSObject {
    public var onEvent: ((SystemEvent) -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private let registry = DisconnectRegistry()
    /// Connect notifications for already-connected devices arrive right after registration.
    private var quietUntil = Date.distantPast

    public override init() {
        super.init()
    }

    public func start() {
        guard connectNotification == nil else { return }
        quietUntil = Date().addingTimeInterval(2)
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    public func stop() {
        connectNotification?.unregister()
        connectNotification = nil
        registry.removeAll()
    }

    @objc nonisolated private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        let name = device.name ?? "Périphérique Bluetooth"
        registry.replace(address, with: device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))))
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self, Date() >= self.quietUntil else { return }
                self.onEvent?(.bluetooth(deviceName: name, connected: true))
            }
        }
    }

    @objc nonisolated private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString { registry.replace(address, with: nil) }
        let name = device.name ?? "Périphérique Bluetooth"
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.onEvent?(.bluetooth(deviceName: name, connected: false))
            }
        }
    }
}

/// Per-device disconnect registrations, touched from IOBluetooth's callback thread and from the
/// main actor.
private final class DisconnectRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var notifications: [String: IOBluetoothUserNotification] = [:]

    func replace(_ address: String, with notification: IOBluetoothUserNotification?) {
        lock.lock()
        let previous = notifications[address]
        notifications[address] = notification
        lock.unlock()
        previous?.unregister()
    }

    func removeAll() {
        lock.lock()
        let all = notifications.values
        notifications.removeAll()
        lock.unlock()
        all.forEach { $0.unregister() }
    }
}
