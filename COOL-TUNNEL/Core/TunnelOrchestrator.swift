// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// Core/TunnelOrchestrator.swift
//
// Single source of truth for the UI: combines `CoreClient`,
// `SystemProxyController`, persistence, and filesystem paths into one
// observable façade. Views read state from here and call its methods;
// nothing else is `@Observable` in the app.

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

    /// **v2.0.28 (Seamless Recovery Protocol):** live state of the
    /// system-sleep / wake transition. Drives the `HeaderStatusPill`'s
    /// transient *"Pausing for sleep…" / "Asleep" / "Recovering after
    /// wake…"* labels so the user sees the recovery phases instead of
    /// a stale *"Connected"* or *"Error"* pill while the orchestrator
    /// is mid-cycle. `.idle` is the steady-state and never observed by
    /// the user as a pill label — the base `isRunning` / `lastError`
    /// rendering takes over.
    public private(set) var sleepWakeState: SleepWakeState = .idle

    /// Snapshot of `activeMode` taken at `handleSystemWillSleep`.
    /// Re-applied by `handleSystemDidWake` to bring the proxy back
    /// to the same mode the user was running before the system
    /// suspended — autonomously, without an operator click.
    /// Cleared once the wake recovery completes (success or failure).
    private var modeBeforeSleep: ProxyMode?
    public private(set) var logEntries: [LogEntry] = []
    public private(set) var firewallState: FirewallState = .unknown
    public private(set) var lastDiagnosticReport: DiagnosticReport?
    public private(set) var lastLatencyReport: LatencyReport?
    public private(set) var developerMetrics: DeveloperMetrics = .idle
    public private(set) var lastError: String?

    /// **v2.0.29 (Deterministic Error Reporting):** layer attribution
    /// for the most recent connection failure. Set whenever `recordError`
    /// is called from a connection-failure path; cleared on successful
    /// `start()` / `switchMode()`. Renders as a chip on the
    /// `HeaderView` error banner — `[ISP]` / `[VPS]` / `[Local Kernel]`.
    /// `nil` means "no layer attributed" (operational error, or
    /// classification was inconclusive); the banner falls back to the
    /// pre-2.0.29 plain-text rendering.
    public private(set) var lastErrorLayer: ErrorLayer?

    // MARK: - Dependencies (injected; defaultable)

    private let core: CoreClient
    private let proxyController: SystemProxyController
    private let firewall: FirewallProbe
    private let profileStore: ProfileStore
    private let settingsStore: SettingsStore
    private let paths: AppSupportPaths
    private let naiveResolver: NaiveBinaryResolver
    private let telemetry: LifecycleTelemetryLogger

    private var eventTask: Task<Void, Never>?
    private var didBootstrap: Bool = false
    /// Hardware-derived cap on retained log entries — 1000 on a
    /// modern Apple Silicon, 600 on a mid-tier Mac, 300 on older
    /// Intel hardware. A lower cap keeps the SwiftUI diff cheap on
    /// every append, which is the hot path that gets noticeable
    /// pause-spikes if naive starts streaming hundreds of lines a
    /// second on a flaky network.
    private let maxLogEntries: Int = PerformanceProfile.current.maxLogEntries
    /// In-flight task for [`refreshNaiveDescriptor`]. The Settings
    /// view's `.task` can fire two refreshes back-to-back if the
    /// user opens / dismisses / reopens the sheet quickly; without
    /// this each invocation would spawn its own `lipo` +
    /// `--version` subprocess pair and stomp the cached descriptor.
    /// Late callers `await` the existing task instead of spinning
    /// (the old `while … { await Task.yield() }` was a MainActor
    /// busy-loop that pinned a CPU under contention).
    private var refreshNaiveTask: Task<Void, Never>?

    /// In-flight debounced settings autosave; cancelled and
    /// replaced on every `persistSettings()` call so a rapid burst
    /// of edits collapses into a single write.
    private var persistSettingsTask: Task<Void, Never>?

    /// Single-flight guard for the `listeningOutsideLoopback`
    /// auto-stop. A burst of anomaly events would otherwise queue
    /// duplicate `stop()` tasks racing on `activeMode`.
    private var autoStopTask: Task<Void, Never>?
    private var selfHealTask: Task<Void, Never>?
    private var vpsHealthTask: Task<Void, Never>?
    /// Single-flight guard for the credential auto-sync flow.
    /// Triggered by HTTP-407-class auth failures in the engine's
    /// stderr stream when the active profile has a
    /// `subscriptionURL`. A burst of auth-failure log lines from
    /// a single failed start would otherwise queue duplicate
    /// re-fetches against the panel; once one is in flight, every
    /// other auth-failure line in the same window is a no-op.
    private var credentialAutoSyncTask: Task<Void, Never>?
    /// Timestamp of the last auto-sync attempt (success or
    /// failure). Pairs with `credentialAutoSyncCooldown` to keep
    /// a continuously-retrying engine from hammering the
    /// subscription panel — once the sync runs and returns "no
    /// drift," any further auth-failure stderr lines in the
    /// cooldown window are accepted and dropped, not retried.
    private var lastCredentialAutoSyncAt: ContinuousClock.Instant?
    /// Lower bound between consecutive auto-sync attempts. 30 s
    /// is long enough to let a transient panel hiccup self-heal,
    /// short enough that a real credential rotation propagates
    /// to the operator within one minute even if the first sync
    /// races a panel restart.
    private static let credentialAutoSyncCooldown: Duration = .seconds(30)
    private var lastTrafficSnapshot: TrafficSnapshotState?
    private var pendingLogEntries: [LogEntry] = []
    private var logFlushTask: Task<Void, Never>?
    private let logFlushIntervalNanos: UInt64 = PerformanceProfile.current.logFlushIntervalNanos
    private let maxLogBatchEntries: Int = PerformanceProfile.current.maxLogBatchEntries
    private let maxLogLineCharacters: Int = PerformanceProfile.current.maxLogLineCharacters

    /// Cached descriptor for the naive binary the app is currently
    /// configured to spawn. Populated on bootstrap and after each
    /// settings change so the Settings view can render the chip / arch
    /// summary without firing extra subprocesses.
    public private(set) var activeNaiveDescriptor: NaiveBinaryDescriptor?

    // `hostArchitecture` was previously re-exported here as a
    // convenience for the Settings view. Removed because
    // `HostArchitecture.current` is itself a static cached value
    // — the orchestrator was just a second alias adding no value
    // and inflating its public surface. Settings now reads
    // `HostArchitecture.current` directly.

    // MARK: - Construction

    public init(
        core: CoreClient,
        proxyController: SystemProxyController,
        firewall: FirewallProbe,
        profileStore: ProfileStore,
        settingsStore: SettingsStore,
        paths: AppSupportPaths,
        naiveResolver: NaiveBinaryResolver = NaiveBinaryResolver(),
        telemetry: LifecycleTelemetryLogger? = nil
    ) {
        self.core = core
        self.proxyController = proxyController
        self.firewall = firewall
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.paths = paths
        self.naiveResolver = naiveResolver
        self.telemetry = telemetry ?? LifecycleTelemetryLogger(url: paths.lifecycleTelemetryFile)
        self.telemetry.record(
            "orchestrator.init",
            mode: nil,
            running: false,
            details: ["telemetry_path": paths.lifecycleTelemetryFile.path]
        )
    }

    /// Builds an orchestrator wired with default dependencies sourced from
    /// the running app bundle.
    public static func bootstrap() -> TunnelOrchestrator {
        // Try the real Application Support directory first. If that
        // genuinely cannot be created (sandbox quirk, broken home
        // dir, full disk on `/Users`) we degrade to a temporary
        // directory and surface the failure as `lastError` after
        // construction — the user sees a real error message
        // explaining why Start fails, instead of a `fatalError`
        // that takes down the app with no UI feedback. LTSC users
        // landing security fixes in 2027 cannot afford boot-time
        // crashes that bypass every diagnostic surface.
        let paths: AppSupportPaths
        var bootstrapError: String?
        do {
            paths = try AppSupportPaths()
        } catch {
            bootstrapError =
                "Application Support unavailable: \(error.localizedDescription) — engine will refuse to start. Free disk space and relaunch."
            paths = AppSupportPaths.fallback()
        }

        // Pick the engine binary the orchestrator will spawn. The
        // settings store is read here (no I/O beyond UserDefaults
        // — no credential store, no keychain) so we honour any
        // `customRustCorePath` the user installed via the Settings
        // → Rust Core → Update flow on a previous run. Falls back
        // to the bundled binary when the path is empty or the
        // file no longer exists (e.g. the user manually removed
        // the managed copy under Application Support).
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

        // v0.1.5.5: passwords moved off the macOS Keychain by default.
        // The file-backed store writes to ~/Library/Application Support/
        // COOL-TUNNEL/credentials.json with mode 0600 — same protection
        // posture as Keychain on a single-user Mac, but no system
        // password prompt fires when the app launches under a fresh
        // ad-hoc-signed binary hash. The Keychain stays wired as the
        // *legacy* leg of `MigratingCredentialStore` so users upgrading
        // from v0.1.5.4 keep their saved passwords; the migration only
        // runs on a user-initiated Start, never at boot.
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
    /// Performs **exactly one** code-signature check before the UI
    /// appears: `cool-tunnel-core` is verified inside [`CoreClient.start`]
    /// because the engine has to launch for the app to function. The
    /// bundled `naive` binary is **not** verified here — its signature,
    /// host-arch slice, and `--version` output are inspected lazily the
    /// first time the user opens Settings or clicks Start, so launch
    /// stays fast and we avoid pre-paying authentication cost the user
    /// may never need (read-only profile browsing doesn't spawn naive).
    public func bootstrapIfNeeded() async {
        // **UX-F#16 (v0.1.7.19):** the `subscribeToEvents`
        // stream-end handler now flips `didBootstrap = false`
        // when the engine dies, so this guard correctly
        // re-bootstraps (re-spawns the engine) on the
        // next call rather than short-circuiting.
        guard !didBootstrap else { return }
        recordTelemetry("bootstrap.begin")

        // **Lifecycle-F#16 (v0.1.7.18):** crash-recovery sweep
        // BEFORE any other startup work. If the previous run
        // died with system proxy enabled, the user's network
        // is currently broken — disable the proxy first so
        // `firewall.currentState()` and any subsequent
        // network-touching calls actually work.
        await recoverFromCrashIfNeeded()

        profiles = profileStore.loadProfiles()
        selectedProfileID = profileStore.loadSelectedID() ?? profiles.first?.id
        settings = settingsStore.load()
        firewallState = await firewall.currentState()

        do {
            try await core.start()
            subscribeToEvents()
            // Only flip the guard on success so a future call (e.g.
            // a Retry button after a transient launch failure) can
            // re-attempt the engine spawn instead of permanently
            // short-circuiting on the previous failure.
            didBootstrap = true
            recordTelemetry("bootstrap.success")
        } catch {
            // **v2.0.29:** engine spawn failure is local-kernel-by-construction
            // — the Rust core couldn't be exec'd, the JSON-over-stdio
            // pipe never opened, or the orchestrator's own bootstrap
            // path threw. Hardcoded `.localKernel`; running the classifier
            // would only confirm what we already know.
            recordError("engine failed to start: \(error)", layer: .localKernel)
            recordTelemetry("bootstrap.failure", layer: .localKernel, message: error.localizedDescription)
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
        // Coalesce concurrent refreshes onto the in-flight task
        // instead of spinning. The previous `while isRefreshingNaive
        // { await Task.yield() }` was a MainActor busy-loop — under
        // contention it pinned a CPU and starved the UI. Holding a
        // single shared `Task` lets late callers `await` for free,
        // and dropping the cached task inside `defer` means the next
        // call genuinely re-runs the resolver.
        if let inFlight = refreshNaiveTask {
            await inFlight.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.activeNaiveDescriptor = try await self.naiveResolver.resolve(settings: self.settings)
            } catch let error as NaiveResolverError {
                // **v2.0.29:** naive binary failure is local-kernel-by-construction.
                self.recordError("naive binary unusable: \(error.localizedDescription)", layer: .localKernel)
                self.activeNaiveDescriptor = nil
            } catch {
                // **v2.0.29:** naive binary inspection failure is local-kernel-by-construction.
                self.recordError(
                    "naive binary inspection failed: \(error.localizedDescription)",
                    layer: .localKernel)
                self.activeNaiveDescriptor = nil
            }
        }
        refreshNaiveTask = task
        await task.value
        refreshNaiveTask = nil
    }

    /// Stops the engine and reverts the system proxy. Called from
    /// `AppDelegate.applicationWillTerminate` on real app quit.
    /// Sets `isShuttingDown = true` so the event-stream-end handler
    /// in `subscribeToEvents` knows the upcoming silence is
    /// expected (and not an engine crash).
    public func shutdown() async {
        recordTelemetry("shutdown.begin")
        isShuttingDown = true
        selfHealTask?.cancel()
        selfHealTask = nil
        vpsHealthTask?.cancel()
        vpsHealthTask = nil
        credentialAutoSyncTask?.cancel()
        credentialAutoSyncTask = nil
        flushPendingLogs()
        // Flush any pending debounced settings write before we go
        // away — without this, a settings edit made <250ms before
        // Cmd+Q would be silently dropped.
        flushSettings()
        eventTask?.cancel()
        eventTask = nil
        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        // **Lifecycle-F#16 (v0.1.7.18):** clear sentinel after
        // clean disable so next launch's recovery scan doesn't
        // fire spuriously.
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        await core.stop()
        activeMode = .stopped
        isRunning = false
        developerMetrics = .idle
        developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
            pid: nil,
            naiveRunning: false,
            firewallState: firewallState,
            status: "Stopped"
        )
        lastTrafficSnapshot = nil
        recordTelemetry("shutdown.success")
    }

    /// Set true the moment the orchestrator is about to tear the
    /// engine down on purpose. Lets the `subscribeToEvents` loop
    /// distinguish "the user quit the app" from "the engine just
    /// died on us" when its event stream finishes.
    private var isShuttingDown: Bool = false

    /// **Lifecycle-F#7 (v0.1.7.19):** transition lock. While
    /// true, `switchMode` / `start` / `stop` short-circuit to
    /// no-op. Without this, a user who clicks Smart at t=0 and
    /// Global at t=50 ms (mid-`stopQuiet`) gets two concurrent
    /// transitions racing on `paths.configFile`,
    /// `proxyController` state, and `core.send(...)` ordering.
    /// Both transitions write `naive`'s config; whichever wins
    /// the file race is what naive sees, and the system proxy
    /// state is whatever the last `enableX` call applied. The
    /// flag makes "second click while a transition is in
    /// flight" a clean no-op — the user's first intent wins.
    private var transitionInFlight: Bool = false

    /// **Engine-F#P1.2 (v0.2):** suppresses the
    /// `stateChanged(false)` recovery-error path while a
    /// user-initiated stop is in flight. Without this, every
    /// clean Stop produces a misleading "naive stopped
    /// unexpectedly — system proxy reverted" banner one tick
    /// later — naive's intentional shutdown event arrives at
    /// `handle(event:)` before `stop()` has reached its
    /// `isRunning = false` line, so the recovery branch fires
    /// for what was actually a healthy shutdown. Set true at
    /// the head of `stop()` and `stopQuiet()`, cleared in their
    /// `defer`. The event handler reads it as part of the
    /// existing `wasRunning && !isShuttingDown` guard.
    private var userStopInFlight: Bool = false

    /// **UX-F#3 (v0.1.7.19):** captured at start time so
    /// `selectedProfile.set` can detect "user edited the
    /// active profile while connected" and surface a banner.
    /// Without this, a profile-field edit silently keeps the
    /// running engine using the old config, but the form
    /// shows the new value — confusing.
    private var activeProfileID: String?

    /// **UX-F#6 (v2.0.14):** dirty flag set by the
    /// `selectedProfile.set` UX-F#3 detection path. While `true`
    /// the running naive instance's config is stale; a mode
    /// switch must therefore go through the full
    /// stop-engine / start-engine path so naive picks up the
    /// edits. Cleared on every successful `startCore` —
    /// re-launching the engine resyncs naive to the current
    /// profile, so subsequent mode switches can take the
    /// no-restart hot-swap path again.
    ///
    /// The flag is intentionally separate from `lastError` (which
    /// the same setter writes a banner into) — `lastError` is a
    /// user-facing surface that may be cleared independently
    /// (e.g. dismissing a banner) without affecting the
    /// orchestrator's internal "engine config is stale" truth.
    private var activeProfileEdited: Bool = false

    // MARK: - Profile management

    public var selectedProfile: Profile? {
        get {
            guard let id = selectedProfileID else { return profiles.first }
            return profiles.first { $0.id == id }
        }
        set {
            guard let updated = newValue else { return }
            // **UX-F#3 (v0.1.7.19):** detect "user edited the
            // active profile while connected" and surface a
            // banner. The running engine's config is locked at
            // the start-of-session moment; subsequent edits are
            // silently buffered for the next start. Without
            // this banner, users edit the server field, see
            // their input persist (correct), but get confused
            // when their browser keeps using the old server.
            // We flag it but don't auto-restart — restart-on-
            // edit could lose mid-session work for users who
            // are just typing a new draft profile.
            if isRunning, let active = activeProfileID, active == updated.id {
                let prior = profiles.first(where: { $0.id == updated.id })
                if let prior = prior, prior != updated {
                    lastError =
                        "Profile edits applied — click Stop, then a mode chip to use them. The running connection is still on the old config."
                    // **UX-F#6 (v2.0.14):** mark the running
                    // engine's config as stale so subsequent
                    // `switchMode` calls take the full restart
                    // path (which picks up the edits) instead of
                    // the no-restart hot-swap path (which would
                    // keep naive on the old config).
                    activeProfileEdited = true
                }
            }
            // **v2.0.25 hotfix:** previously this was an
            // update-in-place only — `if let index { profiles[index]
            // = updated }`. When the assigned profile carried an id
            // not present in `profiles` (the subscription-import
            // path's `selectedProfile?.id ?? UUID().uuidString`
            // fallback fires, or the previous selectedProfileID was
            // dangling), the new profile was silently dropped:
            // `selectedProfileID` advanced to the phantom id but the
            // array — and therefore `save(profiles:)` and the
            // credential store — never saw the imported credentials.
            // Result: subscription-imported password not saved on
            // next launch. Append-when-not-found makes any value
            // assigned through `selectedProfile =` persistent.
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
        // Delete the credential entry for the removed profile so a
        // stale entry does not linger if the user later creates a new
        // profile with the same id (e.g. another "default"). Goes
        // through the migrating store so the legacy Keychain copy is
        // cleaned up too.
        profileStore.deletePassword(forProfileID: id)
    }

    /// Debounced settings autosave. The Settings view binds form
    /// fields directly to `settings` and calls this on every
    /// keystroke; the previous unconditional `settingsStore.save`
    /// wrote the full UserDefaults blob once per character. The
    /// 250ms coalesce window means a typed paragraph turns into a
    /// single write; an explicit `commit()` (Done button) still
    /// flushes immediately via `flushSettings()`.
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

    /// Fetches a subscription manifest from `urlString` and imports the first
    /// profile's credentials into the selected profile (or a new profile if
    /// none is selected). Throws a typed [`SubscriptionImportError`] keyed
    /// on the failure mode so the UI can surface actionable banners
    /// (revoked, expired, server-down) instead of a single generic message.
    ///
    /// **Status-code mapping (Hardening v2.0.18-pre).** Laravel-side
    /// failures land on three buckets:
    /// - `401` — authenticated but the token resolves to a disabled /
    ///   expired / quota-exceeded account (`isActive() == false`).
    /// - `404` / `422` — token malformed or unknown. NOTE: the
    ///   server's `SubscriptionController` deliberately serves the
    ///   cover-site response for these to defeat enumeration, so the
    ///   client typically sees a `200 text/html` instead. The
    ///   manifest-decode-fails branch below handles that case.
    /// - `5xx` — the panel is down or APP_KEY is misconfigured.
    /// All three become distinct `SubscriptionImportError` cases below
    /// so the SwiftUI banner copy can match the failure mode.
    public func importFromSubscriptionURL(_ urlString: String) async throws {
        // Validate the URL shape (https:// + parseable) up-front so
        // we surface `invalidURL` before paying for a fetch attempt.
        // `SubscriptionClient.parseURL` enforces the same rules; we
        // pre-call here so a malformed input throws the right
        // user-facing error rather than the client's
        // `malformedURL`/`nonHTTPSURL` distinction the UI would just
        // collapse anyway.
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            url.scheme?.lowercased() == "https"
        else {
            throw SubscriptionImportError.invalidURL
        }
        // **OPSEC (post-v2.0.50):** never log the raw subscription
        // string. The path of a panel URL typically embeds the
        // operator's subscription token (e.g.
        // `/api/v1/subscription/<TOKEN>`); the previous form
        // (`url.host ?? urlString`) fell back to the full string
        // when `url.host` was nil (edge case: `https:///path` or
        // similar parser-permissive shapes), leaking the token
        // into the in-memory log AND the lifecycle-telemetry
        // file. Log host-only; if even the host can't be
        // resolved, log a fixed-shape placeholder.
        let host = url.host.flatMap { $0.isEmpty ? nil : $0 } ?? "<unknown>"
        appendInfo("subscription: fetching \(host)…")

        let manifest: SubscriptionManifestV1
        do {
            manifest = try await SubscriptionClient().fetch(from: trimmed)
        } catch let err as SubscriptionClientError {
            throw Self.translate(err)
        }

        // The client's `validate` already rejected an empty profile
        // list; this guard is defence-in-depth and matches the
        // existing public error type.
        guard let primary = manifest.primaryProfile else {
            throw SubscriptionImportError.noProfiles
        }

        // Preserve the user's chosen `localPort` and existing
        // profile id (if any) — the manifest is the source of
        // truth for credentials, not for per-machine UI state.
        // **v2.0.21 (Phase A fix):** previously the `host:port`
        // field was dropped on import — `Profile.server` got just
        // `first.host`. Subscriptions for panels on non-default
        // ports lost the port and silently fell back to the
        // engine's hardcoded :443. Now we serialize `host:port`
        // straight from the manifest's `ProfileV1`.
        let imported = Profile(
            id: selectedProfile?.id ?? UUID().uuidString,
            server: "\(primary.host):\(primary.port)",
            username: primary.username,
            password: primary.password,
            localPort: selectedProfile?.localPort ?? "1080",
            // **Auto-sync foundation (post-v2.0.48):** remember
            // the URL we just imported from so the auth-failure
            // auto-sync flow can re-fetch transparently when the
            // upstream rotates credentials. Stored on the
            // profile, persisted via ProfileStore alongside the
            // other fields.
            subscriptionURL: trimmed
        )
        selectedProfile = imported
        // Username deliberately omitted — the in-memory log buffer
        // backs the LogConsole's copy-to-pasteboard / share path,
        // and the engine treats usernames as account identifiers
        // worth redacting (`core/src/domain/credentials.rs`
        // `Username::Display` returns `"***"`). Matching that
        // discipline on the Mac side avoids leaking the username
        // into a support log the user pastes into a ticket.
        // **OPSEC (post-v2.0.50):** previously logged
        // `\(primary.host):\(primary.port)`, which leaked the
        // operator's proxy hostname into the in-memory log + the
        // lifecycle-telemetry file (the same redaction gap the
        // v2.0.47 debug_handshake fix closed at a different
        // callsite). Hostname:port is operator-fingerprinting
        // infrastructure metadata; the import-success message
        // doesn't need it to be useful.
        appendInfo("subscription: imported new credentials")
    }

    /// Translates a [`SubscriptionClientError`] (transport-shape
    /// failures) into the UI-facing [`SubscriptionImportError`]
    /// (failure-mode-shape errors, paired with actionable banner
    /// copy in `errorDescription`). Status-code routing matches
    /// the panel's `SubscriptionController` defensive-CDN cases:
    /// the panel itself answers every error with a 200 cover-site,
    /// so the explicit 4xx/5xx branches only fire when something
    /// in front of the panel (CDN, proxy interposition, DNS
    /// hijack) returns its own status.
    private static func translate(_ err: SubscriptionClientError) -> SubscriptionImportError {
        switch err {
        case .malformedURL, .nonHTTPSURL:
            return .invalidURL
        case .transportFailed(let msg):
            return .networkError(msg)
        case .httpStatus(let code):
            switch code {
            case 401: return .subscriptionRevoked
            case 404, 422: return .tokenInvalid
            case 429: return .rateLimited
            case 500...599: return .serverError(status: code)
            default: return .unexpectedStatus(code)
            }
        case .malformedManifest, .unexpectedContentType:
            // 200 + non-manifest body (or non-JSON Content-Type)
            // is the cover-site path the panel uses for any
            // rejected token — UI surfaces this as `tokenInvalid`
            // so the user understands the URL didn't match an
            // account.
            return .tokenInvalid
        case .oversizeBody(let cap):
            return .manifestTooLarge(cap: cap)
        case .manifestRejected(let validation):
            switch validation {
            case .unsupportedVersion(let got, _):
                return .unsupportedVersion(got: got)
            case .noProfiles:
                return .noProfiles
            case .tooManyProfiles, .counterfeitCapabilities,
                .invalidIssuedAt, .malformedExpiry, .validityTooLong,
                .blockedHost:
                // All six signal a stub or counterfeit manifest.
                // The user action is identical: do not connect,
                // contact the operator. Lumping into one UI case
                // keeps the banner copy clear; support can pivot
                // on the os_log entry that includes the structured
                // reason if a real distinction matters.
                return .manifestCounterfeit
            case .expired:
                return .manifestExpired
            case .stale(let ageSeconds):
                let days = max(1, Int(ageSeconds / (24 * 60 * 60)))
                return .manifestStale(daysOld: days)
            }
        }
    }

    // MARK: - Mode switching

    /// Atomically switches the *active* proxy mode. Three cases:
    ///
    /// 1. Proxy is stopped → equivalent to `start(mode:)`
    /// 2. Proxy is running in `mode` already → no-op (don't bounce
    ///    the supervisor for a click that selects the current mode)
    /// 3. Proxy is running in a *different* mode → stop, then start in
    ///    the new mode in one shot — the UI sees a single observable
    ///    transition (`activeMode` flips old→new at the very end of
    ///    the bring-up); `isRunning` never blinks false.
    ///
    /// This is what powers the single-button mode picker in the UI:
    /// tapping a mode chip while the tunnel is live hot-swaps it
    /// instead of forcing the user to stop first.
    ///
    /// **UX-F#5 (v2.0.13):** publish-state suppression during a
    /// hot-swap. The earlier implementation flipped
    /// `isRunning = false` and `activeMode = .stopped` inside
    /// `stopQuiet`, then flipped them back to true / newMode at the
    /// end of `startCore`. Between the two flips SwiftUI got at least
    /// one render opportunity (every `await` yield is a render
    /// boundary), so the Stop button visibly blinked through "Start"
    /// and the mode picker briefly de-highlighted every segment.
    /// Now `stopQuiet` is told to leave the published state alone
    /// during a hot-swap; `startCore` writes the new mode at the end
    /// as a single observable transition. On a failure inside the
    /// bring-up the engine is genuinely dead, so we restore truthful
    /// state (`isRunning = false`, `activeMode = .stopped`) before
    /// re-throwing — the UI must not lie about a non-running engine.
    ///
    /// **UX-F#6 (v2.0.14):** skip the engine restart entirely when
    /// the active profile is unchanged. Smart / Global / Local modes
    /// only differ in **system proxy configuration** (PAC vs SOCKS5
    /// vs none) and, for Smart, **PAC file regeneration**. The naive
    /// process binds to 127.0.0.1:port with the same config in all
    /// three modes, so killing and re-spawning it on every mode
    /// switch is unnecessary work that also drops in-flight TCP
    /// connections (apps see ~200-500 ms of "connection refused"
    /// during the gap). The new no-restart path reapplies the
    /// system-proxy + PAC bits and updates `activeMode` in a single
    /// observable transition, with naive untouched. Falls through to
    /// the full restart path if:
    ///
    ///   - the active profile has been edited (`activeProfileEdited`)
    ///     — naive must restart to pick up the new config;
    ///   - the user switched the *selected* profile to a different one
    ///     (`selectedProfileID != activeProfileID`) — same reasoning;
    ///   - `applyModeWithoutRestart` itself throws — partial
    ///     `proxyController` state is recovered by stopQuiet's
    ///     `disableAll()`, then startCore writes the correct config.
    public func switchMode(to newMode: ProxyMode) async throws {
        recordTelemetry(
            "switch.request",
            details: ["target_mode": newMode.rawValue]
        )
        selfHealTask?.cancel()
        selfHealTask = nil
        // A mode switch supersedes any in-flight credential
        // auto-sync — the auto-sync's captured `activeModeAtTrigger`
        // would otherwise restart the engine in the previous mode
        // a beat after the user picked the new one.
        credentialAutoSyncTask?.cancel()
        credentialAutoSyncTask = nil
        // **Lifecycle-F#7 (v0.1.7.19):** transition lock. A
        // rapid second click while a prior switchMode is
        // mid-flight (between stopQuiet and startCore) is a
        // clean no-op. The user's first intent wins. See the
        // `transitionInFlight` declaration above for the race
        // it defends against.
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
            // One logical user action, one log line. The earlier
            // implementation called the public `stop()` here, which
            // emitted "stopped" before the subsequent "started in X" —
            // so the live log read as a three-step dance for what the
            // user experiences as one tap. Quiet-stop here and let the
            // post-start switch line do the talking.
            let from = activeMode

            // **UX-F#6 (v2.0.14):** try the no-restart path first.
            // Gating: same-profile + not-edited + currently-running.
            // Anything else falls through to the full restart below
            // (which preserves the old behaviour exactly).
            let canHotSwapWithoutRestart =
                !activeProfileEdited
                && selectedProfileID == activeProfileID
                && activeMode != .stopped
            if canHotSwapWithoutRestart {
                do {
                    try await applyModeWithoutRestart(newMode)
                    // **UX-F#7 (v2.0.15):** verify naive is still
                    // alive before declaring the swap successful.
                    // The orchestrator's `transitionInFlight` gate
                    // (UX-F#5) suppresses any `stateChanged(false)`
                    // event the engine emits during this window, so
                    // a naive death that happens between
                    // `applyModeWithoutRestart` starting and ending
                    // would otherwise go undetected — the user
                    // would see "switched to X" with the Stop
                    // button still red while their browser quietly
                    // stalls. Throwing here routes the call into
                    // the fallback full-restart path below.
                    try await verifyNaiveLiveAfterHotSwap()
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
                    // No-restart attempt failed — `proxyController`
                    // state may be partial (e.g. enableSmartPAC
                    // succeeded for some network services but not
                    // others before throwing). Fall through to the
                    // full restart path; stopQuiet's `disableAll()`
                    // will reset proxyController to a clean state
                    // before startCore reapplies the correct config.
                    //
                    // Defensive: mark the active profile as edited
                    // so any later code path that re-checks the
                    // hot-swap gate sees it as ineligible. The
                    // current call's fallback below is unconditional
                    // (it doesn't re-check the gate), so this is
                    // belt-and-suspenders for future refactors.
                    // Cleared at the next successful `startCore`.
                    activeProfileEdited = true
                    Self.hotSwapLogger.notice(
                        "no-restart switch to \(newMode.rawValue, privacy: .public) failed (\(error.localizedDescription, privacy: .public)); falling back to full engine restart"
                    )
                }
            }

            // UX-F#5: skip the published `isRunning = false /
            // activeMode = .stopped` flips in stopQuiet. The user's
            // intent is "still running, just under a different mode",
            // and that is what the UI should show throughout. The
            // engine IS torn down and brought back up internally, but
            // the observable state stays at the OLD mode until
            // `startCore` writes the NEW one in a single transition.
            await stopQuiet(publishStoppedState: false)
            do {
                try await startQuiet(mode: newMode)
            } catch {
                // Engine is genuinely dead — startCore's writes never
                // ran. Restore truthful UI state so the user sees the
                // failure instead of a phantom "Stop" button over a
                // dead engine.
                activeMode = .stopped
                isRunning = false
                developerMetrics = .idle
                developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
                    pid: nil,
                    naiveRunning: false,
                    firewallState: firewallState,
                    status: "Start failed"
                )
                lastTrafficSnapshot = nil
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

    /// **UX-F#6 (v2.0.14):** hot-swap mode without restarting the
    /// engine. Reapplies the system-proxy configuration for
    /// `newMode` and, when switching *to* Smart, regenerates the
    /// PAC file. The running naive process is left untouched —
    /// `127.0.0.1:port` keeps accepting connections throughout, so
    /// long-lived TCP sessions don't drop and apps connecting
    /// during the swap don't get refused.
    ///
    /// Order of operations:
    ///
    ///   1. Regenerate PAC (only if `newMode == .smart`). Done
    ///      before touching `proxyController` so a PAC-gen failure
    ///      surfaces before any system-proxy change has happened.
    ///   2. Apply the system-proxy configuration for `newMode`
    ///      (the same `enableSmartPAC` / `enableGlobalSOCKS` /
    ///      `disableAll` calls `startCore` makes at the equivalent
    ///      step in the full path).
    ///   3. Update the recovery sentinel (`ProxyActiveFlag`) so a
    ///      hard crash before the next clean stop is recoverable —
    ///      same invariant as the full path.
    ///   4. Publish `activeMode = newMode` as a single observable
    ///      transition. The picker and any other UI bound to
    ///      `activeMode` re-renders once.
    ///
    /// Throws on any failure. The caller (`switchMode`) handles
    /// the error by falling through to the full engine restart —
    /// see the `do/catch` around the call site for the rationale.
    private func applyModeWithoutRestart(_ newMode: ProxyMode) async throws {
        recordTelemetry(
            "switch.hotswap.begin",
            details: ["to_mode": newMode.rawValue]
        )
        // Mirror `startCore`'s optimistic banner clear (line ~582):
        // a successful mode switch should not leave the user
        // staring at a stale failure banner. If the body below
        // throws, `switchMode` falls through to `startCore`, which
        // also clears `lastError` at its own top — so either path
        // ends with a coherent banner state.
        lastError = nil
        lastErrorLayer = nil

        guard let profile = selectedProfile else {
            throw OrchestratorError.noProfile
        }
        let port = try parsePort(profile.localPort)

        if newMode == .smart {
            // The set of direct-domains may have changed in
            // `settings` since the last start; regenerate the PAC
            // every time we hot-swap into Smart so the routing
            // table reflects the user's current intent. (The full
            // `startCore` path does the same — this is parity, not
            // a new policy.)
            let pacResponse = try await core.send(
                .generatePac(directDomains: settings.directDomains, port: port)
            )
            guard case .pac(let pacJS) = pacResponse else {
                throw OrchestratorError.unexpectedResponse
            }
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
            // switchMode never calls this with `.stopped` — that
            // branch routes to `stop()` instead. Keep the case
            // defensively explicit so a future caller can't slip
            // through to silently no-op.
            return
        }

        // Single observable transition for SwiftUI. `isRunning` is
        // already true and stays true; only the mode chip changes.
        activeMode = newMode
        updateDeveloperKernelHealth(pid: lastTrafficSnapshot?.pid)
        recordTelemetry(
            "switch.hotswap.applied",
            details: ["to_mode": newMode.rawValue]
        )
    }

    /// Internal stop path used by `switchMode` — same teardown work as
    /// `stop()`, no `appendInfo("stopped")`. Stays private; callers
    /// outside the orchestrator should use `stop()` so the log is
    /// always informative for explicit stops.
    ///
    /// `publishStoppedState` controls whether `isRunning` and
    /// `activeMode` are flipped to `false` / `.stopped` after the
    /// engine teardown completes. Default `true` matches the
    /// always-stop semantics every legacy caller wants. Pass `false`
    /// from `switchMode` so the UI doesn't observe the brief
    /// "stopped" intermediate state during a hot-swap (UX-F#5).
    private func stopQuiet(publishStoppedState: Bool = true) async {
        recordTelemetry(
            "stop.quiet.begin",
            details: ["publish_stopped_state": String(publishStoppedState)]
        )
        // **Engine-F#P1.2 (v0.2):** mark this stop as user-
        // initiated for the duration of the call so the
        // `stateChanged(false)` event handler doesn't post a
        // phantom "naive stopped unexpectedly" banner for the
        // shutdown event we just *asked* naive to emit.
        userStopInFlight = true
        defer { userStopInFlight = false }

        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        // **Lifecycle-F#16 (v0.1.7.18):** clear sentinel on
        // clean stop. Same reasoning as `shutdown()`.
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
            developerMetrics = .idle
            developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
                pid: nil,
                naiveRunning: false,
                firewallState: firewallState,
                status: "Stopped"
            )
            lastTrafficSnapshot = nil
        }
        recordTelemetry(
            "stop.quiet.success",
            details: ["publish_stopped_state": String(publishStoppedState)]
        )
    }

    /// Internal start path mirror of `start(mode:)` that omits the
    /// trailing "started in X" log line so `switchMode` can replace
    /// the pair of stop/start lines with a single "switched from X
    /// to Y".
    private func startQuiet(mode: ProxyMode) async throws {
        try await startCore(mode: mode, log: false)
    }

    /// **UX-F#7 (v2.0.15):** post-hot-swap liveness probe.
    ///
    /// Sends `probe_naive_live` to the engine and throws if the
    /// engine reports naive is no longer running. The
    /// `transitionInFlight` gate (UX-F#5) suppresses
    /// `stateChanged(false)` events delivered during a hot-swap
    /// so the UI doesn't blink, but that suppression also hides
    /// a genuine naive crash if it happens in the ~50 ms swap
    /// window. This probe converts that silent gap into an
    /// explicit yes/no answer the orchestrator can route on.
    ///
    /// Throws on:
    ///   - The engine reports `running: false`. Caller's catch
    ///     arm logs at `.notice` and falls through to the
    ///     full-restart path; `startCore` re-spawns naive.
    ///   - The engine itself is dead and `core.send` errors out
    ///     with broken-pipe / connection-closed. Same recovery
    ///     path; the full-restart path will surface a more
    ///     useful error if it can't bring the engine back.
    ///   - The engine returns a response shape we don't
    ///     recognise (`.unexpectedResponse`). Defensive — won't
    ///     fire under normal operation.
    private func verifyNaiveLiveAfterHotSwap() async throws {
        let response = try await core.send(.probeNaiveLive)
        guard case .naiveLiveness(let running, let pid) = response else {
            throw OrchestratorError.unexpectedResponse
        }
        if !running {
            Self.hotSwapLogger.notice(
                "post-swap liveness probe says naive is dead (last known pid=\(pid.map(String.init) ?? "none", privacy: .public)); will route to full restart"
            )
            throw HotSwapError.engineDied
        }
    }

    /// Internal control-flow signal used by
    /// `verifyNaiveLiveAfterHotSwap` to route the swap back
    /// through the full-restart fallback. Never surfaces to the
    /// user — `switchMode`'s catch arm logs and re-tries via
    /// `stopQuiet`/`startQuiet`. Kept as a private nested type
    /// (rather than added to `OrchestratorError`) because it
    /// describes an *internal* recovery transition, not a
    /// user-facing failure mode.
    private enum HotSwapError: Error {
        case engineDied
    }

    // MARK: - Lifecycle commands

    /// Validates the selected profile, writes config + PAC, spawns naive,
    /// and applies the requested system-proxy configuration. Logs
    /// "started in X" on success.
    public func start(mode: ProxyMode) async throws {
        try await startCore(mode: mode, log: true)
    }

    /// Underlying start implementation. `log` controls whether the
    /// trailing "started in X" line is appended — `switchMode` calls
    /// this with `log: false` so it can emit a single "switched
    /// from X to Y" line in the public log instead of the
    /// stop/start pair the user sees as visual noise.
    ///
    /// **Engine-F#P0 (v0.2):** the entire body is wrapped in a
    /// single do/catch that publishes any failure to `lastError`
    /// (via `recordError`) before re-throwing. Pre-v0.2, every
    /// throw inside this method propagated to the view's empty
    /// catch block, where the comment claimed "lastError carries
    /// the user-facing surface" — but no path here ever set it on
    /// failure. Result: a port-collision or naive-spawn-failure
    /// produced silent UI on the click of Smart / Global / Local.
    /// Now: any failure path inside `startCore` populates
    /// `lastError` and the live log before the throw escapes, so
    /// the existing HeaderView error banner becomes the visible
    /// surface for engine errors too.
    private func startCore(mode: ProxyMode, log: Bool) async throws {
        guard mode != .stopped else { return }
        recordTelemetry(
            "start.begin",
            details: ["target_mode": mode.rawValue]
        )
        // Clear stale error from any previous failed attempt — a successful
        // start should not leave the user staring at last week's failure.
        // Hoisted above the do/catch so a successful start always begins
        // with a clean banner, while a failing start will repopulate
        // `lastError` from the catch arm below.
        lastError = nil
        lastErrorLayer = nil

        do {
            guard var profile = selectedProfile else {
                throw OrchestratorError.noProfile
            }

            try hydratePasswordIfNeeded(&profile)

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
            try RestrictedFile.write(configJSON, to: paths.configFile)

            let port = try parsePort(profile.localPort)

            if mode == .smart {
                let pacResponse = try await core.send(
                    .generatePac(directDomains: settings.directDomains, port: port)
                )
                guard case .pac(let pacJS) = pacResponse else {
                    throw OrchestratorError.unexpectedResponse
                }
                try RestrictedFile.write(pacJS, to: paths.pacFile)
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
                    port: port,
                    monitorIntervalSecs: PerformanceProfile.current.connectionMonitorIntervalSecs
                ))
            guard case .started(let naivePID) = started else {
                throw OrchestratorError.unexpectedResponse
            }

            // Apply system proxy.
            switch mode {
            case .smart:
                try await proxyController.enableSmartPAC(pacURL: paths.pacFile)
                // **Lifecycle-F#16 (v0.1.7.18):** write the
                // proxy-active sentinel so a crash before
                // `disableAll()` runs is recoverable on next launch.
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
                // local mode doesn't touch system proxy — clear
                // any stale flag from a previous mode run.
                ProxyActiveFlag.clear(
                    at: ProxyActiveFlag.path(in: paths.supportDirectory))
            case .stopped:
                break
            }

            activeMode = mode
            isRunning = true
            updateDeveloperKernelHealth(pid: naivePID)
            startVPSHealthLoop()
            // **UX-F#3 (v0.1.7.19):** capture which profile the
            // engine started with. The selectedProfile setter
            // compares against this to detect edits to the
            // currently-active profile.
            activeProfileID = selectedProfileID
            // **UX-F#6 (v2.0.14):** the engine just resynced to
            // the current profile — clear the stale-config flag.
            activeProfileEdited = false
            if log {
                appendInfo("started in \(mode.title)")
            }
            recordTelemetry(
                "start.success",
                details: [
                    "mode": mode.rawValue,
                    "local_port": String(port),
                    "naive_pid": String(naivePID),
                ]
            )
        } catch {
            // Build a user-readable message: the typed
            // `OrchestratorError` cases already carry localized
            // descriptions; everything else falls back to the
            // error's own description. Engine wire errors
            // (`ErrorPayload`) include the engine's own message
            // string, which is what we want surfaced for things
            // like "address already in use".
            let detail =
                (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // **v2.0.29 (Deterministic Error Reporting):** classify
            // the connection failure into ISP / VPS / Local Kernel so
            // the banner chip pinpoints the broken node. Pre-2.0.29
            // the operator saw a generic "Couldn't start <mode>" with
            // no signal whether to check their wifi, their server, or
            // their app — they had to run `Diag` manually to find out.
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
        vpsHealthTask?.cancel()
        vpsHealthTask = nil
        // User-initiated stop cancels any in-flight credential
        // auto-sync — the operator wants the tunnel down, not a
        // background restart that surprises them by re-spawning
        // naive a half-second after they hit Stop.
        credentialAutoSyncTask?.cancel()
        credentialAutoSyncTask = nil
        // Guard against re-entry when we're already stopped. A
        // user spam-clicking the Stop button would otherwise loop
        // back through `disableAll()` (which iterates every active
        // network service and runs `networksetup` twice each) and
        // then call `core.send(.stopProxy)` against an engine
        // that no longer has a proxy to stop — surfacing as a
        // misleading "stop failed: not_running" log line. Single
        // exit point keeps the user-facing behaviour clean.
        guard isRunning || activeMode != .stopped else { return }
        // **Engine-F#P1.2 (v0.2):** see `userStopInFlight` doc —
        // suppresses the spurious "naive stopped unexpectedly"
        // recovery error that would otherwise fire when naive's
        // intentional `stateChanged(false)` event arrives mid-
        // stop, before this body has set `isRunning = false`.
        userStopInFlight = true
        defer { userStopInFlight = false }

        try? await proxyController.disableAll()  // try-ok: best-effort proxy revert
        // **Lifecycle-F#16 (v0.1.7.18):** clear sentinel on
        // user-initiated stop.
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        do {
            _ = try await core.send(.stopProxy)
        } catch {
            recordError("stop failed: \(error)")
        }
        activeMode = .stopped
        isRunning = false
        developerMetrics = .idle
        developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
            pid: nil,
            naiveRunning: false,
            firewallState: firewallState,
            status: "Stopped"
        )
        lastTrafficSnapshot = nil
        appendInfo("stopped")
        recordTelemetry("stop.success")
    }

    /// **Lifecycle-F#16 (v0.1.7.18):** crash-recovery sweep.
    /// Called by AppDelegate before any other startup work. If
    /// the proxy-active sentinel exists, the previous run died
    /// without disabling — force-disable the system proxy now
    /// so the user gets a working network on launch.
    ///
    /// **Engine-F#P2.5 (v0.2):** also sweeps for orphan `naive`
    /// processes that survived the crash. If `cool-tunnel-core`
    /// was SIGKILL'd while `naive` was its child, naive gets
    /// reparented to launchd and keeps holding its local port.
    /// On the next launch, `core.send(.startProxy)` would fail
    /// with EADDRINUSE — combined with the silent-error fix
    /// (P0 #1) the user would just see "Couldn't start: address
    /// already in use" with no obvious culprit. This sweep
    /// terminates orphans (parent PID == 1) before the next
    /// start attempt so launches are deterministic.
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

        await sweepOrphanNaiveIfAny()
    }

    /// **Engine-F#P2.5 (v0.2):** terminate any `naive` process
    /// reparented to launchd (PID 1) — the signature of an
    /// orphan that outlived its `cool-tunnel-core` parent.
    /// Two-stage match keeps this targeted and safe:
    ///
    /// 1. `pgrep -x naive` returns processes whose **executable
    ///    name** is exactly `naive`. Matching the process name
    ///    (not `-f` against the cmdline) avoids killing a user's
    ///    own `cat /path/to/naive` or text editor.
    /// 2. `ps -o ppid=` filters to PIDs whose parent is `1`
    ///    (launchd). A naive whose parent is still alive belongs
    ///    to that parent — leave it alone.
    ///
    /// SIGTERM with a 500 ms grace, then SIGKILL any survivors.
    /// Failures (sandbox-blocked `kill`, missing `pgrep`, etc.)
    /// are logged and skipped — the sweep is best-effort, never
    /// blocks the bootstrap.
    private func sweepOrphanNaiveIfAny() async {
        let pgrep = URL(fileURLWithPath: "/usr/bin/pgrep")
        let ps = URL(fileURLWithPath: "/bin/ps")

        let listing: SubprocessResult
        do {
            listing = try await Subprocess.run(
                executable: pgrep,
                arguments: ["-x", "naive"],
                timeout: 5
            )
        } catch {
            Self.recoveryLogger.warning(
                "orphan-naive sweep skipped (pgrep launch failed): \(error.localizedDescription, privacy: .public)"
            )
            return
        }
        // pgrep convention: exit 0 = matches printed; exit 1 =
        // no match (clean); exit ≥ 2 = error. Only act on exit 0.
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
            // naive processes exist but have living parents —
            // owned by another tool, not our orphan.
            return
        }

        let pidStr = orphans.map(String.init).joined(separator: ", ")
        appendInfo(
            "orphan naive (PID \(pidStr)) survived previous crash — terminating"
        )
        Self.recoveryLogger.notice(
            "sweeping orphan naive PIDs: \(pidStr, privacy: .public)"
        )

        for pid in orphans {
            _ = kill(pid, SIGTERM)
        }
        try? await Task.sleep(nanoseconds: 500_000_000)  // try-ok: sleep cancellation
        for pid in orphans where kill(pid, 0) == 0 {
            // Still alive after SIGTERM grace — escalate.
            _ = kill(pid, SIGKILL)
        }
    }

    /// Helper: returns the parent PID of `pid` via `ps -o ppid=`.
    /// `nil` on any failure (process gone, ps unavailable, malformed
    /// output) so callers treat the candidate as "don't touch."
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

    /// **Engine-F#P2.5 (v0.2):** dedicated logger for the
    /// crash-recovery / orphan-sweep path. Same subsystem as
    /// `ProxyActiveFlag.logger` (`ProxyRecovery`) so the full
    /// recovery story shows up under one `log show` predicate.
    private static let recoveryLogger = Logger.cooltunnel("ProxyRecovery")

    /// **UX-F#6 (v2.0.14):** dedicated logger for the no-restart
    /// mode-switch path (`applyModeWithoutRestart`). When the
    /// no-restart attempt fails and we fall back to the full
    /// engine restart, the diagnostic goes here at `.notice` so a
    /// support engineer can confirm whether the hot-swap path is
    /// the right shape for the failures they see in the field.
    /// User-visible errors come from the subsequent
    /// `startCore` catch arm via `recordError`.
    private static let hotSwapLogger = Logger.cooltunnel("HotSwap")

    /// **F-1 (v2.0.28 — Seamless Recovery Protocol):** called by
    /// AppDelegate when `NSWorkspace.willSleepNotification` fires.
    /// Pauses the engine cleanly *before* the system suspends so
    /// upstream TCP gets closed gracefully and the lsof
    /// `monitor_loop` stops hammering across the sleep window.
    /// Pre-v2.0.28 there was no willSleep listener at all — the
    /// engine kept its state through suspend, hardware NIC dropped
    /// the upstream connections under it, and the user woke up to
    /// a "Connected" pill that no longer carried any traffic
    /// (the "zombie" symptom).
    ///
    /// Skips:
    /// - `.stopped` mode — nothing to pause.
    /// - `.localOnly` mode — the SOCKS listener on `127.0.0.1` has
    ///   no upstream TCP that gets dropped by hardware sleep, so
    ///   there's nothing to recover from on wake.
    ///
    /// State machine: `.idle → .pausing → .paused`. The wake
    /// handler picks up from `.paused` and re-applies
    /// `modeBeforeSleep`.
    public func handleSystemWillSleep() async {
        guard isRunning, activeMode != .stopped, activeMode != .localOnly else {
            return
        }
        let snapshotMode = activeMode
        sleepWakeState = .pausing
        appendInfo(
            "system entering sleep — pausing engine to avoid zombie connections after wake")
        await stop()
        // `stop()` clears `activeMode` and `isRunning`; we pinned
        // the pre-sleep mode in `snapshotMode` above so the wake
        // handler can re-apply it.
        modeBeforeSleep = snapshotMode
        sleepWakeState = .paused
    }

    /// **F-2 (v2.0.28 — Seamless Recovery Protocol):** called by
    /// AppDelegate when `NSWorkspace.didWakeNotification` fires.
    /// Two paths:
    ///
    /// **Path A — clean checkpoint (preferred).** If `willSleep`
    /// reached us (so `sleepWakeState == .paused` and
    /// `modeBeforeSleep` carries the pre-sleep mode), the engine
    /// is already stopped and we just re-spawn it in the same
    /// mode. 500 ms cooldown lets the network stack settle (DNS
    /// TTLs reset, route table sync, Wi-Fi association complete)
    /// before we ask `naive` to bind upstream again. End state:
    /// `sleepWakeState = .idle`, mode restored, no operator
    /// intervention required.
    ///
    /// **Path B — missing checkpoint (fallback).** If we somehow
    /// missed `willSleep` (app launched mid-sleep window, or the
    /// notification raced after the system already suspended), we
    /// fall through to the prior probe-only behaviour from
    /// v0.1.7.18 so we at least surface the zombie state through
    /// the error banner.
    public func handleSystemDidWake() async {
        // Path A — we cleanly paused via willSleep.
        if sleepWakeState == .paused, let mode = modeBeforeSleep {
            sleepWakeState = .recovering
            appendInfo("system woke — recovering engine in \(mode.title) mode")
            // 500 ms cooldown for the network stack to settle.
            try? await Task.sleep(nanoseconds: 500_000_000)  // try-ok: sleep cancellation
            do {
                try await switchMode(to: mode)
                sleepWakeState = .idle
                modeBeforeSleep = nil
                appendInfo("recovery complete — \(mode.title) restored")
            } catch {
                sleepWakeState = .idle
                modeBeforeSleep = nil
                // **v2.0.29 (Deterministic Error Reporting):** the
                // wake-recovery failure is exactly the path where
                // layer attribution helps most — a wake into a
                // dead Wi-Fi association reads as `.isp`, a
                // wake while travelling to a network that blocks
                // the operator's VPS reads as `.vps`, and a wake
                // where naive crashed during sleep reads as
                // `.localKernel`. The chip on the banner gives the
                // operator the right next click — open Wi-Fi
                // settings, open the server's status page, or
                // click a mode to respawn naive — without having
                // to run `Diag` manually.
                await recordClassifiedError(
                    "auto-recovery after sleep failed: \(error.localizedDescription)"
                )
            }
            return
        }

        // Path B — missing checkpoint, fall back to probe-only.
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
        let response = try await core.send(.probeNaiveLive)
        guard case .naiveLiveness(let running, _) = response else {
            throw OrchestratorError.unexpectedResponse
        }
        guard running else { throw HotSwapError.engineDied }
        let report = try await core.probe(profile: profile, timeoutSecs: 3)
        guard report.reachable else { throw HotSwapError.engineDied }
    }

    public func runDiagnostics() async {
        recordTelemetry("diagnostics.begin")
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
                updateEncryptionOverhead(from: report)
                // Per-sample timing breakdown into the live log so the
                // user can read the DNS / connect / TLS / first-byte
                // split alongside the total — matches how clash-verge
                // surfaces probe results in its log pane.
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
        appendInfo("debug handshake: starting reference-naive probe…")
        do {
            guard var profile = selectedProfile else {
                throw OrchestratorError.noProfile
            }
            try hydratePasswordIfNeeded(&profile)
            let validation = try await core.send(.validateProfile(profile))
            guard case .validation(let validationReport) = validation, validationReport.ok else {
                throw OrchestratorError.invalidProfile(reason: extractValidationReason(validation))
            }
            let descriptor = try await naiveResolver.resolve(settings: settings)
            activeNaiveDescriptor = descriptor
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
            let glyph = report.ok ? "✓" : "✗"
            appendInfo(
                "debug handshake: \(glyph) server=\(report.server) target=\(report.target) connect_ok=\(report.connectOk) post_connect_recv=\(report.postConnectReceivedBytes)B elapsed=\(report.elapsedMs)ms"
            )
            appendInfo("debug handshake sent[0..1024]=\(report.localSentHex)")
            appendInfo(
                "debug handshake recv[0..1024]=\(report.localReceivedHex.isEmpty ? "<empty>" : report.localReceivedHex)"
            )
            for line in report.naiveStdout {
                appendInfo("debug handshake naive stdout: \(line)")
            }
            for line in report.naiveStderr {
                appendLog(source: .stderr, text: "[debug handshake naive stderr] \(line)")
            }
            if let error = report.error, !error.isEmpty {
                appendLog(source: .stderr, text: "[debug handshake error] \(error)")
            }
            let total = Self.formatElapsed(since: started)
            // **Redaction (post-v2.0.45):** the `server` and `target`
            // bare-hostname strings (e.g. `"cookie.coolwhite.space:443"`,
            // `"www.google.com:443"`) do not match any pattern in
            // `LifecycleTelemetryLogger.redact` — the rule set only
            // catches `scheme://userinfo@host`, auth headers, cookies,
            // and JSON credential pairs. Emitting them verbatim leaked
            // the operator's server hostname into the 0600-mode
            // telemetry file on every Debug Handshake click. Both
            // values are already visible in the user's live log
            // surface and exported on demand through the log
            // console's Copy / Save / Share path, so dropping them
            // from auto-persisted telemetry loses nothing the
            // operator can't recover. Regression-tested by
            // `LifecycleTelemetryRedactionTests
            // .testDebugHandshakeDetailsCarryNoServerHostname`.
            recordTelemetry(
                report.ok ? "debug_handshake.success" : "debug_handshake.failure",
                details: ["elapsed": total]
            )
        } catch {
            recordError("debug handshake failed: \(error)", layer: .localKernel)
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
            self.flushPendingLogs()
            // Stream ended. Two cases produce that:
            //   1. We deliberately shut the engine down via
            //      `shutdown()` — `isShuttingDown` is true and we
            //      stay quiet.
            //   2. The engine subprocess died on us — pipe broke,
            //      cool-tunnel-core crashed, OS killed it. The user
            //      needs to know; otherwise the live log just stops
            //      receiving lines and they assume "nothing's
            //      happening" while the proxy is silently dead.
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
        developerMetrics = .idle
        developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
            pid: nil,
            naiveRunning: false,
            firewallState: firewallState,
            status: "Engine exited"
        )
        lastTrafficSnapshot = nil
        vpsHealthTask?.cancel()
        vpsHealthTask = nil
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
                    // **M7 (v2.0.38):** classify the failure so a
                    // permanent error (bad profile shape, missing
                    // naive binary, wire-protocol drift) doesn't
                    // burn the full retry budget and three confused
                    // log lines before the operator sees the real
                    // cause. Transient failures (engine race,
                    // keychain unlock pending, network blip) still
                    // retry as before.
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

    /// Detects HTTP-407-class auth failures in the engine's
    /// stderr. NaiveProxy is built on Chromium's networking stack
    /// and reports proxy-auth failures with `ERR_PROXY_AUTH_*` /
    /// `ERR_TUNNEL_AUTH_*` chips, plus the raw `407` status if it
    /// surfaces in any log line. The match is permissive on
    /// purpose — a false positive turns into a no-op
    /// `scheduleCredentialAutoSync` when the upstream credentials
    /// are unchanged, but a false negative leaves the operator
    /// stranded with a stale password.
    ///
    /// Pure / nonisolated so the function is testable from outside
    /// the MainActor and so the hot stderr loop in `handle(event:)`
    /// doesn't need to hop actors for the check.
    nonisolated static func isProxyAuthFailureLine(_ line: String) -> Bool {
        let upper = line.uppercased()
        if upper.contains("ERR_PROXY_AUTH") { return true }
        if upper.contains("ERR_TUNNEL_AUTH") { return true }
        if upper.contains("407 PROXY AUTHENTICATION") { return true }
        if upper.contains("PROXY AUTHENTICATION REQUIRED") { return true }
        if upper.contains("AUTHENTICATION REQUIRED") { return true }
        // Raw status-code match — surrounded by non-alphanumeric
        // separators so a coincidental "407" inside a longer
        // numeric run (port numbers, byte counts) doesn't fire.
        // The separators include space, comma, period, colon,
        // bracket, paren, slash, equals, quote, and end-of-line.
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

    /// Auto-sync triggered by an auth-failure log line. Returns
    /// early when there's nothing to do (no profile, no
    /// subscription URL on the profile, or a sync already in
    /// flight). Otherwise: fetches the subscription URL,
    /// compares the returned credentials to the cached values,
    /// and restarts the engine only when they actually differ.
    ///
    /// **Single-flight discipline.** A failed start can emit
    /// many 407-shaped stderr lines in a few milliseconds; only
    /// the first one schedules an actual sync. The
    /// `credentialAutoSyncTask` property is the gate.
    ///
    /// **Fail-quiet on the "no drift" path.** If the upstream
    /// returns the same credentials we already cached, the auth
    /// failure was something else (subscription token revoked,
    /// server-side basic_auth misconfiguration, etc.) — the sync
    /// logs a one-line info note and falls through to the
    /// existing error-classification path the user has always
    /// seen.
    ///
    /// **Restart path.** When credentials do change, the engine
    /// is stopped via `stopQuiet()` (the same path
    /// `switchMode` uses for hot-swap) and started against the
    /// previous mode. A start failure here surfaces through the
    /// usual self-heal pipeline — auto-sync is best-effort,
    /// not a hard guarantee.
    private func scheduleCredentialAutoSync(reason: String) {
        guard credentialAutoSyncTask == nil else { return }
        guard let profile = selectedProfile else { return }
        guard let url = profile.subscriptionURL,
            !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return
        }
        // Cooldown — drop the request silently if we're inside
        // the window of the previous attempt. The continuously-
        // failing case (panel down + engine retrying) should
        // hit the panel at most twice per minute, not 200 times
        // per second.
        if let last = lastCredentialAutoSyncAt,
            ContinuousClock.now - last < Self.credentialAutoSyncCooldown
        {
            return
        }
        lastCredentialAutoSyncAt = ContinuousClock.now
        let oldPassword = profile.password
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
                // Don't recordError here — the existing
                // error-classification path already produced a
                // user-facing banner for the underlying auth
                // failure. A second banner about a failed
                // sync would be noise.
                return
            }

            // **UX-F#3 race:** the `selectedProfile` setter
            // raises a "Profile edits applied — click Stop,
            // then a mode chip" banner whenever a running
            // session's profile is mutated. The auto-sync IS
            // about to do exactly that, so the banner is
            // false-positive guidance — the user can't act on
            // it any faster than we're already acting. Clear
            // it here before the restart.
            self.lastError = nil
            self.lastErrorLayer = nil
            self.activeProfileEdited = false

            // After import, selectedProfile reflects the upstream's
            // current credentials. If nothing changed, the auth
            // failure was something other than credential drift.
            let refreshed = self.selectedProfile
            let changed =
                refreshed?.password != oldPassword
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

            // Quiet stop (no recovery banner, no system-proxy
            // revert flicker) followed by a fresh start. If start
            // fails, the engine's existing event-driven self-heal
            // path takes over from there.
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

    /// Returns true for failures that retrying `start(mode:)` will not
    /// recover. Used by `scheduleSelfHeal` to short-circuit the retry
    /// budget when the cause is unambiguously configuration / shape
    /// rather than a transient race.
    ///
    /// Conservatively false-by-default: when in doubt, retry. The
    /// retry budget (3 attempts over ~7.5 s total) is cheap enough
    /// that a wrong "permanent" classification is more harmful than
    /// a wrong "transient" one. Specifically, `credentialReadFailed`
    /// is treated as transient — the keychain can unlock between
    /// attempts.
    private static func isPermanentStartFailure(_ error: Error) -> Bool {
        switch error {
        case OrchestratorError.noProfile,
            OrchestratorError.invalidProfile,
            OrchestratorError.naiveBinaryUnusable:
            return true
        default:
            break
        }
        // Wire-protocol error codes the engine emits for malformed /
        // unknown requests are bugs in the Swift caller, not transient
        // — retrying produces the same frame and the same rejection.
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
            // **Auto-sync hook (post-v2.0.48):** if the engine
            // reports an HTTP-407-class auth failure in stderr,
            // the active profile carries a `subscriptionURL`, and
            // no sync is already in flight, fetch fresh
            // credentials from the panel and restart the engine.
            // The check is cheap (substring scan on each stderr
            // line) and gated by `selectedProfile?.subscriptionURL`
            // inside `scheduleCredentialAutoSync`, so profiles
            // without a subscription URL never pay any cost
            // beyond the substring test.
            if source == .stderr,
                Self.isProxyAuthFailureLine(line)
            {
                scheduleCredentialAutoSync(reason: "engine reported HTTP 407 / proxy auth failure")
            }
        case .stateChanged(let running):
            // **UX-F#5 (v2.0.13):** during a hot-swap
            // (`switchMode`) the engine emits stateChanged(false)
            // for the .stopProxy and stateChanged(true) for the
            // subsequent .startProxy. Surfacing those to
            // `isRunning` / `activeMode` produces the
            // Stop→Start→Stop button blink and a brief de-
            // highlight of the mode picker — exactly the
            // "single observable transition" semantics the
            // hot-swap was supposed to give us. switchMode owns
            // the public state during its window and writes the
            // final mode as a single transition at the end of
            // startCore; we defer to it here.
            //
            // Outside `transitionInFlight`, the event handler
            // remains the source of truth for natural-death
            // recovery (naive segfaults, OOMs, etc.) — that's
            // the path the recovery banner below was added for.
            if transitionInFlight {
                return
            }
            // **UX-F#5 (v0.1.7.19):** when naive dies on its
            // own (`running:false` arriving outside a
            // user-initiated stop), revert system proxy
            // immediately. Without this, macOS keeps routing
            // browser requests at `127.0.0.1:1080` where
            // nothing is listening — the user sees a misleading
            // "Idle" header but every page in their browser
            // stalls. The status flip is visible in the
            // HeaderView; the proxy revert makes the visible
            // state actually match the network state.
            let wasRunning = isRunning
            let modeBeforeStop = activeMode
            isRunning = running
            recordTelemetry(
                running ? "engine.state.running" : "engine.state.stopped",
                details: ["mode_before_event": modeBeforeStop.rawValue]
            )
            if !running {
                activeMode = .stopped
                developerMetrics = .idle
                developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
                    pid: nil,
                    naiveRunning: false,
                    firewallState: firewallState,
                    status: "Stopped"
                )
                lastTrafficSnapshot = nil
                vpsHealthTask?.cancel()
                vpsHealthTask = nil
                // **Engine-F#P1.2 (v0.2):** the recovery branch
                // is gated on `!userStopInFlight` so an
                // intentional Stop's own `stateChanged(false)`
                // doesn't trigger a phantom "naive stopped
                // unexpectedly" banner. The flag is set by
                // `stop()` / `stopQuiet()` for the duration of
                // the call — see its declaration for the
                // race window it covers.
                if wasRunning && !isShuttingDown && !userStopInFlight {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await self.proxyController.disableAll()  // try-ok: best-effort proxy revert
                        ProxyActiveFlag.clear(
                            at: ProxyActiveFlag.path(in: self.paths.supportDirectory))
                        self.scheduleSelfHeal(
                            mode: modeBeforeStop,
                            reason: "naive stopped unexpectedly")
                    }
                }
            }
        case .anomaly(let reason, let detail):
            appendLog(source: .stderr, text: "[anomaly:\(reason.rawValue)] \(detail)")
            // `ListeningOutsideLoopback` means naive is exposed beyond
            // 127.0.0.1 — every byte from any LAN client could be
            // proxied. This is the one anomaly the original Swift
            // implementation auto-stopped on; we restore that behaviour
            // here. The other anomalies (count thresholds) stay advisory.
            if reason == .listeningOutsideLoopback {
                // **v2.0.29:** anomaly auto-stop is local-kernel-by-construction
                // (e.g. naive bound outside loopback, too many established
                // connections). Hardcoded `.localKernel`.
                recordError("Critical: \(detail). Auto-stopping.", layer: .localKernel)
                // Single-flight the auto-stop. Multiple anomalies
                // arriving in quick succession would otherwise
                // queue multiple `stop()` Tasks, each racing on
                // `activeMode` / `isRunning` and each potentially
                // logging a "stop failed: not_running" tail.
                if autoStopTask == nil {
                    autoStopTask = Task { [weak self] in
                        await self?.stop()
                        self?.autoStopTask = nil
                    }
                }
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
        case .trafficSnapshot(let pid, let established, let localClients, let remote):
            updateDeveloperTraffic(
                pid: pid,
                established: established,
                localClients: localClients,
                remote: remote
            )
        }
    }

    // MARK: - Helpers

    private func appendLog(source: LogSource, text: String) {
        enqueueLog(LogEntry(source: source, text: boundedLogText(text)))
    }

    private func appendInfo(_ message: String) {
        enqueueLog(LogEntry(source: .stdout, text: "[orchestrator] \(boundedLogText(message))"))
    }

    /// Synchronous error record — stores the message + optional
    /// `ErrorLayer` and writes the formatted line to `logEntries`.
    /// Pre-2.0.29 took only the message; the new `layer:` parameter
    /// defaults to `nil` so every existing call site keeps the prior
    /// plain-text behaviour. Connection-failure paths use
    /// [`recordClassifiedError`] which runs the layer probe before
    /// calling this; layer-by-construction paths (engine spawn
    /// failure, naive binary unusable, anomaly auto-stop) hardcode
    /// `.localKernel` because the classifier would just confirm what the
    /// caller already knows.
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

    /// **v2.0.29 (Deterministic Error Reporting):** runs the
    /// connection-failure classifier (3 second budget), then
    /// records the error with the resulting layer. Classifier
    /// returns `nil` only on inconclusive probes — in which case
    /// the banner falls back to the pre-2.0.29 plain-text
    /// rendering, no chip. Used by the connection-bring-up paths
    /// in `startCore` and the wake-recovery branch of
    /// `handleSystemDidWake`.
    private func recordClassifiedError(_ message: String) async {
        let layer = await classifyConnectionFailure()
        recordError(message, layer: layer)
    }

    /// **v2.0.29 (Deterministic Error Reporting):** layer
    /// classifier. Two parallel probes:
    ///
    /// 1. **Apple NCSI endpoint** — Apple's own captive-portal
    ///    detection URL. Unlikely to be blocked by ISPs and
    ///    returns a deterministic body. If the probe fails,
    ///    general internet is broken → ISP layer.
    /// 2. **Direct TCP probe to the user's VPS hostname** —
    ///    bypasses the system proxy so the probe sees raw
    ///    network state, not the in-flight broken proxy path.
    ///    If Apple succeeds but VPS fails, the VPS is broken.
    ///
    /// Both probes have a 3 s budget. The decision matrix:
    ///
    /// |           | Apple ✓     | Apple ✗      |
    /// |-----------|-------------|--------------|
    /// | **VPS ✓** | `.localKernel`    | `.isp`* |
    /// | **VPS ✗** | `.vps`      | `.isp`  |
    ///
    /// `*` Apple unreachable but VPS reachable is unusual — typically
    /// indicates ISP-level NCSI blocking, DNS hijack, or a captive
    /// portal that lets the user's VPS through (some hotel networks).
    /// Most actionable verdict for the user is `.isp`: their
    /// path to the broader internet is constrained even if the
    /// specific path to their VPS happens to work.
    private func classifyConnectionFailure() async -> ErrorLayer? {
        // Capture the VPS host string on `@MainActor` BEFORE the
        // `async let` branches. `selectedProfile` is MainActor-
        // isolated; reading it from inside a Sendable async closure
        // is a Swift 6 strict-concurrency error. Pinning to a `let`
        // here also keeps the host stable across the parallel probes
        // — a profile-switch mid-classification can't cause one
        // probe to test against a different server than the other.
        let vpsHost: String? = {
            guard let profile = self.selectedProfile else { return nil }
            // `profile.server` is "host" or "host:port" — strip the
            // port for the TCP probe; we always test :443 since
            // that's where NaiveProxy listens.
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

    /// **v2.0.29 (Deterministic Error Reporting):** raw TCP
    /// reachability probe. Bypasses the system proxy by going
    /// through `Network.NWConnection` directly — `URLSession`
    /// would honour the system proxy that the orchestrator's own
    /// `proxyController.enableSmartPAC` may have just installed,
    /// and we'd loop the probe through the broken `naive` path
    /// instead of testing raw connectivity.
    ///
    /// `port` defaults to 443 (NaiveProxy's standard listen port,
    /// and Apple's NCSI endpoint is HTTPS too). 3 s timeout. The
    /// continuation-resume guard uses an `NSLock` because the
    /// `NWConnection.stateUpdateHandler` can fire multiple times
    /// (e.g. `.preparing` → `.ready` → `.cancelled`) and the
    /// timeout task races against real state transitions; without
    /// the guard a `CheckedContinuation` would crash on a double
    /// resume.
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
            // `@Sendable` is required because `resumeOnce` is
            // captured into both `stateUpdateHandler` (a Sendable
            // closure on `NWConnection`) and the dispatch-queue
            // timeout block; Swift 6 strict concurrency rejects
            // capture of a non-Sendable local function in a
            // Sendable closure. The body only touches Sendable
            // state (`NSLock`, the `@unchecked Sendable` flag
            // box, and the `CheckedContinuation` which is itself
            // Sendable), so the annotation is sound.
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

    private func updateDeveloperTraffic(
        pid: UInt32,
        established: UInt32,
        localClients: UInt32,
        remote: UInt32
    ) {
        let now = Date()
        let snapshot = TrafficSnapshotState(
            sampledAt: now,
            pid: pid,
            established: established,
            localClients: localClients,
            remote: remote
        )
        let prior = lastTrafficSnapshot
        lastTrafficSnapshot = snapshot

        let elapsed = prior.map { max(0.001, now.timeIntervalSince($0.sampledAt)) } ?? 0
        let inboundDelta =
            prior.map {
                Int(localClients.saturatingDifference(from: $0.localClients))
            } ?? 0
        let outboundDelta =
            prior.map {
                Int(remote.saturatingDifference(from: $0.remote))
            } ?? 0
        let inboundBps =
            elapsed > 0 ? Int((Double(inboundDelta) * 64_000.0 / elapsed).rounded()) : 0
        let outboundBps =
            elapsed > 0 ? Int((Double(outboundDelta) * 96_000.0 / elapsed).rounded()) : 0

        developerMetrics.sampledAt = now
        developerMetrics.throughput = DeveloperMetrics.Throughput(
            inboundBytesPerSecond: inboundBps,
            outboundBytesPerSecond: outboundBps,
            status: established == 0 ? "No active flows" : "\(established) TCP flows"
        )
        developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
            pid: pid,
            naiveRunning: true,
            firewallState: firewallState,
            status: "PID \(pid) supervised"
        )
    }

    private func updateDeveloperKernelHealth(pid: UInt32?) {
        developerMetrics.sampledAt = Date()
        developerMetrics.localKernel = DeveloperMetrics.LocalKernelHealth(
            pid: pid,
            naiveRunning: isRunning,
            firewallState: firewallState,
            status: isRunning ? (pid.map { "PID \($0) starting" } ?? "Supervisor starting") : "Idle"
        )
    }

    private func startVPSHealthLoop() {
        vpsHealthTask?.cancel()
        guard isRunning else { return }
        guard var profile = selectedProfile else {
            developerMetrics.vps = .idle
            return
        }
        // **H3 (v2.0.38):** hydration can now throw on credential-store
        // failure. Distinguish that from "no password set": the
        // latter falls through with profile.password == "" and the
        // probe runs against the user's server with an empty
        // password (which the server will reject — that's the
        // diagnostic we want); the former skips the probe and
        // labels the metric so the operator sees the real cause
        // instead of an empty-password rejection that misroutes
        // them into the wrong fix.
        do {
            try hydratePasswordIfNeeded(&profile)
        } catch {
            developerMetrics.vps = DeveloperMetrics.VPSHealth(
                server: profile.server,
                reachable: nil,
                dnsMs: nil,
                tcpMs: nil,
                status: "Credential read failed: \(error.localizedDescription)",
                checkedAt: Date()
            )
            return
        }

        let server = profile.server
        developerMetrics.vps = DeveloperMetrics.VPSHealth(
            server: server,
            reachable: nil,
            dnsMs: nil,
            tcpMs: nil,
            status: "Checking",
            checkedAt: nil
        )

        vpsHealthTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.vpsHealthTask = nil }
            while !Task.isCancelled, self.isRunning {
                await self.refreshVPSHealth(profile: profile)
                try? await Task.sleep(nanoseconds: 15_000_000_000)  // try-ok: sleep cancellation
            }
        }
    }

    private func refreshVPSHealth(profile: Profile) async {
        do {
            let report = try await core.probe(profile: profile, timeoutSecs: 3)
            developerMetrics.vps = DeveloperMetrics.VPSHealth(
                server: report.server,
                reachable: report.reachable,
                dnsMs: report.dnsResolveMs,
                tcpMs: report.tcpConnectMs,
                status: report.reachable ? "Reachable" : (report.error ?? "Unreachable"),
                checkedAt: Date()
            )
        } catch {
            developerMetrics.vps = DeveloperMetrics.VPSHealth(
                server: profile.server,
                reachable: false,
                dnsMs: nil,
                tcpMs: nil,
                status: error.localizedDescription,
                checkedAt: Date()
            )
        }
    }

    /// Fills in the profile's password from the credential store
    /// when the in-memory copy is empty. Instance-method form;
    /// delegates to the static `hydratePassword(_:from:)` so the
    /// H3 plumbing is unit-testable without standing up a full
    /// `TunnelOrchestrator`.
    private func hydratePasswordIfNeeded(_ profile: inout Profile) throws {
        try Self.hydratePassword(&profile, from: profileStore)
    }

    /// Static helper that does the actual H3 hydration. Pure: takes
    /// the profile (inout) and a `ProfileStore`, throws
    /// `OrchestratorError.credentialReadFailed(reason:)` on credential
    /// backend failure. Item-not-found returns `""` per the
    /// `CredentialStore` contract and falls through to the original
    /// no-password UX — the orchestrator's validation gate handles
    /// the empty-string case.
    ///
    /// **H3 (v2.0.38):** the throw lets callers distinguish "keychain
    /// locked" from "no password was ever set." The previous
    /// implementation collapsed both into the empty-string path, which
    /// then surfaced a misleading "please enter a password" banner.
    ///
    /// Visibility: marked `internal` (no access modifier) and `static`
    /// so the unit-test target can pin the H3 contract directly via
    /// `@testable import Cool_Tunnel` without constructing a real
    /// orchestrator (which would need `CoreClient`, `SystemProxyController`,
    /// `FirewallProbe`, etc.). `nonisolated` because the helper is
    /// pure (no instance state, no MainActor-bound dependencies);
    /// the implicit `@MainActor` from the enclosing class would
    /// otherwise force every caller — production and test — onto
    /// the main actor for no benefit.
    nonisolated static func hydratePassword(
        _ profile: inout Profile, from store: ProfileStore
    )
        throws
    {
        guard profile.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let stored: String
        do {
            stored = try store.password(forProfileID: profile.id)
        } catch {
            throw OrchestratorError.credentialReadFailed(reason: error.localizedDescription)
        }
        if !stored.isEmpty {
            profile.password = stored
        }
    }

    private func updateEncryptionOverhead(from report: LatencyReport) {
        guard report.samples.count >= 2 else {
            developerMetrics.encryption = .idle
            return
        }
        let direct = report.samples[0]
        let proxied = report.samples[1]
        guard direct.ok || proxied.ok else {
            developerMetrics.encryption = DeveloperMetrics.EncryptionOverhead(
                directHandshakeMs: direct.tlsMs,
                proxiedHandshakeMs: proxied.tlsMs,
                overheadMs: nil,
                status: "Handshake probe failed",
                sampledAt: Date()
            )
            return
        }
        let overhead = max(0, proxied.tlsMs - direct.tlsMs)
        developerMetrics.encryption = DeveloperMetrics.EncryptionOverhead(
            directHandshakeMs: direct.tlsMs,
            proxiedHandshakeMs: proxied.tlsMs,
            overheadMs: overhead,
            status: "\(Self.formatMs(overhead)) TLS delta",
            sampledAt: Date()
        )
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
        // Also clear `lastError` — a user clicking "Clear logs"
        // expects the error pill to disappear too. The previous
        // behaviour left a stale error visible after the log
        // showed empty, leading users to think the clear didn't
        // work or that the error reappeared.
        lastError = nil
        lastErrorLayer = nil
    }

    /// **UX-F#1 (v0.1.7.17):** dismiss the error banner from
    /// `HeaderView`. Encapsulated so the public setter on
    /// `lastError` stays `private(set)`.
    public func dismissLastError() {
        lastError = nil
        lastErrorLayer = nil
    }

    // MARK: - Declarative UI schema

    /// Pure projection from mutable orchestrator fields to the
    /// structured state SwiftUI renders.
    ///
    /// **Heng / Silent Operator invariant:** this is the public map
    /// of what the UI is allowed to know. Keep operational recovery
    /// policy in the orchestrator, and keep views as pure functions
    /// of this value plus local UI draft state. Future AI-led edits
    /// should extend this schema before reaching directly into
    /// lifecycle internals from a leaf view.
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
            developer: CoolTunnelViewState.Developer(metrics: developerMetrics),
            settings: settings,
            resources: CoolTunnelViewState.Resources(
                activeNaiveDescriptor: activeNaiveDescriptor
            )
        )
    }

    /// Applies an explicit UI intent. This is the only imperative
    /// bridge the SwiftUI composition root needs for tunnel controls.
    ///
    /// Leaf views should emit `TunnelIntent` instead of invoking
    /// `start`, `stop`, diagnostics, or log mutation directly. That
    /// preserves the Silent Operator design: screens describe operator
    /// intent, while this layer decides the quietest safe operational
    /// action.
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
        profile.serverValidation == .valid
            && !profile.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && profile.localPortValue != nil
    }

    /// Final UI-intent gate before any control surface reaches the
    /// engine. The form performs live validation, but this guard keeps
    /// the menu bar, keyboard shortcuts, and future surfaces under the
    /// same "First Scold, Then Do Good" contract.
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
        if profile.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // **H3 (v2.0.38):** distinguish credential-store failure
            // from "no password set" so the rejection banner tells
            // the user the right thing to fix. The previous
            // implementation collapsed both into the empty-string
            // path and emitted "Start rejected: enter a password"
            // even when the keychain was locked.
            do {
                profile.password = try profileStore.password(forProfileID: profile.id)
            } catch {
                recordError(
                    "Start rejected: couldn't read stored password (\(error.localizedDescription)). Unlock the Keychain and try again.",
                    layer: .localKernel
                )
                return false
            }
        }
        guard !profile.password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            recordError("Start rejected: enter a password for the selected profile.", layer: .localKernel)
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

