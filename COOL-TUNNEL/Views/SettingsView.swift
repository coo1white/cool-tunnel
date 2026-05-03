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

/// Inline Settings panel — direct-domains list, This-Mac hardware
/// readout, Naive Binary section (Test + Update + OK/NG verdict),
/// Rust Core section (same shape), behaviour toggles, and an
/// About footer with the running app version. Driven by an
/// `isShowing` binding from `ContentView`; Cmd+W and the Back
/// button both flip it back to false.
@MainActor
public struct SettingsView: View {
    @Environment(TunnelOrchestrator.self) private var orchestrator
    @Environment(\.colorScheme) private var colorScheme

    /// Mode-aware alpha for the green/red/blue/red pill
    /// backgrounds across the verdict + updater rows. v0.1.7.7
    /// shipped with a flat 0.10 that vanished on dark; this
    /// reaches `CTSurface.statusPillAlpha` so light stays
    /// 0.10 and dark gets 0.22.
    private var pillAlpha: Double { CTSurface.statusPillAlpha(colorScheme) }

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

    // -- App self-updater (new in v0.1.7.6)
    @State private var appUpdater = AppUpdater()

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
                            // Pressing Return inside the
                            // TextField now adds the domain
                            // instead of falling through to the
                            // Done button's `.defaultAction`
                            // shortcut (which would dismiss
                            // Settings without adding the
                            // typed value — a real workflow
                            // trap).
                            .onSubmit { addDomain() }
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

                Section("Cool Tunnel") {
                    appUpdaterSection
                }

                Section("Appearance") {
                    appearancePicker
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
            // Flat fill (not a RoundedRectangle) — combining a
            // rounded shape with `.ignoresSafeArea()` would extend
            // the rounded corners off-screen, leaving a visible
            // square edge where the radius lives outside the
            // visible region. The Settings panel reads as a
            // full-window slide-in, so a flat background is what
            // the layout actually wants.
            Rectangle()
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
            // Reset the app self-updater too. v0.1.7.6 forgot
            // this, so a `.failed` or `.upToDate` state
            // persisted across Settings open/close cycles —
            // until the next time the user opened Settings
            // they'd see the stale message before re-clicking
            // Check. `reset()` is a no-op while in-flight, so
            // a mid-download state survives the dismiss
            // (orphan-download issue still defer to v0.2 for
            // a real cancel + lifecycle-promotion fix).
            appUpdater.reset()
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
                    // Curated palette colour, not the system tint —
                    // the latter renders as Apple aqua and clashes
                    // with the System 7-leaning palette.
                    .foregroundStyle(CTPalette.macBlue)
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
    /// and an Update button next to Test. v0.1.5.8 audit: the busy
    /// flag is now set **synchronously** in the button action
    /// before the Task is spawned, so a rapid double-click can't
    /// race the .disabled re-render and queue a second inspection
    /// or update.
    @ViewBuilder
    private var naiveBinarySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(isInspecting ? "Testing…" : "Test") {
                    // Synchronous re-entry guard. Even if SwiftUI
                    // hasn't yet re-rendered the disabled state, we
                    // catch a fast second tap here.
                    guard !isInspecting && !updaterIsBusy else { return }
                    isInspecting = true
                    Task { await runInspectionWork() }
                }
                .disabled(isInspecting || updaterIsBusy)

                Button(updaterButtonTitle) {
                    // Updater itself has a state-machine guard, but
                    // we mirror the synchronous-flag pattern for
                    // consistency and to keep the button label
                    // ("Update" → "Resolving…") in lock-step with
                    // the click.
                    guard !updaterIsBusy && !isInspecting else { return }
                    Task { await runUpdate() }
                }
                .disabled(updaterIsBusy || isInspecting)

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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((verdict.ok ? Color.green : Color.red).opacity(pillAlpha))
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
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.red.opacity(pillAlpha))
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
                    // Long failure messages (URLs, hashes, server
                    // errors) get truncated by `lineLimit(2)`. The
                    // hover tooltip + selectable text gives users
                    // a way to read or copy the full string for
                    // support tickets.
                    .help(message)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
                // Hover tooltip + selection so users can read or
                // copy a long path/version even when it's
                // middle-truncated. Diagnostic info — exactly
                // what's hidden by truncation is what the user
                // wants when they're in Settings.
                .help(value)
                .textSelection(.enabled)
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

