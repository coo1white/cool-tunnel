// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// Single source of truth for the UI: combines `CoreClient`,
// `SystemProxyController`, persistence, and filesystem paths
// into one observable façade. Nothing else in the app is
// `@Observable`.

import Darwin
import Foundation
import Network
import Observation
import os

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

    /// Live state of the sleep / wake transition. Drives the
    /// `HeaderStatusPill`'s transient labels; `.idle` is the
    /// steady state and falls back to the base `isRunning` /
    /// `lastError` rendering.
    public private(set) var sleepWakeState: SleepWakeState = .idle

    /// Snapshot of `activeMode` at `handleSystemWillSleep`,
    /// re-applied autonomously on wake. Cleared once recovery
    /// completes (success or failure).
    private var modeBeforeSleep: ProxyMode?
    public private(set) var logEntries: [LogEntry] = []
    public private(set) var firewallState: FirewallState = .unknown
    public private(set) var lastDiagnosticReport: DiagnosticReport?
    public private(set) var lastLatencyReport: LatencyReport?
    public private(set) var lastError: String?

    /// Layer attribution for the most recent connection failure.
    /// Renders as a `[ISP]` / `[VPS]` / `[Local Kernel]` chip on
    /// the error banner. `nil` falls back to plain-text rendering.
    public private(set) var lastErrorLayer: ErrorLayer?

    // MARK: - Dependencies (injected; defaultable)

    private let core: CoreClient
    private let proxyController: SystemProxyController
    private let firewall: FirewallProbe
    private let profileStore: ProfileStore
    private let settingsStore: SettingsStore
    private let paths: AppSupportPaths
    private let singboxResolver: SingboxBinaryResolver
    private let telemetry: LifecycleTelemetryLogger

    private var eventTask: Task<Void, Never>?
    private var didBootstrap: Bool = false
    /// Hardware-derived cap on retained log entries: a lower cap
    /// keeps the SwiftUI diff cheap on a flaky-network burst.
    private let maxLogEntries: Int = PerformanceProfile.current.maxLogEntries
    /// In-flight task for [`refreshSingboxDescriptor`]. Late callers
    /// `await` the existing task rather than spawning duplicate
    /// `lipo` + `version` subprocess pairs.
    private var refreshSingboxTask: Task<Void, Never>?

    /// Debounced settings autosave; replaced on every call so a
    /// burst collapses into a single write.
    private var persistSettingsTask: Task<Void, Never>?

    /// Single-flight guard for `listeningOutsideLoopback`
    /// auto-stop. Defeats the queued-stop race on a burst.
    private var autoStopTask: Task<Void, Never>?
    private var selfHealTask: Task<Void, Never>?
    /// Single-flight guard for credential auto-sync. A burst of
    /// HTTP-407-shaped stderr lines from one failed start would
    /// otherwise queue duplicate re-fetches against the panel.
    private var credentialAutoSyncTask: Task<Void, Never>?
    /// Timestamp of the last auto-sync attempt. Pairs with
    /// `credentialAutoSyncCooldown` so a continuously-retrying
    /// engine can't hammer the panel.
    private var lastCredentialAutoSyncAt: ContinuousClock.Instant?
    /// Lower bound between auto-sync attempts.
    private static let credentialAutoSyncCooldown: Duration = .seconds(30)
    private var pendingLogEntries: [LogEntry] = []
    private var logFlushTask: Task<Void, Never>?
    private let logFlushIntervalNanos: UInt64 = PerformanceProfile.current.logFlushIntervalNanos
    private let maxLogBatchEntries: Int = PerformanceProfile.current.maxLogBatchEntries
    private let maxLogLineCharacters: Int = PerformanceProfile.current.maxLogLineCharacters

    /// Cached descriptor for the sing-box binary the app is
    /// configured to spawn. Settings reads from this rather than
    /// re-firing `lipo` / `version` subprocesses.
    public private(set) var activeSingboxDescriptor: SingboxBinaryDescriptor?

    // MARK: - Construction

    public init(
        core: CoreClient,
        proxyController: SystemProxyController,
        firewall: FirewallProbe,
        profileStore: ProfileStore,
        settingsStore: SettingsStore,
        paths: AppSupportPaths,
        singboxResolver: SingboxBinaryResolver = SingboxBinaryResolver(),
        telemetry: LifecycleTelemetryLogger? = nil
    ) {
        self.core = core
        self.proxyController = proxyController
        self.firewall = firewall
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.paths = paths
        self.singboxResolver = singboxResolver
        self.telemetry = telemetry ?? LifecycleTelemetryLogger(url: paths.lifecycleTelemetryFile)
        self.telemetry.record(
            "orchestrator.init",
            mode: nil,
            running: false,
            details: ["telemetry_path": paths.lifecycleTelemetryFile.path]
        )
    }

    /// Builds an orchestrator with default dependencies.
    public static func bootstrap() -> TunnelOrchestrator {
        // Degrade to a temp dir + visible `lastError` rather than
        // `fatalError` if Application Support is unavailable —
        // boot-time crashes bypass every diagnostic surface.
        let paths: AppSupportPaths
        var bootstrapError: String?
        do {
            paths = try AppSupportPaths()
        } catch {
            bootstrapError =
                "Application Support unavailable: \(error.localizedDescription) — engine will refuse to start. Free disk space and relaunch."
            paths = AppSupportPaths.fallback()
        }

        // Read settings (UserDefaults only — no credential store)
        // so a custom `customRustCorePath` from a previous
        // Settings → Rust Core → Update is honoured. Falls back
        // to the bundled binary on missing override.
        let savedSettings = SettingsStore().load()
        let bundledCore = RustCoreResolver.bundledURL()
        let executableURL: URL
        if !savedSettings.customRustCorePath.isEmpty,
            FileManager.default.isExecutableFile(atPath: savedSettings.customRustCorePath)
        {
            executableURL = URL(fileURLWithPath: savedSettings.customRustCorePath)
        } else {
            executableURL = bundledCore
        }

        // Passwords default to a file-backed store at
        // `~/Library/Application Support/COOL-TUNNEL/credentials.json`
        // mode 0600. Same posture as Keychain on a single-user
        // Mac, without the system password prompt that fires
        // when the ad-hoc-signed binary hash changes. Keychain
        // stays as the legacy leg of `MigratingCredentialStore`
        // for upgrades from pre-Keychain-migration builds.
        let fileStore = FileCredentialStore.defaultStore(paths: paths)
        let credentials = MigratingCredentialStore(
            primary: fileStore,
            legacy: KeychainStore()
        )
        let orchestrator = TunnelOrchestrator(
            core: CoreClient(executableURL: executableURL),
            proxyController: SystemProxyController(),
            firewall: FirewallProbe(),
            profileStore: ProfileStore(credentials: credentials),
            settingsStore: SettingsStore(),
            paths: paths
        )
        if let bootstrapError {
            orchestrator.lastError = bootstrapError
        }
        return orchestrator
    }

    // MARK: - Bootstrap

    /// Loads persisted state and starts the engine. Idempotent.
    ///
    /// Verifies `cool-tunnel-core` inside [`CoreClient.start`]
    /// (it has to launch for the app to function). The bundled
    /// `sing-box` binary is NOT verified here — its sig / arch /
    /// version are inspected lazily on first Settings open or
    /// Start, so read-only profile browsing doesn't pre-pay the
    /// authentication cost.
    public func bootstrapIfNeeded() async {
        // `subscribeToEvents` flips `didBootstrap = false` on
        // engine death so a follow-up call re-spawns.
        guard !didBootstrap else { return }
        recordTelemetry("bootstrap.begin")

        // Crash-recovery sweep BEFORE other startup work: if the
        // previous run died with system proxy enabled, the user's
        // network is currently broken and subsequent
        // network-touching calls would fail.
        await recoverFromCrashIfNeeded()

        profiles = profileStore.loadProfiles()
        selectedProfileID = profileStore.loadSelectedID() ?? profiles.first?.id
        settings = settingsStore.load()
        firewallState = await firewall.currentState()

        do {
            try await core.start()
            subscribeToEvents()
            // Flip the guard only on success so a Retry button
            // can re-attempt after a transient launch failure.
            didBootstrap = true
            recordTelemetry("bootstrap.success")
        } catch {
            // Engine spawn failure is local-kernel-by-construction;
            // the classifier would only confirm what we know.
            recordError("engine failed to start: \(error)", layer: .localKernel)
            recordTelemetry("bootstrap.failure", layer: .localKernel, message: error.localizedDescription)
        }
    }

    /// Re-inspects the active sing-box binary and caches the
    /// descriptor for the Settings view. Coalesces concurrent
    /// refreshes onto the in-flight task — a MainActor busy-loop
    /// would pin a CPU and starve the UI.
    public func refreshSingboxDescriptor() async {
        if let inFlight = refreshSingboxTask {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.activeSingboxDescriptor = try await self.singboxResolver.resolve(settings: self.settings)
            } catch let error as SingboxResolverError {
                self.recordError("sing-box binary unusable: \(error.localizedDescription)", layer: .localKernel)
                self.activeSingboxDescriptor = nil
            } catch {
                self.recordError(
                    "sing-box binary inspection failed: \(error.localizedDescription)",
                    layer: .localKernel)
                self.activeSingboxDescriptor = nil
            }
        }
        refreshSingboxTask = task
        await task.value
        refreshSingboxTask = nil
    }

    /// Stops the engine and reverts the system proxy. Sets
    /// `isShuttingDown` so the event-stream-end handler knows
    /// the upcoming silence is expected (not an engine crash).
    public func shutdown() async {
        recordTelemetry("shutdown.begin")
        isShuttingDown = true
        selfHealTask?.cancel()
        selfHealTask = nil
        credentialAutoSyncTask?.cancel()
        credentialAutoSyncTask = nil
        flushPendingLogs()
        // Flush the debounced settings write — without this, an
        // edit made <250 ms before Cmd+Q is silently dropped.
        flushSettings()
        eventTask?.cancel()
        eventTask = nil
        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        // Clear the sentinel so next launch's recovery scan
        // doesn't fire spuriously.
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        await core.stop()
        activeMode = .stopped
        isRunning = false
        recordTelemetry("shutdown.success")
    }

    /// True from the moment we begin tearing the engine down on
    /// purpose. Lets `subscribeToEvents` distinguish "user quit"
    /// from "engine died on us" when the event stream finishes.
    private var isShuttingDown: Bool = false

    /// Transition lock. Two concurrent mode switches would race
    /// on `paths.configFile`, `proxyController` state, and
    /// `core.send` ordering; the second click is a clean no-op.
    private var transitionInFlight: Bool = false

    /// Suppresses the `stateChanged(false)` recovery-error path
    /// for the duration of a user-initiated stop. Without this,
    /// the engine's intentional shutdown event arrives before
    /// `stop()` sets `isRunning = false`, and the recovery
    /// branch fires for a healthy shutdown.
    private var userStopInFlight: Bool = false

    /// Profile ID the engine started with — separate from
    /// `selectedProfileID` so `selectedProfile.set` can detect
    /// "user edited the active profile while connected" and
    /// surface a banner instead of silently keeping the running
    /// engine on the old config.
    private var activeProfileID: String?

    /// Dirty flag: when true, the running sing-box's config is
    /// stale and a mode switch must go through the full
    /// stop-engine / start-engine path rather than the no-restart
    /// hot-swap. Separate from `lastError` so dismissing the
    /// banner doesn't accidentally clear the orchestrator's
    /// internal "config is stale" truth.
    private var activeProfileEdited: Bool = false

    // MARK: - Profile management

    public var selectedProfile: Profile? {
        get {
            guard let id = selectedProfileID else { return profiles.first }
            return profiles.first { $0.id == id }
        }
        set {
            guard let updated = newValue else { return }
            // Detect "user edited the active profile while
            // connected" and surface a banner. We flag (not
            // auto-restart) — restart-on-edit could drop in-flight
            // work for users typing a draft.
            if isRunning, let active = activeProfileID, active == updated.id {
                let prior = profiles.first(where: { $0.id == updated.id })
                if let prior = prior, prior != updated {
                    lastError =
                        "Profile edits applied — click Stop, then a mode chip to use them. The running connection is still on the old config."
                    // Mark the running engine's config stale so a
                    // subsequent `switchMode` takes the full
                    // restart path that picks up the edits.
                    activeProfileEdited = true
                }
            }
            // Append-when-not-found so a value assigned with an
            // id not yet in `profiles` (subscription-import path
            // / dangling selectedProfileID) is persisted rather
            // than dropped.
            if let index = profiles.firstIndex(where: { $0.id == updated.id }) {
                profiles[index] = updated
            } else {
                profiles.append(updated)
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
            uuid: "",
            reality: .empty,
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
        // Delete the credential entry too — through the migrating
        // store so the legacy Keychain copy is cleaned up.
        profileStore.deleteUUID(forProfileID: id)
    }

    /// Debounced settings autosave (250 ms). Bound directly to
    /// SwiftUI form fields so a typed paragraph collapses into
    /// one write; `flushSettings()` flushes synchronously on
    /// explicit commit.
    public func persistSettings() {
        persistSettingsTask?.cancel()
        persistSettingsTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)  // try-ok: sleep cancellation
            guard !Task.isCancelled, let self else { return }
            self.settingsStore.save(self.settings)
        }
    }

    /// Skip the debounce window and write `settings` synchronously.
    /// Use from explicit commit points (Done button, app shutdown).
    public func flushSettings() {
        persistSettingsTask?.cancel()
        persistSettingsTask = nil
        settingsStore.save(settings)
    }

    // MARK: - Subscription import

    /// Fetches a subscription manifest from `urlString` and
    /// imports its first profile's credentials. Throws typed
    /// [`SubscriptionImportError`] keyed on the failure mode so
    /// the UI banner can match (revoked / expired / server-down).
    ///
    /// Note: 404 / 422 don't reach this branch in practice — the
    /// panel's `SubscriptionController` deliberately serves the
    /// cover-site response to defeat enumeration, so the client
    /// typically sees `200 text/html` and routes through the
    /// manifest-decode-fails branch.
    public func importFromSubscriptionURL(_ urlString: String) async throws {
        // Up-front URL validation so a malformed input surfaces
        // as `invalidURL` rather than paying for a fetch.
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https"
        else {
            throw SubscriptionImportError.invalidURL
        }
        // Never log the raw subscription string — the URL path
        // typically embeds the subscription token. A
        // `url.host ?? urlString` fallback would leak the token
        // for `https:///path` and similar parser-permissive
        // shapes. Log host only.
        let host = url.host.flatMap { $0.isEmpty ? nil : $0 } ?? "<unknown>"
        appendInfo("subscription: fetching \(host)…")

        // The panel itself answers every error with a 200 cover-site,
        // so the 4xx/5xx branches fire only when something in front of
        // the panel (CDN, proxy interposition, DNS hijack) returns its
        // own status.
        let manifest: SubscriptionManifestV2
        do {
            manifest = try await SubscriptionClient().fetch(from: trimmed)
        } catch let err as SubscriptionClientError {
            switch err {
            case .malformedURL, .nonHTTPSURL:
                throw SubscriptionImportError.invalidURL
            case .transportFailed(let msg):
                throw SubscriptionImportError.networkError(msg)
            case .httpStatus(let code):
                switch code {
                case 401: throw SubscriptionImportError.subscriptionRevoked
                case 404, 422: throw SubscriptionImportError.tokenInvalid
                case 429: throw SubscriptionImportError.rateLimited
                case 500...599: throw SubscriptionImportError.serverError(status: code)
                default: throw SubscriptionImportError.unexpectedStatus(code)
                }
            case .malformedManifest, .unexpectedContentType:
                // Cover-site path for any rejected token — UI shows
                // "URL didn't match an account".
                throw SubscriptionImportError.tokenInvalid
            case .oversizeBody(let cap):
                throw SubscriptionImportError.manifestTooLarge(cap: cap)
            case .manifestRejected(let validation):
                switch validation {
                case .unsupportedVersion(let got, _):
                    throw SubscriptionImportError.unsupportedVersion(got: got)
                case .noProfiles:
                    throw SubscriptionImportError.noProfiles
                case .tooManyProfiles, .counterfeitCapabilities,
                    .invalidIssuedAt, .malformedExpiry, .validityTooLong,
                    .blockedHost, .missingUuid, .missingRealityPublicKey,
                    .missingRealityDestHost:
                    // All nine are stub/counterfeit signals OR
                    // operator-side misconfiguration (Reality
                    // keypair not generated, UUID column empty)
                    // with the same user action — "do not connect,
                    // contact operator"; collapse to one banner.
                    // Support can pivot on the structured os_log
                    // entry to distinguish the operator-fix
                    // sub-cases.
                    throw SubscriptionImportError.manifestCounterfeit
                case .expired:
                    throw SubscriptionImportError.manifestExpired
                case .stale(let ageSeconds):
                    let days = max(1, Int(ageSeconds / (24 * 60 * 60)))
                    throw SubscriptionImportError.manifestStale(daysOld: days)
                }
            }
        }

        // Defence-in-depth — `manifest.validate` already
        // rejected an empty profile list.
        guard let primary = manifest.primaryProfile else {
            throw SubscriptionImportError.noProfiles
        }

        // Preserve user's `localPort` and existing profile id —
        // the manifest is authoritative for credentials, not
        // per-machine UI state. `subscriptionURL` is persisted so
        // the auth-failure auto-sync flow can re-fetch when the
        // upstream rotates credentials.
        //
        // **v3.0.0 (sub-phase F):** the imported `Profile` carries
        // the VLESS `uuid` and the Reality block directly. v2.x
        // basic-auth `password` is gone; the engine driving sing-box
        // consumes `uuid` + `reality.*` to render the client
        // `config.json` and complete the VLESS+Reality handshake
        // against `cool-tunnel-server`'s matching keypair.
        let imported = Profile(
            id: selectedProfile?.id ?? UUID().uuidString,
            server: "\(primary.host):\(primary.port)",
            username: primary.username,
            uuid: primary.uuid,
            reality: ProfileReality(
                publicKey: primary.reality.publicKey,
                destHost: primary.reality.destHost,
                shortId: primary.reality.shortId
            ),
            localPort: selectedProfile?.localPort ?? "1080",
            subscriptionURL: trimmed
        )
        selectedProfile = imported
        // Don't log username (treated as account identifier by
        // the engine's redaction) or `host:port` (operator-
        // fingerprinting infrastructure metadata).
        appendInfo("subscription: imported new credentials")
    }

    // MARK: - Mode switching

    /// Atomically switches the active proxy mode.
    ///
    /// - Stopped → equivalent to `start(mode:)`.
    /// - Already running in `mode` → no-op.
    /// - Running in a different mode → hot-swap with a single
    ///   observable transition. `isRunning` never blinks false.
    ///
    /// When the active profile is unchanged the hot-swap takes
    /// the no-restart path: sing-box keeps its listener, only the
    /// system-proxy + PAC config changes, and apps don't see the
    /// 200-500 ms "connection refused" gap a respawn produces.
    /// Falls through to the full restart path on:
    /// - profile edited (`activeProfileEdited` — sing-box needs new
    ///   config);
    /// - selected profile changed
    ///   (`selectedProfileID != activeProfileID`);
    /// - `applyModeWithoutRestart` threw (partial proxyController
    ///   state recovered by `stopQuiet.disableAll()`).
    public func switchMode(to newMode: ProxyMode) async throws {
        recordTelemetry(
            "switch.request",
            details: ["target_mode": newMode.rawValue]
        )
        selfHealTask?.cancel()
        selfHealTask = nil
        // Mode switch supersedes any in-flight credential
        // auto-sync — its captured `activeModeAtTrigger` would
        // otherwise restart the engine in the previous mode.
        credentialAutoSyncTask?.cancel()
        credentialAutoSyncTask = nil
        guard !transitionInFlight else { return }
        transitionInFlight = true
        defer { transitionInFlight = false }

        guard newMode != .stopped else {
            await stop()
            return
        }
        if isRunning && activeMode == newMode {
            recordTelemetry(
                "switch.noop",
                details: ["target_mode": newMode.rawValue]
            )
            return
        }
        if isRunning {
            // One user action, one log line: quiet-stop here so
            // only the post-start "switched from X to Y" line is
            // emitted, not "stopped" + "started in Y".
            let from = activeMode

            // Try the no-restart path first; gated on same
            // profile, not edited, currently running.
            let canHotSwapWithoutRestart =
                !activeProfileEdited
                && selectedProfileID == activeProfileID
                && activeMode != .stopped
            if canHotSwapWithoutRestart {
                do {
                    try await applyModeWithoutRestart(newMode)
                    // Verify the engine is still alive — the
                    // `transitionInFlight` gate suppresses any
                    // `stateChanged(false)` during the swap
                    // window, so an engine death would otherwise
                    // be silent.
                    try await verifyEngineLiveAfterHotSwap()
                    appendInfo("switched from \(from.title) to \(newMode.title)")
                    recordTelemetry(
                        "switch.success",
                        details: [
                            "from_mode": from.rawValue,
                            "to_mode": newMode.rawValue,
                            "restart": "false",
                        ]
                    )
                    return
                } catch {
                    // Partial `proxyController` state is reset by
                    // stopQuiet's `disableAll()`; startCore then
                    // reapplies. Mark `activeProfileEdited` as
                    // belt-and-suspenders so any future re-check
                    // of the hot-swap gate sees this call as
                    // ineligible. Cleared on next successful
                    // `startCore`.
                    activeProfileEdited = true
                    Self.hotSwapLogger.notice(
                        "no-restart switch to \(newMode.rawValue, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); falling back to full engine restart"
                    )
                }
            }

            // Skip stopQuiet's `isRunning = false / .stopped`
            // flips: observable state stays at the OLD mode until
            // `startCore` writes the NEW one in a single
            // transition, so the UI doesn't blink through "Stop".
            await stopQuiet(publishStoppedState: false)
            do {
                try await startQuiet(mode: newMode)
            } catch {
                // Engine genuinely dead — restore truthful state.
                activeMode = .stopped
                isRunning = false
                recordTelemetry(
                    "switch.failure",
                    message: error.localizedDescription,
                    details: [
                        "from_mode": from.rawValue,
                        "to_mode": newMode.rawValue,
                    ]
                )
                throw error
            }
            appendInfo("switched from \(from.title) to \(newMode.title)")
            recordTelemetry(
                "switch.success",
                details: [
                    "from_mode": from.rawValue,
                    "to_mode": newMode.rawValue,
                    "restart": "true",
                ]
            )
            return
        }
        try await start(mode: newMode)
    }

    /// Hot-swap mode without restarting the engine.
    /// Reapplies system-proxy config (and regenerates PAC for
    /// Smart) while sing-box keeps accepting on 127.0.0.1:port —
    /// no connection drops.
    ///
    /// 1. Regenerate PAC (Smart only) — before touching
    ///    `proxyController` so a PAC-gen failure surfaces with
    ///    no system-proxy change applied.
    /// 2. Apply system-proxy config for `newMode`.
    /// 3. Update the recovery sentinel.
    /// 4. Publish `activeMode = newMode` as a single transition.
    ///
    /// Throws on any failure; caller falls through to the full
    /// engine restart.
    private func applyModeWithoutRestart(_ newMode: ProxyMode) async throws {
        recordTelemetry(
            "switch.hotswap.begin",
            details: ["to_mode": newMode.rawValue]
        )
        // Mirror `startCore`'s optimistic banner clear so a
        // successful swap doesn't leave a stale failure banner.
        lastError = nil
        lastErrorLayer = nil

        guard let profile = selectedProfile else {
            throw OrchestratorError.noProfile
        }
        let port = try parsePort(profile.localPort)

        if newMode == .smart {
            // `settings.directDomains` may have changed since
            // the last start; regenerate every swap so the PAC
            // reflects current intent.
            //
            // **v3.0.0 (sub-phase F):** PAC generation is no longer
            // delegated to the Rust engine — sub-phase D dropped
            // `generate_pac` because the sing-box client config
            // routes through a single VLESS outbound and has no
            // PAC notion of its own. The orchestrator still needs
            // a PAC file for system-proxy smart-mode (macOS's
            // `networksetup -setautoproxyurl`), so we render it
            // in-process from the same `directDomains` list the
            // Rust generator consumed.
            let pacJS = Self.generatePacJavaScript(
                directDomains: settings.directDomains,
                port: port
            )
            try RestrictedFile.write(pacJS, to: paths.pacFile)
        }

        switch newMode {
        case .smart:
            try await proxyController.enableSmartPAC(pacURL: paths.pacFile)
            ProxyActiveFlag.write(
                at: ProxyActiveFlag.path(in: paths.supportDirectory),
                mode: "smart"
            )
        case .global:
            try await proxyController.enableGlobalSOCKS(port: port)
            ProxyActiveFlag.write(
                at: ProxyActiveFlag.path(in: paths.supportDirectory),
                mode: "global"
            )
        case .localOnly:
            try await proxyController.disableAll()
            ProxyActiveFlag.clear(
                at: ProxyActiveFlag.path(in: paths.supportDirectory))
        case .stopped:
            // switchMode never calls here with `.stopped` —
            // explicit case prevents a future caller silently
            // no-op'ing through.
            return
        }

        // Single observable transition: `isRunning` stays true,
        // only the mode chip changes.
        activeMode = newMode
        recordTelemetry(
            "switch.hotswap.applied",
            details: ["to_mode": newMode.rawValue]
        )
    }

    /// Stop path used by `switchMode`. Same teardown as
    /// `stop()` without the `appendInfo("stopped")` line so
    /// switchMode can emit a single "switched from X to Y".
    ///
    /// `publishStoppedState: false` (passed from a hot-swap)
    /// leaves `isRunning` / `activeMode` alone so the UI
    /// doesn't observe a brief "stopped" intermediate state.
    private func stopQuiet(publishStoppedState: Bool = true) async {
        recordTelemetry(
            "stop.quiet.begin",
            details: ["publish_stopped_state": String(publishStoppedState)]
        )
        // Mark this stop user-initiated for the duration of the
        // call so the `stateChanged(false)` event doesn't post a
        // phantom "engine stopped unexpectedly" banner.
        userStopInFlight = true
        defer { userStopInFlight = false }

        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        do {
            _ = try await core.send(.stopProxy)
        } catch {
            recordError("stop failed: \(error)")
        }
        if publishStoppedState {
            activeMode = .stopped
            isRunning = false
        }
        recordTelemetry(
            "stop.quiet.success",
            details: ["publish_stopped_state": String(publishStoppedState)]
        )
    }

    /// Quiet `startCore` variant for switchMode — omits the
    /// "started in X" line.
    private func startQuiet(mode: ProxyMode) async throws {
        try await startCore(mode: mode, log: false)
    }

    /// Post-hot-swap liveness probe. The `transitionInFlight`
    /// gate suppresses `stateChanged(false)` during the swap so
    /// the UI doesn't blink, but that also hides a genuine
    /// engine crash. This probe converts the silent gap into a
    /// yes/no answer the caller can route on.
    ///
    /// **v3.0.0 (sub-phase F):** wire-protocol method name is
    /// `probe_singbox_live`; reply tag is `singbox_liveness`.
    /// The semantics are unchanged from the v2.x `probe_naive_live`
    /// — the engine answers "is the supervised proxy still alive",
    /// the proxy binary is now `sing-box`.
    private func verifyEngineLiveAfterHotSwap() async throws {
        let response = try await core.send(.probeSingboxLive)
        guard case .singboxLiveness(let running, let pid) = response else {
            throw OrchestratorError.unexpectedResponse
        }
        if !running {
            Self.hotSwapLogger.notice(
                "post-swap liveness probe says engine is dead (last known pid=\(pid.map(String.init) ?? "none", privacy: .public)); will route to full restart"
            )
            throw HotSwapError.engineDied
        }
    }

    /// Internal control-flow signal for the hot-swap → full-
    /// restart fallback. Not user-facing.
    private enum HotSwapError: Error {
        case engineDied
    }

    // MARK: - Lifecycle commands

    /// Validates the selected profile, writes config + PAC,
    /// spawns sing-box, applies system-proxy. Logs "started in X".
    public func start(mode: ProxyMode) async throws {
        try await startCore(mode: mode, log: true)
    }

    /// Implementation. `log: false` from `switchMode` suppresses
    /// "started in X" so the caller can emit a single "switched
    /// from X to Y" instead.
    ///
    /// Wrapped in do/catch that publishes any failure to
    /// `lastError` before re-throwing — without this, a
    /// port-collision or spawn-failure showed no UI banner.
    private func startCore(mode: ProxyMode, log: Bool) async throws {
        guard mode != .stopped else { return }
        recordTelemetry(
            "start.begin",
            details: ["target_mode": mode.rawValue]
        )
        // Hoisted above the do/catch so success always begins
        // with a clean banner; failure repopulates from below.
        lastError = nil
        lastErrorLayer = nil

        do {
            guard var profile = selectedProfile else {
                throw OrchestratorError.noProfile
            }

            try hydrateUUIDIfNeeded(&profile)

            // The engine's `Profile` deserializer enforces every
            // rule the Swift form used to do inline.
            let validation = try await core.send(.validateProfile(profile))
            guard case .validation(let report) = validation, report.ok else {
                throw OrchestratorError.invalidProfile(reason: extractValidationReason(validation))
            }

            // **v3.0.0 (sub-phase F):** sing-box client config
            // replaces NaiveProxy `config.json`. The on-disk
            // filename (`paths.configFile`) is unchanged; the JSON
            // shape is the sing-box client format with VLESS+Reality
            // outbound + SOCKS5 inbound.
            let configResponse = try await core.send(.generateSingboxConfig(profile))
            guard case .singboxConfig(let configJSON) = configResponse else {
                throw OrchestratorError.unexpectedResponse
            }
            try RestrictedFile.write(configJSON, to: paths.configFile)

            let port = try parsePort(profile.localPort)

            if mode == .smart {
                // **v3.0.0 (sub-phase F):** Swift-side PAC generator —
                // see `applyModeWithoutRestart` for the rationale (Rust
                // crate dropped `generate_pac` because sing-box's
                // own config has no PAC notion).
                let pacJS = Self.generatePacJavaScript(
                    directDomains: settings.directDomains,
                    port: port
                )
                try RestrictedFile.write(pacJS, to: paths.pacFile)
            }

            // Resolver checks host-arch slice, runs `version`,
            // verifies the code signature, and refuses to return
            // a descriptor that would crash on spawn.
            let descriptor: SingboxBinaryDescriptor
            do {
                descriptor = try await singboxResolver.resolve(settings: settings)
            } catch let error as SingboxResolverError {
                throw OrchestratorError.singboxBinaryUnusable(error)
            }
            activeSingboxDescriptor = descriptor

            let started = try await core.send(
                .startProxy(
                    binaryPath: descriptor.url.path,
                    configPath: paths.configFile.path,
                    port: port,
                    monitorIntervalSecs: PerformanceProfile.current.connectionMonitorIntervalSecs
                ))
            guard case .started(let enginePID) = started else {
                throw OrchestratorError.unexpectedResponse
            }

            switch mode {
            case .smart:
                try await proxyController.enableSmartPAC(pacURL: paths.pacFile)
                // Recovery sentinel so a crash before
                // `disableAll()` is recoverable on next launch.
                ProxyActiveFlag.write(
                    at: ProxyActiveFlag.path(in: paths.supportDirectory),
                    mode: "smart"
                )
            case .global:
                try await proxyController.enableGlobalSOCKS(port: port)
                ProxyActiveFlag.write(
                    at: ProxyActiveFlag.path(in: paths.supportDirectory),
                    mode: "global"
                )
            case .localOnly:
                try await proxyController.disableAll()
                // Local mode doesn't touch system proxy.
                ProxyActiveFlag.clear(
                    at: ProxyActiveFlag.path(in: paths.supportDirectory))
            case .stopped:
                break
            }

            activeMode = mode
            isRunning = true
            // Capture which profile the engine started with —
            // `selectedProfile.set` compares to detect edits.
            activeProfileID = selectedProfileID
            // Engine just resynced — clear the stale-config flag.
            activeProfileEdited = false
            if log {
                appendInfo("started in \(mode.title)")
            }
            recordTelemetry(
                "start.success",
                details: [
                    "mode": mode.rawValue,
                    "local_port": String(port),
                    "engine_pid": String(enginePID),
                ]
            )
        } catch {
            // `OrchestratorError` carries localized descriptions;
            // engine wire errors (`ErrorPayload`) carry the
            // engine's own message ("address already in use").
            let detail =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // Classify the failure into ISP / VPS / Local Kernel
            // so the banner chip points the user at the broken
            // node without making them run Diag manually.
            await recordClassifiedError("Couldn't start \(mode.title): \(detail)")
            recordTelemetry(
                "start.failure",
                layer: lastErrorLayer,
                message: detail,
                details: ["mode": mode.rawValue]
            )
            throw error
        }
    }

    public func stop() async {
        recordTelemetry("stop.begin")
        selfHealTask?.cancel()
        selfHealTask = nil
        // Cancel auto-sync — Stop means tunnel down, not a
        // background re-spawn half a second later.
        credentialAutoSyncTask?.cancel()
        credentialAutoSyncTask = nil
        // Spam-clicking Stop would otherwise re-run
        // `disableAll()` (iterates every network service twice
        // through `networksetup`) and emit a misleading
        // "stop failed: not_running".
        guard isRunning || activeMode != .stopped else { return }
        userStopInFlight = true
        defer { userStopInFlight = false }

        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        do {
            _ = try await core.send(.stopProxy)
        } catch {
            recordError("stop failed: \(error)")
        }
        activeMode = .stopped
        isRunning = false
        appendInfo("stopped")
        recordTelemetry("stop.success")
    }

    /// Crash-recovery sweep. If the proxy-active sentinel
    /// exists, the previous run died with system proxy enabled
    /// and the user's network is currently broken. Also
    /// terminates orphan `sing-box` processes (parent PID == 1)
    /// that survived a SIGKILL'd parent and would otherwise
    /// hold the local port, surfacing as EADDRINUSE on the next
    /// start.
    public func recoverFromCrashIfNeeded() async {
        let flagURL = ProxyActiveFlag.path(in: paths.supportDirectory)
        guard ProxyActiveFlag.existsIndicatingCrash(at: flagURL) else {
            return
        }
        let payload = ProxyActiveFlag.readPayload(at: flagURL)
        appendInfo(
            "previous run crashed with system proxy enabled" + (payload.map { " (mode=\($0.mode))" } ?? "")
                + " — reverting"
        )
        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        ProxyActiveFlag.clear(at: flagURL)

        await sweepOrphanEnginesIfAny()
    }

    /// Terminates `sing-box` processes reparented to launchd
    /// (PID 1). Two-stage match:
    /// 1. `pgrep -x sing-box` — exact executable name (not
    ///    `-f`), so a user's `cat /path/to/sing-box` survives.
    /// 2. `ps -o ppid=` — parent must be 1.
    ///
    /// SIGTERM with 500 ms grace, then SIGKILL. Best-effort —
    /// failures (sandbox-blocked, missing tools) are logged.
    ///
    /// **v3.0.0:** target binary name changed from `naive` to
    /// `sing-box`. A v2.x crashed naive orphan on a freshly-
    /// upgraded Mac is no longer collected here — the operator
    /// will see it once at first launch as a stale port-bind, at
    /// which point manually killing the lingering `naive` is the
    /// one-time recovery.
    private func sweepOrphanEnginesIfAny() async {
        let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
        let ps = URL(fileURLWithPath: "/bin/ps")

        let listing: SubprocessResult
        do {
            listing = try await Subprocess.run(
                executable: pgrep,
                arguments: ["-x", "sing-box"],
                timeout: 5
            )
        } catch {
            Self.recoveryLogger.warning(
                "orphan-sing-box sweep skipped (pgrep launch failed): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        // Only act on `exit 0` (matches printed); `exit 1`
        // means no match, `≥ 2` means error.
        guard listing.exitCode == 0 else { return }

        let candidatePIDs: [pid_t] = listing.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { line in
                pid_t(line.trimmingCharacters(in: .whitespaces))
            }
        guard !candidatePIDs.isEmpty else { return }

        var orphans: [pid_t] = []
        for pid in candidatePIDs {
            let parent: pid_t? = await Self.parentPID(of: pid, ps: ps)
            if parent == 1 {
                orphans.append(pid)
            }
        }
        guard !orphans.isEmpty else {
            // Owned by another tool; not our orphan.
            return
        }

        let pidStr = orphans.map(String.init).joined(separator: ", ")
        appendInfo(
            "orphan sing-box (PID \(pidStr)) survived previous crash — terminating"
        )
        Self.recoveryLogger.notice(
            "sweeping orphan sing-box PIDs: \(pidStr, privacy: .public)"
        )

        for pid in orphans {
            _ = kill(pid, SIGTERM)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)  // try-ok: sleep cancellation
        for pid in orphans where kill(pid, 0) == 0 {
            _ = kill(pid, SIGKILL)
        }
    }

    /// Returns the parent PID of `pid` via `ps -o ppid=`.
    /// `nil` on any failure so callers treat the candidate as
    /// "don't touch".
    private static func parentPID(of pid: pid_t, ps: URL) async -> pid_t? {
        do {
            let result = try await Subprocess.run(
                executable: ps,
                arguments: ["-o", "ppid=", "-p", String(pid)],
                timeout: 2
            )
            guard result.exitCode == 0 else { return nil }
            let trimmed = result.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return pid_t(trimmed)
        } catch {
            return nil
        }
    }

    /// Crash-recovery / orphan-sweep logger. Same subsystem as
    /// `ProxyActiveFlag.logger` so the full recovery story
    /// surfaces under one `log show` predicate.
    private static let recoveryLogger = Logger.cooltunnel("ProxyRecovery")

    /// No-restart mode-switch diagnostic logger. Fires at
    /// `.notice` when the hot-swap path fails; user-visible
    /// errors come from the subsequent `startCore` catch arm.
    private static let hotSwapLogger = Logger.cooltunnel("HotSwap")

    /// Called by AppDelegate on
    /// `NSWorkspace.willSleepNotification`.
    /// Pauses cleanly before suspend so upstream TCP closes
    /// gracefully and `monitor_loop` stops hammering across the
    /// sleep window — without this the user wakes to a
    /// "Connected" pill over dropped connections.
    ///
    /// Skips `.stopped` and `.localOnly` (the loopback SOCKS
    /// listener has no upstream to drop).
    public func handleSystemWillSleep() async {
        guard isRunning, activeMode != .stopped, activeMode != .localOnly else {
            return
        }
        let snapshotMode = activeMode
        sleepWakeState = .pausing
        appendInfo(
            "system entering sleep — pausing engine to avoid zombie connections after wake")
        await stop()
        // `stop()` cleared `activeMode`; the wake handler reads
        // `modeBeforeSleep` to re-apply.
        modeBeforeSleep = snapshotMode
        sleepWakeState = .paused
    }

    /// Called by AppDelegate on `didWakeNotification`.
    ///
    /// Path A (preferred): clean checkpoint from willSleep —
    /// re-spawn in the same mode after a 500 ms network-stack
    /// settle window (DNS TTLs reset, route table sync, Wi-Fi
    /// association complete).
    ///
    /// Path B (fallback): missed willSleep (mid-sleep launch /
    /// notification raced) — probe-only behaviour that surfaces
    /// the zombie state through the error banner.
    public func handleSystemDidWake() async {
        // Path A — clean checkpoint.
        if sleepWakeState == .paused, let mode = modeBeforeSleep {
            sleepWakeState = .recovering
            appendInfo("system woke — recovering engine in \(mode.title) mode")
            try? await Task.sleep(nanoseconds: 500_000_000)  // try-ok: sleep cancellation
            do {
                try await switchMode(to: mode)
                sleepWakeState = .idle
                modeBeforeSleep = nil
                appendInfo("recovery complete — \(mode.title) restored")
            } catch {
                sleepWakeState = .idle
                modeBeforeSleep = nil
                await recordClassifiedError(
                    "auto-recovery after sleep failed: \(error.localizedDescription)"
                )
            }
            return
        }

        // Path B — missed checkpoint, probe-only.
        guard isRunning, activeMode != .stopped, activeMode != .localOnly else {
            return
        }
        let mode = activeMode
        appendInfo("system woke — probing engine health (no pre-sleep checkpoint)")
        do {
            guard let profile = selectedProfile else { return }
            try await verifyRunningProxyHealthy(profile: profile)
            _ = try await core.send(.validateProfile(profile))
        } catch {
            try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
            ProxyActiveFlag.clear(
                at: ProxyActiveFlag.path(in: paths.supportDirectory))
            isRunning = false
            activeMode = .stopped
            didBootstrap = false
            scheduleSelfHeal(
                mode: mode,
                reason: "connection became unresponsive while system slept")
        }
    }

    private func verifyRunningProxyHealthy(profile: Profile) async throws {
        let response = try await core.send(.probeSingboxLive)
        guard case .singboxLiveness(let running, _) = response else {
            throw OrchestratorError.unexpectedResponse
        }
        guard running else { throw HotSwapError.engineDied }
        let report = try await core.probe(profile: profile, timeoutSecs: 3)
        guard report.reachable else { throw HotSwapError.engineDied }
    }

    public func runDiagnostics() async {
        recordTelemetry("diagnostics.begin")
        // `ContinuousClock` is monotonic; `Date()` can jump
        // backward on NTP adjustment and report negative elapsed.
        let started = ContinuousClock.now
        appendInfo("diagnostics: starting…")
        do {
            let response = try await core.send(.runDiagnostics)
            if case .diagnostic(let report) = response {
                lastDiagnosticReport = report
                let total = Self.formatElapsed(since: started)
                appendInfo("diagnostics: \(report.probes.count) probes in \(total)")
                recordTelemetry(
                    "diagnostics.success",
                    details: ["probe_count": String(report.probes.count), "elapsed": total]
                )
            }
        } catch {
            recordError("diagnostics failed: \(error)")
        }
    }

    public func runLatencyTest(mode: ProxyTestMode) async {
        recordTelemetry(
            "latency.begin",
            details: ["test_mode": mode.rawValue]
        )
        let started = ContinuousClock.now
        appendInfo("latency: starting (\(mode.rawValue))…")
        do {
            let response = try await core.send(.runLatencyTest(mode: mode))
            if case .latency(let report) = response {
                lastLatencyReport = report
                // Per-sample DNS / connect / TLS / first-byte
                // split into the live log alongside the total.
                for sample in report.samples {
                    appendInfo(Self.formatSampleLine(sample))
                }
                let total = Self.formatElapsed(since: started)
                appendInfo("latency: \(report.samples.count) samples in \(total)")
                recordTelemetry(
                    "latency.success",
                    details: [
                        "test_mode": mode.rawValue,
                        "sample_count": String(report.samples.count),
                        "elapsed": total,
                    ]
                )
            }
        } catch {
            recordError("latency test failed: \(error)")
        }
    }

    public func runDebugHandshake() async {
        recordTelemetry("debug_handshake.begin")
        let started = ContinuousClock.now
        appendInfo("debug handshake: starting reference-proxy probe…")
        do {
            guard var profile = selectedProfile else {
                throw OrchestratorError.noProfile
            }
            try hydrateUUIDIfNeeded(&profile)
            let validation = try await core.send(.validateProfile(profile))
            guard case .validation(let validationReport) = validation, validationReport.ok else {
                throw OrchestratorError.invalidProfile(reason: extractValidationReason(validation))
            }
            let descriptor = try await singboxResolver.resolve(settings: settings)
            activeSingboxDescriptor = descriptor
            let response = try await core.send(
                .debugHandshake(
                    binaryPath: descriptor.url.path,
                    profile: profile,
                    timeoutSecs: 12
                )
            )
            guard case .debugHandshake(let report) = response else {
                throw OrchestratorError.unexpectedResponse
            }
            // Verdict + actionable hint. Hex dumps and operator
            // infrastructure metadata (`server` hostname) are
            // omitted from the live log; operators needing
            // byte-level forensics read the engine's stderr
            // passthrough below, which carries the same
            // wire-level signature from the engine's perspective.
            let glyph = report.ok ? "✓" : "✗"
            appendInfo("debug handshake: \(glyph) elapsed=\(report.elapsedMs)ms")

            // Falls back to raw error only on `.other` —
            // unrecognised failure shape where the operator needs
            // the verbatim cause.
            if let classification = report.failureClassification {
                appendInfo("  ↪ \(classification.operatorHint)")
                if classification == .other, let error = report.error, !error.isEmpty {
                    appendLog(source: .stderr, text: "[debug handshake] \(error)")
                }
            }

            // The engine's stdout/stderr stays in the log —
            // carries engine-perspective diagnostics for unusual
            // failures.
            //
            // **v3.0.0 (sub-phase F):** wire field names renamed
            // `naive_*` → `singbox_*`; the streams are from the
            // temporary `sing-box` child the engine spawned for
            // the debug-handshake probe.
            for line in report.singboxStdout {
                appendInfo("debug handshake engine stdout: \(line)")
            }
            for line in report.singboxStderr {
                appendLog(source: .stderr, text: "[debug handshake engine stderr] \(line)")
            }
            let total = Self.formatElapsed(since: started)
            // Telemetry details intentionally omit `server` and
            // `target` hostnames — bare hostnames don't match any
            // `LifecycleTelemetryLogger.redact` pattern, so
            // emitting them would leak operator infrastructure
            // metadata into the persisted telemetry file. Both
            // values are recoverable from the live log on demand.
            // Regression: `LifecycleTelemetryRedactionTests
            // .testDebugHandshakeDetailsCarryNoServerHostname`.
            recordTelemetry(
                report.ok ? "debug_handshake.success" : "debug_handshake.failure",
                details: ["elapsed": total]
            )
        } catch {
            recordError("debug handshake failed: \(error)", layer: .localKernel)
        }
    }

    // MARK: - PAC generation (v3.0.0 sub-phase F)

    /// Generates the smart-mode PAC JavaScript that
    /// `networksetup -setautoproxyurl` consumes. Successor to the
    /// v2.x `RequestKind::GeneratePac` engine call — sub-phase D
    /// dropped that from the Rust crate because sing-box's client
    /// config has no PAC notion of its own. The orchestrator still
    /// drives a PAC file for system-proxy smart-mode (macOS does
    /// not natively understand "SOCKS but exempt this list of
    /// domains"; PAC is the only stable way to express it across
    /// every macOS-bundled browser).
    ///
    /// Output mirrors the previous Rust-rendered shape so a
    /// support transcript that captured the v2.x file is still
    /// recognisable. Each direct-domain is a `dnsDomainIs` match
    /// against either the bare domain (when it starts with `.`)
    /// or the exact host plus its subdomains; anything not in the
    /// list falls through to `SOCKS5 127.0.0.1:<port>; SOCKS 127.0.0.1:<port>`.
    ///
    /// `nonisolated` static so a future unit test can pin the
    /// output shape without standing up a full orchestrator.
    nonisolated static func generatePacJavaScript(
        directDomains: [String],
        port: UInt16
    ) -> String {
        // Sanitised list: trim whitespace + strip leading dots +
        // drop any blank entries. The leading-dot strip matches
        // the v2.x renderer; `dnsDomainIs(host, ".cn")` matches
        // any host ending in `.cn`, which is the natural
        // expression of "all of China's gTLD" the operator
        // intends.
        let sanitised: [String] =
            directDomains
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.hasPrefix(".") ? String($0.dropFirst()) : $0 }

        // JS string literals: escape backslashes and double
        // quotes. The direct-domains are user-controlled (via the
        // Settings sheet) so a careful encode prevents a domain
        // with an embedded `"` from terminating the JS string and
        // hijacking the PAC.
        let escaped =
            sanitised.map { domain -> String in
                let backslash = domain.replacingOccurrences(of: "\\", with: "\\\\")
                let quoted = backslash.replacingOccurrences(of: "\"", with: "\\\"")
                return "\"\(quoted)\""
            }
            .joined(separator: ", ")

        let proxyLine = "SOCKS5 127.0.0.1:\(port); SOCKS 127.0.0.1:\(port)"

        return """
            // Generated by Cool Tunnel v3.0.0 (sub-phase F). PAC for smart-mode
            // routing: every host in `directDomains` is sent DIRECT; anything
            // else flows through the local SOCKS5 listener at 127.0.0.1:\(port).
            var directDomains = [\(escaped)];

            function FindProxyForURL(url, host) {
                if (isPlainHostName(host)) { return "DIRECT"; }
                if (host == "localhost" || host == "127.0.0.1" || host == "::1") {
                    return "DIRECT";
                }
                if (isInNet(host, "10.0.0.0", "255.0.0.0")) { return "DIRECT"; }
                if (isInNet(host, "172.16.0.0", "255.240.0.0")) { return "DIRECT"; }
                if (isInNet(host, "192.168.0.0", "255.255.0.0")) { return "DIRECT"; }
                for (var i = 0; i < directDomains.length; i++) {
                    if (dnsDomainIs(host, "." + directDomains[i]) || host == directDomains[i]) {
                        return "DIRECT";
                    }
                }
                return "\(proxyLine)";
            }
            """
    }

    // MARK: - Time formatting helpers

    /// Renders a monotonic interval as `Nms` / `N.NNs`. Sub-ms
    /// rounds up to `1ms` so timings never read `0ms`.
    private static func formatElapsed(since start: ContinuousClock.Instant) -> String {
        let elapsed = ContinuousClock.now - start
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

    /// One-liner readout for a [`LatencySample`]. Each numeric
    /// field goes through [`formatMs`] so a malformed payload
    /// (NaN / infinity / negative) doesn't trap on `Int(_:)`.
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

    /// Defensive `Double → "Nms"` formatter. Rust clamps to a
    /// finite non-negative `u64`, but Swift's `Codable` accepts
    /// any `Double` — guard against a protocol-version drift /
    /// hand-crafted reply that would `Int(_:)`-trap the UI.
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
            self.flushPendingLogs()
            // Stream ended. Two sources:
            //   1. We tore the engine down via `shutdown()` —
            //      `isShuttingDown` is true; stay quiet.
            //   2. Engine died on us — pipe broke / cool-tunnel-core
            //      crashed / OS killed it. Surface, or the user
            //      thinks "nothing's happening" over a dead proxy.
            if !self.isShuttingDown {
                await self.handleEngineStreamEnded()
            }
        }
    }

    private func handleEngineStreamEnded() async {
        recordTelemetry("engine.stream_ended")
        let modeToRecover = modeBeforeSleep ?? activeMode
        let shouldRecover =
            isRunning
            && modeToRecover != .stopped
            && sleepWakeState != .pausing
            && sleepWakeState != .recovering

        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        isRunning = false
        activeMode = .stopped
        didBootstrap = false
        if shouldRecover {
            scheduleSelfHeal(
                mode: modeToRecover,
                reason: "engine subprocess exited unexpectedly")
        } else {
            recordError(
                "Engine subprocess exited unexpectedly — system proxy reverted. Click a mode chip to relaunch the engine and try again.",
                layer: .localKernel
            )
        }
    }

    private func scheduleSelfHeal(mode: ProxyMode, reason: String) {
        guard mode != .stopped else { return }
        guard selfHealTask == nil else { return }
        lastError = nil
        lastErrorLayer = nil
        appendInfo("\(reason) - self-healing will restart \(mode.title)")
        selfHealTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.selfHealTask = nil }
            let delays: [UInt64] = [
                500_000_000,
                2_000_000_000,
                5_000_000_000,
            ]
            for (index, delay) in delays.enumerated() {
                try? await Task.sleep(nanoseconds: delay)  // try-ok: sleep cancellation
                guard !Task.isCancelled, !self.isShuttingDown else { return }
                await self.bootstrapIfNeeded()
                do {
                    try await self.start(mode: mode)
                    self.appendInfo(
                        "self-healing recovered \(mode.title) on attempt \(index + 1)"
                    )
                    return
                } catch {
                    // Classify so permanent errors (bad profile,
                    // missing binary, protocol drift) don't burn
                    // the full retry budget before the operator
                    // sees the real cause; transient failures
                    // still retry.
                    if Self.isPermanentStartFailure(error) {
                        self.appendInfo(
                            "self-healing aborted on attempt \(index + 1): \(error.localizedDescription) (permanent failure — not retrying)"
                        )
                        self.recordError(
                            "Self-healing aborted: \(error.localizedDescription)",
                            layer: .localKernel
                        )
                        return
                    }
                    self.appendInfo(
                        "self-healing attempt \(index + 1) failed: \(error.localizedDescription)"
                    )
                }
            }
            self.recordError(
                "Self-healing could not restart \(mode.title). System proxy is reverted; check the log before retrying.",
                layer: .localKernel
            )
        }
    }

    // MARK: - Credential auto-sync (HTTP-407 self-healing)

    /// Detects auth-class handshake failures in the engine's
    /// stderr. Permissive on purpose: a false positive is a no-op
    /// `scheduleCredentialAutoSync`; a false negative leaves the
    /// operator stuck with stale credentials.
    ///
    /// **v3.0.0 (sub-phase F):** matches both the historical
    /// NaiveProxy HTTP-407 patterns AND the new sing-box
    /// VLESS+Reality handshake-rejection signatures. The legacy
    /// 407 chips stay so an HTTP-shaped reverse proxy in front of
    /// a v2.x server still fires the auto-sync; the new chips
    /// catch the strings sing-box itself emits when the VLESS
    /// user_id is wrong or the Reality handshake fails
    /// (`reality handshake failed`, `unknown vless user`,
    /// `xtls-rprx-vision flow not allowed`, etc.).
    ///
    /// `nonisolated` so the hot stderr loop doesn't hop actors.
    nonisolated static func isProxyAuthFailureLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        // Legacy NaiveProxy / HTTP-CONNECT chips.
        if upper.contains("ERR_PROXY_AUTH") { return true }
        if upper.contains("ERR_TUNNEL_AUTH") { return true }
        if upper.contains("407 PROXY AUTHENTICATION") { return true }
        if upper.contains("PROXY AUTHENTICATION REQUIRED") { return true }
        if upper.contains("AUTHENTICATION REQUIRED") { return true }
        // **v3.0.0 (sub-phase F):** VLESS+Reality chips from
        // sing-box's own diagnostic output. The exact strings
        // are SAGERNET/sing-box-stable across the upstream-tag
        // window the cool-tunnel-server release line targets.
        if upper.contains("REALITY HANDSHAKE FAILED") { return true }
        if upper.contains("UNKNOWN VLESS USER") { return true }
        if upper.contains("VLESS: USER NOT FOUND") { return true }
        if upper.contains("VLESS USER NOT FOUND") { return true }
        if upper.contains("INVALID USER_ID") { return true }
        if upper.contains("INVALID USER ID") { return true }
        if upper.contains("XTLS-RPRX-VISION FLOW NOT ALLOWED") { return true }
        // Raw "407" match — surrounded by non-alphanumeric
        // separators so a coincidence inside a longer numeric
        // run (port number, byte count) doesn't fire.
        let separators: [Character] = [
            " ", ",", ".", ":", ";", "[", "]", "(", ")", "{", "}",
            "/", "=", "\"", "'", "\t", "\n", "\r",
        ]
        if let range = line.range(of: "407") {
            let before: Character? =
                range.lowerBound == line.startIndex
                ? nil
                : line[line.index(before: range.lowerBound)]
            let after: Character? =
                range.upperBound == line.endIndex
                ? nil
                : line[range.upperBound]
            let leftOK = before.map { separators.contains($0) } ?? true
            let rightOK = after.map { separators.contains($0) } ?? true
            if leftOK && rightOK {
                return true
            }
        }
        return false
    }

    /// Auto-sync triggered by an auth-failure log line.
    /// Single-flight via `credentialAutoSyncTask` so a burst of
    /// 407-shaped stderr lines doesn't queue duplicate fetches.
    ///
    /// Fail-quiet on the "no drift" path — if the upstream
    /// returns identical credentials, the auth failure was
    /// something else (revoked token, server-side misconfig);
    /// the existing error path takes over.
    private func scheduleCredentialAutoSync(reason: String) {
        guard credentialAutoSyncTask == nil else { return }
        guard let profile = selectedProfile else { return }
        guard let url = profile.subscriptionURL, !url.isBlank else {
            return
        }
        // Cooldown — keeps a continuously-failing engine from
        // hitting the panel hundreds of times per second.
        if let last = lastCredentialAutoSyncAt,
            ContinuousClock.now - last < Self.credentialAutoSyncCooldown
        {
            return
        }
        lastCredentialAutoSyncAt = ContinuousClock.now
        // **v3.0.0 (sub-phase F):** drift check covers `uuid` +
        // every Reality field. A real panel rotation flips `uuid`;
        // a Reality keypair regen on the server flips
        // `reality.publicKey` (and possibly `shortId`); a cover-
        // site change flips `reality.destHost`. Any single one
        // changing is enough to justify a restart.
        let oldUUID = profile.uuid
        let oldRealityPub = profile.reality.publicKey
        let oldRealityDest = profile.reality.destHost
        let oldRealityShortID = profile.reality.shortId
        let oldUsername = profile.username
        let oldServer = profile.server
        let activeModeAtTrigger = activeMode
        appendInfo("credentials: \(reason) — auto-syncing from subscription URL")
        recordTelemetry(
            "credentials.auto_sync.begin",
            details: ["reason": reason]
        )
        credentialAutoSyncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.credentialAutoSyncTask = nil }

            do {
                try await self.importFromSubscriptionURL(url)
            } catch {
                self.appendInfo(
                    "credentials: auto-sync fetch failed — \(error.localizedDescription)"
                )
                self.recordTelemetry(
                    "credentials.auto_sync.fetch_failed",
                    details: ["error": error.localizedDescription]
                )
                // No `recordError` — the existing error path
                // already produced a banner; a second one is
                // noise.
                return
            }

            // `selectedProfile.set` raises a "click Stop then a
            // mode chip" banner whenever a running session's
            // profile mutates — auto-sync IS about to do that, so
            // the banner is false-positive guidance. Clear before
            // the restart.
            self.lastError = nil
            self.lastErrorLayer = nil
            self.activeProfileEdited = false

            let refreshed = self.selectedProfile
            let changed =
                refreshed?.uuid != oldUUID
                || refreshed?.reality.publicKey != oldRealityPub
                || refreshed?.reality.destHost != oldRealityDest
                || refreshed?.reality.shortId != oldRealityShortID
                || refreshed?.username != oldUsername
                || refreshed?.server != oldServer
            guard changed else {
                self.appendInfo(
                    "credentials: auto-sync — upstream returned identical credentials; not restarting"
                )
                self.recordTelemetry("credentials.auto_sync.no_drift")
                return
            }

            self.appendInfo(
                "credentials: auto-sync — credentials refreshed; restarting \(activeModeAtTrigger.title)"
            )
            self.recordTelemetry(
                "credentials.auto_sync.restart",
                details: ["mode": activeModeAtTrigger.rawValue]
            )

            // Quiet stop + fresh start. A failed start hands off
            // to the existing event-driven self-heal path.
            await self.stopQuiet()
            do {
                try await self.start(mode: activeModeAtTrigger)
                self.appendInfo(
                    "credentials: auto-sync — restarted with refreshed credentials"
                )
                self.recordTelemetry("credentials.auto_sync.success")
            } catch {
                self.appendInfo(
                    "credentials: auto-sync — restart failed: \(error.localizedDescription)"
                )
                self.recordTelemetry(
                    "credentials.auto_sync.restart_failed",
                    details: ["error": error.localizedDescription]
                )
            }
        }
    }

    /// Returns true for failures that retrying won't recover.
    /// False-by-default — when in doubt, retry. The 3-attempt
    /// budget is cheap so a wrong "permanent" classification is
    /// more harmful than a wrong "transient" one (e.g.
    /// `credentialReadFailed` is transient because the keychain
    /// can unlock between attempts).
    private static func isPermanentStartFailure(_ error: Error) -> Bool {
        switch error {
        case OrchestratorError.noProfile,
            OrchestratorError.invalidProfile,
            OrchestratorError.singboxBinaryUnusable:
            return true
        default:
            break
        }
        // Wire-protocol rejections are Swift-side bugs — retry
        // produces the same frame and the same rejection.
        if let payload = error as? ErrorPayload,
            payload.code == "invalid_request" || payload.code == "malformed_request"
        {
            return true
        }
        return false
    }

    private func handle(event: CoreEvent) {
        switch event {
        case .logLine(let source, let line):
            appendLog(source: source, text: line)
            // Cheap substring-check on every stderr line — gated
            // inside `scheduleCredentialAutoSync` on the profile
            // having a `subscriptionURL`, so profiles without one
            // never pay beyond the substring test.
            if source == .stderr,
                Self.isProxyAuthFailureLine(line)
            {
                scheduleCredentialAutoSync(reason: "engine reported HTTP 407 / proxy auth failure")
            }
        case .stateChanged(let running):
            // During a hot-swap the engine emits stateChanged
            // pairs for the implicit stopProxy/startProxy.
            // switchMode owns the public state across that
            // window and writes the final mode as a single
            // transition; defer here. Outside the gate this
            // handler is the source of truth for natural death.
            if transitionInFlight {
                return
            }
            // When the engine dies outside a user-initiated stop,
            // revert system proxy immediately. Without this,
            // macOS keeps routing at `127.0.0.1:1080` where
            // nothing is listening — every page stalls behind
            // a misleading "Idle" header.
            let wasRunning = isRunning
            let modeBeforeStop = activeMode
            isRunning = running
            recordTelemetry(
                running ? "engine.state.running" : "engine.state.stopped",
                details: ["mode_before_event": modeBeforeStop.rawValue]
            )
            if !running {
                activeMode = .stopped
                // `!userStopInFlight` keeps an intentional Stop's
                // own `stateChanged(false)` from triggering a
                // phantom "engine stopped unexpectedly" banner.
                if wasRunning && !isShuttingDown && !userStopInFlight {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await self.proxyController.disableAll()  // try-ok: best-effort proxy revert
                        ProxyActiveFlag.clear(
                            at: ProxyActiveFlag.path(in: self.paths.supportDirectory))
                        self.scheduleSelfHeal(
                            mode: modeBeforeStop,
                            reason: "engine stopped unexpectedly")
                    }
                }
            }
        case .anomaly(let reason, let detail):
            appendLog(source: .stderr, text: "[anomaly:\(reason.rawValue)] \(detail)")
            // `ListeningOutsideLoopback` exposes the engine beyond
            // `127.0.0.1` — every LAN byte could be proxied.
            // Other anomalies stay advisory.
            if reason == .listeningOutsideLoopback {
                recordError("Critical: \(detail). Auto-stopping.", layer: .localKernel)
                // Single-flight — duplicate anomalies arriving
                // in quick succession would otherwise queue
                // racing `stop()` tasks.
                if autoStopTask == nil {
                    autoStopTask = Task { [weak self] in
                        await self?.stop()
                        self?.autoStopTask = nil
                    }
                }
            }
        case .diagnosticProgress(let step, let ok, let elapsedMs):
            // `elapsedMs == 0` means an older engine omitted
            // timing; fall back to the legacy bare-step format.
            let glyph = ok ? "✓" : "✗"
            if elapsedMs == 0 {
                appendInfo("\(glyph) \(step)")
            } else {
                appendInfo("\(glyph) \(step) (\(elapsedMs)ms)")
            }
        case .trafficSnapshot:
            // Live throughput is no longer rendered; the engine still
            // emits these on every lsof tick. Ignore.
            break
        }
    }

    // MARK: - Helpers

    private func appendLog(source: LogSource, text: String) {
        enqueueLog(LogEntry(source: source, text: boundedLogText(text)))
    }

    private func appendInfo(_ message: String) {
        enqueueLog(LogEntry(source: .stdout, text: "[orchestrator] \(boundedLogText(message))"))
    }

    /// Synchronous error record. Connection-failure paths use
    /// [`recordClassifiedError`] (runs the layer probe first);
    /// layer-by-construction paths hardcode `.localKernel`.
    private func recordError(_ message: String, layer: ErrorLayer? = nil) {
        let bounded = boundedLogText(message)
        lastError = bounded
        lastErrorLayer = layer
        recordTelemetry("error.recorded", layer: layer, message: bounded)
        let prefix = layer.map { "[\($0.diagnosticLabel)] " } ?? ""
        enqueueLog(LogEntry(source: .stderr, text: "[error] \(prefix)\(bounded)"), flushNow: true)
    }

    private func enqueueLog(_ entry: LogEntry, flushNow: Bool = false) {
        pendingLogEntries.append(entry)
        if flushNow || pendingLogEntries.count >= maxLogBatchEntries {
            flushPendingLogs()
            return
        }
        guard logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: self.logFlushIntervalNanos)  // try-ok: sleep cancellation
            guard !Task.isCancelled else { return }
            self.flushPendingLogs()
        }
    }

    private func flushPendingLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        guard !pendingLogEntries.isEmpty else { return }
        logEntries.append(contentsOf: pendingLogEntries)
        pendingLogEntries.removeAll(keepingCapacity: true)
        trimLogs()
    }

    private func boundedLogText(_ text: String) -> String {
        guard text.count > maxLogLineCharacters else { return text }
        let prefix = text.prefix(maxLogLineCharacters)
        return "\(prefix)... [truncated]"
    }

    /// Runs the layer classifier (3 s budget) then records.
    /// Inconclusive probes yield `nil` and the banner falls
    /// back to plain-text (no chip).
    private func recordClassifiedError(_ message: String) async {
        let layer = await classifyConnectionFailure()
        recordError(message, layer: layer)
    }

    /// Two parallel reachability probes:
    /// 1. Apple's NCSI endpoint — ISPs rarely block it.
    /// 2. Direct TCP to the user's VPS hostname (bypasses the
    ///    in-flight broken proxy).
    ///
    /// |           | Apple ✓        | Apple ✗ |
    /// |-----------|----------------|---------|
    /// | **VPS ✓** | `.localKernel` | `.isp`  |
    /// | **VPS ✗** | `.vps`         | `.isp`  |
    ///
    /// Apple ✗ + VPS ✓ is unusual (NCSI block / captive portal)
    /// — `.isp` is the actionable verdict either way.
    private func classifyConnectionFailure() async -> ErrorLayer? {
        // Capture `vpsHost` on the MainActor BEFORE the
        // `async let` branches — `selectedProfile` is
        // MainActor-isolated and reading it from a Sendable
        // closure is a Swift 6 strict-concurrency error. Also
        // pins the host stable across both probes.
        let vpsHost: String? = {
            guard let profile = self.selectedProfile else { return nil }
            // Strip the port — we always test :443 (the upstream
            // proxy's listen port).
            let host = String(profile.server.split(separator: ":").first ?? "")
            return host.isEmpty ? nil : host
        }()

        async let appleReachable = Self.probeReachability(host: "www.apple.com")
        async let vpsReachable: Bool = {
            guard let host = vpsHost else { return false }
            return await Self.probeReachability(host: host)
        }()

        let internet = await appleReachable
        let vps = await vpsReachable

        switch (internet, vps) {
        case (false, false): return .isp
        case (true, false): return .vps
        case (false, true): return .isp
        case (true, true): return .localKernel
        }
    }

    /// Raw TCP reachability probe via `NWConnection`. Bypasses
    /// the system proxy — `URLSession` would honour the in-flight
    /// `proxyController.enableSmartPAC` install and loop through
    /// the broken engine path instead of testing raw connectivity.
    ///
    /// The continuation-resume guard uses `NSLock`:
    /// `stateUpdateHandler` can fire multiple times
    /// (`.preparing` → `.ready` → `.cancelled`) and races against
    /// the timeout task, so a `CheckedContinuation` would crash
    /// on double resume without it.
    private static func probeReachability(
        host: String,
        port: UInt16 = 443,
        timeout: TimeInterval = 3.0
    ) async -> Bool {
        final class State: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false
        }
        let state = State()
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return false }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let queue = DispatchQueue(label: "ct.probe.\(host).\(port)", qos: .userInitiated)

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            // `@Sendable` required: Swift 6 strict concurrency
            // rejects capture of a non-Sendable local function
            // in a Sendable closure. Sound here — body only
            // touches Sendable state.
            @Sendable func resumeOnce(_ value: Bool) {
                state.lock.lock()
                defer { state.lock.unlock() }
                guard !state.resumed else { return }
                state.resumed = true
                conn.cancel()
                cont.resume(returning: value)
            }
            conn.stateUpdateHandler = { newState in
                switch newState {
                case .ready: resumeOnce(true)
                case .failed, .cancelled, .waiting: resumeOnce(false)
                default: break
                }
            }
            conn.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) {
                resumeOnce(false)
            }
        }
    }

    private func trimLogs() {
        if logEntries.count > maxLogEntries {
            logEntries.removeFirst(logEntries.count - maxLogEntries)
        }
    }

    /// Fills the UUID from the credential store when the
    /// in-memory copy is empty. Delegates to the static form.
    ///
    /// **v3.0.0 (sub-phase F):** renamed from
    /// `hydratePasswordIfNeeded`. The stored credential is now a
    /// VLESS UUID, not a NaiveProxy basic-auth password.
    private func hydrateUUIDIfNeeded(_ profile: inout Profile) throws {
        try Self.hydrateUUID(&profile, from: profileStore)
    }

    /// Throws `OrchestratorError.credentialReadFailed` on
    /// backend failure so callers can distinguish "keychain
    /// locked" from "no UUID set" (item-not-found returns
    /// `""` per `CredentialStore` contract and the validation
    /// gate handles the empty case).
    ///
    /// `nonisolated` static so the unit-test target can pin the
    /// contract without standing up a full `TunnelOrchestrator`.
    nonisolated static func hydrateUUID(
        _ profile: inout Profile, from store: ProfileStore
    )
        throws
    {
        guard profile.uuid.isBlank else {
            return
        }
        let stored: String
        do {
            stored = try store.uuid(forProfileID: profile.id)
        } catch {
            throw OrchestratorError.credentialReadFailed(reason: error.localizedDescription)
        }
        if !stored.isEmpty {
            profile.uuid = stored
        }
    }

    private func recordTelemetry(
        _ event: String,
        layer: ErrorLayer? = nil,
        message: String? = nil,
        details: [String: String] = [:]
    ) {
        telemetry.record(
            event,
            mode: activeMode == .stopped ? nil : activeMode,
            running: isRunning,
            layer: layer,
            message: message,
            details: details
        )
    }

    public func clearLogs() {
        pendingLogEntries.removeAll(keepingCapacity: false)
        logFlushTask?.cancel()
        logFlushTask = nil
        logEntries.removeAll()
        // "Clear logs" clears the error pill too — users expect
        // it to disappear with the log.
        lastError = nil
        lastErrorLayer = nil
    }

    /// Dismisses the error banner. Encapsulated so `lastError`
    /// stays `private(set)`.
    public func dismissLastError() {
        lastError = nil
        lastErrorLayer = nil
    }

    // MARK: - Declarative UI schema

    /// Pure projection from mutable orchestrator fields to the
    /// structured state SwiftUI renders. This is the public map
    /// of what the UI is allowed to know; keep operational
    /// recovery policy in the orchestrator and keep views as
    /// pure functions of this value plus local draft state.
    public func viewState(
        ui: CoolTunnelUIState = CoolTunnelUIState()
    ) -> CoolTunnelViewState {
        let error: CoolTunnelViewState.ErrorBanner? =
            lastError.flatMap { message in
                message.isEmpty
                    ? nil
                    : CoolTunnelViewState.ErrorBanner(
                        message: message,
                        layer: lastErrorLayer
                    )
            }
        let hasSelectedProfile = selectedProfile != nil
        let selectedProfileIsStartable = selectedProfile?.isStartable ?? false
        let selectedProfileCanRequestStart =
            selectedProfile.map(Self.profileCanRequestStart) ?? false
        let connection = CoolTunnelViewState.Connection(
            isRunning: isRunning,
            activeMode: activeMode,
            sleepWakeState: sleepWakeState,
            firewallState: firewallState,
            error: error
        )
        let controlPanel = CoolTunnelViewState.ControlPanel(
            isRunning: isRunning,
            activeMode: activeMode,
            hasSelectedProfile: hasSelectedProfile,
            selectedProfileIsStartable: selectedProfileIsStartable,
            selectedProfileCanRequestStart: selectedProfileCanRequestStart
        )
        return CoolTunnelViewState(
            ui: ui,
            connection: connection,
            header: CoolTunnelViewState.Header(
                statusPill: Self.statusPill(
                    isRunning: isRunning,
                    lastError: error?.message,
                    sleepWakeState: sleepWakeState
                ),
                errorBanner: error,
                showsFirewallBadge: firewallState == .enabled
            ),
            controlPanel: controlPanel,
            menuBar: CoolTunnelViewState.MenuBar(
                statusLine: Self.menuBarStatusLine(
                    error: error?.message,
                    isRunning: isRunning,
                    activeMode: activeMode
                ),
                symbolName: Self.menuBarSymbol(
                    hasError: error != nil,
                    isRunning: isRunning
                ),
                isRunning: isRunning,
                activeMode: activeMode,
                hasSelectedProfile: hasSelectedProfile,
                selectedProfileCanRequestStart: selectedProfileCanRequestStart
            ),
            profiles: CoolTunnelViewState.Profiles(
                all: profiles,
                selectedID: selectedProfileID,
                selected: selectedProfile
            ),
            activityLog: CoolTunnelViewState.ActivityLog(entries: logEntries),
            diagnostics: CoolTunnelViewState.Diagnostics(
                lastDiagnosticReport: lastDiagnosticReport,
                lastLatencyReport: lastLatencyReport
            ),
            settings: settings,
            resources: CoolTunnelViewState.Resources(
                activeSingboxDescriptor: activeSingboxDescriptor
            )
        )
    }

    /// Applies an explicit UI intent. The only imperative bridge
    /// the SwiftUI composition root needs for tunnel controls;
    /// leaf views should emit `TunnelIntent` rather than calling
    /// `start` / `stop` / diagnostics directly.
    public func perform(_ intent: TunnelIntent) async {
        switch intent {
        case .switchMode(let mode):
            guard mode == .stopped || guardCanRequestStart() else { return }
            do {
                try await switchMode(to: mode)
            } catch {
                Self.uiIntentLogger.error(
                    "mode intent \(mode.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        case .toggleRunning(let preferredMode):
            let target: ProxyMode = isRunning ? .stopped : preferredMode
            guard target == .stopped || guardCanRequestStart() else { return }
            do {
                try await switchMode(to: target)
            } catch {
                Self.uiIntentLogger.error(
                    "toggle intent target=\(target.rawValue, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        case .runDiagnostics:
            await runDiagnostics()
        case .runLatencyTest(let mode):
            await runLatencyTest(mode: mode)
        case .runDebugHandshake:
            await runDebugHandshake()
        case .dismissError:
            dismissLastError()
        case .clearLogs:
            clearLogs()
        }
    }

    private static func statusPill(
        isRunning: Bool,
        lastError: String?,
        sleepWakeState: SleepWakeState
    ) -> CoolTunnelViewState.StatusPill {
        switch sleepWakeState {
        case .pausing:
            return CoolTunnelViewState.StatusPill(
                headline: "Pausing for sleep…",
                tint: .yellow
            )
        case .paused:
            return CoolTunnelViewState.StatusPill(
                headline: "Asleep",
                tint: .secondary
            )
        case .recovering:
            return CoolTunnelViewState.StatusPill(
                headline: "Recovering after wake…",
                tint: .yellow
            )
        case .idle:
            break
        }
        if lastError != nil {
            return CoolTunnelViewState.StatusPill(headline: "Error", tint: .red)
        }
        if isRunning {
            return CoolTunnelViewState.StatusPill(headline: "Connected", tint: .green)
        }
        return CoolTunnelViewState.StatusPill(headline: "Not connected", tint: .secondary)
    }

    private static func menuBarStatusLine(
        error: String?,
        isRunning: Bool,
        activeMode: ProxyMode
    ) -> String {
        if let error, !error.isEmpty {
            return "Error · \(error)"
        }
        if isRunning {
            return "Active · \(activeMode.title)"
        }
        return "Idle"
    }

    private static func menuBarSymbol(hasError: Bool, isRunning: Bool) -> String {
        if hasError {
            return "exclamationmark.triangle.fill"
        }
        return isRunning ? "arrow.up.right.circle.fill" : "arrow.up.right.circle"
    }

    private static let uiIntentLogger = Logger.cooltunnel("UI.Intent")

    private static func profileCanRequestStart(_ profile: Profile) -> Bool {
        profile.serverValidation == .valid && !profile.username.isBlank
            && profile.localPortValue != nil
    }

    /// Final UI-intent gate before any control surface reaches
    /// the engine — keeps the menu bar, keyboard shortcuts, and
    /// future surfaces under the same validation contract as
    /// the form.
    private func guardCanRequestStart() -> Bool {
        guard var profile = selectedProfile else {
            recordError("Start rejected: select or create a profile first.", layer: .localKernel)
            return false
        }
        guard Self.profileCanRequestStart(profile) else {
            recordError(
                "Start rejected: fix server, username, and local port before launching.",
                layer: .localKernel
            )
            return false
        }
        if profile.uuid.isBlank {
            // Distinguish credential-store failure from
            // "no UUID set" so the rejection banner says
            // the right thing — collapsing both produced
            // "enter a credential" even when the keychain was
            // locked.
            do {
                profile.uuid = try profileStore.uuid(forProfileID: profile.id)
            } catch {
                recordError(
                    "Start rejected: couldn't read stored UUID (\(error.localizedDescription)). Unlock the Keychain and try again.",
                    layer: .localKernel
                )
                return false
            }
        }
        guard !profile.uuid.isBlank else {
            recordError(
                "Start rejected: import a subscription URL or paste a VLESS UUID for the selected profile.",
                layer: .localKernel
            )
            return false
        }
        // **v3.0.0 (sub-phase F):** Reality fields are NOT in the
        // credential store — they live in the UserDefaults blob —
        // so an empty `reality.publicKey` here means the user
        // never imported a subscription URL or hand-entered the
        // value. Reject up front with the same actionable banner;
        // the engine would otherwise reject with
        // "reality.public_key must not be empty" through
        // `validate_profile`.
        guard !profile.reality.publicKey.isBlank else {
            recordError(
                "Start rejected: import a subscription URL to populate the Reality public key.",
                layer: .localKernel
            )
            return false
        }
        guard !profile.reality.destHost.isBlank else {
            recordError(
                "Start rejected: the profile is missing its Reality dest_host. Re-import via subscription URL.",
                layer: .localKernel
            )
            return false
        }
        return true
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

/// Identifies which node in the connection chain is broken when
/// a connection-failure path fires. Populated by
/// [`TunnelOrchestrator.classifyConnectionFailure`].
public enum ErrorLayer: String, Sendable, Codable, Equatable {
    /// On the user's Mac — sing-box not running, loopback bind
    /// failed, OS firewall blocking, wrong credentials.
    case localKernel
    /// Between Mac and internet — ISP, Wi-Fi, captive portal,
    /// DNS. Apple's NCSI endpoint is unreachable.
    case isp
    /// The user's upstream proxy server — DNS doesn't resolve,
    /// host up but `:443` refuses, or the daemon rejects the
    /// handshake. General internet works.
    case vps

    /// Short label rendered in the `HeaderView` error chip.
    public var diagnosticLabel: String {
        switch self {
        case .localKernel: "Local Kernel"
        case .isp: "ISP"
        case .vps: "VPS"
        }
    }

    /// Plain-language sentence for support transcript / `Diag`
    /// export. Not rendered in the banner itself — banner stays
    /// scannable.
    public var humanExplanation: String {
        switch self {
        case .localKernel:
            return
                "the issue is in the Local Kernel layer — `sing-box` may not be running, "
                + "the saved credentials may be wrong, or the OS firewall "
                + "may be blocking outbound traffic"
        case .isp:
            return
                "the issue is in the ISP layer — Wi-Fi, captive portal, DNS, "
                + "or the route from this Mac to the public internet"
        case .vps:
            return
                "the issue is in the VPS layer — its hostname may "
                + "not resolve, `:443` may refuse connections, or the "
                + "daemon may be rejecting the handshake"
        }
    }
}

/// Finite state machine for the sleep / wake transition.
///
/// ```text
///                  willSleepNotification
///   .idle  ─────────────────────────────►  .pausing
///                                              │ (await stop())
///                                              ▼
///                                          .paused
///                                              │ didWakeNotification
///                                              ▼
///                                         .recovering
///                                              │ (await switchMode)
///                                              ▼
///                                            .idle
/// ```
///
/// `.idle` is the steady state; the pill falls back to base
/// `isRunning` / `lastError` rendering.
public enum SleepWakeState: String, Sendable, Codable, Equatable {
    /// Steady state. No sleep transition in flight.
    case idle
    /// `willSleepNotification` fired. `stop()` is in progress;
    /// engine is being asked to drain cleanly.
    case pausing
    /// Engine fully stopped; system is presumably asleep. Waiting
    /// for `didWakeNotification` to drive the recovery branch.
    case paused
    /// `didWakeNotification` fired; the orchestrator is re-spawning
    /// the engine and reapplying the pre-sleep `ProxyMode`.
    case recovering
}

/// Conforms to `LocalizedError` so the
/// `(error as? LocalizedError)?.errorDescription` casts at the
/// catch sites in `startCore` etc. hit these cases — without it
/// the user sees Swift's default "The operation couldn't be
/// completed. (...error N.)".
public enum OrchestratorError: LocalizedError, Sendable, Equatable {
    case noProfile
    case invalidProfile(reason: String)
    case unexpectedResponse
    /// `sing-box` binary unusable — file missing, not Mach-O, no
    /// host-arch slice, or broken signature. Wrapped error
    /// tells the user which.
    case singboxBinaryUnusable(SingboxResolverError)
    /// Credential store read failed — keychain locked, prompt
    /// dismissed, file IO, corrupted entry. Distinct from "no
    /// credential set" so the banner says "unlock keychain"
    /// rather than the misleading "enter a credential". **v3.0.0
    /// (sub-phase F):** the stored credential is now a VLESS UUID.
    case credentialReadFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noProfile: "No profile is selected."
        case .invalidProfile(let reason): "Invalid profile: \(reason)"
        case .unexpectedResponse: "Engine returned an unexpected response."
        case .singboxBinaryUnusable(let err):
            "sing-box binary cannot be used: \(err.errorDescription ?? "unknown error")"
        case .credentialReadFailed(let reason):
            "Couldn't read stored credential: \(reason). Unlock the Keychain and try again."
        }
    }
}

/// UI-facing subscription import errors, keyed on the failure
/// mode rather than transport shape.
public enum SubscriptionImportError: LocalizedError, Sendable, Equatable {
    /// URL didn't parse, or wasn't `https://…`.
    case invalidURL
    /// Transport failure.
    case networkError(String)
    /// HTTP 401 — account disabled / expired / quota exceeded.
    case subscriptionRevoked
    /// HTTP 404 / 422, or 200-with-HTML cover-site response.
    case tokenInvalid
    /// HTTP 429 — panel rate-limits at 60/min.
    case rateLimited
    /// HTTP 5xx.
    case serverError(status: Int)
    /// Anything outside 2xx / the explicit cases above.
    case unexpectedStatus(Int)
    /// JSON decoded but had no usable profile.
    case noProfiles
    /// Manifest `version != 1`.
    case unsupportedVersion(got: UInt32)
    /// `expires_at` in the past — stale URL.
    case manifestExpired
    /// `issued_at` > 7 days old — typically a caching proxy.
    case manifestStale(daysOld: Int)
    /// Failed structural sanity (issued_at == 0 / far future /
    /// expires_at < issued_at) — stub / counterfeit panel.
    case manifestCounterfeit
    /// Body exceeded the 1 MB cap.
    case manifestTooLarge(cap: Int)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The subscription URL is not valid. It must start with https://."
        case .networkError(let msg):
            "Network error: \(msg). Check your internet connection and try again."
        case .subscriptionRevoked:
            "This account is no longer active. Ask your administrator to re-enable it or issue a new subscription URL."
        case .tokenInvalid:
            "This subscription URL doesn't match any account on the server. Double-check the URL or ask for a new one."
        case .rateLimited:
            "Too many import attempts. Wait a minute and try again."
        case .serverError(let status):
            "The server returned a \(status) error. The panel may be down or misconfigured (e.g. APP_KEY unset). Try again later."
        case .unexpectedStatus(let status):
            "Unexpected server response (HTTP \(status))."
        case .noProfiles:
            "The subscription manifest contained no usable profiles."
        case .unsupportedVersion(let got):
            "This subscription URL uses manifest version \(got); this app understands version 1. Update the app or ask the operator for a v1 URL."
        case .manifestExpired:
            "This subscription URL has expired. Ask the administrator for a new one."
        case .manifestStale(let daysOld):
            "The subscription manifest is \(daysOld) days old. A network-level cache on your connection may be serving a stale copy — try a different network or DNS resolver."
        case .manifestCounterfeit:
            "The subscription manifest looks fake or tampered with. Do not connect — verify the panel URL with the administrator."
        case .manifestTooLarge(let cap):
            "The subscription response is suspiciously large (over \(cap / (1024 * 1024)) MB). Verify the panel URL with the administrator before retrying."
        }
    }
}