/// Errors raised by the orchestrator (separate from engine and OS errors,
/// which surface as their own types).
///
/// **v2.0.29 (Deterministic Error Reporting):** taxonomy that
/// pinpoints which node in the connection chain is broken when a
/// connection-failure path fires. Eliminates the "self-doubt"
/// failure mode where the user has to run manual diagnostics to
/// figure out whether the issue is the ISP path, the VPS, or the
/// local macOS kernel/app stack. Classifier
/// ([`TunnelOrchestrator.classifyConnectionFailure`])
/// runs two parallel probes (Apple's NCSI endpoint for general
/// upstream reachability + a direct TCP probe to the user's VPS
/// hostname bypassing the proxy) with a 3 second budget; both
/// probes go around the system proxy so the classifier sees the
/// raw network state, not the in-flight broken proxy path.
public enum ErrorLayer: String, Sendable, Codable, Equatable {
    /// The issue is on the user's Mac — `naive` isn't running, the
    /// loopback bind failed, the OS firewall is blocking outbound
    /// traffic, or the app's saved credentials are wrong.
    case localKernel
    /// The issue is between the Mac and the public internet —
    /// the ISP, Wi-Fi association, captive portal, or DNS. The
    /// classifier reaches this verdict when even Apple's NCSI
    /// endpoint is unreachable.
    case isp
    /// The issue is the user's NaiveProxy server — DNS for the
    /// configured hostname doesn't resolve, the host is up but
    /// `:443` refuses connections, or the upstream daemon is
    /// rejecting the handshake. The classifier reaches this
    /// verdict when general internet works but the user's VPS
    /// hostname specifically does not.
    case vps

