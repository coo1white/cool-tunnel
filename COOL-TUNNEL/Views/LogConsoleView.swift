// Views/LogConsoleView.swift
//
// Live log view: stream of `LogEntry` values with auto-scroll and a
// clear button. v0.1.5.4 redesign: log surface sits inside the same
// Liquid Glass card as the rest of the app, ms-timed entries are
// monospaced, stderr lines tinted cherry-rose to stand out without
// shouting.

import SwiftUI

/// Live engine log: streams `LogEntry` values from the orchestrator
/// with auto-scroll, monospaced rendering (Monaco), and stderr lines
/// tinted cherry-rose. Empty state shows a friendly "waiting for
/// the first log line" placeholder instead of a blank rectangle.
public struct LogConsoleView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Environment(\.colorScheme) private var colorScheme

    /// Inner-scrollview surface fill. The previous flat
    /// `paper.opacity(0.55)` made the log surface read as a
    /// *highlighted* lighter rectangle in dark mode (because
    /// `paper`'s dark variant is itself a card-like dark
    /// colour, and 0.55 on top of the parent card composited
    /// LIGHTER than the surround). Inverted in dark mode: a
    /// black overlay at 35% recesses the surface so it reads
    /// as a sunken log area in both modes.
    private var logSurfaceFill: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.35)
            : CTPalette.paper.opacity(0.55)
    }

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "scroll")
                    .font(.system(size: 14))
                    .foregroundStyle(CTPalette.cherryRose)
                Text("Live log")
                    .font(.system(.headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(CTPalette.inkBlue)
                Spacer()
                Text("\(orchestrator.logEntries.count) lines")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Button("Clear") {
                    orchestrator.clearLogs()
                }
                .buttonStyle(SoftButtonStyle(tint: CTPalette.inkBlue))
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if orchestrator.logEntries.isEmpty {
                            emptyState
                        } else {
                            ForEach(orchestrator.logEntries) { entry in
                                row(for: entry)
                            }
                        }
                        Color.clear.frame(height: 1).id("__bottom__")
                    }
                    .padding(10)
                }
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(logSurfaceFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CTPalette.borderInk.opacity(0.40), lineWidth: 0.7)
                }
                .onChange(of: orchestrator.logEntries.count) { _, _ in
                    // Skip the scroll animation on the `.light`
                    // performance tier (older Intel hardware) — the
                    // 100ms linear curve compounds badly under
                    // high log volume because every appended line
                    // queues another animated scroll. The static
                    // jump-to-bottom keeps the UI usable.
                    if PerformanceProfile.current.repeatingSymbolEffectsAllowed {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("__bottom__", anchor: .bottom)
                        }
                    } else {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        // Mode-aware tint — matches the header pill so the whole
        // window reads as one mood. See ConnectionFormView for the
        // same pattern.
        .pupCard(cornerRadius: 8, tint: CTPalette.accent(for: orchestrator.activeMode))
    }

    /// Friendly placeholder when no log lines have arrived yet — the
    /// blank dark rectangle from earlier versions read as "broken"
    /// even though it's the empty-and-fine state.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(CTPalette.cherryRose)
                // Pulse is gated by the same performance tier the
                // header status pill uses, so older Intel hardware
                // doesn't burn GPU on a continuously animating
                // empty-state placeholder.
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: PerformanceProfile.current.repeatingSymbolEffectsAllowed
                )
            Text("Waiting for the first log line…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    private func row(for entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(CTTypography.monoSmall)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(entry.text)
                .font(CTTypography.monoSmall)
                .foregroundStyle(entry.source == .stderr ? CTPalette.cherryRose : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
