import EspazioCore
import Foundation
import IOKit.ps

/// Battery / power adapter changes via `IOPSNotificationCreateRunLoopSource` (event-driven).
@MainActor
public final class PowerMonitor {
    public var onEvent: ((SystemEvent) -> Void)?
    public private(set) var status: PowerStatus?
    private var source: CFRunLoopSource?

    public init() {}

    public func start() {
        guard source == nil else { return }
        status = Self.readStatus()
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.update() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .defaultMode)
        source = created
    }

    public func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .defaultMode)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }

    private func update() {
        guard let current = Self.readStatus() else { return }
        let previous = status
        status = current
        guard previous != current else { return }
        onEvent?(.power(current, previous: previous))
    }

    static func readStatus() -> PowerStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return nil }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let onAC = providing == "AC Power"
        guard let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return PowerStatus(level: 1, isCharging: false, isOnExternalPower: onAC, hasBattery: false)
        }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                (description["Type"] as? String) == "InternalBattery"
            else { continue }
            let current = description["Current Capacity"] as? Double ?? Double(description["Current Capacity"] as? Int ?? 0)
            let maximum = description["Max Capacity"] as? Double ?? Double(description["Max Capacity"] as? Int ?? 100)
            let charging = description["Is Charging"] as? Bool ?? false
            let level = maximum > 0 ? min(max(current / maximum, 0), 1) : 0
            // Report the level with 1 % granularity so equality checks suppress noise.
            return PowerStatus(level: (level * 100).rounded() / 100, isCharging: charging, isOnExternalPower: onAC, hasBattery: true)
        }
        return PowerStatus(level: 1, isCharging: false, isOnExternalPower: onAC, hasBattery: false)
    }
}
