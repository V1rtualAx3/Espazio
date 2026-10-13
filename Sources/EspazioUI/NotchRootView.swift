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
        // The window always reserves the tall size; the shape adapts to the content.
        let size = geometry.contentSize(for: notchState, tall: tall)
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
            Color.clear
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
    public static let silentBadge = "silent-badge"
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
        .accessibilityLabel([item.title, item.subtitle].compactMap { $0 }.joined(separator: ", "))
    }

    @ViewBuilder
    private var leading: some View {
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
        if let progress = item.progress {
            EZProgressBar(value: progress).frame(width: 56)
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
                .font(EZFont.caption)
                .foregroundStyle(EZColor.notchSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}
