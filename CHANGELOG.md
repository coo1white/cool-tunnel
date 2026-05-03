# Changelog

All notable changes to Cool Tunnel land here. Versions follow
roughly-semver: bumps in the third digit are features; bumps in
the fourth digit are pre-release polish on the same line.

The pre-release `v0.1.5.x` series soaked from May 2 to May 3, 2026.
**v0.1.6** is the first stable release; **v0.1.7** is the first
release on the Long-Term Servicing Channel line — see
[SUPPORT.md](./SUPPORT.md) for the support contract.

## [0.1.7.3] — 2026-05-03 (LTSC patch)

LTSC in-line patch — robustness audit pass. Two parallel audits
(Swift + Rust) returned 103 findings; this patch closes the
high-confidence correctness/security fixes plus quick-win
hygiene. The bigger items (release-SHA-manifest infra to close
the updater codesign gap, channel-split for control-plane vs
log-line traffic, EngineSession enum-state) are deferred to
v0.2.0 because they touch shared infrastructure or change the
release-publishing process.

**Correctness — Swift:**

- AppDelegate `applicationShouldTerminate` now races shutdown
  against a 5-second watchdog; whichever finishes first calls
  `reply(toApplicationShouldTerminate:)`. Without the watchdog
  any future shutdown-step hang (signal-blocked syscall, wedged
  `networksetup`) parked the app in "terminating…" forever with
  the engine + system proxy still alive.
- `CoreClient.send` enforces a 120-second per-request deadline.
  Every continuation in `pending` has a sibling timeout Task
  that resumes it with `requestTimeout` if the engine fails to
  reply. Previously a hung engine froze the UI indefinitely
  with no recovery short of Force Quit.
- `bootstrapIfNeeded` retains its didBootstrap-on-success
  semantic from v0.1.7.2 (no regression).
- `TunnelOrchestrator.stop()` early-returns when already stopped
  — spam-clicking Stop no longer iterates `networksetup` twice
  per active service or surfaces "stop failed: not_running" to
  the UI.
- `clearLogs()` now also clears `lastError`. The error pill
  no longer survives a "Clear logs" tap.
- `listeningOutsideLoopback` auto-stop is single-flighted —
  burst-of-anomalies no longer queues duplicate `stop()` Tasks
  racing on `activeMode`.
- `ProfileStore.loadProfiles` deduplicates by id, drops
  empty-id entries, trims whitespace from server/username/port
  fields. A corrupted UserDefaults blob (TimeMachine restore
  race, manual `defaults import` mistake) no longer produces
  duplicate profiles where `removeSelectedProfile` deletes
  every match in one keystroke.
- New `Subprocess.run` helper drains stdout/stderr concurrently
  while the child runs, with hard timeout escalation
  (terminate → interrupt → SIGKILL). Replaces three boot-path
  callers (FirewallProbe, NaiveBinaryResolver,
  RustCoreResolver) that each suffered from the classic
  pipe-fills-then-deadlocks bug if the subprocess wrote >64 KB
  to stderr.

**Security — Swift:**

- `RestrictedFile.write` no longer chmods *after* rename. The
  v0.1.5.5 promise of 0600 on `credentials.json` had a real
  race window: `Data.write(.atomic)` writes a temp file with
  default umask (0644) then renames; if the process crashed or
  hit ENOSPC between rename and chmod, the credential file
  persisted at 0644. New flow opens the temp file with
  `O_CREAT|O_EXCL|0600`, writes, fsyncs, renames atomically.
  No window where the file is on disk world-readable.
- `NaiveUpdater` validates the upstream tag against
  `^v?\d+(\.\d+){0,3}(-[A-Za-z0-9.]+)?$` before interpolating
  it into the GitHub asset URL. A future upstream tag
  containing `..`, spaces, `?`, `#`, or `/` would have
  produced a URL pointing outside the intended release
  directory.

**Correctness — Rust:**

