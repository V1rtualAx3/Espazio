import AppKit
import EspazioCore

/// Caps Lock state from modifier-flag events.
///
/// - Initial state is read from `NSEvent.modifierFlags` (no permission needed).
/// - Changes come from global + local `flagsChanged` monitors. Global monitoring of keyboard
///   events may require the Accessibility permission; when no permission is granted the state is
///   still read whenever Espazio receives a local event, and the UI reports the limitation.
/// - Num Lock: Mac keyboards expose no Num Lock state; reported as unavailable (never invented).
@MainActor
public final class KeyboardMonitor {
    public var onEvent: ((SystemEvent) -> Void)?
    public private(set) var capsLockOn: Bool
    private var globalMonitor: Any?
    private var localMonitor: Any?

    public init() {
        capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
    }

    public var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    public func start() {
        guard globalMonitor == nil else { return }
        capsLockOn = NSEvent.modifierFlags.contains(.capsLock)
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.update(on) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            let on = event.modifierFlags.contains(.capsLock)
            MainActor.assumeIsolated { self?.update(on) }
            return event
        }
    }

    public func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    private func update(_ on: Bool) {
        guard on != capsLockOn else { return }
        capsLockOn = on
        onEvent?(.capsLock(isOn: on))
    }
}
