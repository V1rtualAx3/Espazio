import Foundation

/// User-selected focus mode. The macOS Focus state is not exposed through a suitable public
/// API, so Espazio relies on an explicit manual mode (spec §3.7).
public enum FocusMode: String, Sendable, Codable, CaseIterable {
    /// Every enabled module may peek.
    case normal
    /// Only P0/P1 may peek.
    case focused
    /// Nothing peeks; items are queued and an indicator is shown in the collapsed notch.
    case silent
}

/// Contextual signals that influence what may interrupt the user.
public struct FocusContext: Sendable, Equatable {
    /// A calendar event is in progress.
    public var isInMeeting: Bool
    /// The frontmost window on the notch screen is full screen.
    public var isFullScreen: Bool
    /// The screen is mirrored (projector, AirPlay mirroring): the audience sees the notch.
    public var isPresenting: Bool

    public init(isInMeeting: Bool = false, isFullScreen: Bool = false, isPresenting: Bool = false) {
        self.isInMeeting = isInMeeting
        self.isFullScreen = isFullScreen
        self.isPresenting = isPresenting
    }
}

/// Decides whether an activity may *interrupt* (peek). Items that may not interrupt are still
/// kept and reachable from the expanded notch: nothing is ever dropped silently by the policy.
public struct FocusPolicy: Sendable, Equatable {
    public var mode: FocusMode
    public var context: FocusContext
    /// Sources the user has muted entirely (they are not even queued).
    public var mutedSources: Set<ActivitySource>

    public init(mode: FocusMode = .normal, context: FocusContext = .init(), mutedSources: Set<ActivitySource> = []) {
        self.mode = mode
        self.context = context
        self.mutedSources = mutedSources
    }

    /// Least important priority allowed to peek in the current state.
    public var peekThreshold: ActivityPriority? {
        switch mode {
        case .silent:
            return nil
        case .focused:
            return context.isPresenting ? .p0 : .p1
        case .normal:
            // Presenting: only agent decisions, which cannot wait.
            if context.isPresenting { return .p0 }
            if context.isInMeeting || context.isFullScreen { return .p1 }
            return .p4
        }
    }

    public func accepts(_ item: ActivityItem) -> Bool {
        // Agent decisions can never be muted: a pending request must stay reachable.
        if item.requiresDecision { return true }
        return !mutedSources.contains(item.source)
    }

    public func mayPeek(_ item: ActivityItem) -> Bool {
        guard accepts(item), let threshold = peekThreshold else { return false }
        if item.priority <= threshold { return true }
        // The continuous information the user chose (track, counters, timer…) never interrupts:
        // it stays during a meeting or in full screen, and only goes away in silent or focused
        // mode and while presenting, when an audience sees the notch.
        return mode == .normal && !context.isPresenting && LiveActivityKey.all.contains(item.coalescingKey)
    }
}