    /// Backwards-compat shim: callers that don't go through the
    /// button (the initial `.task`, the post-Choose adopt path,
    /// the post-Update re-inspection) still flip the busy flag the
    /// old way. The button itself sets the flag synchronously
    /// before spawning, so this guard is only ever entered with
    /// `isInspecting == true` from those entry points OR with
    /// `false` and we want to respect that.
    private func runInspection() async {
        if !isInspecting {
            isInspecting = true
        }
        await runInspectionWork()
    }

    /// Performs the inspection itself, assuming the caller has
    /// already set `isInspecting = true` synchronously. Always
    /// resets the flag in `defer` so any early-return path leaves
    /// the UI clean.
    private func runInspectionWork() async {
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
    /// reflects the post-update binary without the user having to
    /// click Test again.
    private func runUpdate() async {
        guard let installedURL = await updater.update() else {
            return  // Failure is surfaced via `updater.state` already.
        }
        draft.customNaiveBinaryPath = installedURL.path
        // Owned re-inspection — set the flag synchronously here so
        // the button stays disabled across the post-update probe.
        isInspecting = true
        await runInspectionWork()
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

            // Disable Choose during inspection / update — same
            // rationale as the Rust Core picker: avoid stacking an
            // NSOpenPanel modal on top of in-flight probe work.
            Button("Choose…") { chooseNaiveBinary() }
                .disabled(isInspecting || updaterIsBusy)

            if !draft.customNaiveBinaryPath.isEmpty {
                Button("Reset") {
                    guard !isInspecting && !updaterIsBusy else { return }
                    draft.customNaiveBinaryPath = ""
                    binaryPickerError = nil
                }
                .disabled(isInspecting || updaterIsBusy)
            }
        }
    }

    // MARK: - Appearance picker (new in v0.1.7.7)

    /// Three-way segmented picker: Match System / Light / Dark.
    /// Bound to `draft.appearanceMode`; the change is published
    /// to the orchestrator via the `.onChange` below so the
    /// chosen scheme applies *immediately* (not only on Done).
    /// The dynamic `CTPalette` colours pick up the new scheme
    /// the moment SwiftUI re-renders with the updated
    /// `preferredColorScheme`.
    @ViewBuilder
    private var appearancePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Appearance", selection: $draft.appearanceMode) {
                ForEach(AppearanceMode.allCases, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("App appearance")
            // Without this VoiceOver announces only the label
            // ("App appearance, picker") and never says which
            // segment is selected. The value name pairs the
            // picker readout with the same string the visible
            // subtitle uses.
            .accessibilityValue(draft.appearanceMode.displayName)
            .onChange(of: draft.appearanceMode) { _, newValue in
                // Push to the orchestrator immediately so the
                // app re-renders with the new scheme. The full
                // settings blob still flushes on Done via
                // `commit()`; this is the live-preview path.
                orchestrator.settings.appearanceMode = newValue
                orchestrator.persistSettings()
            }
            Text(appearanceSubtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var appearanceSubtitle: String {
        switch draft.appearanceMode {
        case .system:
            "Follows the macOS appearance setting (System Settings → Appearance)."
        case .light:
            "Always uses the System 7 / Platinum-era light palette, regardless of the macOS appearance."
        case .dark:
            "Always uses the dark palette, regardless of the macOS appearance."
        }
    }

    // MARK: - App self-updater section (new in v0.1.7.6)

    /// "Cool Tunnel" Settings row — current version display +
    /// Check / Update buttons, mirroring the Naive Binary and
    /// Rust Core sections. Drives `AppUpdater`, which fetches
    /// `releases/latest` from GitHub, verifies the .zip against
    /// the SHA-256 manifest the same release publishes, ditto-
    /// extracts, code-signature-verifies, and spawns a relaunch
    /// helper that swaps the bundle while the app quits.
    @ViewBuilder
    private var appUpdaterSection: some View {
        // Wrap in a single VStack so the title row and the
        // optional status row read as ONE Form-section row
        // rather than two separate ones with Form's intra-row
        // padding between them. Mirrors the structure the
        // appearancePicker uses below.
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "shippingbox.fill")
                    .font(.title3)
                    .foregroundStyle(CTPalette.macBlue)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cool Tunnel \(appVersion.marketingVersion)")
                        .font(.body.weight(.semibold))
                    Text(appUpdaterSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        // Cap the title-row width so a long
                        // subtitle can't push the action button
                        // off the right edge at the 780pt min
                        // window width.
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                appUpdaterActionButton
            }
            appUpdaterStatusRow
        }
    }