- `ProxySupervisor::stop()` now passes `&mut handle` to
  `tokio::time::timeout` so on the 2-second drain expiry the
  handle can still be `abort()`ed and awaited. The previous
  implementation moved the handle into `timeout`, leaking the
  task indefinitely (still awaiting `child.wait()`); the inner
  `Child` was never dropped, so `kill_on_drop(true)` never
  fired, so a subsequent `start_proxy` could spawn a *second*
  `naive` against the still-alive previous PID.
- `monitor_loop` exits as soon as the supervised PID is gone
  (checked each tick via `/bin/kill -0`). Previously the loop
  kept probing the stale PID forever; on macOS PIDs roll over
  (max 99,998), so a long session could see another process
  take the same PID and the engine would emit anomalies
  derived from someone else's lsof output — a confused-deputy
  hazard for a security monitor.
- `monitor::run` (lsof probe) wrapped with a 4-second Tokio
  timeout. A wedged `lsof` can no longer freeze the monitor
  loop.
- `lsof` exit=1 with empty stderr is now treated as "no
  matching open files" (a perfectly normal state for a `naive`
  that hasn't accepted a connection yet) instead of
  `MonitorError::NonZeroExit`. Stops the spurious
  `tracing::warn!` line on every probe of an idle proxy.
- `run_probe` (curl) wrapped with `kill_on_drop(true)` and an
  outer Tokio timeout (`max_time + 5s`). Cancelled diagnostic
  Tasks no longer leak curl processes; a curl wedged in
  libc's getaddrinfo is reaped.
- `read_capped_line` enforces a hard cap on bytes discarded in
  oversized-frame resync mode (`16 × MAX_FRAME_BYTES`). A
  multi-GB blob with no newline can no longer burn CPU forever
  in the consume loop; protocol-level desync now fail-fast as
  `InvalidData`.
- `client_mode::run` now breaks out of the read loop when an
  error-frame send fails (writer is gone → engine is shutting
  down → stop reading). Previously the engine kept consuming
  inputs forever, masking real shutdown.
- `ProxySupervisor::read_lines` now logs the IO error before
  returning instead of swallowing with `Err(_)`. Mid-session
  log silence is the most likely cause of "where did my logs
  go?" — operators get a real signal to debug from.

**Hygiene — Rust:**

- `init_tracing` uses `try_init` instead of `init` so a future
  test that drives both client and server modes doesn't panic
  on the second call.
- Dead intra-doc reference to the deleted `ANOMALY_DEBOUNCE`
  constant cleaned up; `Debouncer::default()` is the canonical
  source of the 100 ms window.
- `MAX_INFLIGHT_REQUESTS` doc-vs-code mismatch fixed: doc
  previously claimed "drop on burst" but the code uses
  `acquire_owned().await` (queue). Doc rewritten to match
  reality; the actual drop behaviour is left as a
  defer-to-next-minor since it's a behaviour change.
- `axum::serve` body limit lowered from the 2 MiB default to
  64 KiB via `DefaultBodyLimit::max`. A profile is a few
  hundred bytes; tightening the ceiling shrinks the
  oversized-body attack surface.

**Deferred to v0.2.0:**

- Sw#C4: Updaters defeat the codesign gate (download → ad-hoc
  sign → next-launch verify passes the just-signed binary).
  Real fix needs a release-SHA-256 manifest the updaters can
  pin against; that's a release-process change beyond LTSC
  scope. **Until then, the existing CodeSignVerifier check
  catches arbitrary unsigned binaries but does not catch a
  MITM on the GitHub asset URL.**
- Sw#H2/H3: 3 of 6 subprocess callers migrated to
  `Subprocess.run`; the updater-side helpers retain bespoke
  flows. Migrate in v0.2.
- Sw#H11: bootstrap-failure visibility through subsequent
  user-initiated Start.
- Ru#C2: `start_proxy` cancellation-safety + anomaly-debouncer
  reset race.
- Ru#C4: EngineSession enum-state to make the three lifecycle
  fields (supervisor / monitor_handle / active_port) refactor-
  proof.
- Ru#H6: zombie-handler cleanup on writer death.
- Ru#H7: split control-plane vs log channels (anomalies and
  state-changes today share a 256-buffer mpsc with high-volume
  log lines).
