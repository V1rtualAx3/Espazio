import EspazioCore
import SwiftUI

/// Root view hosted in each notch window. The window is top-anchored and centered on the notch;
/// the shape morphs between collapsed, peek and expanded.
public struct NotchRootView: View {
    let presentation: NotchPresentation
    let state: EspazioState
    let actions: EspazioActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(presentation: NotchPresentation, state: EspazioState, actions: EspazioActions) {
        self.presentation = presentation
        self.state = state
        self.actions = actions
    }

    public var body: some View {
        let geometry = presentation.geometry
        let notchState = presentation.state
        let tall = presentation.tab != .home || !state.pendingRequests.isEmpty
        let showsPendingDot = notchState == .collapsed && state.pendingDecisionCount > 0
        // The window always reserves the tall size; the shape adapts to the content.
        let size = showsPendingDot ? geometry.collapsedIndicatorSize : geometry.contentSize(for: notchState, tall: tall)
        let topRadius: CGFloat = notchState == .expanded ? 10 : 6
        let bottomRadius = notchState == .expanded ? geometry.metrics.cornerRadiusExpanded : geometry.metrics.cornerRadiusCollapsed

        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                NotchShape(topRadius: topRadius, bottomRadius: bottomRadius)
                    .fill(EZColor.notchBackground)
                content(state: notchState, geometry: geometry)
                    .padding(.horizontal, topRadius)
                    .transition(.opacity)
            }
            .frame(width: size.width, height: size.height)
            .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .contentShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
            .opacity(presentation.suppressed && notchState != .expanded ? 0 : 1)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(EZMotion.spring(reduceMotion: reduceMotion), value: notchState)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Espazio")
    }

    @ViewBuilder
    private func content(state notchState: NotchState, geometry: NotchGeometry) -> some View {
        switch notchState {
        case .collapsed:
            if state.pendingDecisionCount > 0 {
                VStack {
                    Spacer(minLength: 0)
                    PendingDecisionDot().padding(.bottom, 2)
                }
            } else {
                Color.clear
            }
        case .peek:
            if let item = state.peek {
                PeekView(item: item, state: state, geometry: geometry)
                    .id(item.coalescingKey)
            } else {
                Color.clear
            }
        case .expanded:
            ExpandedView(presentation: presentation, state: state, actions: actions)
        }
    }
}

/// Well-known coalescing keys shared by the coordinator and the views.
public enum PeekKeys {
    public static let nowPlaying = "media"
    public static let trackChange = "media-track"
}

