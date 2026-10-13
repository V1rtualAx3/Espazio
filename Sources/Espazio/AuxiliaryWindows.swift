import AppKit
import EspazioCore
import EspazioUI
import SwiftUI

/// Spotlight-like Quick Actions panel: key without activating the app, closes on focus loss.
@MainActor
final class QuickActionsController: NSObject, NSWindowDelegate {
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    let model = QuickActionsModel()
    private var panel: Panel?
    var onExecute: ((QuickActionItem) -> Void)?

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(catalog: [QuickActionItem]) {
        if isVisible { close() } else { show(catalog: catalog) }
    }

    func show(catalog: [QuickActionItem]) {
        model.query = ""
        model.selection = 0
        model.catalog = catalog
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.screens.first
        if let frame = screen?.visibleFrame {
            let size = NSSize(width: 560, height: 380)
            panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.maxY - frame.height * 0.22 - size.height, width: size.width, height: size.height), display: false)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        let view = QuickActionsView(
            model: model,
            onExecute: { [weak self] item in
                self?.close()
                self?.onExecute?(item)
            },
            onClose: { [weak self] in self?.close() })
        let hosting = NSHostingView(rootView: VStack { view; Spacer(minLength: 0) })
        panel.contentView = hosting
        return panel
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

/// Settings window (regular, appearance-adaptive).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let state: EspazioState
    private weak var actions: SettingsActions?
    var lastError: String? {
        didSet { if window != nil { refreshContent() } }
    }

    init(state: EspazioState, actions: SettingsActions) {
        self.state = state
        self.actions = actions
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled, .closable], backing: .buffered, defer: true)
            window.title = "Réglages Espazio"
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
            refreshContent()
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func refreshContent() {
        guard let actions else { return }
        window?.contentViewController = NSHostingController(rootView: SettingsView(state: state, actions: actions, lastError: lastError))
    }
}

/// Menu bar item: entry points that do not depend on the notch.
@MainActor
final class StatusItemController: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private weak var coordinator: AppCoordinator?
    private let silentItem = NSMenuItem(title: "Mode silencieux", action: #selector(toggleSilent), keyEquivalent: "")

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "rectangle.topthird.inset.filled", accessibilityDescription: "Espazio")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        menu.addItem(withTitle: "Ouvrir la notch", action: #selector(openNotch), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Actions rapides", action: #selector(openQuickActions), keyEquivalent: "").target = self
        silentItem.target = self
        menu.addItem(silentItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Réglages…", action: #selector(openSettings), keyEquivalent: ",").target = self
        if coordinator.updates.isConfigured {
            menu.addItem(withTitle: "Rechercher des mises à jour…", action: #selector(checkUpdates), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Espazio", action: #selector(quit), keyEquivalent: "q").target = self
        menu.delegate = self
        item.menu = menu
    }

    @objc private func openNotch() { coordinator?.toggleNotch() }
    @objc private func openQuickActions() { coordinator?.toggleQuickActions() }
    @objc private func openSettings() { coordinator?.openSettings() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func checkUpdates() { coordinator?.checkForUpdates() }

    @objc private func toggleSilent() {
        guard let coordinator else { return }
        coordinator.setFocusMode(coordinator.state.settings.focusMode == .silent ? .normal : .silent)
    }
}

extension StatusItemController: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        silentItem.state = coordinator?.state.settings.focusMode == .silent ? .on : .off
    }
}
