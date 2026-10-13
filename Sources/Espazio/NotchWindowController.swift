import AppKit
import EspazioCore
import EspazioUI
import SwiftUI

/// Borderless, non-activating panel that never steals focus when it appears. It can become key
/// only while expanded (text fields), still without activating the application.
final class NotchPanel: NSPanel {
    var allowsKey = false

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isFloatingPanel = true
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
        isReleasedWhenClosed = false
    }

    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

/// Content view tracking hover over the visible notch shape.
final class HoverTrackingView: NSView {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

/// One notch on one display. Presentation (collapsed / peek / expanded) is local to the screen;
/// content and decisions come from the shared `EspazioState`, so an action taken on one screen
/// is reflected everywhere and executed once.
@MainActor
final class NotchWindowController: NSObject, NSWindowDelegate {
    let screenID: UInt32
    private(set) var screen: ScreenDescriptor
    let presentation: NotchPresentation
    private let panel: NotchPanel
    private let hoverView = HoverTrackingView()
    private let state: EspazioState
    private weak var coordinator: AppCoordinator?
    private var hoverTask: Task<Void, Never>?
    private var resizeTask: Task<Void, Never>?
    private var hovering = false

    init(screen: ScreenDescriptor, state: EspazioState, coordinator: AppCoordinator) {
        self.screenID = screen.id
        self.screen = screen
        self.state = state
        self.coordinator = coordinator
        let geometry = NotchGeometry(screen: screen)
        presentation = NotchPresentation(geometry: geometry)
        panel = NotchPanel(frame: geometry.windowFrame(for: .collapsed))
        super.init()

        let root = NotchRootView(presentation: presentation, state: state, actions: coordinator)
        let hosting = NSHostingView(rootView: root)
        hosting.translatesAutoresizingMaskIntoConstraints = false
        hoverView.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: hoverView.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: hoverView.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: hoverView.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: hoverView.bottomAnchor),
        ])
        hoverView.onHover = { [weak self] inside in self?.hoverChanged(inside) }
        panel.contentView = hoverView
        panel.delegate = self

        let click = NSClickGestureRecognizer(target: self, action: #selector(clicked))
        click.delaysPrimaryMouseButtonEvents = false
        hoverView.addGestureRecognizer(click)

        panel.setFrame(geometry.windowFrame(for: .collapsed), display: false)
        panel.orderFrontRegardless()
    }

    func close() {
        hoverTask?.cancel()
        resizeTask?.cancel()
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
    }

    var isExpanded: Bool { presentation.state == .expanded }

    // MARK: - Geometry

    func update(screen newScreen: ScreenDescriptor) {
        screen = newScreen
        presentation.geometry = NotchGeometry(screen: newScreen)
        panel.setFrame(presentation.geometry.windowFrame(for: presentation.state), display: true)
    }

    func setSuppressed(_ suppressed: Bool) {
        guard presentation.suppressed != suppressed else { return }
        presentation.suppressed = suppressed
        if suppressed, presentation.state != .expanded, state.pendingDecisionCount == 0 {
            panel.orderOut(nil)
        } else {
            panel.orderFrontRegardless()
        }
    }

    // MARK: - State transitions

    /// Called by the coordinator whenever the shared peek changes.
    func syncPeek() {
        guard presentation.state != .expanded else { return }
        let target: NotchState = state.peek == nil ? .collapsed : .peek
        if presentation.suppressed, target == .peek, state.peek?.priority != .p0 { return }
        transition(to: target)
    }

    func expand(tab: NotchTab? = nil, makeKey: Bool) {
        if let tab { presentation.tab = tab }
        if presentation.suppressed { panel.orderFrontRegardless() }
        transition(to: .expanded)
        if makeKey {
            panel.allowsKey = true
            panel.makeKey()
        }
    }

    func collapse() {
        guard presentation.state == .expanded else { return }
        panel.allowsKey = false
        if panel.isKeyWindow { panel.resignKey() }
        transition(to: state.peek == nil ? .collapsed : .peek)
        if presentation.suppressed { panel.orderOut(nil) }
    }

    private func transition(to target: NotchState) {
        guard target != presentation.state else { return }
        let geometry = presentation.geometry
        let current = geometry.contentSize(for: presentation.state)
        let next = geometry.contentSize(for: target)
        resizeTask?.cancel()
        panel.allowsKey = target == .expanded && panel.allowsKey
        if next.width >= current.width || next.height >= current.height {
            // Grow the window first, then let SwiftUI animate the shape inside it.
            panel.setFrame(unionFrame(presentation.state, target), display: true)
        }
        presentation.state = target
        resizeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(EZMotion.collapseDuration * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.panel.setFrame(geometry.windowFrame(for: self.presentation.state), display: true)
        }
    }

    private func unionFrame(_ a: NotchState, _ b: NotchState) -> NSRect {
        let geometry = presentation.geometry
        return geometry.windowFrame(for: a).union(geometry.windowFrame(for: b))
    }

    // MARK: - Interaction

    private func hoverChanged(_ inside: Bool) {
        hovering = inside
        hoverTask?.cancel()
        let settings = state.settings
        if inside {
            guard settings.expandOnHover, presentation.state != .expanded else { return }
            let delay = settings.hoverDelay
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self, self.hovering else { return }
                self.expand(tab: self.coordinator?.preferredTab(), makeKey: false)
            }
        } else {
            guard presentation.state == .expanded else { return }
            hoverTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 450_000_000)
                guard !Task.isCancelled, let self, !self.hovering, !self.isEditingText else { return }
                self.collapse()
            }
        }
    }

    /// Keep the panel open while the user types in a field.
    private var isEditingText: Bool {
        panel.isKeyWindow && panel.firstResponder is NSTextView
    }

    @objc private func clicked() {
        guard presentation.state != .expanded else { return }
        hoverTask?.cancel()
        expand(tab: coordinator?.preferredTab(), makeKey: true)
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard presentation.state == .expanded, !hovering else { return }
        collapse()
    }
}
