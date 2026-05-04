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
    private let paths: AppSupportPaths
    private let naiveResolver: NaiveBinaryResolver

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
        naiveResolver: NaiveBinaryResolver = NaiveBinaryResolver()
    ) {
        self.core = core
        self.proxyController = proxyController
        self.firewall = firewall
        self.profileStore = profileStore
        self.settingsStore = settingsStore
        self.paths = paths
        self.naiveResolver = naiveResolver
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
            bootstrapError = "Application Support unavailable: \(error.localizedDescription) — engine will refuse to start. Free disk space and relaunch."
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
                self.recordError("naive binary unusable: \(error.localizedDescription)")
                self.activeNaiveDescriptor = nil
            } catch {
                self.recordError("naive binary inspection failed: \(error.localizedDescription)")
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
        isShuttingDown = true
        // Flush any pending debounced settings write before we go
        // away — without this, a settings edit made <250ms before
        // Cmd+Q would be silently dropped.
        flushSettings()
        eventTask?.cancel()
        eventTask = nil
        try? await proxyController.disableAll()
        // **Lifecycle-F#16 (v0.1.7.18):** clear sentinel after
        // clean disable so next launch's recovery scan doesn't
        // fire spuriously.
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        await core.stop()
        activeMode = .stopped
        isRunning = false
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

    /// **UX-F#3 (v0.1.7.19):** captured at start time so
    /// `selectedProfile.set` can detect "user edited the
    /// active profile while connected" and surface a banner.
    /// Without this, a profile-field edit silently keeps the
    /// running engine using the old config, but the form
    /// shows the new value — confusing.
    private var activeProfileID: String?

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
                }
            }
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
            try? await Task.sleep(nanoseconds: 250_000_000)
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
            await stopQuiet()
            try await startQuiet(mode: newMode)
            appendInfo("switched from \(from.title) to \(newMode.title)")
            return
        }
        try await start(mode: newMode)
    }

    /// Internal stop path used by `switchMode` — same teardown work as
    /// `stop()`, no `appendInfo("stopped")`. Stays private; callers
    /// outside the orchestrator should use `stop()` so the log is
    /// always informative for explicit stops.
    private func stopQuiet() async {
        try? await proxyController.disableAll()
        // **Lifecycle-F#16 (v0.1.7.18):** clear sentinel on
        // clean stop. Same reasoning as `shutdown()`.
        ProxyActiveFlag.clear(
            at: ProxyActiveFlag.path(in: paths.supportDirectory))
        do {
            _ = try await core.send(.stopProxy)
        } catch {
            recordError("stop failed: \(error)")
        }
        activeMode = .stopped
        isRunning = false
    }

    /// Internal start path mirror of `start(mode:)` that omits the
    /// trailing "started in X" log line so `switchMode` can replace
    /// the pair of stop/start lines with a single "switched from X
    /// to Y".
    private func startQuiet(mode: ProxyMode) async throws {
        try await startCore(mode: mode, log: false)
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
    private func startCore(mode: ProxyMode, log: Bool) async throws {
        guard mode != .stopped else { return }
        guard var profile = selectedProfile else {
            throw OrchestratorError.noProfile
        }
        // Clear stale error from any previous failed attempt — a successful
        // start should not leave the user staring at last week's failure.
        lastError = nil

        // Hydrate the password from the credential store on demand.
        // `loadProfiles()` deliberately leaves passwords empty so app
        // launch never triggers a credential-store access; we pull
        // here, after the user has already committed to starting,
        // which is the contextually-sensible place for any prompt the
        // migrating store may surface for upgraders.
        if profile.password.isEmpty {
            let stored = profileStore.password(forProfileID: profile.id)
            if !stored.isEmpty {
                profile.password = stored
            }
        }

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
                port: port
            ))
        guard case .started = started else {
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
        // **UX-F#3 (v0.1.7.19):** capture which profile the
        // engine started with. The selectedProfile setter
        // compares against this to detect edits to the
        // currently-active profile.
        activeProfileID = selectedProfileID
        if log {
            appendInfo("started in \(mode.title)")
        }
    }

    public func stop() async {
        // Guard against re-entry when we're already stopped. A
        // user spam-clicking the Stop button would otherwise loop
        // back through `disableAll()` (which iterates every active
        // network service and runs `networksetup` twice each) and
        // then call `core.send(.stopProxy)` against an engine
        // that no longer has a proxy to stop — surfacing as a
        // misleading "stop failed: not_running" log line. Single
        // exit point keeps the user-facing behaviour clean.
        guard isRunning || activeMode != .stopped else { return }
        try? await proxyController.disableAll()
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
        appendInfo("stopped")
    }

    /// **Lifecycle-F#16 (v0.1.7.18):** crash-recovery sweep.
    /// Called by AppDelegate before any other startup work. If
    /// the proxy-active sentinel exists, the previous run died
    /// without disabling — force-disable the system proxy now
    /// so the user gets a working network on launch.
    public func recoverFromCrashIfNeeded() async {
        let flagURL = ProxyActiveFlag.path(in: paths.supportDirectory)
        guard ProxyActiveFlag.existsIndicatingCrash(at: flagURL) else {
            return
        }
        let payload = ProxyActiveFlag.readPayload(at: flagURL)
        appendInfo(
            "previous run crashed with system proxy enabled" +
            (payload.map { " (mode=\($0.mode))" } ?? "") +
            " — reverting"
        )
        try? await proxyController.disableAll()
        ProxyActiveFlag.clear(at: flagURL)
    }

    /// **UX-F#4 (v0.1.7.18):** called by AppDelegate when the
    /// system wakes from sleep. If the proxy is still nominally
    /// running, send a probe through it; if the probe fails the
    /// connection became zombie during sleep (TCP keepalives
    /// dropped, naive's upstream was reset). Surface a
    /// `lastError` so the user sees the dead-proxy state in the
    /// HeaderView banner instead of trusting the still-pink
    /// status pill.
    public func handleSystemDidWake() async {
        guard isRunning, activeMode != .stopped, activeMode != .localOnly else {
            return
        }
        appendInfo("system woke from sleep — probing engine health")
        do {
            // Light-touch probe: send a `Ping`-equivalent — the
            // existing diagnostics is heavier than we need here.
            // Use the same validate-profile path the start flow
            // uses; if the engine pipe is dead, this throws.
            guard let profile = selectedProfile else { return }
            _ = try await core.send(.validateProfile(profile))
        } catch {
            recordError("connection became unresponsive while system slept — click Stop, then restart your mode")
        }
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
                // **UX-F#16 (v0.1.7.19):** the engine
                // (`cool-tunnel-core`) subprocess died — pipe
                // broke or process crashed. The previous
                // "click Start again" message was misleading;
                // a Start click hits `core.send(...)` which
                // throws `.notRunning`. Now: revert the
                // system proxy first (UX-F#5 reasoning), flip
                // `didBootstrap` back to false so the next
                // mode click re-runs the bootstrap path
                // (which calls `core.start()`), and surface
                // an actionable error.
                try? await self.proxyController.disableAll()
                ProxyActiveFlag.clear(
                    at: ProxyActiveFlag.path(in: self.paths.supportDirectory))
                self.isRunning = false
                self.activeMode = .stopped
                self.didBootstrap = false
                self.recordError(
                    "Engine subprocess exited unexpectedly — system proxy reverted. Click a mode chip to relaunch the engine and try again."
                )
            }
        }
    }

    private func handle(event: CoreEvent) {
        switch event {
        case .logLine(let source, let line):
            appendLog(source: source, text: line)
        case .stateChanged(let running):
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
            isRunning = running
            if !running {
                activeMode = .stopped
                if wasRunning && !isShuttingDown {
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await self.proxyController.disableAll()
                        ProxyActiveFlag.clear(
                            at: ProxyActiveFlag.path(in: self.paths.supportDirectory))
                        self.recordError(
                            "naive stopped unexpectedly — system proxy reverted. Check the log for why, then click a mode to retry."
                        )
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
                recordError("Critical: \(detail). Auto-stopping.")
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
        // Also clear `lastError` — a user clicking "Clear logs"
        // expects the error pill to disappear too. The previous
        // behaviour left a stale error visible after the log
        // showed empty, leading users to think the clear didn't
        // work or that the error reappeared.
        lastError = nil
    }

    /// **UX-F#1 (v0.1.7.17):** dismiss the error banner from
    /// `HeaderView`. Encapsulated so the public setter on
    /// `lastError` stays `private(set)`.
    public func dismissLastError() {
        lastError = nil
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
