import EspazioCore
import Foundation
import IOBluetooth

/// Bluetooth connect / disconnect notifications (opt-in; requires the Bluetooth permission).
@MainActor
public final class BluetoothMonitor: NSObject {
    public var onEvent: ((SystemEvent) -> Void)?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
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
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications.removeAll()
    }

    @objc private func deviceConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let address = device.addressString ?? UUID().uuidString
        disconnectNotifications[address]?.unregister()
        disconnectNotifications[address] = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        guard Date() >= quietUntil else { return }
        onEvent?(.bluetooth(deviceName: device.name ?? "Périphérique Bluetooth", connected: true))
    }

    @objc private func deviceDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString {
            disconnectNotifications[address]?.unregister()
            disconnectNotifications[address] = nil
        }
        onEvent?(.bluetooth(deviceName: device.name ?? "Périphérique Bluetooth", connected: false))
    }
}
