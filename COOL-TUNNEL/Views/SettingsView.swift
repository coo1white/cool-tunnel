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

                Section("Naive Binary") {
                    naiveBinaryPicker
                    if let error = binaryPickerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("The selected binary is verified for a valid code signature before each launch.")
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
        .frame(width: 520, height: 520)
        .onAppear { draft = orchestrator.settings }
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
        let trimmed = newDomain
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

    private func verifyAndAdopt(url: URL) async {
        do {
            try await CodeSignVerifier.verifyValid(at: url)
            draft.customNaiveBinaryPath = url.path
            binaryPickerError = nil
        } catch let error as CodeSignError {
            binaryPickerError = "Rejected: \(error.localizedDescription)"
        } catch {
            binaryPickerError = "Rejected: \(error.localizedDescription)"
        }
    }

    private func commit() {
        orchestrator.settings = draft
        orchestrator.persistSettings()
        dismiss()
    }
}
