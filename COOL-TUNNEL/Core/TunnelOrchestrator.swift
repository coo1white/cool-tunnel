// Core/TunnelOrchestrator.swift
//
// Single source of truth for the UI: combines `CoreClient`,
// `SystemProxyController`, persistence, and filesystem paths into one
// observable façade. Views read state from here and call its methods;
// nothing else is `@Observable` in the app.

import Foundation
import Observation

/// One streamed line of engine output, surfaced in the live log view.
public struct LogEntry: Sendable, Identifiable, Hashable {
    public let id: UUID
    public let timestamp: Date
    public let source: LogSource
    public let text: String

    public init(timestamp: Date = .init(), source: LogSource, text: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.source = source
        self.text = text
    }
}

@MainActor
@Observable
public final class TunnelOrchestrator {

    // MARK: - Observable state

    public private(set) var profiles: [Profile] = [.default]
    public var selectedProfileID: String?
    public var settings: AppSettings = .default
    public private(set) var activeMode: ProxyMode = .stopped
    public private(set) var isRunning: Bool = false
    public private(set) var logEntries: [LogEntry] = []
    public private(set) var firewallState: FirewallState = .unknown
    public private(set) var lastDiagnosticReport: DiagnosticReport?
    public private(set) var lastLatencyReport: LatencyReport?
    public private(set) var lastError: String?

    // MARK: - Dependencies (injected; defaultable)

    private let core: CoreClient
    private let proxyController: SystemProxyController
    private let firewall: FirewallProbe
    private let profileStore: ProfileStore
    private let settingsStore: SettingsStore
    private let keychain: KeychainStore
    private let paths: AppSupportPaths
    private let naiveResolver: NaiveBinaryResolver

    private var eventTask: Task<Void, Never>?
    private var didBootstrap: Bool = false
    private let maxLogEntries: Int = 1000
    /// Re-entrancy guard for [`refreshNaiveDescriptor`]. The Settings
    /// view's `.task` can fire two refreshes back-to-back if the user
    /// opens / dismisses / reopens the sheet quickly; without this
    /// guard each invocation would spawn its own `lipo` + `--version`
    /// subprocess pair and stomp the cached descriptor with whichever
    /// returned last (not necessarily the most recent settings).
    private var isRefreshingNaive: Bool = false

    /// Cached descriptor for the naive binary the app is currently
    /// configured to spawn. Populated on bootstrap and after each
    /// settings change so the Settings view can render the chip / arch
    /// summary without firing extra subprocesses.
    public private(set) var activeNaiveDescriptor: NaiveBinaryDescriptor?

    /// Detected host CPU. Exposed so the Settings view can render
    /// "This Mac: Apple Silicon" without re-querying sysctl.
    public let hostArchitecture: HostArchitecture = .current

    // MARK: - Construction

    public init(
        core: CoreClient,
        proxyController: SystemProxyController,
        firewall: FirewallProbe,
        profileStore: ProfileStore,
        settingsStore: SettingsStore,
        keychain: KeychainStore,
        paths: AppSupportPaths,
        naiveResolver: NaiveBinaryResolver = NaiveBinaryResolver()
    ) {
        self.core = core
        self.proxyController = proxyController
        self.firewall = firewall
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.keychain = keychain
        self.paths = paths
        self.naiveResolver = naiveResolver
    }

    /// Builds an orchestrator wired with default dependencies sourced from
    /// the running app bundle.
    public static func bootstrap() -> TunnelOrchestrator {
        let executableURL =
            Bundle.main.url(
                forResource: "cool-tunnel-core",
                withExtension: nil
            ) ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/cool-tunnel-core")

        let paths: AppSupportPaths
        do {
            paths = try AppSupportPaths()
        } catch {
            fatalError("unable to create application support directory: \(error)")
        }

        let keychain = KeychainStore()
        return TunnelOrchestrator(
            core: CoreClient(executableURL: executableURL),
            proxyController: SystemProxyController(),
            firewall: FirewallProbe(),
            profileStore: ProfileStore(keychain: keychain),
            settingsStore: SettingsStore(),
            keychain: keychain,
            paths: paths
        )
    }

