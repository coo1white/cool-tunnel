// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Views/LogConsoleView.swift
//
// **Phase 2.3 (v0.2):** the live log gains a real export
// pipeline — text filter, copy-all, save-to-file, share, and
// drag-out — plus per-row context menus for copying single
// lines. Closes the audit's "logs are a monospace wall with
// no way to extract them for support tickets" finding (P2 #13).
//
// Header layout:
//
//   [scroll │ Live log] [filter field] [count] [⋯ menu]
//   ^drag handle
//
//   - The scroll icon is `.draggable(logAsText)`. Dragging it
//     onto TextEdit / Mail / Slack drops the log as plain text.
//     Distinct from the scroll-content gesture so the trackpad
//     can still scroll the log surface.
//   - The filter field narrows visible rows by case-insensitive
//     substring match on the entry text. Count reads
//     "X of Y" while filtering, "X lines" otherwise.
//   - The ⋯ menu collects Copy All (⌘⇧C), Save to File…
//     (`.fileExporter` writing UTF-8 plain text), Share…
//     (`ShareLink` over the log text), and Clear.
//
// Each row gets a context menu with Copy Line and Copy with
// Timestamp — matches Console.app and Xcode's debugger console.

import AppKit
import SwiftUI
import UniformTypeIdentifiers
import os

