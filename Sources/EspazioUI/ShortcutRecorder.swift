import AppKit
import EspazioCore
import SwiftUI

/// Click, then press the new combination. Requires ⌘, ⌥ or ⌃; Escape cancels.
public struct ShortcutRecorder: View {
    let shortcut: KeyShortcut
    let defaultShortcut: KeyShortcut
    let onChange: (KeyShortcut) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hint: String?

    public init(shortcut: KeyShortcut, defaultShortcut: KeyShortcut, onChange: @escaping (KeyShortcut) -> Void) {
        self.shortcut = shortcut
        self.defaultShortcut = defaultShortcut
        self.onChange = onChange
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let hint {
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            Button(recording ? "Tapez le raccourci…" : shortcut.displayString) {
                recording ? stop() : start()
            }
            .frame(minWidth: 120)
            .accessibilityHint("Cliquez puis tapez une nouvelle combinaison de touches")
            if shortcut != defaultShortcut, !recording {
                Button {
                    onChange(defaultShortcut)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .help("Rétablir \(defaultShortcut.displayString)")
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        hint = nil
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags
            MainActor.assumeIsolated { handle(keyCode: keyCode, flags: flags) }
            return nil
        }
    }

    private func handle(keyCode: UInt32, flags: NSEvent.ModifierFlags) {
        if keyCode == 53 {
            stop()
            return
        }
        var modifiers: KeyShortcut.Modifiers = []
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        let candidate = KeyShortcut(keyCode: keyCode, modifiers: modifiers)
        guard candidate.isValid, !KeyShortcut.reservedKeyCodes.contains(keyCode) else {
            hint = "Ajoutez ⌘, ⌥ ou ⌃"
            return
        }
        stop()
        onChange(candidate)
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
    }
}
