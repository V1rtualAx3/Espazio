import Foundation

/// Which displays host a notch (spec §3.1).
public enum DisplayMode: String, Sendable, Codable, CaseIterable {
    /// Main display only (default).
    case mainOnly
    /// Every connected display.
    case allScreens
    /// The display with the active window / pointer (optional mode).
    case activeScreen
}

public enum DisplayPlanner {
    /// Returns the displays that must host a notch, in a stable order.
    ///
    /// - Parameters:
    ///   - screens: currently connected displays.
    ///   - mode: user preference.
    ///   - activeScreenID: display of the frontmost window, if known. It is *not* assumed to be
    ///     the main display.
    ///   - preferBuiltInNotch: in `.mainOnly`, prefer the built-in notched display when the
    ///     main display has no notch but the laptop panel is still connected and active.
    public static func screensToHost(
        _ screens: [ScreenDescriptor], mode: DisplayMode, activeScreenID: UInt32?, preferBuiltInNotch: Bool = false
    ) -> [ScreenDescriptor] {
        guard !screens.isEmpty else { return [] }
        let main = screens.first(where: \.isMain) ?? screens[0]
        switch mode {
        case .allScreens:
            return screens.sorted { lhs, rhs in
                if lhs.isMain != rhs.isMain { return lhs.isMain }
                return lhs.id < rhs.id
            }
        case .mainOnly:
            if preferBuiltInNotch, !main.hasPhysicalNotch, let notched = screens.first(where: \.hasPhysicalNotch) {
                return [notched]
            }
            return [main]
        case .activeScreen:
            if let activeScreenID, let active = screens.first(where: { $0.id == activeScreenID }) {
                return [active]
            }
            return [main]
        }
    }

    /// Diff between two plans so the window layer only creates / removes / moves what changed.
    public struct Diff: Sendable, Equatable {
        public var added: [UInt32]
        public var removed: [UInt32]
        public var updated: [UInt32]
    }

    public static func diff(old: [ScreenDescriptor], new: [ScreenDescriptor]) -> Diff {
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let added = new.map(\.id).filter { oldByID[$0] == nil }
        let removed = old.map(\.id).filter { newByID[$0] == nil }
        let updated = new.compactMap { screen -> UInt32? in
            guard let previous = oldByID[screen.id], previous != screen else { return nil }
            return screen.id
        }
        return Diff(added: added, removed: removed, updated: updated)
    }
}
