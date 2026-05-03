# Changelog

All notable changes to Cool Tunnel land here. Versions follow
roughly-semver: bumps in the third digit are features; bumps in
the fourth digit are pre-release polish on the same line.

The pre-release `v0.1.5.x` series soaked from May 2 to May 3, 2026.
**v0.1.6** is the first stable release.

## [0.1.6] — 2026-05-03 (stable, **LTSC**)

First stable release **and the first release on the Long-Term
Servicing Channel** line. The LTSC posture is documented in
[SUPPORT.md](./SUPPORT.md): public surface (UI flows, CLI flags,
engine protocol, on-disk paths) is locked for the lifetime of the
v0.1.6 line; only patch + minor security fixes and upstream
NaiveProxy updates land in-line. Major changes wait for the next
LTSC line.

LTSC infrastructure shipped as part of v0.1.6:

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
- `scripts/security_check.sh` adds a section 9 LTSC-posture audit
  (lockfile present + fresh, toolchain pin, SUPPORT.md).

Everything from the v0.1.5.x line, plus:

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
