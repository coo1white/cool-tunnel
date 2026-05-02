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
    public func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        profiles = profileStore.loadProfiles()
        selectedProfileID = profileStore.loadSelectedID() ?? profiles.first?.id
        settings = settingsStore.load()
        firewallState = await firewall.currentState()
        await refreshNaiveDescriptor()

        do {
            try await core.start()
            subscribeToEvents()
        } catch {
            recordError("engine failed to start: \(error)")
        }
    }

    /// Re-inspects the active naive binary and caches the descriptor for
    /// the Settings view. Called on bootstrap and after the user changes
    /// the override path so the chip / arch summary stays accurate.
    public func refreshNaiveDescriptor() async {
        do {
            activeNaiveDescriptor = try await naiveResolver.resolve(settings: settings)
        } catch let error as NaiveResolverError {
            // Surfacing the typed error in the log lets a developer see
            // *why* resolution failed without forcing the user to open
            // Settings — but we keep `lastError` clear so a stale
            // descriptor failure does not block manual retries.
            appendInfo("naive: \(error.localizedDescription)")
            activeNaiveDescriptor = nil
        } catch {
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
        do {
            let response = try await core.send(.runDiagnostics)
            if case .diagnostic(let report) = response {
                lastDiagnosticReport = report
                appendInfo("diagnostics: \(report.probes.count) probes")
            }
        } catch {
            recordError("diagnostics failed: \(error)")
        }
    }

    public func runLatencyTest(mode: ProxyTestMode) async {
        do {
            let response = try await core.send(.runLatencyTest(mode: mode))
            if case .latency(let report) = response {
                lastLatencyReport = report
                appendInfo("latency: \(report.samples.count) samples")
            }
        } catch {
            recordError("latency test failed: \(error)")
        }
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
        case .diagnosticProgress(let step, let ok):
            appendInfo("\(ok ? "✓" : "✗") \(step)")
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
