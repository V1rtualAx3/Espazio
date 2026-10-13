import AppKit
import EspazioCore
import EspazioUI

/// Owns one `NotchWindowController` per hosted display and reacts to display changes
/// (connection, resolution, arrangement), Spaces and full-screen apps. Event-driven only.
@MainActor
final class DisplayManager {
    private(set) var controllers: [UInt32: NotchWindowController] = [:]
    private var plannedScreens: [ScreenDescriptor] = []
    private weak var coordinator: AppCoordinator?
    private let state: EspazioState
    private var observers: [NSObjectProtocol] = []
    private var rebuildTask: Task<Void, Never>?

    init(state: EspazioState, coordinator: AppCoordinator) {
        self.state = state
        self.coordinator = coordinator
    }

    func start() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleRebuild() }
        })
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.contextChanged() }
            })
        }
        rebuild()
    }

    func stop() {
        observers.forEach { NotificationCenter.default.removeObserver($0); NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        controllers.values.forEach { $0.close() }
        controllers.removeAll()
    }

    /// Debounced: display reconfiguration fires several notifications in a row.
    func scheduleRebuild() {
        rebuildTask?.cancel()
        rebuildTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            self?.rebuild()
        }
    }

    func rebuild() {
        guard let coordinator else { return }
        let screens = NSScreen.screens.map(Self.descriptor)
        let planned = DisplayPlanner.screensToHost(screens, mode: state.settings.displayMode, activeScreenID: activeScreenID(screens))
        let diff = DisplayPlanner.diff(old: plannedScreens, new: planned)
        for id in diff.removed {
            controllers.removeValue(forKey: id)?.close()
        }
        for screen in planned {
            if let controller = controllers[screen.id] {
                if diff.updated.contains(screen.id) { controller.update(screen: screen) }
            } else {
                controllers[screen.id] = NotchWindowController(screen: screen, state: state, coordinator: coordinator)
            }
        }
        plannedScreens = planned
        contextChanged()
        syncPeek()
    }

    func syncPeek() {
        controllers.values.forEach { $0.syncPeek() }
    }

    var anyExpanded: Bool { controllers.values.contains { $0.isExpanded } }

    /// Expands the notch on the display under the pointer (or the first hosted one).
    func expand(tab: NotchTab?, makeKey: Bool) {
        let mouse = NSEvent.mouseLocation
        let target = controllers.values.first { $0.screen.frame.contains(mouse) } ?? controllers[plannedScreens.first?.id ?? 0]
        target?.expand(tab: tab, makeKey: makeKey)
    }

    func toggle(tab: NotchTab?) {
        if anyExpanded {
            collapseAll()
        } else {
            expand(tab: tab, makeKey: true)
        }
    }

    func collapseAll() {
        controllers.values.forEach { $0.collapse() }
    }

    // MARK: - Context (full screen, active screen)

    private func contextChanged() {
        let fullScreenIDs = FullScreenDetector.fullScreenDisplayIDs(Array(controllers.values.map(\.screen)))
        let hide = state.settings.hideInFullScreen
        for controller in controllers.values {
            controller.setSuppressed(hide && fullScreenIDs.contains(controller.screenID))
        }
        coordinator?.updateFocusContext(isFullScreen: !fullScreenIDs.isEmpty)
        if state.settings.displayMode == .activeScreen {
            let screens = NSScreen.screens.map(Self.descriptor)
            if let active = activeScreenID(screens), controllers[active] == nil { scheduleRebuild() }
        }
    }

    /// Approximation of the "active" display: the one under the pointer. The display of another
    /// app's key window is not observable without the Accessibility permission.
    private func activeScreenID(_ screens: [ScreenDescriptor]) -> UInt32? {
        let mouse = NSEvent.mouseLocation
        return screens.first { $0.frame.contains(mouse) }?.id
    }

    static func descriptor(_ screen: NSScreen) -> ScreenDescriptor {
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        return ScreenDescriptor(
            id: number?.uint32Value ?? 0,
            localizedName: screen.localizedName,
            frame: screen.frame,
            visibleFrame: screen.visibleFrame,
            safeAreaTop: screen.safeAreaInsets.top,
            auxiliaryLeftWidth: screen.auxiliaryTopLeftArea?.width,
            auxiliaryRightWidth: screen.auxiliaryTopRightArea?.width,
            // The primary display (menu bar origin) is screens[0]; NSScreen.main is the key
            // window's display, which is a different concept (spec §3.1).
            isMain: NSScreen.screens.first == screen,
            backingScaleFactor: screen.backingScaleFactor)
    }
}

/// Heuristic full-screen detection without Screen Recording permission: a normal-layer window
/// covering a whole display. Window bounds are readable; titles are not needed.
enum FullScreenDetector {
    static func fullScreenDisplayIDs(_ screens: [ScreenDescriptor]) -> Set<UInt32> {
        guard !screens.isEmpty,
            let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        var result: Set<UInt32> = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                (window[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            // CG coordinates are top-left based; convert to AppKit global coordinates.
            let appKitRect = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            for screen in screens where appKitRect.equalTo(screen.frame) {
                result.insert(screen.id)
            }
        }
        return result
    }
}
