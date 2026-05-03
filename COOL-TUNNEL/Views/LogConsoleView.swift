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
                        .fill(CTPalette.paper.opacity(0.55))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(CTPalette.borderInk.opacity(0.40), lineWidth: 0.7)
                }
                .onChange(of: orchestrator.logEntries.count) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        }
        .padding(16)
        .pupCard(cornerRadius: 8, tint: CTPalette.lilac)
    }

    /// Friendly placeholder when no log lines have arrived yet — the
    /// blank dark rectangle from earlier versions read as "broken"
    /// even though it's the empty-and-fine state.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(CTPalette.bunnyPink)
                .symbolEffect(.pulse, options: .repeating)
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