- Ru#H8: tower-based concurrency limit + per-request timeout
  (would add `tower` dep).
- All wire-format / on-disk-format changes per
  [SUPPORT.md](./SUPPORT.md).

## [0.1.7.2] — 2026-05-03 (LTSC patch)

LTSC in-line patch — module-design audit pass. 113 audit
findings across Swift (58) and Rust (55); this patch closes the
high-confidence correctness fixes + quick wins. Bigger
architectural items (TunnelOrchestrator god-object split,
Resolver/Updater 80% deduplication, async CredentialStore,
moving client_mode/server_mode into the lib) are deferred to
the next minor bump because they touch shared infrastructure
or risk regression on the LTSC tag.

**Swift correctness:**

- `TunnelOrchestrator.bootstrap()` no longer `fatalError`s when
  Application Support cannot be created — falls back to a tmp
  path and surfaces the failure as `lastError`. App boots into a
  diagnosable state instead of crashing pre-UI.
- `bootstrapIfNeeded()` flag is now set on engine-start success
  rather than entry, so a future Retry button can recover from
  transient launch failures.
- `refreshNaiveDescriptor()` busy-wait
  (`while isRefreshing { await Task.yield() }`) replaced with a
  shared `Task` continuation. Late callers `await` instead of
  pinning a CPU under contention.
- `AppDelegate.applicationWillTerminate` `DispatchSemaphore`
  main-thread block (which deadlocked because MainActor IS the
  main thread) replaced with the correct
  `applicationShouldTerminate → .terminateLater →
  reply(toApplicationShouldTerminate:)` AppKit dance. The
  engine actually gets a clean stop on Cmd+Q now.
- `NaiveUpdater.assetURL` `fatalError` on URL-construction
  failure → typed `UpdaterError.message` (consistent with the
  sibling `resolveLatestStableTag` that already used the safer
  pattern).
- `ContentView` `#Preview` `bootstrap()` call wrapped in
  `#if DEBUG` so it doesn't ship a second engine subprocess
  alongside the one `CoolTunnelApp` already owns.

**Swift hygiene:**

- `persistSettings` now debounces (250 ms) so per-keystroke
  edits collapse into one UserDefaults write; `flushSettings`
  exposed for explicit commit points + called from `shutdown`
  so a late edit isn't silently dropped on Cmd+Q.
- Removed `TunnelOrchestrator.hostArchitecture` re-export —
  `HostArchitecture.current` is already a static cached value;
  the re-export was dead public surface.
- Removed dead `Keys.migrated` UserDefaults key + writes
  (set but never read).
- `KeychainStore: CredentialStore` conformance moved from
  `CredentialStore.swift` to `KeychainStore.swift` (Swift
  convention: conformance lives with the type).
- Free-function `writeRestrictedFile(_:to:)` namespaced as
  `RestrictedFile.write(_:to:)` to keep module global scope
  clean.
- `NaiveUpdater.download` doc-comment now honestly describes
  the indeterminate progress (the previous claim of "every ~64
  KB" was untrue; `URLSession.shared.download(from:)` doesn't
  surface byte-level progress).

**Rust correctness:**

- `client_mode::start_proxy` TOCTOU race fixed — engine mutex
  now held across the `ProxySupervisor::spawn` call. Previously
  two concurrent start requests could both pass the "already
  running?" check and both spawn `naive` (two real PIDs!) —
  the loser's events still leaked to Swift before being
  cancelled.
- `ProxySupervisor::stop()` now bounds the monitor-drain wait
  at 2 s. The previous unbounded `handle.await` could in theory
  block indefinitely; `kill_on_drop(true)` on the underlying
  `Child` still reaps the process.
- `ApiError` (`server_mode`) is now a `BadRequest` /
  `Internal` enum with `Debug` derived; previously every
  failure was forced through 500 with no `Debug` for
  `tracing::error!(?err)`.

**Rust hygiene:**