    private var appUpdaterAccessibilityProgressLabel: String {
        switch appUpdater.state {
        case .checking: "Checking for updates"
        case .downloading: "Downloading update"
        case .verifying: "Verifying download integrity"
        case .extracting: "Extracting update"
        case .relaunching: "Relaunching the app"
        default: "Update in progress"
        }
    }

    private var appUpdaterSubtitle: String {
        switch appUpdater.state {
        case .idle:
            "Checks GitHub for a newer release. SHA-256 verified, then downloads, verifies the new app, replaces this copy, and relaunches."
        case .checking:
            "Checking for updates…"
        case .upToDate(let v):
            "You're on the latest version (\(v))."
        case .available(let release):
            // "you're on" reads cleaner than the previous "(was
            // X)" — past tense suggested the user had already
            // upgraded.
            "Update available: \(release.tag) — you're on \(appVersion.marketingVersion)."
        case .downloading:
            // `URLSession.shared.download(from:)` does not report
            // byte-level progress, so the `p` value never moves
            // off 0.0 — showing it would lie. Honest text instead.
            "Downloading… (typically a few seconds on broadband)"
        case .verifying:
            "Verifying SHA-256…"
        case .extracting:
            "Extracting and verifying signature…"
        case .relaunching:
            "Relaunching… The app will close in a moment."
        case .failed(let message):
            "Update failed: \(message)"
        }
    }

    @ViewBuilder
    private var appUpdaterActionButton: some View {
        switch appUpdater.state {
        case .checking, .downloading, .verifying, .extracting, .relaunching:
            // Inline label so VoiceOver announces what's running
            // instead of "progress indicator". Tied to the
            // current phase via the subtitle row below.
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(appUpdaterAccessibilityProgressLabel)
        case .available(let release):
            Button("Update to \(release.tag)") {
                // **AU-13 fix:** the gate is now atomic with
                // the spawn — `markEnteringDownload` returns
                // false IFF the flip was a no-op (already in
                // flight), so the `Task` only spawns when the
                // state actually transitioned to .downloading.
                // Previously a fast double-tap could fire the
                // first click's flip, pass the second click's
                // `!isInFlight` check (race: it ran before
                // SwiftUI re-rendered post-first-flip), no-op
                // its own `markEnteringDownload`, then still
                // spawn a redundant Task that fired a parallel
                // download.
                guard appUpdater.markEnteringDownload() else { return }
                Task { await appUpdater.downloadAndInstall(release) }
            }
            .buttonStyle(.borderedProminent)
            .layoutPriority(1)  // keep the button visible at min window width
            .accessibilityLabel("Download and install \(release.tag)")
        default:
            Button("Check for Updates") {
                // Same AU-13 race-defeating shape as above — the
                // spawn is conditional on the actual state flip.
                guard appUpdater.markEnteringCheck() else { return }
                Task { await appUpdater.checkForUpdates() }
            }
            .accessibilityLabel("Check for Cool Tunnel updates")
        }
    }

