import SwiftUI

/// Notch silhouette: small outward curves at the top edge (merging into the menu bar) and
/// rounded bottom corners. Both radii are animatable so state transitions morph smoothly.
public struct NotchShape: Shape {
    public var topRadius: CGFloat
    public var bottomRadius: CGFloat
    /// When false, the path is open at the top: only the sides and the bottom, for an outline
    /// that merges into the menu bar.
    public var closedTop: Bool

    public init(topRadius: CGFloat = 6, bottomRadius: CGFloat = 10, closedTop: Bool = true) {
        self.topRadius = topRadius
        self.bottomRadius = bottomRadius
        self.closedTop = closedTop
    }

    public var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    public func path(in rect: CGRect) -> Path {
        let top = min(topRadius, rect.width / 4)
        let bottom = min(bottomRadius, (rect.width - 2 * top) / 2, rect.height / 2)
        var path = Path()
        if closedTop {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            // Top-left outward curve.
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top, y: rect.minY + top),
                control: CGPoint(x: rect.minX + top, y: rect.minY))
        } else {
            path.move(to: CGPoint(x: rect.minX + top, y: rect.minY + top))
        }
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        guard closedTop else { return path }
        // Top-right outward curve.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY))
        path.closeSubpath()
        return path
    }
}
