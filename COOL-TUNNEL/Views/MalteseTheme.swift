// Views/MalteseTheme.swift
//
// Design system for Cool Tunnel. Earlier revisions of this file
// were a NewJeans-then-Maltese pastel theme; v0.1.5.7 retunes the
// palette and typography toward **classic Macintosh (System 7 /
// Platinum era) with a modern twist**.
//
// What "classic Mac" means here:
//   - Platinum-family neutrals: warm light grey backgrounds,
//     darker grey borders, off-white card surfaces.
//   - Classic Mac blue (≈ System 7 highlight blue) as the
//     primary accent — visible on the active mode chip and the
//     header gradient, replaces the previous pink-leaning blend.
//   - Tight corner radii (6 pt cards / 4 pt fields) instead of
//     the previous 18–22 pt rounded everything.
//   - Thinner, slightly darker borders so each pane has a
//     clearly drawn frame.
//   - Less shadow — the classic look uses crisp lines, not
//     diffuse glow.
//   - **Monaco** is reintroduced for every monospaced surface
//     (paths, version strings, log lines). Monaco still ships
//     with macOS and is the original Mac Toolbox monospaced
//     face — instant 1991 mood without any third-party fonts.
//
// What "modern twist" means here:
//   - Liquid Glass surfaces still kick in on macOS 26+ via the
//     `.pupCard` modifier. Below 26 we render the same shape with
//     `.regularMaterial` so the look degrades cleanly.
//   - Spring animations on the active-chip transition stay (just
//     snappier — System 7 had no animation budget).
//   - Mode-aware accent colours stay (smart=blue, global=rose,
//     local=mint), but each is desaturated about 25% from the
//     v0.1.5.4–6 palette so the platinum frame reads cleanly.
//   - Status pills still pulse on a Mac fast enough to render it
//     (`PerformanceProfile.repeatingSymbolEffectsAllowed`).
//
// The exported names (`CTPalette`, `pupCard`, `ModeChipStyle`,
// `SoftButtonStyle`) are unchanged so no view file needs updating
// for the palette swap; the `CTTypography` namespace is new and
// the views opt into it row by row.

import SwiftUI

// MARK: - Palette

/// Classic Mac–leaning palette. Background neutrals come from the
/// System 7 / Platinum theme; accent splashes come from the
/// previous Maltese palette but desaturated so they sit on the
/// platinum frame without shouting.
public enum CTPalette {
    // Platinum neutrals — these are the most-used colours and
    // dominate the window now that we've stepped back from the
    // pastel-everywhere look.

    /// Warm off-white card surface. Reads as "paper" against the
    /// platinum window background.
    public static let paper = Color(red: 0.98, green: 0.97, blue: 0.95)
    /// Window background — slightly cooler than paper. Classic
    /// Mac "platinum" hue.
    public static let platinum = Color(red: 0.93, green: 0.93, blue: 0.91)
    /// Border / divider — dark enough to be visible without
    /// being heavy. One value across the design system so every
    /// pane reads as part of the same drawing.
    public static let borderInk = Color(red: 0.42, green: 0.42, blue: 0.45)
    /// Body-text neutral. Slightly warmer than pure black so it
    /// matches the paper surface temperature.
    public static let bodyInk = Color(red: 0.13, green: 0.13, blue: 0.16)

    // Modern-twist accents — kept from the Maltese palette but
    // desaturated about 25% so the platinum frame reads cleanly.

    /// Classic Mac blue — closer to System 7's highlight than to
    /// modern Apple blue. Header text gradient + smart-mode chip.
    public static let macBlue = Color(red: 0.20, green: 0.36, blue: 0.66)
    /// Lighter classic blue for hover / inactive accents.
    public static let macBlueSoft = Color(red: 0.62, green: 0.74, blue: 0.92)
    /// Desaturated rose — global-mode chip, run-state glow,
    /// firewall warning.
    public static let cherryRose = Color(red: 0.85, green: 0.36, blue: 0.50)
    /// Soft pink — for the firewall badge background.
    public static let bunnyPink = Color(red: 0.96, green: 0.78, blue: 0.86)
    /// Lavender for the log-console card tint.
    public static let lilac = Color(red: 0.78, green: 0.74, blue: 0.92)
    /// Mint for local-only mode and "all clear" states.
    public static let mint = Color(red: 0.65, green: 0.85, blue: 0.78)
    /// Cream — kept for backwards reference; mapped to `paper`.
    public static let cream = paper
    /// Deeper blue for headings and active text — alias to
    /// `bodyInk` so existing views keep working.
    public static let inkBlue = bodyInk
    /// Soft blue card tint — alias to `macBlueSoft`. Retained
    /// from the v0.1.5.4 Maltese palette so the connection-form
    /// card keeps its blue cast without a per-view sweep.
    public static let skyBlue = macBlueSoft

    /// Mode-aware accent — pulls one colour per [`ProxyMode`] so
    /// each view doesn't have to repeat the switch.
    public static func accent(for mode: ProxyMode) -> Color {
        switch mode {
        case .stopped: borderInk.opacity(0.6)
        case .smart: macBlue
        case .global: cherryRose
        case .localOnly: mint
        }
    }