- `redaction.rs` regex statics switched from
  `OnceLock<Option<Regex>>` (which silently passthrough'd on
  compile failure → credentials would have leaked) to
  `LazyLock<Regex>` with `.expect(...)`. New
  `redaction_regexes_compile` test ensures `cargo test`
  catches any bad regex edit before it can ship.
- `lib.rs` re-exports `error::CoreError` at the crate root so
  consumers can write `cool_tunnel_core::CoreError`.
- `EngineState` is now `#[derive(Default)]` (manual impl was
  delegating to component defaults anyway).
- `ANOMALY_DEBOUNCE` constant deleted; `Debouncer::default()`
  is the single source of truth for the 100 ms window.
- `GLOBAL_TARGETS` and `SMART_TARGETS` consolidated to one
  underlying `LATENCY_TARGETS` constant (the two were
  byte-identical; future-divergence footgun).
- `LOOPBACK_HOST` moved to `config/mod.rs` so `naive_config`
  and `pac` reference one constant instead of literal
  `"127.0.0.1"` strings in a JS template.
- `MAX_FRAME_BYTES` is now `pub` so the integration test can
  reference it instead of duplicating the magic number.
- `MAX_INFLIGHT_REQUESTS` doc-commented with rationale (was
  bare `= 32` with no explanation).
- `EncodedCredentials` fields made private with accessors;
  `Debug` redacts the password; `Drop` clears the strings
  eagerly. Heap-byte zeroing requires the `zeroize` crate
  (project forbids `unsafe`); deferred to v0.2.
- `pac.rs::encode_js_string_array` `unwrap_or_else` fallback
  collapsed to `unwrap_or_default` with a comment explaining
  it's structurally unreachable (`serde_json::to_string` on
  `&[String]` is infallible).
- `client_mode::dispatch` wildcard arm rewritten with a typed
  payload that names the unmapped `RequestKind` variant.

**Build / lint:**

- `core/build.rs` doc comment promoted to module-level `//!`
  so `clippy::missing-docs` is happy.
- `EngineState::default()` derived; capture's `argv` parameter
  renamed to `command_line` to avoid `clippy::similar_names`.

The deferred items (Sw#10 god-object, Sw#8/9 resolver+updater
dedup, Sw#5/6 CoreClient broken-pipe + race-y shutdown, Ru#C1
stdin drain, Ru#H3/H4 client_mode/server_mode into lib, plus
all wire-format and on-disk-format changes) are tracked for
the next minor bump.

## [0.1.7.1] — 2026-05-03 (LTSC patch)

LTSC in-line patch — UI/UX audit pass. Public surface
unchanged. Engine binary version stays `0.1.7` (cargo doesn't
accept four-segment versions); the .app `MARKETING_VERSION` is
`0.1.7.1`. Naive bundled version unchanged.

A 45-finding multi-pass audit identified visible drift between
the v0.1.7 ship and the v0.1.5.7 platinum-theme intent. This
patch closes the user-visible items:

**Critical:**

- Inline Settings panel `.background` no longer combines a
  rounded rect with `.ignoresSafeArea` — switched to a flat
  `Rectangle()`, which fixes a visible square corner that
  appeared during the slide-in animation.
- `CoolTunnelApp` window resize: `.contentSize` paired with
  `maxWidth: .infinity` let users drag the window to absurd
  dimensions; switched to `.automatic`, and made
  `defaultSize` (820×820) match `idealHeight` so first launch
  doesn't snap.
- Connection-form labels are now `.lineLimit(1) +
  .frame(minWidth: 130) + .fixedSize` so localized labels
  ("Lokaler Anschluss") don't truncate without warning.
- Settings → Direct Domains list now scrolls inside a
  `.frame(maxHeight: 220)` so a hundred-domain smart-mode list
  doesn't push the Naive Binary / Rust Core sections off
  screen.
- Firewall badge background changed from `bunnyPink` (Maltese
  palette holdover) to `cherryRose.opacity(0.12)` so it reads
  as one alert colour.

**High:**

- Header card `cornerRadius` 10 → 8 (matches the rest of the
  design system).
