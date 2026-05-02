// Views/SettingsView.swift
//
// Modal sheet that edits the user's `AppSettings`: direct-domain list,
// custom binary path, and the "skip confirmations" toggle.

import AppKit
import SwiftUI

@MainActor
public struct SettingsView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AppSettings = .default
    @State private var newDomain: String = ""
    @State private var binaryPickerError: String?
    /// Result of the most recent `Test` button press. `nil` until the
    /// user clicks Test, populated thereafter so the panel can show a
    /// fresh signature/arch/version readout for the candidate path.
    @State private var inspection: NaiveBinaryDescriptor?
    @State private var isInspecting: Bool = false

    private let resolver = NaiveBinaryResolver()

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { commit() }
                    .keyboardShortcut(.defaultAction)
            }

            Form {
                Section("Direct Domains") {
                    HStack {
                        TextField("example.com", text: $newDomain)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") { addDomain() }
                            .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if draft.directDomains.isEmpty {
                        Text("No direct domains. All traffic will be proxied.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        domainList
                    }
                    Button("Restore defaults") {
                        draft.directDomains = AppSettings.defaultDirectDomains
                    }
                }

                Section("This Mac") {
                    chipDetectionRow
                }

                Section("Naive Binary") {
                    naiveBinaryPicker
                    naiveBinarySummary
                    if let error = binaryPickerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(
                            "The selected binary is verified for a valid code signature, the right CPU slice, and a working --version response before each launch."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Behaviour") {
                    Toggle("Skip proxy mode confirmations", isOn: $draft.skipProxyConfirmations)
                }
            }
            .formStyle(.grouped)
        }
        .padding(16)
        .frame(width: 560, height: 640)
        .onAppear {
            draft = orchestrator.settings
            // Mirror the orchestrator's cached descriptor so the panel
            // shows real data the first time it opens, before the user
            // touches the Test button.
            inspection = orchestrator.activeNaiveDescriptor
        }
        .task {
            // Bootstrap deliberately skips naive verification to keep the
            // launch path to a single auth check (cool-tunnel-core only).
            // The Settings view is the natural place to pay that cost
            // lazily — by the time the user is here they're about to
            // either configure the binary or just look at it. Running
            // the inspection in a `.task` (cancelled on view dismiss)
            // means we never block presentation of the sheet.
            if orchestrator.activeNaiveDescriptor == nil {
                await orchestrator.refreshNaiveDescriptor()
                inspection = orchestrator.activeNaiveDescriptor
            }
        }
    }

    // MARK: - Chip detection row

    /// Renders "This Mac: Apple Silicon (arm64)" and a subtitle that
    /// nudges Intel users to download a universal naive build if they
    /// later swap the binary.
    @ViewBuilder
    private var chipDetectionRow: some View {
        let host = orchestrator.hostArchitecture
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: host == .appleSilicon ? "cpu" : "desktopcomputer")
                    Text(host.displayName)
                        .font(.body.weight(.semibold))
                    Text("(\(host.machOArchName))")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text(chipDetectionSubtitle(for: host))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func chipDetectionSubtitle(for host: HostArchitecture) -> String {
        switch host {
        case .appleSilicon:
            return "If you replace the bundled naive, pick an arm64 or universal build."
        case .intel:
            return "If you replace the bundled naive, pick an x86_64 or universal build."
        case .unknown:
            return "Could not determine CPU architecture; spawning may fail."
        }
    }

    // MARK: - Naive binary summary

    /// Live readout for whichever binary is currently selected: arch
    /// slices, version, code-signature state, and a Test button to
    /// re-inspect after the user changes the path. The same view powers
    /// both the bundled and user-supplied cases so the two flows stay
    /// visually consistent.
    @ViewBuilder
    private var naiveBinarySummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(isInspecting ? "Testing…" : "Test") {
                    Task { await runInspection() }
                }
                .disabled(isInspecting)
                Spacer()
                if let descriptor = inspection {
                    Text(descriptor.origin == .bundled ? "Bundled" : "Custom")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }

            if let descriptor = inspection {
                summaryRow(label: "Path", value: descriptor.url.path, monospaced: true)
                summaryRow(
                    label: "Architectures",
                    value: descriptor.architectures.sorted().joined(separator: ", "),
                    monospaced: true
                )
                summaryRow(
                    label: "Version",
                    value: descriptor.version ?? "(no --version output)"
                )
                hostSliceRow(descriptor: descriptor)
                signatureRow(descriptor: descriptor)
            } else {
                Text("Not inspected yet — click Test to validate the active binary.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func summaryRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hostSliceRow(descriptor: NaiveBinaryDescriptor) -> some View {
        let host = orchestrator.hostArchitecture
        let ok = descriptor.supportsHostArchitecture
        return HStack(alignment: .firstTextBaseline) {
            Text("Host slice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(
                ok
                    ? "\(host.machOArchName) slice present"
                    : "missing \(host.machOArchName) slice — proxy will fail to spawn"
            )
            .font(.caption)
            // Ternary needs both branches to share a concrete type; the
            // hierarchical `.secondary` and the colour `.red` come from
            // different style families, so we anchor both on `Color`.
            .foregroundStyle(ok ? Color.secondary : Color.red)
        }
    }

    private func signatureRow(descriptor: NaiveBinaryDescriptor) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Signature")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Image(
                systemName: descriptor.isCodeSignatureValid
                    ? "checkmark.seal.fill"
                    : "xmark.seal.fill"
            )
            .foregroundStyle(descriptor.isCodeSignatureValid ? .green : .red)
            Text(descriptor.isCodeSignatureValid ? "valid" : "invalid or missing")
                .font(.caption)
                .foregroundStyle(descriptor.isCodeSignatureValid ? Color.secondary : Color.red)
        }
    }

    /// Runs `inspect` for whichever path the draft currently points at.
    /// Used by both the Test button and after the user picks a new
    /// custom binary.
    private func runInspection() async {
        isInspecting = true
        defer { isInspecting = false }

        let url: URL
        let origin: NaiveBinaryDescriptor.Origin
        if draft.customNaiveBinaryPath.isEmpty {
            url = NaiveBinaryResolver.bundledURL()
            origin = .bundled
        } else {
            url = URL(fileURLWithPath: draft.customNaiveBinaryPath)
            origin = .userSupplied
        }
        do {
            inspection = try await resolver.inspect(url: url, origin: origin)
            binaryPickerError = nil
        } catch let error as NaiveResolverError {
            binaryPickerError = error.localizedDescription
            inspection = nil
        } catch {
            binaryPickerError = error.localizedDescription
            inspection = nil
        }
    }

    @ViewBuilder
    private var naiveBinaryPicker: some View {
        HStack(alignment: .firstTextBaseline) {
            Group {
                if draft.customNaiveBinaryPath.isEmpty {
                    Text("Bundled (default)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(draft.customNaiveBinaryPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Choose…") { chooseNaiveBinary() }

            if !draft.customNaiveBinaryPath.isEmpty {
                Button("Reset") {
                    draft.customNaiveBinaryPath = ""
                    binaryPickerError = nil
                }
            }
        }
    }

    private var domainList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(draft.directDomains, id: \.self) { domain in
                HStack {
                    Text(domain)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Button(role: .destructive) {
                        draft.directDomains.removeAll { $0 == domain }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func addDomain() {
        let trimmed =
            newDomain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !trimmed.isEmpty, !draft.directDomains.contains(trimmed) else { return }
        draft.directDomains.append(trimmed)
        newDomain = ""
    }

    /// Opens an `NSOpenPanel`, validates the selected file's code signature
    /// up front, and only accepts paths that pass. This collapses the
    /// previous free-text TextField — which let any string land in
    /// UserDefaults — into a positive choice gated by a signature check.
    private func chooseNaiveBinary() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select naive binary"
        panel.message = "The selected file must be a code-signed Mach-O executable."
        panel.prompt = "Use"
        panel.treatsFilePackagesAsDirectories = true
        if !draft.customNaiveBinaryPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.customNaiveBinaryPath)
                .deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task { await verifyAndAdopt(url: url) }
    }

    /// Inspect via the resolver: it checks signature, host arch, and
    /// version in one pass and surfaces a typed error if any of those
    /// would prevent the proxy from spawning. We adopt the path even if
    /// only the signature is valid (the host-arch warning is shown
    /// inline so the user can pick a different file).
    private func verifyAndAdopt(url: URL) async {
        isInspecting = true
        defer { isInspecting = false }
        do {
            let descriptor = try await resolver.inspect(url: url, origin: .userSupplied)
            inspection = descriptor
            // Refuse to adopt a binary with a broken signature outright;
            // the orchestrator would reject it at spawn time anyway.
            if !descriptor.isCodeSignatureValid {
                binaryPickerError = "Rejected: code signature is invalid or missing."
                return
            }
            draft.customNaiveBinaryPath = url.path
            binaryPickerError = nil
        } catch let error as NaiveResolverError {
            binaryPickerError = "Rejected: \(error.localizedDescription)"
            inspection = nil
        } catch {
            binaryPickerError = "Rejected: \(error.localizedDescription)"
            inspection = nil
        }
    }

    private func commit() {
        orchestrator.settings = draft
        orchestrator.persistSettings()
        // The active descriptor depends on `customNaiveBinaryPath`; refresh
        // so the next time Settings opens we show the post-commit state.
        Task { await orchestrator.refreshNaiveDescriptor() }
        dismiss()
    }
}
