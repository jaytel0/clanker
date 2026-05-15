import SwiftUI

struct NotchRowChrome: ViewModifier {
    let hovering: Bool
    var accentColor: Color?
    var restingOpacity: Double = 0.045
    var hoverOpacity: Double = 0.07
    var accentedRestingOpacity: Double?
    var showsAccentWash = false
    var accentShadowOpacity: Double = 0.6

    func body(content: Content) -> some View {
        content
            .background(background)
            .overlay(alignment: .leading) {
                if let accentColor {
                    Capsule(style: .continuous)
                        .fill(accentColor)
                        .frame(width: 2.5)
                        .padding(.vertical, 9)
                        .shadow(color: accentColor.opacity(accentShadowOpacity), radius: 4)
                }
            }
            .scaleEffect(hovering ? 1.012 : 1.0)
            .animation(NotchMotion.hover, value: hovering)
    }

    private var background: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        let opacity = backgroundOpacity

        return ZStack {
            shape.fill(.white.opacity(opacity))

            if showsAccentWash, let accentColor {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                accentColor.opacity(0.10),
                                accentColor.opacity(0.0)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
            }

            shape.stroke(.white.opacity(0.05), lineWidth: 0.5)
        }
    }

    private var backgroundOpacity: Double {
        if hovering { return hoverOpacity }
        if accentColor != nil, let accentedRestingOpacity {
            return accentedRestingOpacity
        }
        return restingOpacity
    }
}

extension View {
    func notchRowChrome(
        hovering: Bool,
        accentColor: Color? = nil,
        restingOpacity: Double = 0.045,
        hoverOpacity: Double = 0.07,
        accentedRestingOpacity: Double? = nil,
        showsAccentWash: Bool = false,
        accentShadowOpacity: Double = 0.6
    ) -> some View {
        modifier(
            NotchRowChrome(
                hovering: hovering,
                accentColor: accentColor,
                restingOpacity: restingOpacity,
                hoverOpacity: hoverOpacity,
                accentedRestingOpacity: accentedRestingOpacity,
                showsAccentWash: showsAccentWash,
                accentShadowOpacity: accentShadowOpacity
            )
        )
    }
}