- Settings naive-section inner-card radii unified at 6pt
  (matches the rust-section convention; was 8pt drift).
- Latency menu border swapped from `lilac` to `borderInk`,
  padding aligned with `SoftButtonStyle` (12/7), label gets
  the `.lineLimit(1) + .fixedSize` guard. Disabled "Local
  route" entry added with explanatory tooltip so users don't
  think the menu is incomplete.
- Profile picker frame widened to `minWidth 160 / maxWidth
  320` + `.help(displayName)` so long server names stay
  identifiable.
- About footer text: `Apache 2.0 · Maltese theme · macOS 12+`
  → `Apache 2.0 · Classic Mac theme · macOS 14+` (was
  shipping a stale macOS-floor claim and the pre-platinum
  theme name).
- Updater message + path summary rows get `.help(message)` +
  `.textSelection(.enabled)` so support tickets can quote the
  full string instead of the truncated one.
- Header subtitle gets `.lineLimit(1)`; title gradient second
  stop changed from hardcoded `bodyInk` to `.primary` so it
  remains legible in dark mode.
- Control-panel `Divider` swapped for an explicit borderInk
  hairline so opacity matches the rest of the design system.

**Medium:**

- `LogConsoleView` empty-state pulse and the auto-scroll
  animation are now both gated by `PerformanceProfile` so
  older Intel hardware doesn't burn GPU on continuous effects.
- `SettingsView` chip-detection icon and About pawprint use
  `CTPalette.macBlue` instead of system `.tint` (which was
  rendering as Apple aqua and clashing with the System 7
  palette).
- Direct-domain remove button gets a 22×22 hit target,
  `.help`, and `.accessibilityLabel` for VoiceOver.

The full audit report is in the v0.1.7.1 commit message; the
remaining 30+ MEDIUM/LOW findings (dark-mode dynamic palette
colours, full design-token system, naive/rust section
deduplication) defer to the next minor bump.

## [0.1.7] — 2026-05-03 (**LTSC**)

First release on the **Long-Term Servicing Channel**. The LTSC
posture is documented in [SUPPORT.md](./SUPPORT.md): public
surface (UI flows, CLI flags, engine protocol, on-disk paths) is
locked for the lifetime of the v0.1.7 line; only patch + minor
security fixes and upstream NaiveProxy updates land in-line.
Major changes wait for the next LTSC line.

LTSC infrastructure introduced in v0.1.7:

- `rust-toolchain.toml` pins the build to Rust 1.80.0 — bumps
  happen at LTSC boundaries, never silently across machines.
- `SUPPORT.md` documents the support window (≥ 18 months from
  release), supported macOS / Rust / hardware matrix, what counts
  as a breaking change, and the issue-reporting flow.
- `.github/workflows/ci.yml` runs cargo fmt + clippy + tests +
  swift-format + shellcheck on every push and PR.
- `.github/dependabot.yml` opens weekly dependency-update PRs and
  ignores major bumps inside an LTSC line.
- `core/deny.toml` configures cargo-deny with allow-list
  licences, advisory-as-error, and crates.io as the only trusted
  source.
- `cool-tunnel-core --version` now embeds the build SHA + date
  for support tickets — first line stays
  `cool-tunnel-core <semver>` so the Swift resolver still parses
  it.
- `scripts/security_check.sh` gains a section 9 LTSC-posture
  audit (lockfile present, Cargo.toml ↔ Cargo.lock version-field
  cross-check, toolchain pin, SUPPORT.md).

Plus the v0.1.6 hotfix round-3 fix that didn't ship in-line:

- `SoftButtonStyle` (Stop / Diag / Latency / Settings) now
  carries the same `.lineLimit(1) + .fixedSize(horizontal: true)`
  guard as `ModeChipStyle`. "Settings" no longer wraps to
  "Set- / tings" on narrower window widths.

## [0.1.6] — 2026-05-03 (stable)