    @ViewBuilder
    private var appUpdaterStatusRow: some View {
        switch appUpdater.state {
        case .available(let release):
            HStack(spacing: 6) {
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(CTPalette.macBlue)
                // Self-describing single Link — VoiceOver hears
                // one element ("View release notes for v0.1.7.9,
                // link") rather than two disconnected ones.
                Link(
                    "View release notes for \(release.tag)",
                    destination: release.releaseNotesURL
                )
                .font(.caption)
                .underline(true)
                .accessibilityLabel("View release notes for \(release.tag), opens in browser")
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(CTPalette.macBlue.opacity(pillAlpha))
            }
        case .failed(let message):
            // `alignment: .top` so on multi-line messages the
            // icon + Dismiss button stay aligned with the first
            // line of text rather than drifting to the vertical
            // centre. `lineLimit(3)` + `fixedSize(vertical:)`
            // lets the message expand within the row without
            // the parent layout snapping it back to a single
            // line.
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(message)
                    .textSelection(.enabled)
                // "Dismiss" is the actual semantic — clears the
                // error so the Check button can render again.
                // "Reset" suggested undoing user changes which
                // is misleading.
                Button("Dismiss") { appUpdater.reset() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.red.opacity(pillAlpha))
            }
        default:
            EmptyView()
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
                // Footer text reflects the actual current state:
                // Apache 2.0 licence, classic Macintosh theme (the
                // codebase used to be the "Maltese" theme before
                // the v0.1.5.7 platinum retune), and the real
                // deployment-target floor of macOS 14 (was
                // claiming "12+" since before the floor was raised
                // for performance work).
                Text("Apache 2.0 · Classic Mac theme · macOS 14+")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "pawprint.fill")
                // Use the curated Mac blue token, not the system
                // tint which renders as Apple aqua and clashes
                // with the System 7-leaning palette.
                .foregroundStyle(CTPalette.macBlue)
        }
    }

    private var domainList: some View {
        // Cap the inline list height so very long direct-domain
        // lists (smart-mode users with hundreds of entries) don't
        // push every section below — Naive Binary, Rust Core,
        // About — off-screen. The inner ScrollView keeps the
        // entries reachable while the surrounding Form keeps the
        // section structure stable.
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(draft.directDomains, id: \.self) { domain in
                    HStack {
                        Text(domain)
                            .font(CTTypography.mono)
                            .textSelection(.enabled)
                        Spacer()
                        Button(role: .destructive) {
                            draft.directDomains.removeAll { $0 == domain }
                        } label: {
                            Image(systemName: "minus.circle")
                                // Pad to a 24×24 hit target so
                                // the destructive action is
                                // reachable on trackpad / touch
                                // input — the bare 16pt SF Symbol
                                // was below comfortable click
                                // accuracy.
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(domain)")
                        .accessibilityLabel("Remove \(domain)")
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .frame(maxHeight: 220)
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

            // Disable Choose during inspection / update so the user
            // can't queue an NSOpenPanel modal on top of in-flight
            // probe work — would land a stale path in the draft if
            // the panel resolves before the inspection does.
            Button("Choose…") { chooseRustCore() }
                .disabled(isRustInspecting || rustUpdaterIsBusy)

            if !draft.customRustCorePath.isEmpty {
                Button("Reset") {
                    guard !isRustInspecting && !rustUpdaterIsBusy else { return }
                    draft.customRustCorePath = ""
                    rustPickerError = nil
                    isRustInspecting = true
                    Task { await runRustInspectionWork() }
                }
                .disabled(isRustInspecting || rustUpdaterIsBusy)
            }
        }
    }

    /// Live readout for the Rust core: arch slices, version, code
    /// signature, OK/NG verdict, plus Test + Update buttons. Same
    /// synchronous-busy-flag pattern as the naive section above —
    /// see the comment over `naiveBinarySummary` for the audit
    /// rationale.
    @ViewBuilder
    private var rustCoreSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(isRustInspecting ? "Testing…" : "Test") {
                    guard !isRustInspecting && !rustUpdaterIsBusy else { return }
                    isRustInspecting = true
                    Task { await runRustInspectionWork() }
                }
                .disabled(isRustInspecting || rustUpdaterIsBusy)

                Button(rustUpdaterButtonTitle) {
                    guard !rustUpdaterIsBusy && !isRustInspecting else { return }
                    Task { await runRustUpdate() }
                }
                .disabled(rustUpdaterIsBusy || isRustInspecting)

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
                    .fill((verdict.ok ? Color.green : Color.red).opacity(pillAlpha))
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
                    .fill(Color.red.opacity(pillAlpha))
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
                    // Same hover-and-select treatment as the naive
                    // updater message — long failure strings stay
                    // copyable for support tickets.
                    .help(message)
                    .textSelection(.enabled)
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

    /// Same shim as the naive side: callers from non-button entry
    /// points (initial `.task`, post-Choose adopt path, post-Update
    /// re-inspection) flip the busy flag here. The button itself
    /// already set the flag synchronously.
    private func runRustInspection() async {
        if !isRustInspecting {
            isRustInspecting = true
        }
        await runRustInspectionWork()
    }

    private func runRustInspectionWork() async {
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
        // Owned re-inspection: set the flag synchronously so the
        // button stays disabled across the post-update probe.
        isRustInspecting = true
        await runRustInspectionWork()
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