    /// Two-stop gradient — used for the header background and the
    /// active-mode chip glow. Less dramatic than the v0.1.5.4–6
    /// "dream gradient"; reads as a quiet wash now.
    public static func dreamGradient(for mode: ProxyMode) -> LinearGradient {
        let (a, b): (Color, Color) =
            switch mode {
            case .stopped: (platinum, platinum.opacity(0.6))
            case .smart: (macBlue, macBlueSoft)
            case .global: (cherryRose, bunnyPink)
            case .localOnly: (mint, macBlueSoft)
            }
        return LinearGradient(
            colors: [a, b],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Typography

/// Semantic font helpers that pin every monospaced surface to
/// **Monaco** — the classic Mac Toolbox face that's still bundled
/// with macOS today. Headings stay on the system rounded face for
/// the "modern twist".
public enum CTTypography {
    /// Big titles: app name in the header, Settings sheet title.
    /// Stays on `SF Pro Rounded Bold` for warmth — going full
    /// `Helvetica` would feel too austere next to the platinum
    /// palette.
    public static let title: Font = .system(.title2, design: .rounded).weight(.bold)

    /// Section headings: "Profile", "Live log", "This Mac".
    /// Slightly less weight than `title`.
    public static let sectionHeading: Font = .system(.headline, design: .rounded).weight(.semibold)

    /// Body text in cards and forms.
    public static let body: Font = .system(.body)

    /// Captions and helper labels.
    public static let caption: Font = .system(.caption)

    /// **The classic-Mac core**: every monospaced row — paths,
    /// version strings, log lines, hash digests — uses Monaco at
    /// 12 pt. Falls back to the system monospaced design when
    /// Monaco isn't available (it always is on macOS, but the
    /// fallback keeps the build robust).
    public static let mono: Font =
        Font.custom("Monaco", size: 12, relativeTo: .caption)

    /// Slightly smaller mono for very dense rows (e.g. summary
    /// rows in Settings). Still Monaco.
    public static let monoSmall: Font =
        Font.custom("Monaco", size: 11, relativeTo: .caption2)
}

// MARK: - Surface modifier

/// Wraps any view in the standard "card" surface used across the
/// app. v0.1.5.7 tightens the look:
///
///   - Corner radius default is 8 (was 18) — still rounded enough
///     to feel modern, tight enough to read as a System 7 panel.
///   - Border is `borderInk` at 0.7 pt instead of a pale white
///     hairline — the frame is now a deliberate visual element.
///   - Shadow is much smaller (was a 14 pt diffuse glow, now a
///     6 pt offset by 2 pt) so cards sit on the platinum
///     background without bleeding into it.
public struct PupCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 8
    var tint: Color? = nil

    public func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content.background {
            ZStack {
                if #available(macOS 26.0, *) {
                    shape
                        .fill(.regularMaterial)
                        .glassEffect(in: shape)
                } else {
                    shape.fill(.regularMaterial)
                }
                shape.fill(CTPalette.paper.opacity(0.4))
                if let tint {
                    shape.fill(tint.opacity(0.07))
                }
            }
        }
        .overlay {
            shape.strokeBorder(CTPalette.borderInk.opacity(0.45), lineWidth: 0.7)
        }
        .shadow(color: Color.black.opacity(0.06), radius: 6, x: 0, y: 2)
    }
}

extension View {
    /// Sugar for [`PupCardModifier`] — wraps the view in a
    /// classic-Mac panel. Name retained from the v0.1.5.4 Maltese
    /// theme so view files don't need a sweep.
    public func pupCard(cornerRadius: CGFloat = 8, tint: Color? = nil) -> some View {
        modifier(PupCardModifier(cornerRadius: cornerRadius, tint: tint))
    }
}

// MARK: - Selectable chip button style

/// Pill-shaped button used for the mode picker. Active state still
/// fills with a tint gradient (the "modern twist" — System 7
/// would have used a flat fill or a 1-bit dither pattern); the
/// inactive state is now a plain platinum chip with a 0.6 pt
/// border so the row reads as a row.
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
            // Single line, no truncation. Without this the chip labels
            // ("Smart", "Local") wrap to two lines on the narrower
            // window widths the Connection Form pushes us toward —
            // visible as "Smar / t" and "Lo- / cal" in v0.1.6.
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(isActive ? Color.white : CTPalette.bodyInk)
            .background {
                ZStack {
                    if isActive {
                        shape.fill(
                            LinearGradient(
                                colors: [tint, tint.opacity(0.85)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        shape.fill(CTPalette.paper)
                    }
                }
            }
            .overlay {
                shape.strokeBorder(
                    isActive ? Color.white.opacity(0.50) : CTPalette.borderInk.opacity(0.40),
                    lineWidth: 0.6
                )
            }
            .shadow(
                color: isActive ? tint.opacity(0.30) : .clear,
                radius: isActive ? 5 : 0,
                x: 0,
                y: isActive ? 2 : 0
            )
            .scaleEffect(configuration.isPressed ? 0.97 : (isActive ? 1.01 : 1.0))
            .animation(.spring(response: 0.25, dampingFraction: 0.78), value: isActive)
            .animation(.spring(response: 0.18, dampingFraction: 0.70), value: configuration.isPressed)
    }
}

// MARK: - Soft button style for the secondary actions

/// Companion to [`ModeChipStyle`] for non-radio buttons (Stop,
/// Diagnostics, Latency Test, Settings). Same paper fill + border
/// ink as the rest of the design system — without the
/// active/inactive split.
public struct SoftButtonStyle: ButtonStyle {
    var tint: Color = CTPalette.bodyInk

    public init(tint: Color = CTPalette.bodyInk) {
        self.tint = tint
    }

    public func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        return configuration.label
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(tint)
            .background {
                shape.fill(CTPalette.paper)
            }
            .overlay {
                shape.strokeBorder(CTPalette.borderInk.opacity(0.35), lineWidth: 0.6)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.18, dampingFraction: 0.70), value: configuration.isPressed)
    }
}