First stable release. Hotfix re-released twice in-line on the
v0.1.6 tag with: log-console / connection-form border alignment
to the v0.1.5.7 platinum theme, mode-chip text wrap fix
(`.lineLimit(1) + .fixedSize`), direct mode switching with one
"switched from X to Y" log line, mode-aware card tints across
all four panes, and bundled NaiveProxy bumped to
v148.0.7778.96-2. Everything from the v0.1.5.x line, plus:

- Engine subprocess crash now surfaces a clear error in the live
  log instead of a silent stop.
- Friendlier error messages on the Naive and Rust Core update
  buttons (network failures explain themselves now).
- First-run hint banner on the Connection Form when the profile
  is still the bundled placeholder.
- VoiceOver accessibility labels on the mode chips, Stop, Diag,
  Latency, and Settings buttons.
- New `CHANGELOG.md`, `SECURITY.md`, and `CONTRIBUTING.md` at the
  repo root.
- README rewritten for beginners and non-native English readers —
  short sentences, jargon defined when first used, install steps
  numbered.

## [0.1.5.9] — 2026-05-03 (pre-release)

Swift API Design Guidelines + Rust API Guidelines polish pass.

- Removed two production force-unwrapped URLs in updaters.
- Replaced a `#if DEBUG print()` in `CoreClient` with `os.Logger`
  so malformed-frame diagnostics survive Release builds.
- Justified every `@unchecked Sendable` shim with an explicit
  safety invariant.
- Doc summaries on every public View type.
- Cargo.toml C-METADATA fields (`repository`, `homepage`,
  `documentation`, `keywords`, `categories`).

## [0.1.5.8] — 2026-05-03 (pre-release)

Window-management fix + cross-platform server mode.

- Multi-window-on-reopen bug fixed by switching `WindowGroup` to
  `Window(_:id:)` and moving engine shutdown out of
  `.onDisappear`.
- Cmd+W returns to the main view from Settings (binding
  shortcut), and to a hidden window from main (orderOut).
- `cool-tunnel-core` now supports `--mode server [--listen ADDR]`
  with HTTP endpoints `/health`, `/version`, `/naive/validate`,
  `/naive/config`, `/naive/pac`. Same Mach-O serves both client
  (default, JSON-over-stdio) and server tiers.
- `scripts/package_release.sh` now emits a fourth release asset:
  `cool-tunnel-core-vX.Y.Z-universal` for the in-app Update flow
  and standalone server-tier deployment.
- Deep audit fixes: engine-state mutex no longer held across
  `ProxySupervisor::spawn`; anomaly debouncer survives proxy
  restarts; every Test/Update/Choose/Reset button has a
  synchronous re-entry guard.

## [0.1.5.7] — 2026-05-03 (pre-release)

Classic-Mac visual refresh + macOS 14 floor + performance pass.

- Theme retuned to System 7 / Platinum era with Monaco for every
  monospaced surface.
- `MACOSX_DEPLOYMENT_TARGET` lowered from 26.4 to 14.0 — every
  Mac shipped 2018+ can now install.
- Rust release profile (LTO fat, panic=abort, strip=symbols)
  shrank `cool-tunnel-core` from ~6 MB to 2 MB single-arch.
- New `PerformanceProfile` auto-tunes animation density on older
  Intel hardware (skips repeating pulse + window-background fade
  + caps log buffer at 300 entries on the `.light` tier).

## [0.1.5.6] — 2026-05-03 (pre-release)

Rich machine detail + OK/NG verdict + Naive auto-update.

- Settings → "This Mac" panel now shows CPU brand string,
  P + E core counts, memory, and model identifier (via
  `HostMachine` / `sysctlbyname`).
- Naive Binary `Test` produces a single OK / NG verdict line
  above the per-row breakdown.
- New `Update` button next to Test downloads the latest upstream
  NaiveProxy build, lipo-merges arm64 + x86_64, ad-hoc signs,
  and adopts as the custom binary path.
- About footer with the running app version + build number.

## [0.1.5.5] — 2026-05-03 (pre-release)

Ready to use out of the box.

- Profile passwords moved off the macOS Keychain by default —
  no system password prompt fires before the UI appears.
