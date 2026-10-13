import EspazioCore
import SwiftUI

/// Expanded notch: header row on both sides of the camera, then the selected tab.
struct ExpandedView: View {
    let presentation: NotchPresentation
    let state: EspazioState
    let actions: EspazioActions

    var body: some View {
        let geometry = presentation.geometry
        VStack(spacing: 10) {
            header(notchWidth: geometry.notchRect.width, height: geometry.notchRect.height)
            Group {
                switch presentation.tab {
                case .home: HomeTab(state: state, actions: actions, presentation: presentation)
                case .agents: AgentsTab(state: state, actions: actions)
                case .mail: MailTab(state: state, actions: actions)
                case .chat: ChatTab(state: state, actions: actions)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 16)
        .foregroundStyle(EZColor.notchPrimary)
        .onExitCommand { actions.collapseNotch() }
    }

    private func header(notchWidth: CGFloat, height: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(state.visibleTabs) { tab in
                TabButton(tab: tab, selected: presentation.tab == tab, badge: badge(for: tab)) {
                    presentation.tab = tab
                }
            }
            Spacer(minLength: notchWidth + 8)
            FocusMenu(mode: state.settings.focusMode, pending: state.pendingDecisionCount) { actions.setFocusMode($0) }
            EZIconButton("gearshape", label: "Réglages", size: 12) { actions.openSettings() }
        }
        .frame(height: max(height, 28))
    }

    private func badge(for tab: NotchTab) -> Int? {
        switch tab {
        case .agents: return state.pendingRequests.isEmpty ? nil : state.pendingRequests.count
        case .mail: return state.unreadCount.flatMap { $0 > 0 ? $0 : nil }
        default: return nil
        }
    }
}

private struct TabButton: View {
    let tab: NotchTab
    let selected: Bool
    let badge: Int?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: selected ? tab.selectedSymbol : tab.symbol)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 30, height: 22)
                    .foregroundStyle(selected || hovering ? EZColor.notchPrimary : EZColor.notchTertiary)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.12) : .clear))
                    .animation(.easeOut(duration: 0.15), value: selected)
                if let badge {
                    Text(badge > 99 ? "99+" : "\(badge)")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 3.5)
                        .frame(minWidth: 13, minHeight: 13)
                        .background(Capsule().fill(Color.white))
                        .offset(x: 4, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(tab.title + (badge.map { ", \($0)" } ?? ""))
        .help(tab.title)
    }
}

private struct FocusMenu: View {
    let mode: FocusMode
    let pending: Int
    let onSelect: (FocusMode) -> Void

    var body: some View {
        Menu {
            // Plain buttons rather than a Picker bound through `Binding(get:set:)`, which
            // triggers a Swift 6.1 IRGen crash with an actor-isolated setter.
            ForEach([FocusMode.normal, .focused, .silent], id: \.self) { option in
                Button {
                    onSelect(option)
                } label: {
                    if option == mode {
                        Label(Self.title(option), systemImage: "checkmark")
                    } else {
                        Text(Self.title(option))
                    }
                }
            }
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(mode == .normal ? EZColor.notchSecondary : EZColor.notchPrimary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 28, height: 24)
        .accessibilityLabel("Mode de concentration")
        .help("Mode de concentration")
    }

    static func title(_ mode: FocusMode) -> String {
        switch mode {
        case .normal: return "Normal"
        case .focused: return "Concentré (P0–P1 seulement)"
        case .silent: return "Silencieux"
        }
    }

    private var symbol: String {
        switch mode {
        case .normal: return "moon"
        case .focused: return "moon.fill"
        case .silent: return "bell.slash.fill"
        }
    }
}
