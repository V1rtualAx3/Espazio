import AppKit
import EspazioCore
@testable import EspazioUI
import SwiftUI
import XCTest

/// Off-screen rendering of every notch state with offline sample data. These tests run on the
/// macOS CI runner; they check that each state renders at the expected size without a network
/// connection or a permission. Visual fidelity still needs the manual checklist.
@MainActor
final class NotchRenderingTests: XCTestCase {
    private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme = .dark) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme))
        renderer.scale = 2
        return renderer.cgImage
    }

    private func notch(_ notchState: NotchState, tab: NotchTab = .home, peek: ActivityItem? = nil, long: Bool = false, screen: ScreenDescriptor = PreviewData.builtInScreen) -> (NotchRootView, CGSize) {
        let state = PreviewData.state(longStrings: long)
        state.peek = peek
        let presentation = PreviewData.presentation(notchState, tab: tab, screen: screen)
        return (NotchRootView(presentation: presentation, state: state, actions: NoopActions()), presentation.geometry.windowFrame(for: notchState).size)
    }

    func testEveryStateRenders() {
        let cases: [(NotchState, NotchTab, ActivityItem?)] = [
            (.collapsed, .home, nil),
            (.peek, .home, PreviewData.volumePeek),
            (.peek, .home, PreviewData.approvalPeek),
            (.expanded, .home, nil),
            (.expanded, .agents, nil),
            (.expanded, .mail, nil),
            (.expanded, .chat, nil),
        ]
        for (notchState, tab, peek) in cases {
            for long in [false, true] {
                let (view, size) = notch(notchState, tab: tab, peek: peek, long: long)
                let image = render(view, size: size)
                XCTAssertNotNil(image, "\(notchState) \(tab) long=\(long)")
                XCTAssertEqual(image?.width, Int(size.width * 2))
            }
        }
    }

    func testVirtualNotchOnExternalDisplay() {
        let (view, size) = notch(.expanded, tab: .agents, screen: PreviewData.externalScreen)
        XCTAssertNotNil(render(view, size: size))
        XCTAssertGreaterThan(size.width, 0)
    }

    func testLightModeSettingsAndPalette() {
        final class Noop: SettingsActions {
            func updateSettings(_ settings: EspazioSettings) {}
            func setClaudeHooksInstalled(_ installed: Bool) {}
            func installCodexNotify() {}
            func saveGoogleCredentials(clientID: String, clientSecret: String) {}
            func connectGoogle() {}
            func disconnectGoogle() {}
            func requestCalendarAccess() {}
            func requestRemindersAccess() {}
            func openPrivacySettings(_ pane: String) {}
            func refreshDiagnostics() {}
            func revealAuditLog() {}
        }
        let actions = Noop()
        for scheme in [ColorScheme.light, .dark] {
            XCTAssertNotNil(render(SettingsView(state: PreviewData.state(), actions: actions), size: CGSize(width: 560, height: 470), scheme: scheme))
            let model = QuickActionsModel()
            model.catalog = [QuickActionItem(id: "1", title: "Point produit", symbol: "calendar", action: .openEvent(id: "e"))]
            XCTAssertNotNil(render(QuickActionsView(model: model, onExecute: { _ in }, onClose: {}), size: CGSize(width: 560, height: 200), scheme: scheme))
        }
    }

    func testApprovalCardOffersOnlyAllowOnceAndDeny() {
        let state = PreviewData.state()
        let request = try! XCTUnwrap(state.pendingRequests.first)
        let card = ApprovalCard(request: request, position: 1, total: 1, session: state.sessions.first, actions: NoopActions())
        XCTAssertNotNil(render(card.padding(), size: CGSize(width: 600, height: 220)))
    }

    func testQuickActionsKeyboardModel() {
        let model = QuickActionsModel()
        model.catalog = (0..<3).map { QuickActionItem(id: "\($0)", title: "Item \($0)", symbol: "circle", action: .toggleSilentMode) }
        XCTAssertEqual(model.results.count, 3)
        model.move(-1)
        XCTAssertEqual(model.selection, 2, "wraps around")
        model.move(1)
        XCTAssertEqual(model.selected?.id, "0")
        model.query = "+ appeler le garage demain"
        XCTAssertEqual(model.results.first?.id, "create-reminder")
    }

    func testVisibleTabsFollowModules() {
        let state = EspazioState()
        XCTAssertEqual(state.visibleTabs, [.home, .agents])
        state.settings.modules.gmail = true
        state.settings.modules.claudeCode = false
        state.settings.modules.codex = false
        XCTAssertEqual(state.visibleTabs, [.home, .mail])
    }
}