- New `FileCredentialStore` (file-backed, mode 0600) is the
  primary; the Keychain stays as the legacy leg of a
  `MigratingCredentialStore` so v0.1.5.4 upgraders don't lose
  saved passwords.
- `security_check.sh` secret scan now covers the whole project
  folder.

## [0.1.5.4] — 2026-05-02 (pre-release)

Maltese-themed visual refresh + single-button mode switching.

- Tapping a Smart / Global / Local chip while running hot-swaps
  modes via `TunnelOrchestrator.switchMode(to:)`. No more "Stop
  first, then Start in the new mode" dance.
- Pastel palette + Liquid Glass surfaces (macOS 26+) with
  regular-material fallback.
- `.symbolEffect(.bounce/.pulse)` and `.sensoryFeedback` on the
  right interactions.
- Chip identity renamed from NewJeans-style to Maltese-pup
  (palette and structure unchanged).

## [0.1.5.3] — 2026-05-02 (pre-release)

Repo tidying + Debouncer optimisation + leaked-password guard.

- Removed four loose dev scripts that contained a hardcoded
  development-server password; cleaned the same value out of
  `NaiveProxy_Server_Setup.md` and the Rust test fixtures.
  See [SECURITY.md](./SECURITY.md) for the rotation note.
- `Debouncer` got lazy pruning, an explicit `prune_stale(now)`
  helper, a `Default` impl, and a `window()` accessor.
- New pinned check in `security_check.sh` rejects any future
  commit that tries to reintroduce the literal.

## [0.1.5.2] — 2026-05-02 (pre-release)

Desensitization audit — credential leak gaps closed.

- `Username::Debug` and `Display` now redact (matching `Password`).
- Redaction regex extended to SOCKS, FTP, and `naive+https://`
  URLs and to `Authorization` / `Cookie` headers.
- curl stderr is now redacted before crossing the wire.
- `naive --version` output validated against the canonical
  `naive <semver>` pattern; arbitrary subprocess output can no
  longer reach the Settings UI.

## [0.1.5.1] — 2026-05-02 (pre-release)

Apache 2.0 relicense + expanded README.

- LICENSE replaced with the canonical Apache 2.0 text.
- New `NOTICE` file with copyright + bundled-component
  attribution.
- README expanded with architecture diagram, build-from-source
  steps, repository layout, and trade-offs.
- Audit fixes: diagnostic-event ordering race, monotonic clock
  for elapsed timing, defensive `formatMs` against NaN, naive
  refresh re-entrancy guard.

## [0.1.5] — 2026-05-02 (pre-release)

Live ms timing for diagnostics + latency tests.

- Per-probe `DiagnosticProgress` events with wall-clock
  `elapsed_ms`.
- Per-sample latency breakdown lines (`total= dns= connect=
  tls= ttfb=`).
- Latency probes labelled `baseline (direct, no proxy) <url>`
  vs `via proxy <url>`.

## [0.1.4.1] — 2026-05-02

Single auth before UI.

- Bootstrap now performs exactly one code-signature check
  (`cool-tunnel-core`); naive verification is deferred to
  Settings or proxy start.

## [0.1.4] — 2026-05-02

Universal binary fix.

- Bundled `naive` and `cool-tunnel-core` are now genuine
  universal Mach-Os (arm64 + x86_64). v0.1.3 silently shipped
  arm64-only builds despite the universal claim.
- New `NaiveBinaryResolver` with chip detection and a Settings
  panel that surfaces arch slices, version, and code signature.
- `scripts/fetch_naive.sh`, `scripts/build_rust_core.sh`,
  `scripts/security_check.sh`, `scripts/package_release.sh`.
- 100 ms `Debouncer` for monitor anomalies, with a 100k-event
  stress test.
- AGPL-3.0 license + Disclaimer (later relicensed to Apache 2.0
  in v0.1.5.1).

## [0.1.3] — 2026-05-02

First public release. Rebrand from `naive` to `COOL TUNNEL`,
modular Swift split (`App/Core/Persistence/SystemIntegration/Views`),
new Rust core crate.
