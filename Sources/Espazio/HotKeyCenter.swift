import Carbon.HIToolbox
import EspazioCore
import Foundation

/// Global shortcuts through Carbon `RegisterEventHotKey` (public, no Accessibility permission).
@MainActor
final class HotKeyCenter {
    private var references: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x4553_505A  // "ESPZ"

    init() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr else { return status }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            let id = identifier.id
            MainActor.assumeIsolated { center.fire(id) }
            return noErr
        }, 1, &eventType, context, &eventHandler)
    }

    /// Registers (or re-registers) a shortcut. Returns false if the system refused it
    /// (already taken by another app).
    @discardableResult
    func register(id: UInt32, shortcut: KeyShortcut, handler: @escaping () -> Void) -> Bool {
        unregister(id: id)
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(
            shortcut.keyCode, shortcut.modifiers.rawValue, EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { return false }
        references[id] = reference
        handlers[id] = handler
        return true
    }

    func unregister(id: UInt32) {
        if let reference = references.removeValue(forKey: id) { UnregisterEventHotKey(reference) }
        handlers[id] = nil
    }

    private func fire(_ id: UInt32) {
        handlers[id]?()
    }
}
