import SwiftUI

/// Notch silhouette with continuous curvature.
///
/// The four "corners" use cubic curves with a subtle tangent overshoot so the
/// shape reads as one fluid contour rather than four discrete arcs — this is
/// the same trick Apple uses for the physical notch and the Dynamic Island.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let top = max(0, topRadius)
        let bottom = max(0, bottomRadius)
        // "Squircle factor" — moves Bézier control points outward so the curve
        // is G2 continuous (looks like the notch on a real MacBook).
        let k: CGFloat = 0.55

        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))

        // Top-left inner shoulder
        p.addCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control1: CGPoint(x: rect.minX + top * k, y: rect.minY),
            control2: CGPoint(x: rect.minX + top, y: rect.minY + top * (1 - k))
        )

        // Left wall
        p.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))

        // Bottom-left outer shoulder
        p.addCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control1: CGPoint(x: rect.minX + top, y: rect.maxY - bottom * (1 - k)),
            control2: CGPoint(x: rect.minX + top + bottom * k, y: rect.maxY)
        )

        // Bottom edge
        p.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))

        // Bottom-right outer shoulder
        p.addCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control1: CGPoint(x: rect.maxX - top - bottom * k, y: rect.maxY),
            control2: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom * (1 - k))
        )

        // Right wall
        p.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))

        // Top-right inner shoulder
        p.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rect.maxX - top, y: rect.minY + top * (1 - k)),
            control2: CGPoint(x: rect.maxX - top * k, y: rect.minY)
        )

        p.closeSubpath()
        return p
    }
}
