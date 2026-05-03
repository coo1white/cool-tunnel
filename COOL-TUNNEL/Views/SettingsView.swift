// Views/SettingsView.swift
//
// Inline Settings panel for the v0.1.5.8 layout. Replaces the
// modal sheet that earlier versions presented — Settings now lives
// inside the same window as the main view, swapped in via
// `ContentView`'s `isShowingSettings` flag with a slide animation.
//
// Cmd+W and the Back button both flip `isShowing` back to false,
// returning the user to the main view without dismissing the
// window itself (the AppDelegate's hide-on-Cmd+W handling is
// shadowed by the Back button's keyboard shortcut while this view
// is in the responder chain).
//
// Sections, top to bottom:
//
//   - Direct Domains
//   - This Mac (rich machine detail)
//   - Naive Binary  (Test + Update + OK/NG verdict)
//   - Rust Core    (Test + Update + OK/NG verdict, new in v0.1.5.8)
//   - Behaviour
//   - About        (app version footer)

import AppKit
import SwiftUI

@MainActor
public struct SettingsView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator

    /// Two-way binding to ContentView's `isShowingSettings`. Flipping
    /// to `false` swaps the panel back out for the main view.
    @Binding public var isShowing: Bool

    @State private var draft: AppSettings = .default
    @State private var newDomain: String = ""

    // -- Naive Binary state
    @State private var binaryPickerError: String?
    @State private var inspection: NaiveBinaryDescriptor?
    @State private var isInspecting: Bool = false
    @State private var updater = NaiveUpdater(
        supportDirectory: (try? AppSupportPaths())?.supportDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    )

    // -- Rust Core state (new in v0.1.5.8)
    @State private var rustInspection: RustCoreDescriptor?
    @State private var isRustInspecting: Bool = false
    @State private var rustPickerError: String?
    @State private var rustUpdater = RustCoreUpdater(
        supportDirectory: (try? AppSupportPaths())?.supportDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
    )

    private let resolver = NaiveBinaryResolver()
    private let rustResolver = RustCoreResolver()
    private let host = HostMachine.current
    private let appVersion = AppVersion.current

    public init(isShowing: Binding<Bool>) {
        self._isShowing = isShowing
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    commit()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                // Cmd+W closes the Settings panel (returns to the
                // main view) instead of hiding the whole window.
                // The shortcut takes effect because this button is
                // the responder while Settings is shown.
                .keyboardShortcut("w", modifiers: .command)

                Spacer()

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
                            "Test runs a full code-signature + host-CPU-slice + --version check. Update downloads the latest NaiveProxy from upstream and lipo-merges arm64 + x86_64 into a single universal binary."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Rust Core (engine)") {
                    rustCorePicker
                    rustCoreSummary
                    if let error = rustPickerError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text(
                            "The cool-tunnel-core engine spawns at app launch. "
                                + "Update downloads the latest universal binary "
                                + "from the Cool Tunnel GitHub release; the new "
                                + "core takes effect on the next launch."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("Behaviour") {
                    Toggle("Skip proxy mode confirmations", isOn: $draft.skipProxyConfirmations)
                }

                Section("About") {
                    versionFooter
                }
            }
            .formStyle(.grouped)
        }
        .padding(16)
        .background {
            // Opaque card behind the inline Settings so the
            // mode-aware window background underneath doesn't
            // bleed through and clash with the Form chrome.
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(CTPalette.platinum.opacity(0.6))
                .ignoresSafeArea()
        }
        .onAppear {
            draft = orchestrator.settings
            // Mirror the orchestrator's cached descriptor so the panel
            // shows real data the first time it opens, before the user
            // touches Test.
            inspection = orchestrator.activeNaiveDescriptor
        }
        .task {
            // Lazy first inspection — see the long comment in the
            // bootstrap path docs for why the launch flow stays clean
            // and inspection happens here instead.
            if orchestrator.activeNaiveDescriptor == nil {
                await orchestrator.refreshNaiveDescriptor()
                inspection = orchestrator.activeNaiveDescriptor
            }
            // Initial inspection of the active Rust core too, so the
            // verdict line shows real data without a click.
            if rustInspection == nil {
                await runRustInspection()
            }
        }
        .onDisappear {
            updater.reset()
            rustUpdater.reset()
        }
    }

    // MARK: - Chip detection — rich machine detail

    /// Renders "This Mac" with everything the user likely wants to
    /// see when triaging a "naive won't spawn" issue: brand string,
    /// performance + efficiency cores, memory, model identifier.
    @ViewBuilder
    private var chipDetectionRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: host.architecture == .appleSilicon ? "cpu" : "desktopcomputer")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 1) {
                    Text(host.architecture.displayName)
                        .font(.body.weight(.semibold))
                    Text("(\(host.architecture.machOArchName))")
                        .font(CTTypography.monoSmall)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            machineRow(label: "CPU", value: host.cpuSummary)
            machineRow(label: "Memory", value: host.memorySummary)
            if !host.modelIdentifier.isEmpty {
                machineRow(label: "Model", value: host.modelIdentifier, monospaced: true)
            }
            Text(chipDetectionSubtitle(for: host.architecture))
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    private func machineRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .leading)
            Text(value)
                .font(monospaced ? CTTypography.monoSmall : .caption)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chipDetectionSubtitle(for host: HostArchitecture) -> String {
        switch host {
        case .appleSilicon:
            return "Replace the bundled naive with an arm64 or universal build."
        case .intel:
            return "Replace the bundled naive with an x86_64 or universal build."
        case .unknown:
            return "Could not determine CPU architecture; spawning may fail."
        }
    }

    // MARK: - Naive binary summary

    /// Live readout for whichever binary is currently selected. New
    /// in v0.1.5.6: an OK / NG verdict line above the row breakdown
    /// and an Update button next to Test.
    @ViewBuilder
    private var naiveBinarySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(isInspecting ? "Testing…" : "Test") {
                    Task { await runInspection() }
                }
                .disabled(isInspecting || updaterIsBusy)

                Button(updaterButtonTitle) {
                    Task { await runUpdate() }
                }
                .disabled(updaterIsBusy)

                Spacer()

                if let descriptor = inspection {
                    Text(descriptor.origin == .bundled ? "Bundled" : "Custom")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }

            verdictRow

            if updaterIsBusy || updaterMessage != nil {
                updaterRow
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

    /// One-line OK / NG headline. Computed from the descriptor so
    /// the user sees a clear pass/fail tag *before* scanning the
    /// individual rows.
    @ViewBuilder
    private var verdictRow: some View {
        if isInspecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else if let descriptor = inspection {
            let verdict = naiveVerdict(for: descriptor)
            HStack(spacing: 6) {
                Image(systemName: verdict.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(verdict.ok ? Color.green : Color.red)
                Text(verdict.ok ? "OK" : "NG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(verdict.ok ? Color.green : Color.red)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(verdict.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((verdict.ok ? Color.green : Color.red).opacity(0.10))
            }
        } else if let pickerError = binaryPickerError {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red)
                Text("NG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.red)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(pickerError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            }
        } else {
            EmptyView()
        }
    }

    /// Live progress strip for the updater. Shows a determinate or
    /// indeterminate progress view depending on which pipeline step
    /// is running, plus the textual stage name.
    @ViewBuilder
    private var updaterRow: some View {
        HStack(spacing: 8) {
            Group {
                switch updater.state {
                case .downloading(let p) where p > 0:
                    ProgressView(value: p).controlSize(.small)
                case .succeeded, .failed, .idle:
                    EmptyView()
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 80)
            if let message = updaterMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(updaterMessageColor)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private var updaterIsBusy: Bool {
        switch updater.state {
        case .resolvingTag, .downloading, .extracting, .merging, .installing: true
        default: false
        }
    }

    private var updaterButtonTitle: String {
        switch updater.state {
        case .resolvingTag: "Resolving…"
        case .downloading: "Downloading…"
        case .extracting: "Extracting…"
        case .merging: "Merging…"
        case .installing: "Installing…"
        case .succeeded: "Update again"
        default: "Update"
        }
    }

    private var updaterMessage: String? {
        switch updater.state {
        case .idle: nil
        case .resolvingTag: "Resolving latest upstream NaiveProxy tag…"
        case .downloading(let p) where p > 0: "Downloading… \(Int(p * 100))%"
        case .downloading: "Downloading arm64 + x86_64 builds…"
        case .extracting: "Extracting tarballs…"
        case .merging: "lipo-merging arm64 + x86_64 → universal…"
        case .installing: "Installing into Application Support…"
        case .succeeded(let tag, _): "Updated to \(tag) — click Test to verify."
        case .failed(let message): "Update failed: \(message)"
        }
    }

    private var updaterMessageColor: Color {
        switch updater.state {
        case .succeeded: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func summaryRow(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Text(value)
                .font(monospaced ? CTTypography.monoSmall : .caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func hostSliceRow(descriptor: NaiveBinaryDescriptor) -> some View {
        let host = HostArchitecture.current
        let ok = descriptor.supportsHostArchitecture
        return HStack(alignment: .firstTextBaseline) {
            Text("Host slice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(
                ok
                    ? "\(host.machOArchName) slice present"
                    : "missing \(host.machOArchName) slice — proxy will fail to spawn"
            )
            .font(.caption)
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
            .foregroundStyle(descriptor.isCodeSignatureValid ? Color.green : Color.red)
            Text(descriptor.isCodeSignatureValid ? "valid" : "invalid or missing")
                .font(.caption)
                .foregroundStyle(descriptor.isCodeSignatureValid ? Color.secondary : Color.red)
        }
    }

    /// Boils the descriptor down to one OK / NG headline + a brief
    /// reason. The Test button populates this; the Settings UI shows
    /// it above the per-row breakdown so the user can grok the
    /// outcome at a glance.
    private func naiveVerdict(for descriptor: NaiveBinaryDescriptor) -> (ok: Bool, message: String) {
        if !descriptor.supportsHostArchitecture {
            return (
                false,
                "Missing \(HostArchitecture.current.machOArchName) slice — proxy will fail to spawn."
            )
        }
        if !descriptor.isCodeSignatureValid {
            return (false, "Code signature is invalid or missing.")
        }
        if descriptor.version == nil {
            return (false, "Binary did not respond to --version.")
        }
        let archDesc =
            descriptor.isUniversal ? "universal" : descriptor.architectures.sorted().joined(separator: ", ")
        return (true, "Ready to use · \(archDesc) · \(descriptor.version ?? "")")
    }

    /// Runs `inspect` for whichever path the draft currently points at.
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

    /// Drives the updater pipeline and, on success, adopts the
    /// installed binary as the custom path so the orchestrator picks
    /// it up. Re-runs inspection automatically so the verdict line
    /// reflects the freshly-downloaded version without the user
    /// having to click Test again.
    private func runUpdate() async {
        guard let installedURL = await updater.update() else {
            return  // Failure is surfaced via `updater.state` already.
        }
        draft.customNaiveBinaryPath = installedURL.path
        // Re-run the inspection so the verdict + per-row readout
        // reflect the post-update binary.
        await runInspection()
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
                        .font(CTTypography.mono)
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

    // MARK: - Version footer

    /// "About" row at the bottom of the Settings sheet — version +
    /// build number + a one-line aesthetic credit so the user can
    /// quote the exact build in any support thread.
    private var versionFooter: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(appVersion.displayString)
                    .font(.callout.weight(.medium))
                Text("Apache 2.0 · Maltese theme · macOS 12+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "pawprint.fill")
                .foregroundStyle(.tint)
        }
    }

    private var domainList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(draft.directDomains, id: \.self) { domain in
                HStack {
                    Text(domain)
                        .font(CTTypography.mono)
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

    /// Opens an `NSOpenPanel`, validates the selected file's code
    /// signature up front, and only accepts paths that pass.
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
    /// version in one pass and surfaces a typed error if any of
    /// those would prevent the proxy from spawning.
    private func verifyAndAdopt(url: URL) async {
        isInspecting = true
        defer { isInspecting = false }
        do {
            let descriptor = try await resolver.inspect(url: url, origin: .userSupplied)
            inspection = descriptor
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
        Task { await orchestrator.refreshNaiveDescriptor() }
        // Inline panel: flip the binding instead of calling
        // `dismiss()`. The parent view animates the swap.
        isShowing = false
    }

    // MARK: - Rust Core section

    /// Path picker + Reset for the Rust core. Mirrors the naive
    /// picker so the two sections read as siblings.
    @ViewBuilder
    private var rustCorePicker: some View {
        HStack(alignment: .firstTextBaseline) {
            Group {
                if draft.customRustCorePath.isEmpty {
                    Text("Bundled (default)")
                        .foregroundStyle(.secondary)
                } else {
                    Text(draft.customRustCorePath)
                        .font(CTTypography.mono)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button("Choose…") { chooseRustCore() }

            if !draft.customRustCorePath.isEmpty {
                Button("Reset") {
                    draft.customRustCorePath = ""
                    rustPickerError = nil
                    Task { await runRustInspection() }
                }
            }
        }
    }

    /// Live readout for the Rust core: arch slices, version, code
    /// signature, OK/NG verdict, plus Test + Update buttons.
    @ViewBuilder
    private var rustCoreSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(isRustInspecting ? "Testing…" : "Test") {
                    Task { await runRustInspection() }
                }
                .disabled(isRustInspecting || rustUpdaterIsBusy)

                Button(rustUpdaterButtonTitle) {
                    Task { await runRustUpdate() }
                }
                .disabled(rustUpdaterIsBusy)

                Spacer()

                if let descriptor = rustInspection {
                    Text(descriptor.origin == .bundled ? "Bundled" : "Custom")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: .capsule)
                }
            }

            rustVerdictRow

            if rustUpdaterIsBusy || rustUpdaterMessage != nil {
                rustUpdaterRow
            }

            if let descriptor = rustInspection {
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
                rustHostSliceRow(descriptor: descriptor)
                rustSignatureRow(descriptor: descriptor)
            } else {
                Text("Not inspected yet — click Test to validate the active engine.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var rustVerdictRow: some View {
        if isRustInspecting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Testing…")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        } else if let descriptor = rustInspection {
            let verdict = rustVerdict(for: descriptor)
            HStack(spacing: 6) {
                Image(systemName: verdict.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .foregroundStyle(verdict.ok ? Color.green : Color.red)
                Text(verdict.ok ? "OK" : "NG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(verdict.ok ? Color.green : Color.red)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(verdict.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((verdict.ok ? Color.green : Color.red).opacity(0.10))
            }
        } else if let pickerError = rustPickerError {
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.red)
                Text("NG")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.red)
                Text("·")
                    .foregroundStyle(.secondary)
                Text(pickerError)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.red.opacity(0.10))
            }
        } else {
            EmptyView()
        }
    }

    @ViewBuilder
    private var rustUpdaterRow: some View {
        HStack(spacing: 8) {
            Group {
                switch rustUpdater.state {
                case .downloading(let p) where p > 0:
                    ProgressView(value: p).controlSize(.small)
                case .succeeded, .failed, .idle:
                    EmptyView()
                default:
                    ProgressView().controlSize(.small)
                }
            }
            .frame(width: 80)
            if let message = rustUpdaterMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(rustUpdaterMessageColor)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        }
    }

    private var rustUpdaterIsBusy: Bool {
        switch rustUpdater.state {
        case .resolvingRelease, .downloading, .installing: true
        default: false
        }
    }

    private var rustUpdaterButtonTitle: String {
        switch rustUpdater.state {
        case .resolvingRelease: "Resolving…"
        case .downloading: "Downloading…"
        case .installing: "Installing…"
        case .succeeded: "Update again"
        default: "Update"
        }
    }

    private var rustUpdaterMessage: String? {
        switch rustUpdater.state {
        case .idle: nil
        case .resolvingRelease: "Resolving latest cool-tunnel release…"
        case .downloading(let p) where p > 0: "Downloading… \(Int(p * 100))%"
        case .downloading: "Downloading universal cool-tunnel-core…"
        case .installing: "Installing into Application Support…"
        case .succeeded(let tag, _):
            "Updated to \(tag) — restart Cool Tunnel to use the new engine."
        case .failed(let message): "Update failed: \(message)"
        }
    }

    private var rustUpdaterMessageColor: Color {
        switch rustUpdater.state {
        case .succeeded: .green
        case .failed: .red
        default: .secondary
        }
    }

    private func rustHostSliceRow(descriptor: RustCoreDescriptor) -> some View {
        let host = HostArchitecture.current
        let ok = descriptor.supportsHostArchitecture
        return HStack(alignment: .firstTextBaseline) {
            Text("Host slice")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.red)
            Text(
                ok
                    ? "\(host.machOArchName) slice present"
                    : "missing \(host.machOArchName) slice — engine will fail to spawn"
            )
            .font(.caption)
            .foregroundStyle(ok ? Color.secondary : Color.red)
        }
    }

    private func rustSignatureRow(descriptor: RustCoreDescriptor) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Signature")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)
            Image(
                systemName: descriptor.isCodeSignatureValid
                    ? "checkmark.seal.fill" : "xmark.seal.fill"
            )
            .foregroundStyle(descriptor.isCodeSignatureValid ? Color.green : Color.red)
            Text(descriptor.isCodeSignatureValid ? "valid" : "invalid or missing")
                .font(.caption)
                .foregroundStyle(descriptor.isCodeSignatureValid ? Color.secondary : Color.red)
        }
    }

    private func rustVerdict(for descriptor: RustCoreDescriptor) -> (ok: Bool, message: String) {
        if !descriptor.supportsHostArchitecture {
            return (
                false,
                "Missing \(HostArchitecture.current.machOArchName) slice — engine will fail to spawn."
            )
        }
        if !descriptor.isCodeSignatureValid {
            return (false, "Code signature is invalid or missing.")
        }
        if descriptor.version == nil {
            return (false, "Engine did not respond to --version.")
        }
        let archDesc =
            descriptor.isUniversal
            ? "universal"
            : descriptor.architectures.sorted().joined(separator: ", ")
        return (true, "Ready to use · \(archDesc) · \(descriptor.version ?? "")")
    }

    private func runRustInspection() async {
        isRustInspecting = true
        defer { isRustInspecting = false }
        let url: URL
        let origin: RustCoreDescriptor.Origin
        if draft.customRustCorePath.isEmpty {
            url = RustCoreResolver.bundledURL()
            origin = .bundled
        } else {
            url = URL(fileURLWithPath: draft.customRustCorePath)
            origin = .userSupplied
        }
        do {
            rustInspection = try await rustResolver.inspect(url: url, origin: origin)
            rustPickerError = nil
        } catch let error as RustCoreResolverError {
            rustPickerError = error.localizedDescription
            rustInspection = nil
        } catch {
            rustPickerError = error.localizedDescription
            rustInspection = nil
        }
    }

    private func runRustUpdate() async {
        guard let installedURL = await rustUpdater.update() else { return }
        draft.customRustCorePath = installedURL.path
        await runRustInspection()
    }

    private func chooseRustCore() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "Select cool-tunnel-core binary"
        panel.message = "The selected file must be a code-signed Mach-O executable."
        panel.prompt = "Use"
        panel.treatsFilePackagesAsDirectories = true
        if !draft.customRustCorePath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draft.customRustCorePath)
                .deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await verifyAndAdoptRust(url: url) }
    }

    private func verifyAndAdoptRust(url: URL) async {
        isRustInspecting = true
        defer { isRustInspecting = false }
        do {
            let descriptor = try await rustResolver.inspect(url: url, origin: .userSupplied)
            rustInspection = descriptor
            if !descriptor.isCodeSignatureValid {
                rustPickerError = "Rejected: code signature is invalid or missing."
                return
            }
            draft.customRustCorePath = url.path
            rustPickerError = nil
        } catch let error as RustCoreResolverError {
            rustPickerError = "Rejected: \(error.localizedDescription)"
            rustInspection = nil
        } catch {
            rustPickerError = "Rejected: \(error.localizedDescription)"
            rustInspection = nil
        }
    }
}
