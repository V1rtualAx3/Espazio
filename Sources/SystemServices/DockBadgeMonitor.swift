import AppKit
import ApplicationServices

/// Reads the badge an application shows on its Dock icon (e.g. unread iMessages on Messages).
/// Apple offers no iMessage API: the Dock badge is the only official, content-free signal. Reading
/// it requires the Accessibility permission; only the Dock's own items are queried, nothing else.
@MainActor
public final class DockBadgeMonitor {
    public enum Reading: Equatable, Sendable {
        case count(Int)
        /// The Accessibility permission is not granted.
        case needsPermission
        /// The app is not in the Dock (or the Dock could not be read).
        case unavailable
    }

    public var onChange: ((Reading) -> Void)?
    public private(set) var reading: Reading?
    private let bundleID: String
    private var timer: Timer?

    public init(bundleID: String) {
        self.bundleID = bundleID
    }

    public static let messagesBundleID = "com.apple.MobileSMS"

    public func start(interval: TimeInterval = 4) {
        guard timer == nil else { return }
        poll()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
        reading = nil
    }

    /// Shows the system prompt that lists Espazio in Privacy › Accessibility.
    public static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public func poll() {
        let next = read()
        guard next != reading else { return }
        reading = next
        onChange?(next)
    }

    private func read() -> Reading {
        guard AXIsProcessTrusted() else { return .needsPermission }
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return .unavailable }
        let dockElement = AXUIElementCreateApplication(dock.processIdentifier)
        for list in Self.children(of: dockElement) where Self.string(list, "AXRole") == "AXList" {
            for item in Self.children(of: list) {
                guard let url = Self.url(item, "AXURL"), url.standardizedFileURL.path == appURL.standardizedFileURL.path else { continue }
                return .count(Self.badgeCount(Self.string(item, "AXStatusLabel")))
            }
        }
        return .unavailable
    }

    /// "3" → 3, "99+" → 99, a non-numeric mark ("•") → 1, no badge → 0.
    nonisolated static func badgeCount(_ label: String?) -> Int {
        guard let label = label?.trimmingCharacters(in: .whitespaces), !label.isEmpty else { return 0 }
        let digits = label.filter(\.isNumber)
        return Int(digits) ?? 1
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        (attribute(element, "AXChildren") as? [AXUIElement]) ?? []
    }

    private static func string(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func url(_ element: AXUIElement, _ name: String) -> URL? {
        guard let value = attribute(element, name), CFGetTypeID(value) == CFURLGetTypeID() else { return nil }
        return (value as! CFURL) as URL
    }
}
