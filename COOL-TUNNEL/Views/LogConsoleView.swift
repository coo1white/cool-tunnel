// Views/LogConsoleView.swift
//
// Live log view: stream of `LogEntry` values with auto-scroll and a clear
// button. Distinct colour for stderr lines.

import SwiftUI

public struct LogConsoleView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Live log").font(.headline)
                Spacer()
                Text("\(orchestrator.logEntries.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Clear") {
                    orchestrator.clearLogs()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.12))
                )
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(orchestrator.logEntries) { entry in
                            row(for: entry)
                        }
                        Color.clear.frame(height: 1).id("__bottom__")
                    }
                    .padding(8)
                }
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.black.opacity(0.05))
                )
                .onChange(of: orchestrator.logEntries.count) { _, _ in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func row(for entry: LogEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)

            Text(entry.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(entry.source == .stderr ? .red : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