    // MARK: - Bootstrap

    /// Loads persisted state and starts the engine. Idempotent.
    ///
    /// Performs **exactly one** code-signature check before the UI
    /// appears: `cool-tunnel-core` is verified inside [`CoreClient.start`]
    /// because the engine has to launch for the app to function. The
    /// bundled `naive` binary is **not** verified here — its signature,
    /// host-arch slice, and `--version` output are inspected lazily the
    /// first time the user opens Settings or clicks Start, so launch
    /// stays fast and we avoid pre-paying authentication cost the user
    /// may never need (read-only profile browsing doesn't spawn naive).
    public func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        profiles = profileStore.loadProfiles()
        selectedProfileID = profileStore.loadSelectedID() ?? profiles.first?.id
        settings = settingsStore.load()
        firewallState = await firewall.currentState()

        do {
            try await core.start()
            subscribeToEvents()
        } catch {
            recordError("engine failed to start: \(error)")
        }
    }

    /// Re-inspects the active naive binary and caches the descriptor for
    /// the Settings view. Called from `SettingsView.onAppear` (lazy first
    /// inspection) and after the user changes the override path so the
    /// chip / arch summary stays accurate. **Not** called from
    /// `bootstrapIfNeeded` — see that method's docs for the rationale.
    ///
    /// Re-entrant calls overlap when the user opens / dismisses /
    /// reopens Settings rapidly. We guard with `isRefreshingNaive` so
    /// only one inspection runs at a time; subsequent callers get the
    /// cached descriptor produced by the first call.
    public func refreshNaiveDescriptor() async {
        if isRefreshingNaive {
            // Wait for the in-flight refresh to publish, then return.
            // Polling at the actor's natural cadence is fine here —
            // descriptors take subprocess-call time, not microseconds.
            while isRefreshingNaive { await Task.yield() }
            return
        }
        isRefreshingNaive = true
        defer { isRefreshingNaive = false }
        do {
            activeNaiveDescriptor = try await naiveResolver.resolve(settings: settings)
        } catch let error as NaiveResolverError {
            // The failure modes here all *prevent the proxy from
            // starting* (missing slice, bad signature, missing file).
            // Surface as a real error so the UI can highlight it; the
            // log line is still emitted for developer triage.
            recordError("naive binary unusable: \(error.localizedDescription)")
            activeNaiveDescriptor = nil
        } catch {
            recordError("naive binary inspection failed: \(error.localizedDescription)")
            activeNaiveDescriptor = nil
        }
    }

    /// Stops the engine and reverts the system proxy. Called from the
    /// SwiftUI scene's `onDisappear` hook.
    public func shutdown() async {
        eventTask?.cancel()
        eventTask = nil
        try? await proxyController.disableAll()
        await core.stop()
        activeMode = .stopped
        isRunning = false
    }

    // MARK: - Profile management

    public var selectedProfile: Profile? {
        get {
            guard let id = selectedProfileID else { return profiles.first }
            return profiles.first { $0.id == id }
        }
        set {
            guard let updated = newValue else { return }
            if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
                profiles[index] = updated
            }
            selectedProfileID = updated.id
            profileStore.save(profiles: profiles)
            profileStore.save(selectedID: selectedProfileID)
        }
    }

    public func addProfile(named name: String = "New profile") {
        let newProfile = Profile(
            id: UUID().uuidString,
            server: "",
            username: "",
            password: "",
            localPort: "1080"
        )
        profiles.append(newProfile)
        selectedProfileID = newProfile.id
        profileStore.save(profiles: profiles)
        profileStore.save(selectedID: selectedProfileID)
    }

    public func removeSelectedProfile() {
        guard let id = selectedProfileID, profiles.count > 1 else { return }
        profiles.removeAll { $0.id == id }
        selectedProfileID = profiles.first?.id
        profileStore.save(profiles: profiles)
        profileStore.save(selectedID: selectedProfileID)
        // Delete the password for the removed profile so a stale Keychain
        // entry does not linger if the user later creates a new profile
        // with the same id (e.g. another "default").
        try? keychain.deletePassword(forProfileID: id)
    }

    public func persistSettings() {
        settingsStore.save(settings)
    }

    // MARK: - Mode switching

    /// Atomically switches the *active* proxy mode. Three cases:
    ///
    /// 1. Proxy is stopped → equivalent to `start(mode:)`
    /// 2. Proxy is running in `mode` already → no-op (don't bounce
    ///    the supervisor for a click that selects the current mode)
    /// 3. Proxy is running in a *different* mode → stop, then start in
    ///    the new mode in one shot — the user only sees a single
    ///    state-changed flicker rather than a manual stop / start
    ///    dance
    ///
    /// This is what powers the single-button mode picker in the UI:
    /// tapping a mode chip while the tunnel is live hot-swaps it
    /// instead of forcing the user to stop first.
    public func switchMode(to newMode: ProxyMode) async throws {
        guard newMode != .stopped else {
            await stop()
            return
        }
        if isRunning && activeMode == newMode {
            return
        }
        if isRunning {
            // Stop without surfacing a "stopped" error — this is one
            // logical user action, not two.
            await stop()
        }
        try await start(mode: newMode)
    }

    // MARK: - Lifecycle commands

    /// Validates the selected profile, writes config + PAC, spawns naive,
    /// and applies the requested system-proxy configuration.
    public func start(mode: ProxyMode) async throws {
        guard mode != .stopped else { return }
        guard let profile = selectedProfile else {
            throw OrchestratorError.noProfile
        }
        // Clear stale error from any previous failed attempt — a successful
        // start should not leave the user staring at last week's failure.
        lastError = nil

        // Validate via engine. The engine's `Profile` deserializer enforces
        // every rule the Swift form previously did inline.
        let validation = try await core.send(.validateProfile(profile))
        guard case .validation(let report) = validation, report.ok else {
            throw OrchestratorError.invalidProfile(reason: extractValidationReason(validation))
        }

        // Generate engine artifacts.
        let configResponse = try await core.send(.generateNaiveConfig(profile))
        guard case .naiveConfig(let configJSON) = configResponse else {
            throw OrchestratorError.unexpectedResponse
        }
        try writeRestrictedFile(configJSON, to: paths.configFile)

        let port = try parsePort(profile.localPort)

        if mode == .smart {
            let pacResponse = try await core.send(
                .generatePac(directDomains: settings.directDomains, port: port)
            )
            guard case .pac(let pacJS) = pacResponse else {
                throw OrchestratorError.unexpectedResponse
            }
            try writeRestrictedFile(pacJS, to: paths.pacFile)
        }

        // Resolve the naive binary through the dedicated resolver: it
        // checks the host arch slice, runs `--version`, verifies the
        // code signature, and refuses to return a descriptor that would
        // crash on spawn. One typed error covers all four failure modes.
        let descriptor: NaiveBinaryDescriptor
        do {
            descriptor = try await naiveResolver.resolve(settings: settings)
        } catch let error as NaiveResolverError {
            throw OrchestratorError.naiveBinaryUnusable(error)
        }
        activeNaiveDescriptor = descriptor

        let started = try await core.send(
            .startProxy(
                binaryPath: descriptor.url.path,
                configPath: paths.configFile.path,
                port: port
            ))
        guard case .started = started else {
            throw OrchestratorError.unexpectedResponse
        }

        // Apply system proxy.
        switch mode {
        case .smart:
            try await proxyController.enableSmartPAC(pacURL: paths.pacFile)
        case .global:
            try await proxyController.enableGlobalSOCKS(port: port)
        case .localOnly:
            try await proxyController.disableAll()
        case .stopped:
            break
        }

        activeMode = mode
        isRunning = true
        appendInfo("started in \(mode.title)")
    }

    public func stop() async {
        try? await proxyController.disableAll()
        do {
            _ = try await core.send(.stopProxy)
        } catch {
            recordError("stop failed: \(error)")
        }
        activeMode = .stopped
        isRunning = false
        appendInfo("stopped")
    }

    public func runDiagnostics() async {
        // Wall-clock the whole call client-side so the summary can show
        // total elapsed (engine probes are streamed individually via
        // `diagnosticProgress` events while we await the response).
        // `ContinuousClock` is monotonic — `Date()` can jump backward
        // on NTP adjustments and report a negative elapsed time.
        let started = ContinuousClock.now
        appendInfo("diagnostics: starting…")
        do {
            let response = try await core.send(.runDiagnostics)
            if case .diagnostic(let report) = response {
                lastDiagnosticReport = report
                let total = Self.formatElapsed(since: started)
                appendInfo("diagnostics: \(report.probes.count) probes in \(total)")
            }
        } catch {
            recordError("diagnostics failed: \(error)")
        }
    }

    public func runLatencyTest(mode: ProxyTestMode) async {
        let started = ContinuousClock.now
        appendInfo("latency: starting (\(mode.rawValue))…")
        do {
            let response = try await core.send(.runLatencyTest(mode: mode))
            if case .latency(let report) = response {
                lastLatencyReport = report
                // Per-sample timing breakdown into the live log so the
                // user can read the DNS / connect / TLS / first-byte
                // split alongside the total — matches how clash-verge
                // surfaces probe results in its log pane.
                for sample in report.samples {
                    appendInfo(Self.formatSampleLine(sample))
                }
                let total = Self.formatElapsed(since: started)
                appendInfo("latency: \(report.samples.count) samples in \(total)")
            }
        } catch {
            recordError("latency test failed: \(error)")
        }
    }

    // MARK: - Time formatting helpers

    /// Renders a monotonic interval as `Nms` (or `N.NNs` if ≥ 1s) for
    /// log lines. Fractional under-millisecond values round up to `1ms`
    /// so user-visible timings never show `0ms`. Driven by
    /// `ContinuousClock` so wall-clock NTP adjustments cannot make a
    /// successful operation appear to take negative time.
    private static func formatElapsed(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
        // `Duration.components` is `(seconds: Int64, attoseconds: Int64)`.
        // Convert to milliseconds via Double — this is a logging helper,
        // so we don't need integer-exact precision.
        let comps = elapsed.components
        let ms = max(
            1.0,
            Double(comps.seconds) * 1000.0 + Double(comps.attoseconds) / 1.0e15
        )
        if ms >= 1000.0 {
            return String(format: "%.2fs", ms / 1000.0)
        }
        return "\(Int(ms.rounded()))ms"
    }

    /// One-liner readout for a [`LatencySample`], suitable for the live
    /// log. Includes total elapsed, the curl-reported breakdown
    /// (DNS / connect / TLS / first-byte), and a status glyph. Each
    /// numeric field is run through [`formatMs`] so a malformed engine
    /// payload (NaN, infinity, negative) cannot trap with `Int(_:)`.
    private static func formatSampleLine(_ sample: LatencySample) -> String {
        let glyph = sample.ok ? "✓" : "✗"
        let total = formatMs(sample.elapsedMs)
        let dns = formatMs(sample.dnsMs)
        let connect = formatMs(sample.connectMs)
        let tls = formatMs(sample.tlsMs)
        let firstByte = formatMs(sample.firstByteMs)
        return
            "\(glyph) \(sample.url) total=\(total) dns=\(dns) connect=\(connect) tls=\(tls) ttfb=\(firstByte)"
    }

    /// Defensive `Double → "Nms"` formatter. Rust clamps these values
    /// to a finite non-negative `u64` before serialising, but the Swift
    /// `Codable` decoder accepts any `Double`. Keeping the guard here
    /// means a future protocol-version mismatch (or a hand-crafted
    /// engine reply) cannot crash the UI with an `Int(_:)` trap.
    private static func formatMs(_ ms: Double) -> String {
        guard ms.isFinite, ms >= 0 else { return "?" }
        return "\(Int(ms.rounded()))ms"
    }

    // MARK: - Event subscription

    private func subscribeToEvents() {
        eventTask?.cancel()
        eventTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let stream = await self.core.events()
            for await event in stream {
                self.handle(event: event)
            }
        }
    }

    private func handle(event: CoreEvent) {
        switch event {
        case .logLine(let source, let line):
            appendLog(source: source, text: line)
        case .stateChanged(let running):
            isRunning = running
            if !running { activeMode = .stopped }
        case .anomaly(let reason, let detail):
            appendLog(source: .stderr, text: "[anomaly:\(reason.rawValue)] \(detail)")
            // `ListeningOutsideLoopback` means naive is exposed beyond
            // 127.0.0.1 — every byte from any LAN client could be
            // proxied. This is the one anomaly the original Swift
            // implementation auto-stopped on; we restore that behaviour
            // here. The other anomalies (count thresholds) stay advisory.
            if reason == .listeningOutsideLoopback {
                recordError("Critical: \(detail). Auto-stopping.")
                Task { await self.stop() }
            }
        case .diagnosticProgress(let step, let ok, let elapsedMs):
            // `elapsedMs == 0` means the engine omitted timing (older
            // build); fall back to the legacy bare-step format so users
            // running mismatched binaries still get useful output.
            let glyph = ok ? "✓" : "✗"
            if elapsedMs == 0 {
                appendInfo("\(glyph) \(step)")
            } else {
                appendInfo("\(glyph) \(step) (\(elapsedMs)ms)")
            }
        }
    }

    // MARK: - Helpers

    private func appendLog(source: LogSource, text: String) {
        logEntries.append(LogEntry(source: source, text: text))
        trimLogs()
    }

    private func appendInfo(_ message: String) {
        logEntries.append(LogEntry(source: .stdout, text: "[orchestrator] \(message)"))
        trimLogs()
    }

    private func recordError(_ message: String) {
        lastError = message
        logEntries.append(LogEntry(source: .stderr, text: "[error] \(message)"))
        trimLogs()
    }

    private func trimLogs() {
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    public func clearLogs() {
        logEntries.removeAll()
    }

    private func parsePort(_ raw: String) throws -> UInt16 {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = UInt16(trimmed), port > 0 else {
            throw OrchestratorError.invalidProfile(reason: "port must be 1..=65535")
        }
        return port
    }

    private func extractValidationReason(_ response: CoreResponse) -> String {
        if case .validation(let report) = response, let reason = report.reason {
            return reason
        }
        return "validation failed"
    }
}

/// Errors raised by the orchestrator (separate from engine and OS errors,
/// which surface as their own types).
public enum OrchestratorError: Error, Sendable, Equatable {
    case noProfile
    case invalidProfile(reason: String)
    case unexpectedResponse
    /// The configured `naive` binary cannot be used: the file is missing,
    /// not a Mach-O, lacks a slice for the host CPU, or has a broken
    /// code signature. The wrapped [`NaiveResolverError`] tells the user
    /// which one — and what to do about it.
    case naiveBinaryUnusable(NaiveResolverError)

    public var localizedDescription: String {
        switch self {
        case .noProfile: "No profile is selected."
        case .invalidProfile(let reason): "Invalid profile: \(reason)"
        case .unexpectedResponse: "Engine returned an unexpected response."
        case .naiveBinaryUnusable(let err):
            "naive binary cannot be used: \(err.localizedDescription)"
        }
    }
}