/// Compact view on both sides of the notch: one prioritized piece of information only.
struct PeekView: View {
    let item: ActivityItem
    let state: EspazioState
    let geometry: NotchGeometry
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let wing = geometry.metrics.peekWingWidth
        HStack(spacing: 0) {
            leading
                .frame(width: wing - 12, alignment: .leading)
                .padding(.leading, 12)
            Spacer(minLength: geometry.notchRect.width)
            trailing
                .frame(width: wing - 14, alignment: .trailing)
                .padding(.trailing, 14)
        }
        .frame(height: geometry.notchRect.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCounterItem
            ? counters.map { "\($0.count) \($0.label)" }.joined(separator: ", ")
            : [item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    private var isCounterItem: Bool {
        [LiveActivityKey.mail, LiveActivityKey.chat, LiveActivityKey.messages].contains(item.coalescingKey)
    }

    /// Unread counters shown on their own: the first on the left wing, the others on the right
    /// (e-mail, Chat, iMessage), or icon left and count right when there is only one.
    private var counters: [UnreadCounter] { UnreadCounter.all(in: state) }

    @ViewBuilder
    private var leading: some View {
        if isCounterItem {
            let counters = self.counters
            if counters.count >= 2 {
                CounterLabel(counter: counters[0])
            } else if let only = counters.first {
                CounterIcon(symbol: only.symbol)
            }
        } else {
            // Unread badges sit beside the icon, leaving the right wing to the text.
            HStack(spacing: 8) {
                icon
                if !item.requiresDecision {
                    NotchBadges(state: state, excluding: item.coalescingKey)
                }
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        if item.source == .media, let artwork = state.artwork {
            Image(nsImage: artwork)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: item.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EZColor.notchPrimary)
                .symbolRenderingMode(.monochrome)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isCounterItem {
            let counters = self.counters
            if counters.count >= 2 {
                HStack(spacing: 10) {
                    ForEach(counters.dropFirst(), id: \.key) { CounterLabel(counter: $0) }
                }
            } else if let only = counters.first {
                CounterCount(count: only.count)
            }
        } else {
            mainTrailing
        }
    }

    @ViewBuilder
    private var mainTrailing: some View {
        if let progress = item.progress {
            EZProgressBar(value: progress).frame(width: 56)
        } else if item.coalescingKey == LiveActivityKey.timer, let timer = state.timer {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(TimerFormatter.remaining(until: timer.end, now: context.date))
                    .font(EZFont.captionEmphasis.monospacedDigit())
                    .foregroundStyle(EZColor.notchPrimary)
            }
        } else if item.coalescingKey == LiveActivityKey.event || item.coalescingKey.hasPrefix("event:"),
                  let event = state.events.first(where: { $0.id == item.reference }) {
            // Live countdown, ticking only while the peek is on screen.
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(CountdownFormatter.string(until: event.start, end: event.end, now: context.date))
                    .font(EZFont.captionEmphasis)
                    .foregroundStyle(EZColor.notchPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        } else if item.coalescingKey == PeekKeys.nowPlaying {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(EZColor.notchSecondary)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !reduceMotion && state.nowPlaying?.state == .playing)
        } else if item.requiresDecision {
            Text(item.title)
                .font(EZFont.captionEmphasis)
                .foregroundStyle(EZColor.notchPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        } else {
            Text(item.subtitle ?? item.title)
                .font(EZFont.captionEmphasis)
                .foregroundStyle(EZColor.notchPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .truncationMode(.tail)
        }
    }
}

/// An unread counter (e-mail or Chat) as configured in the settings.
struct UnreadCounter: Equatable {
    let symbol: String
    let count: Int
    let label: String
    let key: String

    /// E-mail first, then Chat; only enabled, non-zero counters.
    @MainActor
    static func all(in state: EspazioState) -> [UnreadCounter] {
        let live = state.settings.live
        let modules = state.settings.modules
        var counters: [UnreadCounter] = []
        if modules.gmail, live.mailBadge, let mail = state.unreadCount, mail > 0 {
            counters.append(UnreadCounter(symbol: "envelope", count: mail, label: "e-mails non lus", key: LiveActivityKey.mail))
        }
        if modules.googleChat, live.chatBadge, !state.chatUnread.isEmpty {
            counters.append(UnreadCounter(
                symbol: "bubble.left", count: state.chatUnread.count, label: "conversations Chat non lues", key: LiveActivityKey.chat))
        }
        if modules.iMessage, live.messagesBadge, let messages = state.messagesUnread, messages > 0 {
            counters.append(UnreadCounter(symbol: "message", count: messages, label: "iMessages non lus", key: LiveActivityKey.messages))
        }
        return counters
    }
}

private struct CounterIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(EZColor.notchSecondary)
    }
}

private struct CounterCount: View {
    let count: Int

    var body: some View {
        Text(BadgeCount.text(count))
            .font(.system(size: 12, weight: .semibold).monospacedDigit())
            .foregroundStyle(EZColor.notchPrimary)
    }
}

/// Icon and count side by side, for one wing.
private struct CounterLabel: View {
    let counter: UnreadCounter

    var body: some View {
        HStack(spacing: 5) {
            CounterIcon(symbol: counter.symbol)
            CounterCount(count: counter.count)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(counter.count) \(counter.label)")
    }
}

/// Small unread counters (e-mail, Chat) shown beside the icon of whatever the peek displays, so a
/// playing track or a meeting countdown never hides them.
struct NotchBadges: View {
    let state: EspazioState
    /// Live item currently shown in full: its own badge is not repeated.
    let excluding: String

    var body: some View {
        HStack(spacing: 5) {
            ForEach(UnreadCounter.all(in: state).filter { $0.key != excluding }, id: \.key) { counter in
                badge(counter.symbol + ".fill", count: counter.count, label: counter.label)
            }
        }
        .fixedSize()
    }

    private func badge(_ symbol: String, count: Int, label: String) -> some View {
        HStack(spacing: 2) {
            Image(systemName: symbol).font(.system(size: 8, weight: .semibold))
            Text(BadgeCount.text(count)).font(.system(size: 9, weight: .semibold).monospacedDigit())
        }
        .foregroundStyle(EZColor.notchSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(count) \(label)")
    }
}