    /// Short label rendered in the `HeaderView` error chip. Held to
    /// one word + an opening / closing bracket so the chip stays
    /// inside the banner's vertical metric.
    public var diagnosticLabel: String {
        switch self {
        case .localKernel: "Local Kernel"
        case .isp: "ISP"
        case .vps: "VPS"
        }
    }

    /// Plain-language sentence the operator can read out loud to a
    /// support partner. Used by `Disclaimer.md` § "Reporting issues"
    /// + the `Diag` button's transcript export. Deliberately not
    /// rendered in the banner itself — the banner shows the chip +
    /// the original `lastError` so the message stays scannable.
    public var humanExplanation: String {
        switch self {
        case .localKernel:
            return
                "the issue is in the Local Kernel layer — `naive` may not be running, "
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

/// **v2.0.28 (Seamless Recovery Protocol):** finite state machine
/// for the orchestrator's system-sleep / wake transition. Owned by
/// `TunnelOrchestrator.sleepWakeState` and read by `HeaderStatusPill`
/// to render the transient phase labels.
///
/// Lifecycle:
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
///                                              │ (await switchMode(to: modeBeforeSleep))
///                                              ▼
///                                            .idle
/// ```
///
/// `.idle` is the steady-state outside sleep transitions; the pill
/// falls back to the base `isRunning` / `lastError` rendering.
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

private struct TrafficSnapshotState: Sendable, Equatable {
    let sampledAt: Date
    let pid: UInt32
    let established: UInt32
    let localClients: UInt32
    let remote: UInt32
}

extension UInt32 {
    fileprivate func saturatingDifference(from prior: UInt32) -> UInt32 {
        self >= prior ? self - prior : 0
    }
}

/// **Conforms to `LocalizedError`, not just `Error`.** Without
/// `LocalizedError`, the `(error as? LocalizedError)?.errorDescription`
/// cast at the catch sites in `startCore` etc. silently misses
/// these cases and the user sees Swift's default
/// `"The operation couldn't be completed. (CoolTunnel.OrchestratorError error N.)"`
/// instead of the strings below. Per-type round-3 review fix.
public enum OrchestratorError: LocalizedError, Sendable, Equatable {
    case noProfile
    case invalidProfile(reason: String)
    case unexpectedResponse
    /// The configured `naive` binary cannot be used: the file is missing,
    /// not a Mach-O, lacks a slice for the host CPU, or has a broken
    /// code signature. The wrapped [`NaiveResolverError`] tells the user
    /// which one — and what to do about it.
    case naiveBinaryUnusable(NaiveResolverError)
    /// **H3 (v2.0.38):** the credential store could not be read.
    /// Distinct from "no password set" (which is not an error; the
    /// validation gate handles it). Typical causes: keychain
    /// locked, user dismissed the keychain access prompt, the file
    /// backend hit an IO error, or a corrupted entry failed to
    /// decode. The orchestrator's existing local-kernel layer maps
    /// these to actionable user copy ("Unlock the Keychain and try
    /// again") instead of the misleading "enter a password" banner
    /// the previous optional-coalesce produced.
    case credentialReadFailed(reason: String)

    public var errorDescription: String? {
        switch self {
        case .noProfile: "No profile is selected."
        case .invalidProfile(let reason): "Invalid profile: \(reason)"
        case .unexpectedResponse: "Engine returned an unexpected response."
        case .naiveBinaryUnusable(let err):
            "naive binary cannot be used: \(err.errorDescription ?? "unknown error")"
        case .credentialReadFailed(let reason):
            "Couldn't read stored password: \(reason). Unlock the Keychain and try again."
        }
    }
}

/// Errors raised during subscription URL import.
///
/// Keyed on the user-facing failure mode rather than transport
/// shape, so banner copy can be both accurate and actionable.
/// Roughly mapped to Laravel response codes — see
/// [`TunnelOrchestrator.importFromSubscriptionURL`] for the
/// status-code → variant table.
public enum SubscriptionImportError: LocalizedError, Sendable, Equatable {
    /// URL didn't parse, or wasn't `https://…`.
    case invalidURL
    /// Transport failure — host unreachable, TLS rejection, etc.
    case networkError(String)
    /// HTTP 401 — token resolved to an inactive account
    /// (disabled, expired, quota exceeded). The user has to ask
    /// the operator to re-enable the account or generate a new
    /// password.
    case subscriptionRevoked
    /// HTTP 404 / 422, or a 200-with-HTML cover-site response.
    /// The token is malformed or doesn't match any account on
    /// this panel.
    case tokenInvalid
    /// HTTP 429 — too many fetches from this IP. The panel
    /// rate-limits at 60/min; the user should wait a minute.
    case rateLimited
    /// HTTP 5xx — panel is down, APP_KEY is unset, or some
    /// other server-side problem.
    case serverError(status: Int)
    /// Anything else outside 2xx / the explicit cases above.
    case unexpectedStatus(Int)
    /// JSON decoded but had no usable profile.
    case noProfiles
    /// Manifest's `version` field is something other than `1`.
    /// Either a counterfeit panel or a v2 server emitting v2-only
    /// manifests; the v1-only client refuses to interpret either.
    case unsupportedVersion(got: UInt32)
    /// Manifest's `expires_at` is in the past — the panel told
    /// the client to re-fetch and the client got a stale URL.
    case manifestExpired
    /// Manifest's `issued_at` is more than 7 days old. Almost
    /// always a caching proxy on the user's network; trying again
    /// over a different network usually resolves it.
    case manifestStale(daysOld: Int)
    /// Manifest passed JSON decode but failed structural sanity
    /// (`issued_at == 0`, `issued_at` far in the future, or
    /// `expires_at < issued_at`). A real panel never emits any
    /// of these — the manifest is from a stub server, a
    /// transcription error, or a counterfeit panel trying to
    /// produce an indefinitely-valid manifest.
    case manifestCounterfeit
    /// Response body exceeded the [`SubscriptionClient.maxBytes`]
    /// cap (1 MB). A real manifest is ~1 KB; this fires only on
    /// a hijacked panel or MITM streaming oversized content.
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

// **v2.0.21 (Phase A):** removed the per-orchestrator
// `SubscriptionManifest` private struct. Only `host`, `username`,
// `password` were decoded — the manifest's `port`, `version`,
// `expires_at`, `issued_at`, and `capabilities` fields were
// silently dropped. Replaced by `SubscriptionManifestV1` in
// `Core/Subscription.swift` (the full ct-protocol mirror) and
// `SubscriptionClient` in `Core/SubscriptionClient.swift` (fetch +
// validate). The orchestrator's `importFromSubscriptionURL` now
// calls into those types and translates their structured errors
// into `SubscriptionImportError` for the UI.
