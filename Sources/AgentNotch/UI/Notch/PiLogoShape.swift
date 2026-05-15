import SwiftUI

/// Pi's official wordmark glyph rendered as a SwiftUI `Shape`.
///
/// Direct port of `pi-logo-on-dark.svg` (viewBox 0 0 800 800) — vector path
/// preserved exactly so it stays sharp at every harness icon size and
/// matches Pi's published mark byte-for-byte. Keeping it as code rather than
/// a bundled image avoids a `.xcassets` round-trip and means the glyph
/// inherits SwiftUI styling (foregroundStyle, opacity, etc.) like any
/// other shape.
///
/// Use `.fill(style: FillStyle(eoFill: true))` so the inner sub-path of the
/// pi letterform is rendered as a hole (matches the SVG's
/// `fill-rule="evenodd"`).
struct PiLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        // Maintain aspect ratio inside `rect` and center.
        let scale = min(rect.width, rect.height) / 800
        let drawSize = 800 * scale
        let originX = rect.minX + (rect.width - drawSize) / 2
        let originY = rect.minY + (rect.height - drawSize) / 2

        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }

        var path = Path()

        // Outer pi letterform (top bar + left leg).
        path.move(to: p(165.29, 165.29))
        path.addLine(to: p(517.36, 165.29))
        path.addLine(to: p(517.36, 400))
        path.addLine(to: p(400, 400))
        path.addLine(to: p(400, 517.36))
        path.addLine(to: p(282.65, 517.36))
        path.addLine(to: p(282.65, 634.72))
        path.addLine(to: p(165.29, 634.72))
        path.closeSubpath()

        // Inner notch — under-bar negative space inside the letterform.
        // Renders as a hole when the path is filled with .eoFill.
        path.move(to: p(282.65, 282.65))
        path.addLine(to: p(282.65, 400))
        path.addLine(to: p(400, 400))
        path.addLine(to: p(400, 282.65))
        path.closeSubpath()

        // Detached right leg block.
        path.move(to: p(517.36, 400))
        path.addLine(to: p(634.72, 400))
        path.addLine(to: p(634.72, 634.72))
        path.addLine(to: p(517.36, 634.72))
        path.closeSubpath()

        return path
    }
}
