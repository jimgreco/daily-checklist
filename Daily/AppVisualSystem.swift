import SwiftUI
import UIKit

private func ritualAdaptiveColor(
    light: (red: Double, green: Double, blue: Double),
    dark: (red: Double, green: Double, blue: Double)
) -> Color {
    Color(uiColor: UIColor { traits in
        let value = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(red: value.red, green: value.green, blue: value.blue, alpha: 1)
    })
}

enum RitualVisualSystem {
    enum ColorToken {
        static let ink = ritualAdaptiveColor(
            light: (0.10, 0.105, 0.15),
            dark: (0.95, 0.945, 0.98)
        )
        static let accent = ritualAdaptiveColor(
            light: (0.38, 0.30, 0.86),
            dark: (0.62, 0.56, 1.00)
        )
        static let canvas = ritualAdaptiveColor(
            light: (0.972, 0.958, 0.925),
            dark: (0.047, 0.044, 0.064)
        )
        static let surface = ritualAdaptiveColor(
            light: (1.00, 0.997, 0.985),
            dark: (0.102, 0.094, 0.135)
        )
        static let softSurface = ritualAdaptiveColor(
            light: (0.948, 0.932, 0.902),
            dark: (0.077, 0.071, 0.103)
        )
        static let controlSurface = ritualAdaptiveColor(
            light: (1.00, 0.998, 0.99),
            dark: (0.145, 0.135, 0.185)
        )
        static let subtleFill = ritualAdaptiveColor(
            light: (0.90, 0.875, 0.84),
            dark: (0.18, 0.17, 0.22)
        )
        static let line = ritualAdaptiveColor(
            light: (0.82, 0.79, 0.75),
            dark: (0.255, 0.235, 0.31)
        )
        static let accentSoft = ritualAdaptiveColor(
            light: (0.91, 0.885, 0.985),
            dark: (0.18, 0.155, 0.29)
        )
        static let success = ritualAdaptiveColor(
            light: (0.10, 0.52, 0.34),
            dark: (0.33, 0.86, 0.59)
        )
        static let open = ritualAdaptiveColor(
            light: (0.08, 0.45, 0.42),
            dark: (0.30, 0.85, 0.78)
        )
        static let warning = ritualAdaptiveColor(
            light: (0.72, 0.43, 0.05),
            dark: (1.00, 0.72, 0.28)
        )
        static let danger = ritualAdaptiveColor(
            light: (0.72, 0.20, 0.25),
            dark: (1.00, 0.45, 0.53)
        )
        static let mintSoft = ritualAdaptiveColor(
            light: (0.86, 0.95, 0.89),
            dark: (0.10, 0.22, 0.17)
        )
    }

    enum Spacing {
        static let xSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let standard: CGFloat = 16
        static let large: CGFloat = 20
        static let xLarge: CGFloat = 24
        static let section: CGFloat = 30
    }

    enum Radius {
        static let control: CGFloat = 14
        static let card: CGFloat = 24
        static let hero: CGFloat = 30
    }
}

// Compatibility aliases let the existing checklist move to the shared system
// without a behavior-changing rewrite.
let ink = RitualVisualSystem.ColorToken.ink
let accent = RitualVisualSystem.ColorToken.accent
let canvas = RitualVisualSystem.ColorToken.canvas
let surface = RitualVisualSystem.ColorToken.surface
let softSurface = RitualVisualSystem.ColorToken.softSurface
let controlSurface = RitualVisualSystem.ColorToken.controlSurface
let subtleFill = RitualVisualSystem.ColorToken.subtleFill
let success = RitualVisualSystem.ColorToken.success
let openState = RitualVisualSystem.ColorToken.open
let delayed = RitualVisualSystem.ColorToken.warning

let ritualLine = RitualVisualSystem.ColorToken.line
let accentSoft = RitualVisualSystem.ColorToken.accentSoft
let dangerColor = RitualVisualSystem.ColorToken.danger

struct RitualBackdrop: View {
    var body: some View {
        ZStack {
            canvas

            RadialGradient(
                colors: [accent.opacity(0.12), .clear],
                center: UnitPoint(x: 0.88, y: 0.02),
                startRadius: 6,
                endRadius: 430
            )

            RadialGradient(
                colors: [success.opacity(0.065), .clear],
                center: UnitPoint(x: 0.04, y: 0.72),
                startRadius: 12,
                endRadius: 360
            )

            LinearGradient(
                colors: [Color.white.opacity(0.05), .clear],
                startPoint: .top,
                endPoint: .center
            )
        }
        .accessibilityHidden(true)
    }
}

private struct RitualCardModifier: ViewModifier {
    let cornerRadius: Double
    let elevated: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: CGFloat(cornerRadius), style: .continuous)

        content
            .background(shape.fill(surface))
            .overlay {
                shape.stroke(ritualLine.opacity(0.72), lineWidth: 1)
            }
            .shadow(
                color: elevated ? Color.black.opacity(0.10) : .clear,
                radius: elevated ? 18 : 0,
                y: elevated ? 9 : 0
            )
    }
}

extension View {
    func ritualCard(cornerRadius: Double = 24, elevated: Bool = false) -> some View {
        modifier(RitualCardModifier(cornerRadius: cornerRadius, elevated: elevated))
    }
}

struct RitualSectionLabel: View {
    let title: String
    let systemImage: String
    var tint: Color = accent

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(ink)
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
        .font(.subheadline.weight(.bold))
        .symbolRenderingMode(.hierarchical)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RitualFormSectionHeader: View {
    let title: String
    let systemImage: String

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(accent)
            .textCase(nil)
    }
}

struct RitualInlineMessage: View {
    enum Tone {
        case neutral
        case success
        case warning
        case danger

        fileprivate var color: Color {
            switch self {
            case .neutral: accent
            case .success: RitualVisualSystem.ColorToken.success
            case .warning: RitualVisualSystem.ColorToken.warning
            case .danger: RitualVisualSystem.ColorToken.danger
            }
        }

        fileprivate var systemImage: String {
            switch self {
            case .neutral: "info.circle.fill"
            case .success: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .danger: "xmark.octagon.fill"
            }
        }
    }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Label(text, systemImage: tone.systemImage)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(tone.color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(tone.color.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(tone.color.opacity(0.20), lineWidth: 1)
            }
    }
}
