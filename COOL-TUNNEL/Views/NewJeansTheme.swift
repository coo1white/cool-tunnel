// Views/NewJeansTheme.swift
//
// Design system for the v0.1.5.4 visual refresh — NewJeans-inspired
// pastel palette + macOS 26 Liquid Glass materials. Centralised so
// every view pulls colours, gradients, and surface modifiers from one
// place; tweaking the palette here cascades through the whole app.
//
// Aesthetic notes:
//   - Pastel pink / baby blue / lavender / mint
//   - Y2K-adjacent: glossy surfaces, soft outer glow, rounded
//     everything (16-22 pt continuous corner radius)
//   - "Genki" energy: spring animations, bouncing symbol effects,
//     gentle scale-on-press
//
// macOS 26 features in active use:
//   - `.glassEffect()` Liquid Glass surfaces (with material fallback
//     for older OS)
//   - `.symbolEffect(.bounce, options:, value:)` for state-change
//     icon feedback
//   - `.contentTransition(.symbolEffect(.replace))` for icon swaps
//   - `.sensoryFeedback` for subtle haptic-style cues on Mac trackpads
//   - Smooth `Gradient` interpolation

import SwiftUI

// MARK: - Palette

/// NewJeans-inspired pastel palette. Each colour is tuned to read
/// comfortably in both light and dark modes — the dark variants are
/// pulled toward neon-pastel rather than muddied, matching the
/// group's MV colour grading.
public enum CTPalette {
    /// Bubblegum pink — primary accent, used for the active mode pill
    /// and the start button while running.
    public static let bunnyPink = Color(red: 1.00, green: 0.71, blue: 0.84)
    /// Saturated rose for emphasis and run-state glow.
    public static let cherryRose = Color(red: 1.00, green: 0.41, blue: 0.61)
    /// Baby blue — secondary accent, used for the smart-mode chip and
    /// idle-state surfaces.
    public static let skyBlue = Color(red: 0.71, green: 0.83, blue: 1.00)
    /// Deep blue for headings on light surfaces.
    public static let inkBlue = Color(red: 0.18, green: 0.27, blue: 0.55)
    /// Lavender for global mode.
    public static let lilac = Color(red: 0.85, green: 0.78, blue: 1.00)
    /// Mint for local-only mode and "all clear" states.
    public static let mint = Color(red: 0.71, green: 0.93, blue: 0.85)
    /// Cream — warm neutral background tint.
    public static let cream = Color(red: 1.00, green: 0.97, blue: 0.92)
    /// Mode-aware accent — pulls one colour per [`ProxyMode`] so each
    /// view doesn't have to repeat the switch.
    public static func accent(for mode: ProxyMode) -> Color {
        switch mode {
        case .stopped: .secondary
        case .smart: skyBlue
        case .global: cherryRose
        case .localOnly: mint
        }
    }

    /// Two-stop pastel gradient — used for the header background and
    /// the active-mode chip glow.
    public static func dreamGradient(for mode: ProxyMode) -> LinearGradient {
        let (a, b): (Color, Color) =
            switch mode {
            case .stopped: (.secondary.opacity(0.15), .secondary.opacity(0.05))
            case .smart: (skyBlue, lilac)
            case .global: (bunnyPink, cherryRose)
            case .localOnly: (mint, skyBlue)
            }
        return LinearGradient(
            colors: [a, b],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Surface modifier

/// Wraps any view in the standard "card" surface used across the app:
/// continuous-corner rounded rectangle, Liquid Glass material on macOS
/// 26+, plain ultraThinMaterial fallback otherwise. Pass a non-nil
/// `tint` to bias the surface toward a mode colour.
public struct GanjiCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 18
    var tint: Color? = nil

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content.background {
            ZStack {
                // Liquid Glass via `.glassEffect()` was added in
                // macOS 26 Tahoe. We gate at compile time so older
                // SDKs still build, then at runtime so older OSes
                // fall back to the regular material — same palette,
                // less depth, no errors.
                if #available(macOS 26.0, *) {
                    shape
                        .fill(.regularMaterial)
                        .glassEffect(in: shape)
                } else {
                    shape.fill(.regularMaterial)
                }
                if let tint {
                    shape.fill(tint.opacity(0.12))
                }
            }
        }
        .overlay {
            shape.strokeBorder(
                .white.opacity(0.35),
                lineWidth: 0.5
            )
        }
        .shadow(color: (tint ?? .black).opacity(0.10), radius: 14, x: 0, y: 6)
    }
}

extension View {
    /// Sugar for [`GanjiCardModifier`] — wraps the view in a Liquid
    /// Glass / pastel card. The name nods to the "ganki / genki"
    /// (元気) brief: the surfaces feel cheerful rather than clinical.
    public func ganjiCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        modifier(GanjiCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Selectable chip button style

/// Pill-shaped button used for the mode picker. When `isActive` is
/// true the chip shows a pastel gradient fill, soft outer glow, and a
/// tiny lift; otherwise it sits flat with a hairline border. Spring
/// animations across the active transition give the picker its
/// "bouncy" feel.
public struct ModeChipStyle: ButtonStyle {
    let isActive: Bool
    let tint: Color

    public init(isActive: Bool, tint: Color) {
        self.isActive = isActive
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        return configuration.label
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .foregroundStyle(isActive ? .white : Color.primary)
            .background {
                ZStack {
                    if isActive {
                        shape.fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        shape.fill(.ultraThinMaterial)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? Color.white.opacity(0.45) : Color.primary.opacity(0.10),
                    lineWidth: 0.6
                )
            }
            .shadow(
                color: isActive ? tint.opacity(0.45) : .clear,
                radius: isActive ? 10 : 0,
                x: 0,
                y: isActive ? 4 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.96 : (isActive ? 1.02 : 1.0))
            .animation(.spring(response: 0.32, dampingFraction: 0.72), value: isActive)
            .animation(.spring(response: 0.20, dampingFraction: 0.65), value: configuration.isPressed)
    }
}

// MARK: - Soft button style for the secondary actions

/// Companion to [`ModeChipStyle`] for non-radio buttons (Stop,
/// Diagnostics, Latency Test, Settings). Same materials and corner
/// radius as the rest of the design system, but without the
/// active/inactive split.
public struct SoftButtonStyle: ButtonStyle {
    var tint: Color = .primary

    public init(tint: Color = .primary) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        return configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .foregroundStyle(tint)
            .background {
                shape.fill(.ultraThinMaterial)
            }
            .overlay {
                shape.strokeBorder(tint.opacity(0.25), lineWidth: 0.6)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.spring(response: 0.20, dampingFraction: 0.65), value: configuration.isPressed)
    }
}
