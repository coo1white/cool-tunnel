// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/Components/UIComponents.swift
//
// Tiny shared building blocks for the compact macOS-utility look.
// Three pieces that previously lived as one-off inline code across
// the view layer:
//
//   - `IconBarButton`        — fixed-frame bordered icon button so a
//                              row of SF Symbols (different intrinsic
//                              glyph widths) lines up evenly and does
//                              not shift when adjacent state toggles.
//   - `VerdictPill`          — OK / NG / info pill with a calm
//                              rounded-rect background. Hoisted out
//                              of SettingsView, which previously had
//                              four near-identical copies.
//   - `SummaryRow`           — fixed-label-column metadata row
//                              (label · value). Hoisted out of
//                              SettingsView's naive + rust sections.
//
// All three are layout-stable: dimensions are derived from intrinsic
// content of fixed-shape inputs, and decorative borders / fills are
// applied via `.background { … }` or `.overlay { … }` so changing
// state never reflows the surrounding row. The brief calls this
// out as a non-negotiable — borders that change layout are
// fragile UI and we don't want them.

import SwiftUI

// MARK: - Icon-only bar button

/// Fixed-size bordered icon button used by the main-window toolbar
/// and any future icon row that needs to read as an even cluster
/// of equally-sized squares. The `.bordered` button style sizes
/// to glyph width by default, which produces a visually uneven row
/// when the glyphs differ — `stethoscope` is narrow,
/// `network.badge.shield.half.filled` is wide. The fixed frame
/// forces a stable hit target and a stable visual column so the
/// row no longer "jumps" when a button enables / disables or
/// when its system image is swapped at runtime.
///
/// **Why a wrapper and not a `ViewModifier`:** the modifier would
/// still need to wrap the underlying `Button` to inject the frame
/// onto the Label — at which point a value-type wrapper is the
/// same shape with less indirection.
public struct IconBarButton: View {
    public let systemImage: String
    public let help: String
    public let accessibilityLabel: String
    public let isEnabled: Bool
    public let action: () -> Void

    public init(
        systemImage: String,
        help: String,
        accessibilityLabel: String,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.help = help
        self.accessibilityLabel = accessibilityLabel
        self.isEnabled = isEnabled
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
        .frame(width: 30, height: 22)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(accessibilityLabel)
    }
}

// MARK: - Verdict pill

/// Quiet status pill with a leading SF Symbol, a short tag
/// ("OK" / "NG" / a custom word), a middot, and a single-line
/// message. The pill carries a soft tinted background sized to
/// the content; the row above and below sees only the pill's
/// natural height, so swapping verdict colour or text does not
/// shift the surrounding form.
///
/// **Mode-aware alpha:** previously hard-coded as `pillAlpha` on
/// `SettingsView` (0.10 light / 0.22 dark). Hoisted here so every
/// pill across the app reads the same — the dark variant ramps
/// brighter so the green/red fill stays legible against
/// `.windowBackground`. The colour is resolved from
/// `@Environment(\.colorScheme)`, so light/dark switches via
/// `NSApp.appearance` repaint without any view rebuild.
public struct VerdictPill: View {
    public enum Kind {
        case ok
        case ng
        /// Neutral informational variant — quaternary fill, no
        /// success / failure colour. Used by the updater progress
        /// strip.
        case neutral
    }

    @Environment(\.colorScheme) private var colorScheme

    public let kind: Kind
    public let tag: String?
    public let message: String
    public let systemImage: String?
    public let messageLineLimit: Int

    public init(
        kind: Kind,
        tag: String? = nil,
        message: String,
        systemImage: String? = nil,
        messageLineLimit: Int = 1
    ) {
        self.kind = kind
        self.tag = tag
        self.message = message
        self.systemImage = systemImage
        self.messageLineLimit = messageLineLimit
    }

    public var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(iconTint)
                    .accessibilityHidden(true)
            }
            if let tag {
                Text(tag)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(iconTint)
            }
            if tag != nil {
                Text("·")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(messageLineLimit)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(backgroundFill)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconTint: Color {
        switch kind {
        case .ok: return .green
        case .ng: return .red
        case .neutral: return .secondary
        }
    }

    private var backgroundFill: Color {
        let alpha: Double = colorScheme == .dark ? 0.22 : 0.10
        switch kind {
        case .ok: return Color.green.opacity(alpha)
        case .ng: return Color.red.opacity(alpha)
        case .neutral: return Color.gray.opacity(alpha * 0.6)
        }
    }

    private var accessibilityLabel: String {
        switch (tag, kind) {
        case (let tag?, _):
            return "\(tag). \(message)"
        case (nil, .ok):
            return "OK. \(message)"
        case (nil, .ng):
            return "Problem. \(message)"
        case (nil, .neutral):
            return message
        }
    }
}

// MARK: - Summary row

/// Two-column "label · value" row with a fixed-width label gutter
/// on the leading edge. Used by the naive + rust diagnostic
/// sections to render Path / Architectures / Version / Host slice
/// rows in a consistent grid.
///
/// The label column width is a free parameter so the same row
/// shape can be re-used at a tighter 70 pt gutter (machine detail)
/// and a looser 90 pt gutter (binary diagnostics). The value
/// column truncates with `.middle` so a long absolute path keeps
/// its leading and trailing segments visible.
public struct SummaryRow: View {
    public let label: String
    public let value: String
    public let monospaced: Bool
    public let labelWidth: CGFloat

    public init(
        label: String,
        value: String,
        monospaced: Bool = false,
        labelWidth: CGFloat = 90
    ) {
        self.label = label
        self.value = value
        self.monospaced = monospaced
        self.labelWidth = labelWidth
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(value)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}