/// Live engine log: streams `LogEntry` values from the
/// orchestrator with auto-scroll, monospaced rendering, and
/// stderr lines tinted `.red`. Empty state shows a friendly
/// "waiting for the first log line" placeholder; an empty
/// filter shows a dedicated "no matches" state with a
/// Clear-filter shortcut.
public struct LogConsoleView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    /// **Phase 2.4 (v0.2):** honour the user's "Reduce motion"
    /// preference (System Settings → Accessibility → Display).
    /// Pre-2.4 the empty-state pulse and the auto-scroll
    /// animation were gated only on `PerformanceProfile`
    /// (hardware tier), which let animation run on a fast Mac
    /// even when the user explicitly opted out.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Case-insensitive substring filter applied to
    /// `entry.text`. Persists for the lifetime of the view.
    @State private var filter: String = ""
    /// Drives the `.fileExporter` sheet; flipped by the Save
    /// to File… menu item.
    @State private var isExporting: Bool = false
    @State private var lastAutoScroll: ContinuousClock.Instant = .now

    public init() {}

    /// Animations run only when both the hardware tier permits
    /// it AND the user hasn't asked the system to reduce motion.
    /// Either gate failing → static UI.
    private var animateLogSurface: Bool {
        PerformanceProfile.current.repeatingSymbolEffectsAllowed
            && !reduceMotion
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            scrollSurface
        }
        .fileExporter(
            isPresented: $isExporting,
            document: PlainTextDocument(logAsText),
            contentType: .plainText,
            defaultFilename: defaultExportFilename
        ) { result in
            switch result {
            case .success(let url):
                Self.uiLogger.info(
                    "log exported to \(url.lastPathComponent, privacy: .public)"
                )
            case .failure(let err):
                Self.uiLogger.error(
                    "log export failed: \(err.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    // MARK: - Filter / source data

    private var filteredEntries: [LogEntry] {
        let needle =
            filter
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !needle.isEmpty else { return orchestrator.logEntries }
        return orchestrator.logEntries.filter { entry in
            entry.text.lowercased().contains(needle)
        }
    }

    /// Renders the FULL log (not the filtered view) as
    /// `HH:mm:ss [stderr|stdout] line` plain text. We ship the
    /// complete log on every export path because the user
    /// dragging or saving usually wants the whole record for
    /// a support ticket — filtering the disk export would
    /// hide context that the recipient doesn't see.
    private var logAsText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return orchestrator.logEntries.map { entry in
            let tag = entry.source == .stderr ? "[stderr]" : "[stdout]"
            return "\(formatter.string(from: entry.timestamp)) \(tag) \(entry.text)"
        }.joined(separator: "\n")
    }

    /// `cool-tunnel-2026-05-05-103412` style. ISO date + zero-
    /// padded time so multiple exports in one minute don't
    /// collide and they sort lexicographically in Finder.
    private var defaultExportFilename: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "cool-tunnel-\(formatter.string(from: Date()))"
    }

    private var countText: String {
        let total = orchestrator.logEntries.count
        let filtered = filteredEntries.count
        let needle = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        if needle.isEmpty {
            return "\(total) lines"
        }
        return "\(filtered) of \(total)"
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            // Drag-out handle. `.draggable` on the scroll icon
            // exports the FULL log as plain text — drop into
            // any text-accepting app to dump the log without a
            // file-picker round trip.
            //
            // Phase 2.4 accessibility: the icon DOES carry meaning
            // for VoiceOver users — it's the drag-out affordance —
            // so it gets an explicit label rather than being
            // hidden. Pointer users see it as a glyph; screen
            // readers hear "Drag the log: N lines."
            Image(systemName: "scroll")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .draggable(logAsText) {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text("\(orchestrator.logEntries.count) log lines")
                            .font(.callout.monospacedDigit())
                    }
                    .padding(8)
                    .background(.regularMaterial, in: .rect(cornerRadius: 6))
                }
                .help("Drag to copy the log as text — drop into TextEdit, Mail, or any text-accepting app.")
                .accessibilityLabel(
                    "Drag the log: \(orchestrator.logEntries.count) lines."
                )
                .accessibilityHint(
                    "Drag this to TextEdit or Mail to export the entire log."
                )

            Text("Live log")
                .font(.headline)

            Spacer()

            filterField

            Text(countText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .accessibilityLabel(countText)

            actionsMenu
        }
    }

    private var filterField: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Filter", text: $filter)
                .textFieldStyle(.plain)
                .frame(width: 130)
                .autocorrectionDisabled()
                .accessibilityLabel("Filter log entries")
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear filter")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.regularMaterial, in: .capsule)
        .overlay {
            Capsule().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
    }

    private var actionsMenu: some View {
        Menu {
            Button("Copy All") {
                copyAll()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(orchestrator.logEntries.isEmpty)

            Button("Save to File…") {
                isExporting = true
            }
            .disabled(orchestrator.logEntries.isEmpty)

            ShareLink(item: logAsText) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            .disabled(orchestrator.logEntries.isEmpty)

            Divider()

            Button("Clear", role: .destructive) {
                orchestrator.clearLogs()
            }
            .disabled(orchestrator.logEntries.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .help("Log actions: copy, save, share, clear")
        .accessibilityLabel("Log actions menu")
        .disabled(orchestrator.logEntries.isEmpty)
    }

    // MARK: - Scrollable log surface

    private var scrollSurface: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if orchestrator.logEntries.isEmpty {
                        emptyState
                    } else if filteredEntries.isEmpty {
                        emptyFilterState
                    } else {
                        ForEach(filteredEntries) { entry in
                            row(for: entry)
                        }
                    }
                    // Anchor for auto-scroll-to-bottom.
                    Color.clear.frame(height: 1).id("__bottom__")
                }
                .padding(10)
            }
            .background(.regularMaterial, in: .rect(cornerRadius: 6, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
            .onChange(of: orchestrator.logEntries.count) { _, _ in
                // Skip the scroll animation on (1) the `.light`
                // performance tier — older Intel hardware where the
                // 100ms linear curve compounds badly under high log
                // volume — and (2) when the user has Reduce Motion on.
                // The static jump-to-bottom keeps the UI usable in
                // both cases.
                let now = ContinuousClock.now
                let elapsed = now - lastAutoScroll
                let elapsedMs =
                    Double(elapsed.components.seconds) * 1000.0
                    + Double(elapsed.components.attoseconds) / 1.0e15
                guard elapsedMs >= Self.minimumAutoScrollIntervalMs else { return }
                lastAutoScroll = now

                if animateLogSurface {
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo("__bottom__", anchor: .bottom)
                    }
                } else {
                    proxy.scrollTo("__bottom__", anchor: .bottom)
                }
            }
        }
    }

    private static let minimumAutoScrollIntervalMs: Double = 250

    // MARK: - Empty states

    /// No entries yet. Pulse is gated by `PerformanceProfile`
    /// (hardware tier) AND `accessibilityReduceMotion` (user
    /// preference), so neither older hardware nor a user who
    /// explicitly opts out gets a continuously-animating
    /// placeholder.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .symbolEffect(.pulse, options: .repeating, isActive: animateLogSurface)
                .accessibilityHidden(true)
            Text("Waiting for the first log line…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Waiting for the first log line.")
    }

    /// The user's filter eliminated every row. Distinct from
    /// the "no entries yet" state: the user *has* logs, just
    /// not matching their search — surfacing a Clear-filter
    /// button keeps them from having to find the X in the
    /// filter field.
    private var emptyFilterState: some View {
        VStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
            Text("No matches for “\(filter)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Clear filter") { filter = "" }
                .buttonStyle(.borderless)
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Row

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
        .contextMenu {
            Button("Copy Line") {
                copy(text: entry.text)
            }
            Button("Copy with Timestamp") {
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm:ss"
                copy(text: "\(formatter.string(from: entry.timestamp)) \(entry.text)")
            }
        }
    }

    // MARK: - Actions

    private func copyAll() {
        copy(text: logAsText)
        Self.uiLogger.info(
            "copied \(self.orchestrator.logEntries.count, privacy: .public) log lines to pasteboard"
        )
    }

    /// Centralised pasteboard write so every "copy" path goes
    /// through one place and stays consistent (clear before
    /// set; one type declaration; UTF-8).
    private func copy(text: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    private static let uiLogger = Logger.cooltunnel("UI.LogConsole")
}

// MARK: - Plain-text document

/// Minimal `FileDocument` adapter for `.fileExporter`. Carries
/// a UTF-8 string in/out of disk. We don't support reading
/// (the export pipeline is write-only) but `FileDocument`
/// requires both initialisers, so the read path constructs an
/// empty document if the bytes don't decode — never thrown
/// during normal export.
private struct PlainTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String

    init(_ text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        let data = configuration.file.regularFileContents ?? Data()
        self.text = String(data: data, encoding: .utf8) ?? ""
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
