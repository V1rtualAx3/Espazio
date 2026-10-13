import Foundation

/// Visual state of a notch (spec §2).
public enum NotchState: String, Sendable, Equatable, CaseIterable {
    /// At rest: matches the physical notch, (almost) invisible.
    case collapsed
    /// Small contextual information on both sides of the notch, never steals focus.
    case peek
    /// Full panel for actions and details.
    case expanded
}

/// Platform-neutral description of a display, built by the AppKit layer from `NSScreen`.
/// Coordinates are AppKit global coordinates (origin bottom-left of the main display).
public struct ScreenDescriptor: Sendable, Equatable, Identifiable {
    /// Stable display identifier (`CGDirectDisplayID`).
    public let id: UInt32
    public var localizedName: String
    public var frame: CGRect
    public var visibleFrame: CGRect
    /// `NSScreen.safeAreaInsets.top`; > 0 only on displays with a camera housing.
    public var safeAreaTop: CGFloat
    /// Width of `auxiliaryTopLeftArea` / `auxiliaryTopRightArea` (the menu bar parts left and
    /// right of the notch), when available.
    public var auxiliaryLeftWidth: CGFloat?
    public var auxiliaryRightWidth: CGFloat?
    public var isMain: Bool
    public var backingScaleFactor: CGFloat

    public init(
        id: UInt32, localizedName: String, frame: CGRect, visibleFrame: CGRect, safeAreaTop: CGFloat,
        auxiliaryLeftWidth: CGFloat?, auxiliaryRightWidth: CGFloat?, isMain: Bool, backingScaleFactor: CGFloat = 2
    ) {
        self.id = id
        self.localizedName = localizedName
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.auxiliaryLeftWidth = auxiliaryLeftWidth
        self.auxiliaryRightWidth = auxiliaryRightWidth
        self.isMain = isMain
        self.backingScaleFactor = backingScaleFactor
    }

    public var hasPhysicalNotch: Bool { safeAreaTop > 0 }
}

/// Sizes used for every state. Centralized so UI and window placement agree.
public struct NotchMetrics: Sendable, Equatable {
    public var virtualNotchWidth: CGFloat = 190
    public var virtualNotchHeight: CGFloat = 32
    /// Extra width on each side of the notch for peek content.
    public var peekWingWidth: CGFloat = 96
    /// Extra height below the notch for a peek subtitle line.
    public var peekExtraHeight: CGFloat = 0
    public var expandedSize = CGSize(width: 640, height: 240)
    public var cornerRadiusCollapsed: CGFloat = 10
    public var cornerRadiusExpanded: CGFloat = 26

    public init() {}

    public static let standard = NotchMetrics()
}

/// Pure geometry: where the notch is on a screen and which window frame each state needs.
public struct NotchGeometry: Sendable, Equatable {
    /// The notch rectangle (physical or virtual) in global coordinates.
    public let notchRect: CGRect
    public let isVirtual: Bool
    public let screenFrame: CGRect
    public let metrics: NotchMetrics

    public init(screen: ScreenDescriptor, metrics: NotchMetrics = .standard) {
        self.metrics = metrics
        self.screenFrame = screen.frame
        let frame = screen.frame
        if screen.hasPhysicalNotch,
            let left = screen.auxiliaryLeftWidth, let right = screen.auxiliaryRightWidth,
            left > 0, right > 0, left + right < frame.width
        {
            let width = frame.width - left - right
            let height = screen.safeAreaTop
            notchRect = CGRect(x: frame.minX + left, y: frame.maxY - height, width: width, height: height)
            isVirtual = false
        } else {
            // Virtual notch centered at the top; height follows the menu bar when it is visible.
            let menuBarHeight = frame.maxY - screen.visibleFrame.maxY
            let height = menuBarHeight > 0 ? min(max(menuBarHeight, 22), 44) : metrics.virtualNotchHeight
            let width = metrics.virtualNotchWidth
            notchRect = CGRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
            isVirtual = true
        }
    }

    /// Size of the visible shape for a state.
    public func contentSize(for state: NotchState) -> CGSize {
        switch state {
        case .collapsed:
            return notchRect.size
        case .peek:
            return CGSize(
                width: notchRect.width + 2 * metrics.peekWingWidth,
                height: notchRect.height + metrics.peekExtraHeight)
        case .expanded:
            let width = min(max(metrics.expandedSize.width, notchRect.width + 2 * metrics.peekWingWidth), screenFrame.width - 16)
            let height = min(metrics.expandedSize.height + notchRect.height, screenFrame.height / 2)
            return CGSize(width: width, height: height)
        }
    }

    /// Window frame for a state: top-aligned with the screen, horizontally centered on the notch,
    /// kept inside the screen.
    public func windowFrame(for state: NotchState) -> CGRect {
        let size = contentSize(for: state)
        var x = notchRect.midX - size.width / 2
        x = min(max(x, screenFrame.minX), screenFrame.maxX - size.width)
        return CGRect(x: x, y: screenFrame.maxY - size.height, width: size.width, height: size.height)
    }

    /// Hit area used to trigger hover expansion (slightly larger than the notch itself).
    public var hoverRect: CGRect { notchRect.insetBy(dx: -8, dy: 0) }
}
