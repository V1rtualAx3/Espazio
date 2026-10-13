import EspazioCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest

final class DisplayTests: XCTestCase {
    // MacBook Pro 14" default scaled resolution: 1512x982, notch ~185pt wide, 32pt high.
    let builtIn = ScreenDescriptor(
        id: 1, localizedName: "Built-in Retina Display", frame: CGRect(x: 0, y: 0, width: 1512, height: 982),
        visibleFrame: CGRect(x: 0, y: 0, width: 1512, height: 950), safeAreaTop: 32,
        auxiliaryLeftWidth: 663, auxiliaryRightWidth: 664, isMain: true)
    let external = ScreenDescriptor(
        id: 7, localizedName: "Studio Display", frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        visibleFrame: CGRect(x: 1512, y: 0, width: 2560, height: 1415), safeAreaTop: 0,
        auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isMain: false)

    func testPhysicalNotchGeometry() {
        let geometry = NotchGeometry(screen: builtIn)
        XCTAssertFalse(geometry.isVirtual)
        XCTAssertEqual(geometry.notchRect, CGRect(x: 663, y: 950, width: 185, height: 32))
    }

    func testVirtualNotchFallbackUsesMenuBarHeight() {
        let geometry = NotchGeometry(screen: external)
        XCTAssertTrue(geometry.isVirtual)
        XCTAssertEqual(geometry.notchRect.height, 25)
        XCTAssertEqual(geometry.notchRect.midX, external.frame.midX)
        XCTAssertEqual(geometry.notchRect.maxY, external.frame.maxY)
    }

    func testVirtualNotchWithHiddenMenuBar() {
        var screen = external
        screen.visibleFrame = screen.frame
        let geometry = NotchGeometry(screen: screen)
        XCTAssertEqual(geometry.notchRect.height, NotchMetrics.standard.virtualNotchHeight)
    }

    func testWindowFramesAreTopAlignedAndInsideScreen() {
        let geometry = NotchGeometry(screen: builtIn)
        for state in NotchState.allCases {
            let frame = geometry.windowFrame(for: state)
            XCTAssertEqual(frame.maxY, builtIn.frame.maxY, "\(state)")
            XCTAssertTrue(builtIn.frame.contains(frame), "\(state)")
            XCTAssertEqual(frame.midX, geometry.notchRect.midX, accuracy: 0.5, "\(state)")
        }
        XCTAssertGreaterThan(geometry.contentSize(for: .expanded).height, geometry.contentSize(for: .peek).height)
        XCTAssertGreaterThan(geometry.contentSize(for: .peek).width, geometry.contentSize(for: .collapsed).width)
        XCTAssertLessThan(geometry.contentSize(for: .expanded, tall: false).height, geometry.contentSize(for: .expanded).height)
        XCTAssertEqual(geometry.windowFrame(for: .expanded).size, geometry.contentSize(for: .expanded))
    }

    func testExpandedFitsSmallScreens() {
        let tiny = ScreenDescriptor(
            id: 3, localizedName: "Tiny", frame: CGRect(x: 0, y: 0, width: 500, height: 300),
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 276), safeAreaTop: 0,
            auxiliaryLeftWidth: nil, auxiliaryRightWidth: nil, isMain: true)
        let geometry = NotchGeometry(screen: tiny)
        let frame = geometry.windowFrame(for: .expanded)
        XCTAssertTrue(tiny.frame.contains(frame))
    }

    func testDisplayPlannerModes() {
        let screens = [external, builtIn]
        XCTAssertEqual(DisplayPlanner.screensToHost(screens, mode: .mainOnly, activeScreenID: 7).map(\.id), [1])
        XCTAssertEqual(DisplayPlanner.screensToHost(screens, mode: .allScreens, activeScreenID: nil).map(\.id), [1, 7])
        XCTAssertEqual(DisplayPlanner.screensToHost(screens, mode: .activeScreen, activeScreenID: 7).map(\.id), [7])
        XCTAssertEqual(DisplayPlanner.screensToHost(screens, mode: .activeScreen, activeScreenID: 99).map(\.id), [1])
        XCTAssertTrue(DisplayPlanner.screensToHost([], mode: .mainOnly, activeScreenID: nil).isEmpty)
    }

    func testMainOnlyCanPreferBuiltInNotch() {
        var ext = external
        ext.isMain = true
        var internalScreen = builtIn
        internalScreen.isMain = false
        let plan = DisplayPlanner.screensToHost([ext, internalScreen], mode: .mainOnly, activeScreenID: nil, preferBuiltInNotch: true)
        XCTAssertEqual(plan.map(\.id), [1])
    }

    func testDiff() {
        var moved = builtIn
        moved.frame.origin.x = 10
        let diff = DisplayPlanner.diff(old: [builtIn], new: [moved, external])
        XCTAssertEqual(diff.added, [7])
        XCTAssertEqual(diff.removed, [])
        XCTAssertEqual(diff.updated, [1])
        XCTAssertEqual(DisplayPlanner.diff(old: [builtIn, external], new: [builtIn]).removed, [7])
    }
}
