# Changelog

All notable changes to Cool Tunnel land here. Versions follow
roughly-semver: bumps in the third digit are features; bumps in
the fourth digit are pre-release polish on the same line.

The pre-release `v0.1.5.x` series soaked from May 2 to May 3, 2026.
**v0.1.6** was the first stable release on the original line.
The **v2.0.x** series is the current Long-Term Servicing Channel
line — see [SUPPORT.md](./SUPPORT.md) for the support contract.

## [2.0.34] — 2026-05-09 — Operator Start Gate

> **Every Start path now rejects ambiguous profile settings before
> the engine is touched.**

Operator-certainty release for the SwiftUI control surfaces. The main
window and menu bar now share the same startability signal, and the
orchestrator enforces a final local guard before routing any UI intent
to the Rust core.

### Changed

- Added `selectedProfileCanRequestStart` to `CoolTunnelViewState` so
  the main control row and menu-bar mode rows agree on whether a
  stopped tunnel can request Start.
- Menu-bar mode rows now stay disabled while stopped until the selected
  profile has a valid server shape, non-empty username, and valid local
  port.
- The primary Start button now distinguishes malformed profile shape
  from password hydration; stored credentials are still checked only
  after an explicit Start intent.
- `TunnelOrchestrator.perform(_:)` now records a local-kernel rejection
  and returns before the engine sees malformed Start or mode-switch
  intents.

### Verified

- `xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL`
- `xcodebuild -project COOL-TUNNEL.xcodeproj -scheme COOL-TUNNEL -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build`
- `cargo fmt --all -- --check`
- `cargo clippy --locked --all-targets --all-features -- -D warnings`
- `cargo test --locked --all-features`
- `cargo deny check`
- `shellcheck scripts/*.sh`

## [2.0.33] — 2026-05-09 — Observability Certainty

> **The operator can now inspect tunnel lifecycle, throughput,
> encryption overhead, and failure layer attribution without guessing
> which part of the path is broken.**

Observability release for macOS client support sessions. The tunnel
continues to run through the existing supervised Rust subprocess and
NaiveProxy path; this release adds local telemetry and an optional
developer HUD over that path.

### Added

- **Append-only lifecycle telemetry** at
  `Application Support/Cool Tunnel/lifecycle-telemetry.jsonl`.
  Each transition row includes wall-clock and monotonic microsecond
  timestamps, mode/running state, optional failure layer, and redacted
  details for support correlation.
- **Developer Overlay** toggle in the control bar. The non-interactive
  HUD shows live throughput, TLS handshake delta, VPS reachability, and
  local kernel/`naive` PID health without blocking normal app use.
- **Rust traffic snapshot events** from the existing connection monitor,
  reusing the same bounded `lsof` parse that powers anomaly detection.

### Changed

- Error-layer language now matches the operator-facing troubleshooting
  taxonomy: **ISP**, **VPS**, and **Local Kernel**.
- Connection start, stop, switch, hot-swap, diagnostics, latency, engine
  stream end, and error paths now emit deterministic lifecycle records.

### Verified

- `xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL`
- `xcodebuild -project COOL-TUNNEL.xcodeproj -scheme COOL-TUNNEL -configuration Debug -destination 'platform=macOS' build`
- `cargo fmt --all -- --check`
- `cargo clippy --locked --all-targets --all-features -- -D warnings`
- `cargo test --locked --all-features`
- `shellcheck scripts/*.sh`

## [2.0.32] — 2026-05-09 — Declarative UI State Schema

> **The SwiftUI surface now renders from an explicit, AI-friendly
> state schema and emits named operator intents instead of hiding
> tunnel side effects inside leaf views.**

Architecture release for maintainability on the LTSC line. No engine
protocol change; the existing connection lifecycle, self-healing, and
menu-bar controls are preserved behind a clearer state boundary.

### Added

- **`CoolTunnelViewState`** as the structured SwiftUI-facing schema
  for connection, header, controls, menu-bar, profiles, activity log,
  diagnostics, settings, and resource descriptor state.
- **`CoolTunnelUIState`** for local view draft state such as Settings
  visibility and the pending mode selection.
- **`TunnelIntent`** as the named UI-to-orchestrator command surface
  for mode changes, Start/Stop, diagnostics, latency tests, error
  dismissal, and log clearing.

### Changed

- Main-window header, control panel, menu-bar content, menu-bar glyph,
  and log-clear action now render from the schema and dispatch intents
  through `TunnelOrchestrator.perform(_:)`.
- Inline documentation now links the schema, status pill, error banner,
  and control panel to the Heng / Silent Operator invariant: views
  describe state and operator intent; the orchestrator owns recovery,
  retry, and system side effects.

### Verified

- `xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL`
- `xcodebuild -project COOL-TUNNEL.xcodeproj -scheme COOL-TUNNEL -configuration Debug -destination 'platform=macOS' build`
- `cargo fmt --all -- --check`
- `cargo clippy --locked --all-targets --all-features -- -D warnings`
- `cargo test --locked --all-features`
- `cargo deny check`
- `shellcheck scripts/*.sh`

## [2.0.31] — 2026-05-09 — Self-Healing Stability + Log Pressure Hardening

> **The tunnel now recovers itself from core exits, proxy drops,
> and sleep/wake edge cases while keeping bursty logs bounded.**
> This release hardens the app's shipped stdio/Rust-core tunnel
> path. The repository still does not contain an
> `NEPacketTunnelProvider` target.

Stability release for long-running menu-bar sessions. Focuses on
bounded memory under noisy child-process output, automatic recovery
after engine loss, and lower energy posture in the GUI/log surfaces.

### Added

- **Self-healing orchestrator loop** for unexpected core stream
  termination and proxy stop events. Non-stopped modes now schedule
  retry attempts automatically instead of leaving the operator with
  a manual "click to retry" state.
- **Sleep/wake health verification** that probes the running proxy
  after wake. If the proxy is no longer reachable, the orchestrator
  clears the stale sentinel, disables the system proxy, marks the
  mode stopped, and lets the self-healing path restart the requested
  mode.
- **Performance-profile-derived pressure caps** for monitor interval,
  log flush interval, log batch size, and maximum retained log-line
  length.

### Changed

- **Core stdout ingestion is now frame-bounded** at the Swift side of
  the JSON-over-stdio protocol. The app no longer relies on unbounded
  `AsyncLineSequence` buffering when the core emits malformed or
  newline-free output.
- **Rust child-log forwarding is byte-bounded** before redaction and
  event emission. Oversized `naive` log lines are truncated with a
  marker instead of allocating an arbitrary string.
- **Log publishing is batched** and flushed on a short timer or when
  enough entries accumulate. Error entries still flush immediately so
  operator-visible failures are not delayed.
- **Log-console auto-scroll is throttled** and uses shorter animation,
  reducing UI churn during noisy bursts.

### Verified

- `bash scripts/preflight.sh` — all green locally.
- GitHub Actions on PR #46 — Rust build/clippy/test, Swift format
  lint, and ShellCheck all passed before merge.

## [2.0.30] — 2026-05-09 — Defensive Input Logic ("First Scold, Then Do Good")

> **The UI is now strict on input to protect the engine's
> integrity, but kind enough to fix your messy pastes for you.**
> No more *"Couldn't start"* failures from a typo'd port or a
> pasted full URL — the field self-corrects what it can, the
> Start button stays disabled until what it can't is fixed, and
> the inline captions tell the operator exactly what to do next.

Final layer of UX hardening for the `ConnectionFormView` + Direct
Domains flow. Closes audit findings D-1 through D-4. No protocol
or infrastructure change; existing deployments can update without
operator action beyond the in-app Update button.

### Added

- **`Profile.serverValidation: ServerValidation`** — pure
  validator on the wire-shape contract (bare host or `host:port`,
  no scheme, no path). Returns one of:
  - `.valid` — engine-acceptable.
  - `.empty` — treated as "still typing" (no caption).
  - `.hasScheme(String)` — pasted with a scheme prefix; the
    captured string is the matched prefix verbatim.
  - `.hasPath` — contains `/`, looks like a pasted URL.
  - `.malformed(reason: String)` — other format failure.
- **`Profile.localPortValue: UInt16?`** — parses `localPort` as
  a `UInt16` ≥ 1024. `nil` for non-numeric, out-of-range, or
  blank input. The 1024 floor is enforced because `naive`
  binding to a well-known port requires `setuid root` privileges
  the app neither has nor should have.
- **`Profile.normaliseServer(_:)`** — the "Good Deed" half of
  the input contract. Auto-strips a scheme prefix
  (`https?://`, `naive+https://`, …) and any trailing path from
  a pasted URL. Idempotent.
- **Inline red captions** in `ConnectionFormView` under the
  Server and Local port fields. Only render when there's a
  concrete problem to fix; absent during empty / valid /
  still-typing states.
- **`onChange`-driven paste normaliser** on the Server field.
  When the user pastes a full URL, the field self-corrects on
  the next runloop tick — they see "https://example.com/path"
  briefly, then it collapses to "example.com." Same effect on
  the Direct Domains TextField.
- **`@State domainAddError: String?`** in `SettingsView` to
  surface rejection reasons inline. Pre-2.0.30 the rejection
  was silent — the operator clicked Add, the field cleared,
  and they assumed success.

### Changed

- **`Profile.isStartable`** is now gated on
  `serverValidation == .valid` AND `localPortValue != nil`.
  Pre-2.0.30 it only checked "non-empty after trim." A typo'd
  port (e.g. `"abc"`) or a pasted full URL would clear the gate
  and the failure surfaced only at engine-validate time. Now
  the Start button stays disabled until the inputs are
  well-formed.
- **`SettingsView.addDomain`** routes through `Profile.normaliseServer`
  + a new `isPlausibleDomainShape` check (loose RFC-1123 hostname
  shape: alphanumerics + dots + hyphens, ≤ 253 chars, must
  contain a dot, no leading/trailing dot, no empty labels).
  Rejects scheme prefixes, path components, and single-label
  inputs like `localhost` (the latter shouldn't be on a public
  PAC bypass list anyway).

### UX guarantees (the "ballast" you don't have to doubt)

| Field | Empty | Valid | Pasted URL | Bad port | Malformed host |
|---|---|---|---|---|---|
| Server | no caption | no caption | auto-strips, transient caption | n/a | red caption + blocks Start |
| Username | no caption | no caption | n/a | n/a | n/a |
| Password | no caption | no caption | n/a | n/a | n/a |
| Local port | no caption | no caption | n/a | red caption + blocks Start | n/a |
| Direct domain | no caption | added silently | auto-strips, then re-validates | n/a | inline error |

Start button reflects all four upstream gates at once — operator
never has to guess which field is blocking.

### Out of scope (deliberate)

- **Live keystroke-by-keystroke rejection** — HIG-violating;
  validation fires on `onSubmit` / focus-leave / Start-press,
  not on every key.
- **Hard-rejecting paste of valid `https://host` URLs** — better
  UX is to normalise + show the user what was accepted.
- **Refactoring the FSM substrate** — already in place per the
  prior "State-Driven UI" audit.

### Process note

Caught a Swift 6 strict-concurrency gap during local Debug
xcodebuild *before* opening the PR — same class of error the
v2.0.29 PR landed and only surfaced at `cut_release.sh` time.
Local Debug build added to the pre-PR ritual; a future hardening
of `.github/workflows/ci.yml` to run `xcodebuild build` is the
trigger if a fourth instance surfaces.

## [2.0.29] — 2026-05-09 — Deterministic Error Reporting (`ErrorLayer` taxonomy)

> **No more *"Couldn't start Smart Mode"* with no signal whether
> to check your wifi, your server, or your app.** When a connection
> fails, the banner chip now pinpoints the broken node — `[Local]`,
> `[Upstream]`, or `[VPS]` — without the operator having to run
> `Diag` manually.

Final intelligence layer added to the `v2.0.28` Seamless Recovery
Protocol. The orchestrator now classifies connection-failure paths
into one of three layers and renders the verdict as a chip on the
`HeaderView` error banner. Passive — the classifier only runs on
failure, never during normal operation; energy posture from the
v2.0.28 audit is preserved.

### Added

- **`ErrorLayer` enum** — public `Sendable Codable Equatable`,
  three cases:
  - `.local` — the issue is on the Mac (`naive` not running, OS
    firewall, saved credentials wrong).
  - `.upstream` — the issue is between the Mac and the public
    internet (ISP, Wi-Fi, captive portal, DNS).
  - `.vps` — the issue is the user's NaiveProxy server (hostname
    doesn't resolve, `:443` refuses, daemon rejecting handshake).
  Carries `diagnosticLabel` (chip text) and `humanExplanation`
  (used by `Disclaimer.md` § "Reporting issues" + the `Diag`
  button's transcript export).
- **`TunnelOrchestrator.lastErrorLayer: ErrorLayer?`** —
  observable state slot; cleared on successful start / mode-switch.
- **`TunnelOrchestrator.classifyConnectionFailure()`** — runs
  two parallel reachability probes (Apple's NCSI endpoint for
  general upstream + a direct TCP probe to the user's VPS
  hostname bypassing the system proxy) with a 3-second budget.
  Decision matrix:
  | | Apple ✓ | Apple ✗ |
  |---|---|---|
  | **VPS ✓** | `.local` | `.upstream`* |
  | **VPS ✗** | `.vps` | `.upstream` |
  *Apple unreachable but VPS reachable typically indicates ISP
  NCSI blocking or a captive portal that lets the user's VPS
  through; `.upstream` is the most actionable verdict.
- **`TunnelOrchestrator.recordClassifiedError(_:)`** — async
  helper that runs the classifier, then records the error with
  the resulting layer. Used by the connection-failure paths in
  `startCore` and the wake-recovery branch of `handleSystemDidWake`.

### Changed

- **`recordError(_:layer:)`** signature. Existing call sites
  unchanged in behaviour — `layer:` defaults to `nil` so plain-text
  rendering is preserved everywhere except the connection paths.
- **Wake-recovery path** (`handleSystemDidWake`) now calls
  `recordClassifiedError` on failure. Pre-2.0.29 the message was
  *"auto-recovery after sleep failed — click a mode to restart
  manually."* The chip now provides the actionable node directly
  (e.g. `[VPS]` after waking onto a network that blocks the
  operator's server).
- **`HeaderView.errorBanner`** — renders the layer chip leading
  the banner message. `nil` layer → no chip, exact pre-2.0.29
  rendering. Layer present → compact uppercase pill (`LOCAL`,
  `UPSTREAM`, `VPS`) above the message in the same banner.
  Accessibility label updated to read *"Error in `<Layer>` layer"*.

### Hardcoded `.local` (no classifier needed)

Three call sites are local-by-construction — running the
classifier would only confirm what the caller already knows:

- `engine failed to start: …` (orchestrator bootstrap throws)
- `naive binary unusable / inspection failed` (binary picker)
- `Critical: …. Auto-stopping.` (anomaly auto-stop)

### Out of scope (deliberate)

- **Microsecond telemetry & persistent Performance HUD** — both
  rejected as speculative noise per the audit response. Only the
  `ErrorLayer` taxonomy was authorised for v2.0.29.
- **Auto-respawn on engine crash** — boundary preserved per the
  *"system resilience, not unauthorised persistence"* framing
  from v2.0.28.

## [2.0.28] — 2026-05-09 — Seamless Recovery Protocol (sleep/wake survival)

> **End of *"click Stop, then restart your mode."*** The system can
> now sleep, the laptop can close, the network can vanish — when the
> machine comes back, the proxy is already running again.

Three wired fixes covering the F-1 / F-2 / F-4 audit findings.
Pre-v2.0.28 the orchestrator only listened for `didWakeNotification`;
on wake it sent one probe and, if the probe failed, surfaced
*"connection became unresponsive while system slept — click Stop,
then restart your mode"* and waited for the operator to act. The
audit also surfaced that the lsof-based `monitor_loop` ran every 5 s
across the entire sleep window even though no hardware state could
change. This release closes both gaps with one cohesive recovery
protocol.

### Added

- **`willSleepNotification` listener (F-1).** A new `sleepObserver`
  in `AppDelegate` subscribes to `NSWorkspace.willSleepNotification`
  and routes it into `TunnelOrchestrator.handleSystemWillSleep()`.
  The orchestrator pins the active mode in `modeBeforeSleep`, flips
  `sleepWakeState = .pausing`, and calls `stop()` to drain cleanly
  *before* the system suspends. Local-only mode is exempt — its
  SOCKS listener has no upstream TCP to lose during sleep.
- **Autonomous wake recovery (F-2).** `handleSystemDidWake()` is
  rewritten with two paths:
  - **Path A — clean checkpoint (preferred).** If `sleepWakeState
    == .paused` and `modeBeforeSleep` is set, the orchestrator
    flips to `.recovering`, waits 500 ms for the network stack to
    settle (DNS TTLs reset, route table sync, Wi-Fi association
    complete), then re-applies the prior mode via `switchMode(to:)`.
    End state: `.idle`, mode restored, no operator click.
  - **Path B — missing checkpoint (fallback).** If we somehow
    missed `willSleep` (app launched mid-sleep, or notification
    raced the suspend), fall through to the prior probe-only
    behaviour from v0.1.7.18 so the zombie state still surfaces.
- **`SleepWakeState` enum.** Public `Sendable Codable` finite-state-
  machine type owned by the orchestrator: `.idle / .pausing /
  .paused / .recovering`. Drives the new pill labels below.

### Changed

- **`HeaderStatusPill` renders the recovery phases (F-2).** New
  `sleepWakeState:` parameter (default `.idle` — old call sites
  unchanged in behaviour). Non-`.idle` values take precedence
  over `isRunning` / `lastError`:
  | State | Pill colour | Pill text |
  | --- | --- | --- |
  | `.pausing` | amber | *Pausing for sleep…* |
  | `.paused` | secondary | *Asleep* |
  | `.recovering` | amber | *Recovering after wake…* |
  Steady-state rendering (`.idle`) is unchanged.

### Performance / Energy

- **`monitor_loop` is now intelligent (F-4).** The 5-second lsof
  cadence in the Rust core was unconditional pre-v2.0.28; it ran
  through every system suspend. Because `handleSystemWillSleep`
  now calls `stop()` (which terminates the engine subprocess
  cleanly), the supervised PID is gone for the duration of the
  sleep window and `monitor_loop` exits naturally on its own
  *"supervised process gone"* check. No new protocol surface, no
  pause/resume RPC — the existing subprocess-lifecycle gate does
  the right thing once the engine actually shuts down on sleep.
  Net effect: zero lsof invocations during system sleep,
  vs. one every 5 seconds pre-fix.

### Out of scope (deliberate)

- **Auto-respawn on engine crash (F-3).** Maintained the existing
  boundary: if the user explicitly stops the engine it stays
  stopped. The recovery protocol shipped here is system-resilience
  scoped, not unauthorised-persistence scoped.
- **Window-occluded conditional cadence.** Behaviour change for the
  foreground-but-occluded case is a UX call deferred until evidence
  surfaces.
- **Memory tightening (F-7 / F-8 / F-9).** Audit confirmed the
  existing discipline; speculative tightening is off the table.

## [2.0.27] — 2026-05-09 (Hotfix: NaiveUpdater self-heals stale lastInstalledTag)

Single-line behaviour fix in `NaiveUpdater`. Mirrors the v2.0.24
fix to `RustCoreUpdater` (PR #31): same defect class, same fix
shape, different updater. No protocol or infrastructure change.

### Fixed

- **`NaiveUpdater.checkForUpdates` self-heals when the managed
  `naive` binary is missing.** Pre-fix symptom (now reachable for
  the bundled-`naive` panel rather than just the engine panel):
  with `~/Library/Application Support/COOL-TUNNEL/naive-managed`
  deleted (Application Support cleanup, manual delete, fresh Mac
  with iCloud-synced UserDefaults from a previous host that did
  install it), the panel would say *"You're on the latest version
  (X)."* while the binary was in fact missing — because
  `lastInstalledTag` in UserDefaults remained authoritative for
  the currency check.

  At the top of `checkForUpdates`, if the file at `installedURL`
  doesn't exist on disk, `lastInstalledTag` is now cleared before
  the tag-currency check runs. The next state the user sees is
  `.available(tag)` with a real *"Update to vX.Y.Z"* button, so a
  single click recovers the binary.

- **Sister-bug discovery process.** This was a sister bug we
  should have caught when fixing `RustCoreUpdater` in #31; the
  audit suite doesn't yet have a codified gate for *"parity-
  required across the three updaters (App / Naive / RustCore)."*
  No change to the audit suite this release — single-occurrence
  fix landed first; if a third asymmetry surfaces in a future
  round-N review, that's the trigger for codifying the gate.

## [2.0.26] — 2026-05-08 (Licence: Apache-2.0 → AGPL-3.0-only)

> **Abandoned all commercial restrictions in favor of absolute
> transparency and open-source stewardship.**
>
> *This project belongs to the community. coolwhite LLC chooses
> transparency over profit, and freedom over control.*

Strategic licence transition under the **coolwhite LLC** copyright
anchor, aligned with the simultaneous switch on the upstream Cool
Tunnel Server stack. Forward-only — every release tagged on or
before `v2.0.25` remains Apache-2.0 for anyone who downloaded it;
AGPL-3.0-only applies prospectively from this tag.

### Changed

- **`LICENSE`** replaced with the verbatim FSF GNU Affero General
  Public License v3 text (`gnu.org/licenses/agpl-3.0.txt`).
- **67 source files** (`.rs` + `.swift` under `core/` + `COOL-TUNNEL/`)
  carry an SPDX short-form header:

  ```
  // SPDX-License-Identifier: AGPL-3.0-only
  // Copyright (C) 2026 coolwhite LLC
  // See LICENSE for full terms.
  ```

  Modern lawyer-blessed shorthand; full preamble lives in `LICENSE`.
- **`core/src/main.rs`** and **`COOL-TUNNEL/App/CoolTunnelApp.swift`**
  carry an additional intent-of-licence note at the entry point:
  *"This software is a sanctuary for personal privacy. Any
  redistribution or modification must strictly adhere to the
  AGPL-3.0 terms to ensure the spirit of freedom remains
  untainted."*
- **`core/Cargo.toml`**: `license = "AGPL-3.0-only"`,
  `authors = ["coolwhite LLC"]`. `Cargo.lock` refreshed.
- **`MARKETING_VERSION`** in the Xcode project: `2.0.25 → 2.0.26`
  (Debug + Release configs).
- **`README.md`**, **`NOTICE`**, **`Disclaimer.md`**,
  **`COOL-TUNNEL/Views/AcknowledgementsView.swift`** rewritten to
  reference AGPL-3.0 throughout. Bundled-component compatibility
  table preserved (NaiveProxy BSD-3, Rust crate set MIT/Apache-2.0/
  BSD-3/ISC/MPL-2.0 — all AGPL-3.0-compatible). Apple SDK headers
  and SF Symbols are used by reference, not redistributed in
  source form, so their proprietary terms do not propagate.

### Why

Coolwhite LLC chose the **Lighthouse** over the **Fortress**: the
project exists to provide order and transparency, not to collect
fees. The Apache-2.0 → AGPL-3.0 transition closes the SaaS loophole
for any future modified server-side variant while keeping the
client itself fully open and freely redistributable.

### What this means in practice

| Audience | Effect |
| --- | --- |
| End users | None. The `.dmg` you download still installs the same way. |
| Forks / packagers | Modifications must be released under AGPL-3.0 with source available; AGPL § 13 obliges source-availability for modified versions run as a network service. |
| Enterprises wanting to embed | Talk to `coolwhite LLC`. The AGPL § 13 source-availability obligation is the trigger to re-evaluate. |

## [2.0.25] — 2026-05-08 (Hotfix: subscription-imported password persists)

Single fix to a silent persistence bug in the subscription-import
flow. Without this, importing a subscription URL would briefly
appear to work — the profile fields populated, the success banner
fired — but the password never reached
`~/Library/Application Support/COOL-TUNNEL/credentials.json`. On
the next launch the profile was missing or stripped of credentials,
forcing the user to re-enter the password by hand.

### Fixed

- **`TunnelOrchestrator.selectedProfile` setter — persist when id
  not in list.** The setter was update-in-place only:
  `if let index = profiles.firstIndex { profiles[index] = updated }`.
  Profiles assigned through `selectedProfile =` whose id wasn't
  already in `profiles` were silently dropped — `selectedProfileID`
  advanced to the new id but `profiles` (and therefore
  `profileStore.save(profiles:)` and the credential store) never
  saw them. `importFromSubscriptionURL` falls back to
  `UUID().uuidString` when no profile is selected; that fresh UUID
  was never in `profiles`, the setter dropped the assignment, and
  the imported password never persisted. Append-when-not-found
  makes any value assigned through `selectedProfile =` durable.

### How it broke

Any path that assigns a brand-new `Profile` to `selectedProfile`
when the existing selection is empty or dangling: subscription
import (the failure mode users actually hit), and any future flow
that wants to atomically swap in a freshly-constructed profile.
Existing call sites — the `ConnectionFormView` field bindings and
the `addProfile` path — assign profiles already in the array, so
they were unaffected and remain so post-fix.

## [2.0.24] — 2026-05-08 (Hotfix: managed-engine self-heal)

Single fix. The Rust Core (engine) panel in Settings could surface
a contradictory state when the managed binary at
`~/Library/Application Support/COOL-TUNNEL/cool-tunnel-core-managed`
was missing — green "You're on the latest version ()." with empty
parens *alongside* red "binary not found." Cause: a stale
`lastInstalledTag` entry in UserDefaults claimed currency against
a binary that no longer existed on disk, and the empty
`currentVersion` (because `Test` had not yet run) bled through to
the message template.

### Fixed

- **`RustCoreUpdater.checkForUpdates`** now self-heals: if
  `installedURL` doesn't exist on disk, `lastInstalledTag` is
  cleared *before* the tag-currency check runs. The next state
  the user sees is `.available(tag)` with a real "Update to vX.Y.Z"
  button, so a single click recovers the engine.
- **`SettingsView.rustUpdaterMessage`** falls back to the resolved
  release tag if `currentVersion` is empty so the parens never
  render blank — defence in depth for any path that bypasses the
  self-heal.

### How it broke

Any path that disconnects the persisted tag from the actual binary
file: Application Support cleanup, manual delete, fresh-Mac
UserDefaults sync via iCloud, an interrupted `update()` call that
wrote `lastInstalledTag` before the atomic install completed.
Pre-2.0.24, the panel was unrecoverable except via `Choose…` or
`Reset` — neither of which is discoverable from the NG state.

## [2.0.23] — 2026-05-07 (Auto-updater fix: macOS 15+/26 incompatibility)

One real shipping bug. v2.0.22 (and every release before it) shipped
an in-app updater path that silently fails on macOS 15 / 26 (Sequoia
/ Tahoe) when the bundle is `.pkg`-installed (root-owned in
`/Applications`). User clicks Update → admin password prompt
appears → user enters it → osascript reports success → app
terminates expecting helper to swap and relaunch → **helper
never actually runs** → on manual restart the user is back on the
old version with no signal anything went wrong.

### Fixed

- **AppUpdater silent failure on root-owned bundles in macOS 15+/26.**
  Previously, AppUpdater ran the entire relaunch helper inside a
  privileged shell:
  ```
  osascript -e 'do shell script "/bin/bash wrapper.sh"
                with administrator privileges'
  ```
  where `wrapper.sh` was supposed to detach the real helper via
  `nohup ... &; disown` so osascript could return promptly while
  the helper kept running as root long enough to wait for the
  parent PID, do the bundle swap, and relaunch. macOS 15+ / 26
  (Tahoe) **kills children of the authorization-elevated shell on
  exit regardless of `nohup`/`disown`** — `nohup ... &; disown`
  worked for decades but Apple changed the rules. The wrapper
  exited 0, osascript reported success, AppUpdater proceeded to
  `state = .relaunching` and terminated, but the real helper was
  killed before its first non-trivial line (`exec 2>>"$LOG"`)
  ever executed — the relaunch log file mtime didn't even update.

  New flow: use `osascript ... with administrator privileges` for
  ONLY a `chown` (a fast atomic operation that doesn't need to
  background), then fall through to the regular user-owned spawn
  path. After the chown the bundle is owned by the current user,
  the relaunch helper spawned via `Process()` inherits the user's
  normal session (no sandbox issue), and future updates skip the
  password prompt entirely. Defence in depth: `lstat()` after the
  osascript call to verify the chown actually took effect.

  Diagnosed via `log show` against a failed v2.0.21→v2.0.22
  attempt: `authd` reported `Succeeded authorizing right
  'system.privilege.admin' by client '/usr/bin/osascript'` at
  21:15:14.385, the wrapper script ran as root and exited 0, the
  parent app exited cleanly at 21:15:24 — and yet the helper
  script's first `echo` to its log never appeared.

  User-visible behaviour:

  | Scenario | Before | After |
  | --- | --- | --- |
  | First update on a `.pkg`-installed bundle | Silent failure | One admin-password prompt for the chown, update completes |
  | Subsequent updates | Re-prompted on every update (when working at all) | Zero password prompts — bundle is now user-owned |
  | User cancels password prompt | "Update cancelled — admin password not entered." | Same |
  | `.dmg`-installed (user-owned) bundles | Worked | Unchanged |

### Bundled
- NaiveProxy v148.0.7778.96-2 (unchanged)
- Cool Tunnel Core v2.0.23

---

## [2.0.22] — 2026-05-07 (v2.0.21 review-fallout: 4 rounds of code review, ~30 fixes)

Four full rounds of code review against the v2.0.21 cycle, each
spawning multiple parallel reviewers with different lenses
(correctness, security, concurrency, perf, UX, supply-chain,
docs). About 30 distinct fixes ship here — no new features, no
wire-protocol change. Backward-compatible drop-in for v2.0.21.

The biggest single-finding payoff was a hidden UX disaster: every
client-side error type except one defined `var localizedDescription`
as a plain stored property without conforming to `LocalizedError`,
so the `(error as? LocalizedError)?.errorDescription` cast at
user-facing catch sites silently fell through and users saw
Swift's default `"…CoolTunnel.CoreClientError error N."` instead
of the carefully-written enum strings. Round 3 fixed it.

### Security / hardening

- **`SubscriptionClient` body-size cap is now load-bearing**
  (1 MB, enforced **during** the read via streaming
  `bytes(for:)` accumulation). The post-hoc `data(for:)` cap
  introduced mid-cycle was reverted in round 4 — `data(for:)`
  buffers the full body before the cap can fire, so on a fast
  network (gigabit) a hostile or hijacked panel can land
  ~1.25 GB in memory inside the 10 s `timeoutIntervalForResource`
  window before the size check trips. Streaming bounds peak
  memory at exactly `maxBytes` regardless of upstream
  throughput.
- **No-redirect delegate** on `SubscriptionClient` fetches.
  Default `URLSession` follows up to ~16 redirects to any host;
  a panel takeover responding `302 Location: https://attacker
  .example/manifest.json` would silently move the documented
  "TLS to the panel domain" trust anchor. `NoRedirectGuard`
  refuses every redirect.
- **`Content-Type` sniff** before JSON decode. Documented in
  the file preamble pre-cycle but never implemented — the
  cover-site path went straight to `JSONDecoder` on multi-MB
  HTML. Multi-value `Content-Type` headers (RFC violation but
  observed in the wild from misconfigured reverse proxies) are
  parsed by splitting on `,` first then `;`.
- **`Subscription.validate(now:)` now enforces 9 rules** (was
  4): `version == 1`, non-empty `profiles[]`, `profiles.count ≤
  16`, `host` not loopback / private / link-local / `localhost`
  / `*.local` (closed-loop SSRF defense), `capabilities.http3 ==
  false`, `issued_at != 0`, `issued_at <= now + 60 s` (forward
  skew tolerance), `expires_at >= issued_at`, `expires_at -
  issued_at <= 1 year`, `expires_at > now`, `now - issued_at
  <= 7 days`. Each adds defense against a counterfeit panel
  trying to bypass the freshness or staleness gates.
- **`AntiTrackingFeature` decode is forward-compatible.** Was
  auto-derived `String`-rawValue Codable that threw on any
  unknown variant — adding any new flag server-side would brick
  every v1 client with a misleading `tokenInvalid` UI. Now
  manual Codable with an `unknown(String)` sink.
- **CI actions pinned to commit SHAs** (`actions/checkout@v6`,
  `actions/cache@v5`, `taiki-e/install-action@v2`). Tag-takeover
  defense.
- **`security_check.sh` now runs from `cut_release.sh`** as
  step 8b. Was opt-in / documentation-only; release operators
  who skipped it shipped without secret scan, embedded-Mach-O
  code-sign verification, NaiveProxy SHA cross-check,
  Info.plist version assertion, or LICENSE/NOTICE presence
  check.
- **`cargo deny check` runs from `audit.sh`** (step 3b).
  Aligns the local synthetic CI gate with what `.github/
  workflows/ci.yml` was already enforcing.
- **`isExcludedFromBackupKey`** set on
  `~/Library/Application Support/COOL-TUNNEL/`. `config.json`
  carries the cleartext `https://user:pass@host` proxy URL and
  `credentials.json` carries base64-encoded passwords; both are
  0600 user-only on disk but Time Machine snapshots are
  accessible to the next admin restoring the user's home.
- **IPv6 host parsing.** `ServerAddress::parse` previously used
  `rfind(':')` and silently mis-parsed bare `2001:db8::1` as
  host=`2001:db8:` port=`1`. Now accepts bracketed form
  `[2001:db8::1]:443`, rejects bare multi-colon strings as
  `AmbiguousIPv6` with a pointer at the bracket fix.
- **`RawProfile` redacted Debug.** Pre-empts a future
  `tracing::warn!(?raw, "deserialize failed")` from dumping
  cleartext credentials to the engine stderr stream.
- **`engineStderrLogger` flipped to `privacy: .private`.**
  Defense-in-depth — the engine's `tracing` is already clamped
  to info, but the Swift forwarder was at `.public`.
- **`url.lastPathComponent` instead of `url.path`** in
  resolver error strings. `url.path` includes
  `/Users/<name>/...` (macOS-username leak in user-visible
  banners and support logs).
- **`Text(verbatim:)` for panel-supplied `displayName`** in
  `ConnectionFormView`. String-literal interpolation on
  `Button(_: LocalizedStringKey)` and `Text(_: LocalizedStringKey)`
  auto-renders markdown — a hostile panel returning
  `host: "**evil**.com"` would render bolded.

### Correctness

- **`CoreClient` stderr-drain `Task` is now cancelled on
  `terminate()`.** The previous `Task.detached` was never
  stored, so rapid start/stop churn under handshake failure
  parked one worker thread per attempt on the synchronous
  `availableData` call until the kernel delivered EOF. Switched
  the read primitive to `read(upToCount:)` (throws on closed
  handle, returns nil on EOF) so close-then-cancel works
  cleanly.
- **`CoreClient.start()` TOCTOU closed.** The
  `process == nil` guard ran *before* `await
  CodeSignVerifier.verifyValid(...)`; two concurrent callers
  could both pass and both reach `process.run()`. New
  `starting: Bool` flag set before the first `await`.
- **`StopProxy` Err-path now emits `StateChanged{false}`.**
  When `supervisor.stop()` returned `Err(stop_failed)` the
  user-emit was gated on `response_succeeded == true` and never
  fired; combined with `monitor_loop`'s pre-claim of
  `emitted_stopped = true`, the orchestrator never learned the
  engine was stopped and the UI stuck on "running" indefinitely.
  Distinguishes "transition committed" (Response | Error.code
  ==`stop_failed`) from "no transition" (Error.code ==
  `not_running`).
- **Saturating arithmetic in `Subscription.validate(now:)`.**
  `nowSecs &+ UInt64(maxForwardSkew)` was wrapping; on the
  `nowSecs > UInt64.max - 60` edge a wrap would produce
  `skewCeiling ≈ 0` and *every* legitimate `issuedAt` would
  flag. Swapped to `addingReportingOverflow` saturating to
  `UInt64.max`.

### Performance

- **`SubscriptionClient` Content-Type sniff** rejects cover-site
  HTML before allocating bytes for a JSON decode pass on
  multi-MB HTML.

### UX

- **All client error types now conform to `LocalizedError`** —
  `CoreClientError`, `OrchestratorError`, `NaiveResolverError`,
  `RustCoreResolverError`, `CodeSignError`, `KeychainError`,
  `FileCredentialError`, `SubscriptionClientError`,
  `SubscriptionValidationError`. Each renamed `var
  localizedDescription` to `var errorDescription: String?`.
  Three of them had no description at all — added per-case
  English copy. The `(error as? LocalizedError)?.errorDescription`
  cast now hits every type instead of falling through to
  Swift's `"…error N."` default.

### Tests

- **`Hello`/`HelloReply`, `ProbeServer`/`ProbeReport`** wire
  round-trip tests on the Rust side — none of the new variants
  had pinning.
- **`monitor_interval_secs` clamp helper** extracted from the
  inline dispatch arm + 4 unit tests pinning `None`, in-range,
  `Some(0)`, above-ceiling behaviour.
- **`ServerAddress::parse` IPv6 cases** — 7 tests covering
  bracketed-with-port, bracketed-without-port, bare-rejected,
  unclosed-bracket, empty-host, invalid-port, junk-after-bracket,
  empty-port-suffix.

### Repository discipline (internal)

- **`ProxyMode::title()` / `ProxyTestMode::title()` removed.**
  Orphan UI helpers in a wire-only Serialize/Deserialize enum;
  the Swift mirror at `Core/Protocol.swift` carries its own
  strings and no Rust caller ever read them.
- **Doc drift.** `Subscription.swift` file-header listed 4 of
  the now-9 client checks; `core/src/lib.rs` Modules list was
  missing 6 of 10 modules; `CHANGELOG`/`SUPPORT`/`README`/
  `CONTRIBUTING` referenced the historical v0.1.7 LTSC line —
  all updated to point at the v2.0.x line.
- **`CoreClient.terminate()` comment** still said "EOF to the
  drain loop's `availableData` call" after the round-2 switch
  to `read(upToCount:)` — corrected.

### Bundled
- NaiveProxy v148.0.7778.96-2 (unchanged)
- Cool Tunnel Core v2.0.22

---

## [2.0.21] — 2026-05-06 (Connection robustness: handshake, pre-flight probe, subscription validation)

Two-phase hardening of the Swift↔Rust JSON-over-stdio bridge
and the subscription-import path. No wire-incompatible change —
old engines that lack the new `Hello` method are accepted as
legacy — but every fresh launch now performs a structured probe
before traffic flows, and every subscription manifest is
validated against the documented v1 schema before the first
profile is written. One real bug shipped along with the
robustness work: subscribers on non-default panel ports were
silently falling back to `:443`. Landed in #17.

### Added
- **`Hello` / `HelloReply` handshake (`PROTOCOL_VERSION = 1`).**
  `CoreClient.start()` runs the handshake immediately after
  spawning the engine subprocess. Engines that lack the method
  (return `invalid_request`) are accepted as legacy. A hard
  protocol mismatch surfaces
  `CoreClientError.protocolVersionMismatch` and tears the
  subprocess down before `start()` returns, so a stale engine
  never lingers behind a failed launch.
- **`ProbeServer { profile, timeout_secs }` request.** New
  `core/src/preflight.rs` runs DNS lookup + a single TCP
  connect with per-step deadlines (clamped 1–30 s; default
  5 s). Always resolves to a structured `ProbeReport` with
  `dns_resolve_ms` / `tcp_connect_ms` for both reachable and
  unreachable cases, so the UI can render timing alongside the
  failure mode rather than catching a transport exception.
  Surfaced in Swift as
  `CoreClient.probe(profile:timeoutSecs:)`.
- **`monitor_interval_secs` is configurable** on `StartProxy`
  (clamped 1–60 s; default 5 s preserved). Plumbed through
  `start_proxy` → `monitor_loop`.
- **Per-request `tracing` span.** Dispatch body wrapped in
  `tracing::info_span!("dispatch", request_id)` so every log
  line emitted under a request handler carries the Swift
  caller's `Request.id` for cross-stack correlation.
- **`SubscriptionManifestV1` schema mirror in Swift.** New
  `Core/Subscription.swift` mirrors the full ct-protocol
  manifest (`version`, `profiles[]`, `capabilities`,
  `issued_at`, `expires_at`, `note`, `signature`) plus a
  `validate(now:)` enforcing `version = 1`, non-empty profiles,
  `expires_at` in the future, and the documented 7-day
  freshness ceiling.
- **`SubscriptionClient` actor.** New
  `Core/SubscriptionClient.swift` fetches with an ephemeral
  `URLSession` (`reloadIgnoringLocalCacheData`, `urlCache=nil`,
  10 s timeout) and decodes; throws structured
  `SubscriptionClientError` cases for transport / HTTP /
  cover-site / validation failures. HMAC verification
  deliberately skipped — the panel signs with the server-only
  `APP_KEY`, so client-side HMAC is impossible. Trust anchor
  is TLS to the panel domain (Caddy + Let's Encrypt cert);
  rationale documented at the top of `Subscription.swift`.

### Fixed
- **Subscription import preserves the panel port.** The
  previous importer dropped the manifest's `port` field, so
  subscribers on non-default panels silently fell back to
  `:443`. Now serialises `host:port` straight from
  `ProfileV1`.

### Changed
- **`TunnelOrchestrator.importFromSubscriptionURL`** refactored
  to use the new `SubscriptionClient` via a private
  `translate(_:)` helper. Adds three new
  `SubscriptionImportError` cases —
  `unsupportedVersion(got:)`, `manifestExpired`,
  `manifestStale(daysOld:)` — with actionable banner copy in
  `errorDescription`.
- **Removed dead code.** The per-orchestrator private
  `SubscriptionManifest` struct (only decoded host / username /
  password) is gone; replaced by the full V1 mirror.

### Repository discipline (internal)
- **Audit schema-sync probe follows the decoder.** PR #17 moved
  the `SubscriptionManifest` decoder out of `TunnelOrchestrator`
  into `Core/Subscription.swift`; the audit step's hard-coded
  `ORCH_FILE` path didn't follow, so the v2.0.21 binary cut
  failed at `audit.sh` step 7 with four "Swift decoder missing
  field" reports even though the decoder was in place. The
  probe now greps `COOL-TUNNEL/Core/*.swift` recursively and
  is robust to future file moves within `Core/`.

### Bundled
- NaiveProxy v148.0.7778.96-2 (unchanged)
- Cool Tunnel Core v2.0.21

---

## [2.0.20] — 2026-05-06 (Xcode 26.4 macOS-SDK build hotfix)

One Swift-side build hotfix caught at the v2.0.19 binary cut.
The fix landed on `main` after the v2.0.19 tag and so is not in
the v2.0.19 release artefact — v2.0.20 ships it. No engine
change; `cool-tunnel-core` is recompiled only because the
xcodeproj `MARKETING_VERSION` and `core/Cargo.toml` advance in
lock-step (B5 anti-drift) and the bundled binary's
`--version` string is asserted by `cut_release.sh` step 8.

### Fixed
- **`textInputAutocapitalization` guarded for macOS.** The
  subscription-import field's `.textInputAutocapitalization(.never)`
  is an iOS-only `View` modifier; on the Xcode 26.4 macOS SDK the
  call trips `error: value of type 'some View' has no member
  'textInputAutocapitalization'`. The line was added in the
  v2.0.18 subscription-import UI cycle (#15) but tolerated by the
  prior SDK. Wrapped in `#if !os(macOS)` / `#endif` — semantically
  a no-op on the only target this project ships, ready for an
  eventual iOS target. Caught at the v2.0.19 binary cut, fixed
  on `main` at 50c511b but post-tag, so released here.

---

## [2.0.19] — 2026-05-06 (Engine-side validation gap closed)

One engine-layer fix that closes the audit ADR's "engine-side
validation gap" (`docs/adr/0001-audit-rules-locked-2026-05-05.md`
§Open work), plus two routine GitHub Actions version bumps from
Dependabot. No user-visible behaviour change in the Mac app —
the fix is engine-internal and matters for any caller that
bypasses the Swift Start button (CLI fixture, iOS port,
scripted test).

### Fixed
- **`validate_profile` returns a structured failure for invalid
  profiles.** Previously, an invalid `Profile` tripped serde's
  `try_from` rejection at the outer `Request` deserialiser,
  surfacing as `Outbound::Error` with `code: "invalid_request"` —
  the right shape for "you sent me bad data" but the wrong shape
  for a *probe* asking "is this profile valid?". The
  `RequestKind::ValidateProfile` variant now carries `RawProfile`
  (the unvalidated wire shape); the handler runs
  `Profile::try_from(raw)` explicitly and emits
  `Outbound::Response` with `ValidationReport { ok, reason }` in
  both the valid and invalid case. Aligns stdio mode with HTTP
  server-mode (which already returned 200 + `ok:false`) — the
  two modes had a stated divergence "by design"; that design is
  now uniform. The Swift caller at
  `TunnelOrchestrator.swift:834` already had the
  `validation.ok == false` branch coded; under the prior design
  that branch was dead code. Defence in depth for the
  empty-password class — PR #12 fixed it at the UI layer in
  v2.0.17; this closes the same gap at the engine. Wire-format
  bytes unchanged. 132 / 132 tests pass (+2 new). Fixed in #14.

### Repository discipline (internal)
- **GitHub Actions versions bumped** by Dependabot, both rebased
  past the swift-format reconciliation (#11 in v2.0.17) and
  brought current with `main` before merge:
  - `actions/checkout` v4 → v6 (#2)
  - `actions/cache` v4 → v5 (#1)

---

## [2.0.17] — 2026-05-06 (Start-button validation + audit gate locked)

One user-visible bug fix plus a repository-discipline cycle that
locks the CI gate that should have caught the drift this cycle
absorbed.

### Fixed
- **Start button now refuses to launch on an incomplete profile.**
  Previously, a profile with an empty Password (or Username,
  Server, Local Port) was still considered "selected" by the
  Start button's enabled-check, so clicking Start would spawn
  `naive` with empty credentials, the upstream would reject the
  auth, and diagnostics surfaced a generic `× upstream_via_socks`
  failure with no signal that the cause was an unfilled form
  field. Now: Start is disabled until every required field is
  filled (whitespace-trim), the tooltip names what's missing
  (`"Fill in server, username, password, and local port to
  start"`), and VoiceOver announces the same. Stop stays enabled
  while running, preserving the recovery invariant. Fixed in #12.

### Repository discipline (internal)
- **CI gate locked.** Required status checks on `main` are now
  enforced with `strict: true`: `Rust (build + clippy + test)`,
  `ShellCheck`, and `Swift (format lint)` must all be green
  before a PR can merge. Previously CI was advisory; drift
  accumulated post-merge across all three axes — this release
  absorbs that drift in one cycle.
- **Lint-floor reconciliation.**
  - `cargo fmt --all` absorbed accumulated rustfmt drift across
    `core/src/{redaction,client_mode,main}.rs` and
    `core/tests/chaos.rs`. (#9)
  - `xcrun swift-format format -i` absorbed ~40 swift-format
    violations across 13 files in `COOL-TUNNEL/{Core,
    SystemIntegration, Persistence, Views}/`. (#11)
  - `.github/workflows/ci.yml` now invokes `xcrun swift-format`
    instead of bare `swift-format` so the toolchain binary is
    found on macos-14 runners regardless of `$PATH` state. The
    Swift lint job had been silently exiting 127 on every run
    since the `--lint` step landed. (#9)
- **Script hygiene.**
  - `scripts/cut_release.sh:92` Xcode-DerivedData lookup now
    carries an explicit `# shellcheck disable=SC2012` with
    justification (path is constrained, BSD `find` lacks
    `-printf`). (#10)
  - `scripts/fetch_naive.sh` no longer rewrites
    `naive.upstream.json` when the three SHAs are unchanged —
    eliminates the permanently-dirty working tree that
    accumulated on every fetch. (#10)
- **Contributor onboarding.** `CONTRIBUTING.md` lists
  `cargo install cargo-deny` as a build prerequisite and adds
  `cargo deny check` to the local test-sweep section. (#9)
- **GitHub repo metadata.** Topics set: `proxy`, `naive`,
  `naiveproxy`, `tunnel`, `macos`, `swiftui`, `rust`,
  `censorship`.

Architecture decision recorded at
`docs/adr/0001-audit-rules-locked-2026-05-05.md`. `required_signatures`
on `main` remains deferred pending maintainer signing setup.

### Bundled
- NaiveProxy v148.0.7778.96-2 (unchanged)
- Cool Tunnel Core v2.0.17

---

## [2.0.16] — 2026-05-05 (hotfix v2.0.15: Xcode project version drift)

v2.0.15 shipped with the bundled `cool-tunnel-core` and
`Cargo.toml` correctly at 2.0.15 but the .app's Info.plist
`CFBundleShortVersionString` still at 2.0.14 — the Xcode
project's `MARKETING_VERSION` build setting wasn't bumped in
lock-step with the Rust crate. The in-app updater's
`verifyExtractedApp` (AU-7) correctly caught the mismatch and
refused to install:

>   Update failed: New app's version does not match the release
>   tag 2.0.15. Refusing to install.

This is exactly the version-drift defense AU-7 was added for —
working as intended — but the user-visible result was an
unusable update for anyone on v2.0.14 trying to upgrade. v2.0.16
is binary-identical to what v2.0.15 was supposed to be, with two
fixes:

1. `MARKETING_VERSION` in
   `COOL-TUNNEL.xcodeproj/project.pbxproj` bumped to 2.0.16 (both
   Debug and Release configurations). The .app's Info.plist
   `CFBundleShortVersionString` now matches Cargo.toml + the
   bundled Rust binary's `--version`.

2. **U#7:** `scripts/package_release.sh` now verifies the
   freshly-built .app's `CFBundleShortVersionString` matches the
   requested version BEFORE producing the .dmg / .pkg / .zip.
   Same shape as the existing U#5 check that catches stale
   bundled `cool-tunnel-core`. If `MARKETING_VERSION` is ever
   missed again, the release fails at packaging time on the
   build machine — the broken bundle never leaves it.

The v2.0.15 release page on GitHub stays as a historical
artifact; users on v2.0.14 retrying their in-app updater will
now pick up v2.0.16 (the new latest) and install cleanly.

### Bundled
- NaiveProxy v148.0.7778.96-2 (unchanged)
- Cool Tunnel Core v2.0.16

---

## [2.0.15] — 2026-05-05 (post-swap liveness probe + updater hardening)

Two fixes on top of v2.0.14: a liveness probe that closes the
last semantic gap in the no-restart hot-swap, and a
security-audit follow-up that caps the in-app Rust-core
updater's manifest fetch at 1 MB.

### Liveness probe after no-restart hot-swap (UX-F#7)

v2.0.14's `applyModeWithoutRestart` leaves naive untouched
during a Smart/Global/Local switch — the orchestrator only
reconfigures system proxy settings. The
`transitionInFlight` gate (UX-F#5) suppresses any
`stateChanged(false)` event delivered during that ~50 ms
window so the UI doesn't blink. The corner case v2.0.14 left
unguarded: if naive happens to die in that exact window
(OOM, kernel signal, panic), the suppression also hides the
genuine death — the orchestrator declares the swap
successful while naive is in fact dead. Browser stalls,
Stop button stays red.

v2.0.15 adds an explicit liveness probe:

  - new engine RPC `probe_naive_live` returns
    `{ running, pid }` from the dispatcher under the engine
    state lock;
  - `switchMode` calls `verifyNaiveLiveAfterHotSwap()` AFTER
    `applyModeWithoutRestart` succeeds, BEFORE the success
    log line. Throws on `running: false`, on engine-transport
    failure, or on any unexpected response shape;
  - the throw is caught one frame up in `switchMode`, logs at
    `.notice` to the `HotSwap` os_log category, and falls
    through to the existing full-restart path which respawns
    naive with the correct config.

The user never sees an error — the recovery path is a normal
restart that takes ~250 ms. The live log shows ONE
"switched from X to Y" line per click on either the
hot-swap path or the recovery path.

Belt-and-suspenders: the catch arm also sets
`activeProfileEdited = true` so any future code path that
re-checks the hot-swap gate sees this profile as ineligible
until the next successful `startCore`. The current call's
fallback is unconditional, so this only matters for future
refactors — but it removes a footgun.

### Updater hardening: 1 MB cap on the Rust-core manifest fetch

`RustCoreUpdater.download` previously rode the shared
`GitHubRedirectGuard.download` default of 100 MB for both
the engine binary AND the SHA-256 manifest. The manifest is
~250 bytes; capping it at 100 MB is two orders of magnitude
looser than necessary. An attacker-shaped 100 MB "manifest"
file from a compromised release-asset path would land on
disk before `SHAVerifier.expectedHash` read it into memory
via `String(contentsOf:)`.

`AppUpdater` already caps its sha256 download at 1 MB
(AppUpdater.swift:605); this brings `RustCoreUpdater` into
line. `maxBytes` is now threaded through
`RustCoreUpdater.download` (default still 100 MB so the
binary fetch is unchanged); the manifest call site passes
`1 * 1024 * 1024`.

Came out of an end-to-end audit of the updater chain. The
naive updater intentionally still has no SHA pin — the
known limitation tracked in `SECURITY.md`.

### Doc refresh

README's "Pick this .dmg if you're not sure" line — bumped
to `Cool-tunnel-v2.0.15.dmg`.

### Validation
- `cargo test --release` — 130/130 pass
- `cargo clippy ... -- -D warnings` — clean
- `xcodebuild Release` — succeeds

### Bundled
- NaiveProxy v148.0.7778.96-2 (unchanged from v2.0.14)
- Cool Tunnel Core v2.0.15

---

## [2.0.14] — 2026-05-05 (mode switch is now invisible to traffic too)

The functional companion to v2.0.13 (UX-F#5). Where v2.0.13
made the mode switch *visually* invisible (button no longer
blinks Stop→Start→Stop, picker no longer de-highlights),
v2.0.14 makes it *functionally* invisible: the underlying
naive process is no longer killed and re-spawned on every
mode switch, so in-flight TCP connections survive and apps
never see ~200-500 ms of `connection refused` during the
swap.

### Why the engine was restarting in the first place

Pre-v2.0.14, `switchMode` was implemented as `stopQuiet();
startQuiet()` — naive was sent `.stopProxy`, killed, then
re-spawned via `.startProxy` with a freshly-resolved binary
descriptor and a freshly-written config. That made sense
when modes meant fundamentally different engine
configurations, but in practice Smart / Global / Local only
differ in:

  - **system proxy configuration** (PAC URL vs SOCKS5 server
    vs nothing), which is a `networksetup` operation
    completely outside the engine; and
  - **PAC file regeneration**, which only matters when the
    new mode is Smart.

The naive process binds to `127.0.0.1:port` with the same
config in all three modes. Restarting it was wasted work that
also broke every TCP connection currently flowing through the
SOCKS5 listener.

### How v2.0.14 hot-swaps without the restart

New private path `applyModeWithoutRestart(_ newMode:)` in
`TunnelOrchestrator`:

  1. Regenerate the PAC file (only when switching *to* Smart;
     parity with `startCore`'s PAC step).
  2. Apply the system-proxy configuration via the existing
     `SystemProxyController` API
     (`enableSmartPAC` / `enableGlobalSOCKS` / `disableAll`).
     The controller already clears the opposing mode
     internally, so a switch from Smart to Global doesn't
     leak PAC settings.
  3. Update the `ProxyActiveFlag` recovery sentinel for the
     new mode.
  4. Publish `activeMode = newMode` as a single observable
     transition. naive is untouched — same PID, same
     listener, same TCP connections.

`switchMode` tries this path first. It falls through to the
existing full restart when:

  - `activeProfileEdited` is `true` (the user edited the
    running profile — naive must restart to pick up the
    edits, the same UX-F#3 banner still fires); or
  - `selectedProfileID != activeProfileID` (the user switched
    to a different profile — same reasoning); or
  - `applyModeWithoutRestart` itself throws — the fallback's
    `disableAll` cleans up partial `proxyController` state
    and `startCore` reapplies the correct config.

A new `activeProfileEdited: Bool` orchestrator flag is set by
the existing UX-F#3 detection in `selectedProfile.set` and
cleared at every successful `startCore`. Together with
`selectedProfileID == activeProfileID`, it's the gate for
"naive's running config matches the current profile".

`applyModeWithoutRestart` clears `lastError` at the top,
mirroring `startCore`'s optimistic-clear policy — a
successful mode switch should not leave the user staring at a
stale failure banner.

A dedicated `Logger.cooltunnel("HotSwap")` os_log subsystem
captures `.notice`-level diagnostics when the no-restart path
fails and we fall back. Surfaces in `log show --predicate
'subsystem == "space.coolwhite.cooltunnel" AND category ==
"HotSwap"'`.

### Behaviour matrix

|                                 | pre-v2.0.13 | v2.0.13 (UX-F#5) | v2.0.14 (UX-F#6) |
|---------------------------------|:-----------:|:----------------:|:----------------:|
| Stop button blink               | yes         | no               | no               |
| Picker lag                      | no          | no               | no               |
| Engine restart on mode switch   | yes         | yes              | **no** *         |
| In-flight TCP connections drop  | yes         | yes              | **no** *         |

\* When the active profile is unchanged. Edited-profile or
profile-switch cases still take the full restart path so
naive picks up the new config — same UX-F#3 banner fires.

### Files changed

- `COOL-TUNNEL/Core/TunnelOrchestrator.swift` — new
  `applyModeWithoutRestart` method, new `activeProfileEdited`
  flag, `switchMode` gates the no-restart path on profile
  parity, `Logger.cooltunnel("HotSwap")` for diagnostics.

### Validation

- `cargo test --release` — 130/130 pass (engine-side
  unchanged but included for completeness).
- `cargo clippy --release --all-targets -- -D warnings` —
  clean.
- `xcodebuild Release` — succeeds.
- `scripts/cut_release.sh 2.0.14` — green; all five artefacts
  emitted.
- Manual: `nc -v 127.0.0.1 1080` survives unbroken across
  rapid Smart / Global / Local clicks; `pgrep -f
  Resources/naive` stays at the same PID through the whole
  sequence; live log shows one `switched from X to Y` line
  per click.

Merged via PR #4.

---

## [2.0.13] — 2026-05-05 (mode-switch UX: no more Stop→Start→Stop button blink)

A user reported that clicking through Smart / Global / Local
modes while connected made the primary action button visibly
flicker `Stop → Start → Stop` and the live log spam
"switched from X to Y" lines as fast as they could click.
The button blink was the visible artifact of a deeper
two-step state transition the orchestrator was publishing
mid-swap.

### Root cause

`switchMode(to:)` was implemented as `stopQuiet(); startQuiet()`.
Both halves wrote to the observable `isRunning` and `activeMode`
properties:

  - `stopQuiet` wrote `isRunning = false`, `activeMode = .stopped`
    after sending `.stopProxy` to the engine.
  - `startCore` wrote `isRunning = true`, `activeMode = newMode`
    at the very end of the bring-up.

Between the two writes, SwiftUI got at least one render
opportunity (every `await` yield is a render boundary), so
the Stop button visibly flipped through "Start" and the mode
picker briefly de-highlighted every segment. The engine also
emitted `stateChanged(false)` then `stateChanged(true)` events
in response to the stop/start commands; the event handler at
`handle(event:)` *also* wrote those values to the public
state, so even when `stopQuiet` was made silent the engine
event would re-introduce the flicker.

Plus, the picker's binding read `orchestrator.activeMode`
while running and `pendingMode` while stopped — so once the
orchestrator stopped flickering through `.stopped`, the
picker became *laggy* (showed the old mode for the full
duration of the engine restart) instead of jumping to the
clicked mode.

### Fix (UX-F#5)

Three coordinated changes so the user perceives a single
instant transition:

  1. **`stopQuiet(publishStoppedState: Bool = true)`** — added
     a parameter that suppresses the `isRunning` /
     `activeMode` flips. `switchMode` calls with `false`. All
     legacy callers default to `true` and behave as before.

  2. **`handle(event:)` — `stateChanged` early-return when
     `transitionInFlight`** — the engine's stop/start events
     during a hot-swap arrive as separate `stateChanged`
     frames; we ignore them while `switchMode` owns the
     public state. The natural-death recovery banner stays
     intact for `stateChanged(false)` events that arrive
     outside a transition (genuine naive crashes).

  3. **`ControlPanelView.modeBinding.get` reads `pendingMode`
     directly** — the picker reflects the clicked mode
     instantly instead of waiting for `activeMode` to catch
     up at the end of the engine restart. The existing
     `.onChange(of: orchestrator.activeMode)` handler keeps
     `pendingMode` in sync when the running mode changes
     from another surface (menu-bar tap, deep-link).

Failure recovery: if `startQuiet` throws after a successful
`stopQuiet(publishStoppedState: false)`, the engine is
genuinely dead — `switchMode` restores truthful state
(`isRunning = false`, `activeMode = .stopped`) before
re-throwing. The UI must not lie about a non-running engine.

### Files changed

- `COOL-TUNNEL/Core/TunnelOrchestrator.swift` — `switchMode`,
  `stopQuiet`, and the `stateChanged` event handler.
- `COOL-TUNNEL/Views/ControlPanelView.swift` — picker binding
  + doc comment.

### Validation

- 130/130 Rust tests pass (no engine-side change; included
  for completeness).
- `cargo clippy -- -D warnings` clean.
- Build succeeds.

User-visible effect: clicking Smart / Global / Local now
keeps the Stop button rock-stable in red, and the picker
segment flips to the clicked mode within a frame. The single
"switched from X to Y" log line still appears. Engine
restart still happens behind the scenes — that's a separate
optimization tracked for a future cycle (mode-switch could
eventually skip the restart entirely since naive's bound
port and config don't change between modes).

---

## [2.0.12] — 2026-05-05 (logic-integrity sweep: validate_profile semantics + clippy clean)

The v2.0.7 → v2.0.11 stretch was an **industrial-hardening**
arc: relaunch-stuck watchdog, .pkg admin-elevation, .pkg
poka-yoke gate, LaunchServices cache flush. Each fix made the
update *path* more robust under hostile filesystem and OS
state. v2.0.12 closes that arc and shifts focus to **logic
integrity** — the *engine's* contracts now match the tests
that describe them, and the lint baseline is clean again.

### Two fixes, both behind the wire

#### 1. `validate_profile` rejects invalid profiles at deserialization

The stdio test
`tests/protocol_roundtrip.rs::rejects_invalid_profile_during_deserialization`
had been failing on `main` since v0.1.7.16 (Rust-F#1). The
test sends a `validate_profile` request with `localPort: "0"`
and expects an `Outbound::Error` frame with code
`invalid_request`. Instead the engine returned a *successful*
`Outbound::Response` carrying
`ValidationReport { ok: false, reason: "invalid profile" }`.

**Root cause:** the v0.1.7.16 change moved
`RequestKind::ValidateProfile` to carry an unvalidated
`RawProfile` so the dispatcher could surface the `ok: false`
branch of `ValidationReport`. That design fits the HTTP server
mode (SM-3 — clients want a uniform 200-with-payload), but
stdio mode treats every "you sent me bad data" as an
`Outbound::Error`. The test was written for the original
"fail at serde-deserialize" behavior and never updated.

**Fix:** revert `ValidateProfile`'s wire variant to carry a
fully-validated `Profile`. Validation runs at serde
deserialization through Profile's `try_from = "RawProfile"`
attribute, so an invalid profile fails the outer
`from_value::<Request>` call upstream and emits an
`invalid_request` error frame. The dispatcher arm collapses
to a clean unconditional `Ok(ValidationReport { ok: true,
reason: None })`.

`server_mode.rs` (HTTP `/naive/validate`) is **unchanged** —
it still returns 200-with-`ok:false` per SM-3, deliberately
diverging from stdio. Doc comments on both sides now spell
out the divergence.

Merged via PR #3.

#### 2. Clippy `-D warnings` baseline restored

A newer Rust toolchain pedantic-lint update added two checks
that triggered in `core/src/server_mode.rs`:

- `clippy::needless_pass_by_value` on
  `ApiError::from_json_rejection` — body only used `err` for
  `tracing::warn!(error = %err, …)` (Display via reference).
  Switched to `&JsonRejection`; updated the two `map_err`
  call sites to pass a reference.
- `clippy::doc_overindented_list_items` on the `naive_validate`
  doc — the `Err(e) →` bullet's continuation was indented 16
  spaces past `///`. Reduced to 5 spaces so the continuation
  aligns with the bullet's text-start (standard markdown rule).

`cargo clippy --release --all-targets -- -D warnings` now
exits 0.

### Validation

- `cargo test --release` — **130/130 pass** (was: 129/130 with
  `rejects_invalid_profile_during_deserialization` failing on
  v2.0.11).
  - lib unit tests: 104/104
  - chaos: 18/18
  - protocol_roundtrip: 6/6 (the previously-failing test is
    now green)
  - doc tests: 2/2
- `cargo clippy --release --all-targets -- -D warnings` — clean.
- Full release pipeline (`scripts/cut_release.sh 2.0.12`) —
  green: universal binary built, `--version` reports 2.0.12,
  bundled naive verified against upstream pin, all four
  artefacts + sha256 manifest emitted.

### Files changed

- `core/src/protocol.rs` — `RequestKind::ValidateProfile`
  variant + doc comment.
- `core/src/client_mode.rs` — dispatcher arm simplified;
  unused `Profile` import dropped.
- `core/src/server_mode.rs` — `from_json_rejection` takes
  `&JsonRejection`; doc list continuation re-indented.
- `core/Cargo.toml`, `core/Cargo.lock`, project.pbxproj —
  version 2.0.11 → 2.0.12.

---

## [2.0.11] — 2026-05-05 (lsregister fix: app no longer shows old version after in-app update)

After updating via the in-app updater (especially from a
`.pkg`-installed, root-owned bundle), restarting the app
from the Dock showed the old version instead of the newly
installed one.

**Root cause:** the relaunch helper swaps the bundle via an
`mv`-pair — old → `.old-update`, staged → `$OLD_APP`. The
inode at `$OLD_APP` changes; LaunchServices may retain a
stale cache entry for the old inode and serve the cached
(old) bundle metadata on the next `open` from the Dock or
Finder, even though the correct new `.app` is on disk.

**Fix:** the relaunch script now calls

```bash
lsregister -f "$OLD_APP"
```

immediately after the chown (admin-elevated path) / bundle
swap (regular path), before the `open`/`launchctl asuser open`.
`-f` forces LaunchServices to invalidate and rebuild its
database entry for that exact path, so subsequent opens
always get the freshly installed bundle.

On the admin-elevated path (`launchctl asuser`) the call
is routed through `launchctl asuser ${ORIG_UID}` so the
*user-scoped* LaunchServices database is updated — running
`lsregister` as root alone would leave the per-user database
stale. Falls through silently if the binary is absent
(should never happen on stock macOS; it ships with the OS).

### Files changed

- `COOL-TUNNEL/SystemIntegration/AppUpdater.swift` — step 5
  of the relaunch script.

---

## [2.0.10] — 2026-05-05 (.pkg installer poka-yoke: blocks when app is running)

A user asked for a poka-yoke (mistake-proof) gate on the
manual `.pkg` installer: if Cool Tunnel is currently running,
the installer should refuse to proceed and ask the user to
quit the app first. Pre-2.0.10 the installer would happily
try to overwrite the running bundle, with two failure modes:

  1. macOS refuses (text-busy / EACCES on the executable
     segment), leaving the user with a partially-replaced
     bundle and no clear path forward.
  2. The bundle WAS replaced but the running process
     continues with the old code in memory; the user thinks
     they're on the new version but the still-running
     instance is the old one, until they happen to relaunch.

### How the gate works

The .pkg is now a **distribution package** (built with
`productbuild --distribution …`) wrapping the existing
component. The distribution descriptor carries an
`installation-check` JavaScript that runs *before* any
install action:

```javascript
function cool_tunnel_install_check() {
    var status = system.run("/usr/bin/pgrep", "-x", "Cool Tunnel");
    if (status === 0) {
        // App is running → block the install.
        my.result.title = "Cool Tunnel is running";
        my.result.message = "Please quit Cool Tunnel and re-open this installer to continue. ...";
        my.result.type = "Fatal";
        return false;
    }
    return true;
}
```

`pgrep -x "Cool Tunnel"` matches the exact executable name
(`Contents/MacOS/Cool Tunnel`, set by `PRODUCT_NAME` in
pbxproj). Exit status 0 means a match was found ⇒ block;
non-zero means safe to install.

If `pgrep` itself fails to launch (vanishingly rare on stock
macOS — it ships with the OS), the check **falls through to
allow** rather than block. Better to let the user proceed
than to permanently brick the installer behind a check we
can't run reliably.

### What changed in the build pipeline

- **New file:** `scripts/Distribution.xml.template` carrying
  the JS check. Note that XML forbids double hyphens inside
  comments, so the file uses pipes (`|`) instead of em-dashes
  in prose; rephrasing to use double hyphens would make
  `productbuild` reject the file.
- **`package_release.sh` reworked:** the .pkg step now does
  `pkgbuild` → component, `awk` substitutes `{{VERSION}}`
  into the template, then `productbuild --distribution …`
  emits the final wrapper.
- **Output identifier unchanged** (`space.coolwhite.cooltunnel.pkg`)
  so a productbuild-signed update still upgrades in place
  rather than installing alongside.

### Combination with v2.0.9 admin-elevated in-app updates

The two paths are complementary, not redundant:

- **v2.0.9 in-app updater:** handles the "Cool Tunnel is
  already running and the user clicks Update inside it" case
  by routing the install through `osascript … with
  administrator privileges` and a `launchctl asuser` relaunch.
- **v2.0.10 .pkg installer gate:** handles the "Cool Tunnel
  is running and the user double-clicks a downloaded .pkg in
  Finder" case by blocking with a clear message before any
  install action. After quitting and re-opening the installer,
  the .pkg installs normally.

## [2.0.9] — 2026-05-05 (.pkg-installed bundles can now self-update)

A user reported that the in-app Update button on a
.pkg-installed Cool Tunnel showed:

> Cool Tunnel was installed via the .pkg installer, so its
> bundle is owned by root. The in-app updater can't get past
> that without admin auth. To self-update from here on:
> 1. Quit Cool Tunnel.
> 2. Drag /Applications/Cool Tunnel.app to the Trash (you'll
>    be asked for admin password).
> 3. Reinstall by dragging Cool Tunnel from the .dmg or .zip
>    into /Applications.

That's a bad UX. The user already cleared one admin-auth gate
when running the .pkg installer, and what they really want is
an in-app update path that handles the second gate the same
way every other privileged macOS operation does — by showing
the standard system authorisation dialog.

### Auto-update now handles root-owned bundles

`refuseReadOnlyInstall` is renamed to `preflightInstallability`
and now **returns** `needsAdminElevation: Bool` for the
root-owned case instead of throwing. When the flag is set,
`spawnRelaunchHelper` routes the install through:

```
osascript -e 'do shell script "/bin/bash <wrapper>"
              with prompt "Cool Tunnel needs to update its
              application bundle. (It was originally installed
              via the .pkg installer, so the bundle is owned
              by root.)"
              with administrator privileges'
```

The user sees the standard macOS authorisation sheet (Touch
ID / password / Apple Watch). After authorisation:

1. The privileged **wrapper** script runs as root, `nohup`s
   the real relaunch helper into the background, and exits
   fast — so `osascript` returns to the parent within a
   second or two instead of blocking 30+ s on the parent-PID
   wait. If the user cancels the dialog, `osascript` exits
   non-zero and Cool Tunnel surfaces a friendly "Update
   cancelled" message and stays running.
2. The **real helper** (now running as root, detached, parent
   = launchd) waits for Cool Tunnel to exit, performs the
   atomic ditto/mv/mv swap exactly like the user-owned path,
   and then runs two extra steps:
   - `chown -R ${ORIG_UID}:staff "$OLD_APP"` — restores
     ownership to the user, so **subsequent updates take the
     regular no-prompt path**. The .pkg → first-update
     transition is the only time the password dialog appears.
   - `launchctl asuser ${ORIG_UID} open "$OLD_APP"` — relaunches
     the new copy in the user's GUI session, NOT as root.
     A bare `open` from a root process would launch the new
     instance as root — which would mangle TCC grants and
     keychain access.
3. `ORIG_UID` is captured from `getuid()` in the parent app
   (Swift) and interpolated into the script. Reading it
   inside the privileged shell isn't safe — `id -u` returns
   `0` there.

### What stays the same

- **chflags-locked bundle** (Get Info → Locked, or
  `chflags uchg`) still throws — admin elevation can't fix
  that, the user really does need to unlock it.
- **Bundle owned by another non-root user** still throws —
  weird state, deserves manual investigation rather than a
  silent ownership change.
- **Read-only volume / parent-not-writable for user-owned
  bundle** still throws.
- The user-owned (regular .dmg/.zip-installed) path is
  byte-identical to v2.0.8: no osascript, no extra prompt,
  just the existing detached `bash` spawn.

The `osascript`'s `with prompt` parameter customises the
dialog text so the user sees Cool Tunnel-specific copy
explaining what's about to happen, rather than the generic
"osascript wants to make changes" string.

## [2.0.8] — 2026-05-05 (UI compaction + appearance scroll-jump fix)

Two surfaced-by-screenshot fixes shipped together.

### 1. The whole upper-window chrome collapses to one row

A user screenshot showed the upper-middle of the main window
was nearly all blank. The status row (`● Not connected` /
`Pick a mode below to connect.`) sat on its own line above
the controls row (mode picker + Start + secondary buttons),
and the firewall warning pill lived in a third corner of the
header. Three separate rows of chrome before the form even
started. The subtitle ("Pick a mode below to connect.")
narrated an action whose UI sat three pixels below it.

**Fix:** the entire header is now a **single horizontal row**:

```
●  Not connected    [Smart│Global│Local]    ▶ Start  ⚕  ⏱⌄  ⚙   [⚠ Firewall on]
```

- `HeaderView` is split into `HeaderStatusPill` (single-line
  dot + headline) and `FirewallBadge` (separately placeable),
  both `public` so the parent composes them.
- The "Pick a mode below to connect." subtitle is **dropped**
  — the mode picker is the action it was instructing.
- `ControlPanelView` drops its internal flexible `Spacer`
  between picker and buttons; those now form a tight
  primary-action cluster.
- The mode picker tightens from `maxWidth: 260 → 220` so the
  whole row fits at the 780-pt window minWidth even with the
  firewall badge on.
- The top-pane `minHeight` drops `360 → 320` since the
  reclaimed vertical space is real.

The error banner still appears under the merged row when
`lastError` is non-nil — that surface didn't change.

### 2. Changing Appearance no longer scrolls Settings to the top

A user reported that tapping Match System / Light / Dark in
**Settings → Appearance** dumped the Settings ScrollView back
to the top, losing whatever section they were reading.

**Root cause:** v2.0.5's `conditionallyPreferredColorScheme`
helper used an `if let scheme { … } else { self }` branch.
Toggling between Match System (nil) and Light/Dark switched
which branch was taken, which counts as a view-tree
*structural* change to SwiftUI — every subtree below it,
including the SettingsView's ScrollView, got rebuilt and
lost its scroll position. Even toggling between Light and
Dark within the `if` branch was enough to re-evaluate the
modifier and cause the same churn.

**Fix:** v2.0.8 drives appearance through **`NSApp.appearance`**
(AppKit-level) instead of `.preferredColorScheme(_:)`
(SwiftUI structural). `ContentView.body.task(id:
appearanceMode)` calls a new `applyAppearance(_:)` that
sets:

- `.system` → `NSApp.appearance = nil` (follow system, the
  AppKit-native equivalent of "Match System")
- `.light` → `NSApp.appearance = NSAppearance(named: .aqua)`
- `.dark` → `NSApp.appearance = NSAppearance(named: .darkAqua)`

Cocoa propagates the resolved appearance to every NSWindow
through `effectiveAppearance`. The SwiftUI view tree is
**not rebuilt** because no view structure changed — only the
resolved colours. The Settings ScrollView keeps its scroll
position across every appearance toggle.

This also lets us delete the `conditionallyPreferredColorScheme`
View extension v2.0.5 added — the AppKit-native path
sidesteps the `nil ≠ "follow system"` SwiftUI bug entirely
without needing the conditional-modifier workaround.

## [2.0.7] — 2026-05-05 (relaunch-stuck hotfix)

Single-issue hotfix on top of v2.0.6.

### Update flow could stall at "Relaunching…"

After a successful in-app update, the UI transitioned to
`.relaunching` ("The app will close in a moment.") and
called `NSApp.terminate(nil)`. AppKit's
`applicationShouldTerminate` returned `.terminateLater` and
spawned a real shutdown Task plus a 5-second watchdog Task
to fire `NSApp.reply(toApplicationShouldTerminate: true)`.

In rare conditions — most commonly an in-flight URLSession
holding the run loop, or a window-close animation racing
the reply — neither Task fired soon enough and the process
never exited. The relaunch helper kept waiting on our PID,
the user saw the spinner stuck indefinitely, and only
Force Quit recovered.

**Fix (`SystemIntegration/AppUpdater.swift`):** schedule a
`Task.detached` immediately before `NSApp.terminate(nil)`
that calls `Darwin.exit(0)` after **8 seconds**,
unconditionally. The clean shutdown path still has every
chance to win (5 s watchdog, 8 s hard exit), and any
system-proxy state we'd normally clean up in
`orchestrator.shutdown()` is recovered by the
`recoverFromCrashIfNeeded` sweep on next launch — exactly
the same path that handles a real crash.

The detached Task does not depend on the MainActor or any
SwiftUI run loop, so it fires even if the main thread is
fully stuck.

### Recovery for users currently stuck on v2.0.6

If you're reading this from a stuck v2.0.6 "Relaunching…":

1. Force Quit Cool Tunnel.
2. Relaunch — the `recoverFromCrashIfNeeded` sweep clears
   any leaked system-proxy state.
3. Settings → Cool Tunnel → Update → install v2.0.7.

## [2.0.6] — 2026-05-05 (resizable Live log + release-pipeline hygiene)

Two changes shipped together:

### 1. Live log no longer hides the Server form

The four panes used to live in a single `VStack`. Live log
had `frame(minHeight: 220)` but no upper bound, so on a tall
window it ate every extra pixel — the Server form's
Password and Local-port rows plus the explanatory footer
disappeared off the bottom of the window with no scroll.

**Fix:** switched the main layout to `VSplitView`, which
gives the user a draggable divider between the Form pane
(top) and the Live log (bottom). Pull the divider down to
surface the hidden Server rows; pull it up for live-tail
use. Both halves keep their own internal scrolling within
the user-chosen split.

- Top pane minimum: 360 pt (room for header + control row
  + four Server form rows + footer text without truncation).
- Bottom pane: 80 pt minimum, 220 pt ideal, no max — the
  user resizes freely above the floor.

### 2. `scripts/cut_release.sh` — single-command release prep

Pre-2.0.6 the release flow was implicit: a developer was
expected to run `fetch_naive.sh`, `cargo clean`, bump
versions, build Release, then `package_release.sh`. Skip
any step and you ship a release with stale bundled binaries
— exactly the *"the apps bundle has 2.0.3 inside a 2.0.5
.app"* surprise the user reported.

**New:** `scripts/cut_release.sh <VERSION>` runs every
freshness step in order with hard preconditions:

1. `scripts/fetch_naive.sh` — pulls latest upstream naive
   into `COOL-TUNNEL/naive` and updates
   `naive.upstream.json`.
2. `cargo clean` in `core/` — guarantees the next Xcode
   build cannot reuse stale rust artefacts.
3. Verify `core/Cargo.toml` matches the requested version
   (refuse to proceed otherwise).
4. `cargo update -p cool-tunnel-core` — refreshes
   `Cargo.lock` for the new version.
5. `xcodebuild Release` — Xcode's Build Rust core run
   script phase now produces a fresh universal cool-
   tunnel-core because step 2 cleared the cache.
6. Verify the freshly-built bundled cool-tunnel-core's
   `--version` matches the requested version.
7. Verify the bundled naive's SHA-256 matches the pinned
   manifest in `naive.upstream.json`.
8. Hand the .app to `package_release.sh`, which runs its
   own preconditions and emits the .dmg / .pkg / .zip /
   core-binary / .sha256.

After this completes, `dist/Cool-tunnel-v…` is ready to
upload via `gh release create`.

---

## [2.0.5] — 2026-05-05 (hotfix bundle: AppUpdater pre-flight + Match System appearance)

Three issues found in user testing of v2.0.4:

### 1. "Match System" appearance stayed locked dark/light

`.preferredColorScheme(nil)` does NOT mean "follow system" the
way the docs suggest on macOS — once the modifier has been
applied with a concrete `.light` or `.dark` and then re-applied
with `nil`, the scheme stays *locked* at whatever was last
concrete. Users picked Match System and the app stayed in the
previous mode regardless of their System Settings → Appearance.

**Fix:** new `conditionallyPreferredColorScheme(_:)` view
helper that simply DOES NOT apply the modifier when the value
is `nil`. SwiftUI then follows the window's `NSAppearance`
dynamically, which is what Match System should always have
done.

### 2. AppUpdater pre-flight kept rejecting writable bundles

The v2.0.3 `Darwin.access(W_OK)` check was over-restrictive on
macOS 14+ — even after the user toggled Cool Tunnel ON in
System Settings → Privacy & Security → App Management,
`access(W_OK)` kept returning `false` (TCC permission grants
don't consistently propagate to `access(2)` syscalls in the
running process until the process is restarted, and even then
sometimes not). The user got the same error after taking every
step the message recommended.

**Fix:** removed the `access(W_OK)` pre-flight. The pre-flight
now only catches conditions we can prove block the install:
- `chflags uchg|schg` (Locked checkbox / immutable flag)
- root-owned bundle (`.pkg`-installer leaves the app owned by
  root, blocks user-level `mv`)
- bundle owned by another non-root user (rare; user-rename
  edge case)

Anything else (App Management TCC residue, exotic ACLs) is now
trusted to surface from the relaunch helper's actual `mv`/`ditto`
call, which logs to `~/Library/Logs/cool-tunnel-relaunch.log`.

### 3. Update-failed banner truncated multi-line guidance

The .pkg-ownership recovery message has multiple steps; the
existing UI capped the error banner at 3 lines (`lineLimit(3)`)
and gave only a Dismiss button. The user couldn't read past
"...installed via the .pkg installer..." before the message
hit the truncation.

**Fix:** raised `lineLimit` to 12, restructured the banner as
a `VStack` with a button row, and added a **"Reveal in Finder"**
button next to Dismiss — one click takes the user to the
bundle they need to drag to Trash for the manual reinstall.

### Carved out

- Deep-link to System Settings → Privacy & Security → App
  Management. The error message now mentions the full path
  textually; a one-click button is a 2.1 nicety.
- Privileged-helper architecture (Sparkle-style `SMJobBless`
  for self-update of root-owned bundles) — substantial
  architecture change; deferred.

---

## [2.0.4] — 2026-05-05 (hotfix — phantom spinner next to "You're on the latest version")

The Settings → Naive Binary and Settings → Rust Core sections
left a small `ProgressView` spinner permanently spinning next
to the "You're on the latest version (X)" text after a
successful Check. Cosmetic — the check itself completed; just
the indeterminate-progress glyph never went away.

### Cause

`updaterRow` and `rustUpdaterRow` both render a leading
`ProgressView` whose `.frame(width: 80)` slot uses an inner
switch over `updater.state`. v2.0.2 added the new `.checking
/ .upToDate / .available` states but only added their text
to `updaterMessage` — the row's `case .succeeded, .failed,
.idle: EmptyView()` arm wasn't extended, so `.upToDate` and
`.available` fell into the `default: ProgressView()` arm.
`.upToDate` and `.available` are *resting* states (the check
finished; nothing's in flight), so they should render no
spinner.

### Fix

Add `.upToDate, .available` to the `EmptyView` arm of both
`updaterRow` and `rustUpdaterRow`. Two lines.

After 2.0.4, the row renders just the message ("You're on
the latest version (X).") with no leading spinner.

---

## [2.0.3] — 2026-05-05 (hotfix — false-positive "bundle is locked" on Update)

`AppUpdater.refuseReadOnlyInstall` over-reported "Cool Tunnel's
bundle is locked. Right-click → Get Info → uncheck Locked"
because it leaned on `URLResourceKey.isWritableKey`, which
returns `false` for a *superset* of conditions:

- the actual Locked-checkbox / `chflags uchg|schg` case (the
  one the message addresses),
- ACL inheritance and POSIX-mode quirks left by Time Machine
  restores,
- macOS 14+ App-Management TCC denials,
- some signed-bundle metadata states on Sequoia.

Users without an actually-locked bundle saw a hint pointing at
a checkbox they'd find already unchecked.

### Fix

- **Probe `chflags` directly** via `lstat` + `st_flags &
  (UF_IMMUTABLE | SF_IMMUTABLE)`. This is authoritative for
  the Locked-checkbox case; the message stays accurate when
  it fires.
- **Fall back to `access(W_OK)`** for non-chflags causes (ACL,
  TCC, mode bits). New, separate error message: "Cool Tunnel
  can't modify its own bundle. On macOS 14 and later, open
  System Settings → Privacy & Security → App Management and
  turn on Cool Tunnel. If you've already done that — or if
  you're on an older macOS — move the app to /Applications
  and try Update again."
- **Drop `URLResourceKey.isWritableKey` from the bundle-level
  check.** The parent-folder check still uses it (where the
  semantics are clean enough).

After 2.0.3, you only see the Locked-checkbox hint when there
is actually a Locked checkbox to uncheck.

---

## [2.0.2] — 2026-05-05 (Check-then-update for naive + rust core)

`NaiveUpdater` and `RustCoreUpdater` now mirror `AppUpdater`'s
check-then-update pattern. Pre-2.0.2 every "Update" click did
a full download regardless of whether you were already on the
latest — clicking "Update again" on naive pulled the same
binary again because upstream's `-N` patch suffix re-tags the
unchanged naive build, and the user-visible verdict pill never
moved.

### Bug surface

- "Update again" button (naive + rust core) always fired a
  fresh download. For naive specifically: upstream tags like
  `v148.0.7778.96-2` re-publish the same naive binary under a
  new tag suffix, so the download produced cosmetically
  different bytes (different upstream packaging) but the
  binary's `--version` stayed at `148.0.7778.96`. Wasteful,
  confusing, and caused the verdict pill to never look
  "settled."

### Fix

- **New states on both updaters:** `checking` /
  `upToDate(currentVersion:latestTag:)` /
  `available(tag:currentVersion:)`. State machine still
  monotonic — in-flight checks/updates can't be clobbered.
- **New method `checkForUpdates(currentVersion:)` on both
  updaters.** Resolves the latest tag (one HTTP GET, no
  binary fetch) and compares against the binary's `--version`
  via `tagIsConsideredCurrent(_:forBinaryVersion:lastInstalled:)`.
  Two paths qualify as "current": exact tag match against
  the persisted `lastInstalledTag`, OR semver match after
  stripping `v` prefix and `-N` suffix from the tag.
- **`lastInstalledTag` persisted in `UserDefaults`** on both
  updaters (keys `NaiveUpdater.lastInstalledTag` and
  `RustCoreUpdater.lastInstalledTag`). Without persistence,
  every relaunch would falsely report "Update available"
  against an upstream patch tag the user already installed.
- **`NaiveUpdater.update()` reuses the resolved tag from
  `.available`.** Saves one HTTP roundtrip in the typical
  Check → Update flow.
- **SettingsView morphing button + subtitle** for both naive
  and rust core sections, mirroring AppUpdater:
  - `Check for Updates` (idle / upToDate / failed / succeeded)
  - `Checking…` (in-flight)
  - `Update to <tag>` (available)
  - `Resolving… / Downloading… / Extracting… / Merging… /
    Installing…` (pipeline phases)
  - Subtitle reads `You're on the latest version (X)` when
    `.upToDate`, exactly like AppUpdater.

### Carved out

- `NaiveUpdater.update()` and `RustCoreUpdater.update()`
  paths still allow direct invocation (no Check first) for
  back-compat with any future "force update" flow. The
  Settings UI no longer routes there directly.

---

## [2.0.1] — 2026-05-05 (hotfix — Rust core version drift + updater verification)

Hotfix on top of v2.0.0. Three findings closed, one user-facing
bug, two preventive.

### Bug fix

- **`core/Cargo.toml` was never bumped from `0.1.7`.** The
  Rust binary in v2.0.0's `cool-tunnel-core-v2.0.0-universal`
  asset self-reported `cool-tunnel-core 0.1.7` because that's
  what `env!("CARGO_PKG_VERSION")` resolved to at compile
  time. Settings → Rust Core → Update on a v2.0.0 install
  appeared to "succeed" (download + SHA-256 match passed) but
  the verdict pill kept showing 0.1.7. Cargo.toml is now at
  `2.0.1`; the rebuilt binary self-reports correctly. **U#1**

### Updater hardening (catches future drift)

- **RustCoreUpdater post-install `--version` verification.**
  After `atomicallyInstall`, the updater now runs the new
  binary's `--version` and refuses to enter `.succeeded` if
  the self-reported semver doesn't match the release tag's
  semver. Pre-2.0.1, the updater trusted the SHA-256 match —
  which proves byte integrity but says nothing about whether
  those bytes were built from a `Cargo.toml` matching the
  tag. The new check would have caught v2.0.0's drift at
  install time, surfacing a clear error instead of letting
  the user discover it via the verdict pill. **U#2**

### Build-pipeline hardening (catches drift at packaging)

- **`scripts/package_release.sh` Cargo.toml precondition.**
  At the top of the script: parse `core/Cargo.toml`'s
  `version` field and exit with a clear error if it doesn't
  match the version arg. Would have rejected v2.0.0's
  packaging run with "core/Cargo.toml version is '0.1.7' but
  you requested '2.0.0'." **U#6**

- **`scripts/package_release.sh` Resources/cool-tunnel-core
  precondition.** Verify the .app's bundled engine binary
  self-reports the requested version too (catches the case
  where Cargo.toml was bumped but the .app wasn't rebuilt
  from it). **U#5**

### Carved out for a future release

- **U#3** (Settings UI shows two version sources without
  reconciliation) — addressed in part by U#2's fail-fast
  posture; the conflicting display will go away naturally
  once a release ships with mismatched versions blocked at
  install time. Pure-UI reconciliation pass deferred.
- **U#4** (NaiveUpdater has the same "tag-only success"
  shape as RustCoreUpdater pre-2.0.1) — naive is upstream-
  authoritative (klzgrad publishes binary == tag) so the
  divergence is very unlikely. Symmetry fix deferred.
- **U#7** (`lastInstalledTag` short-circuit) — minor;
  bandwidth optimisation only.

---

## [2.0.0] — 2026-05-05 (full identity rebuild — first-class macOS app)

Major version. The v0.1.x line was a custom-painted experiment;
v2.0 is what the same app looks like when every surface is built
from the platform's own primitives. **27 files changed, +1479 /
−1199**, with the entire `MalteseTheme.swift` palette module
removed.

The transformation was driven by a third-party UX audit applying
Apple's editorial bar and a forensic-pass engine/lifecycle audit.
Every P0 and P1 finding from both audits is closed; P2 went from
0 / 12 to 12 / 12.

### Engine + lifecycle (Phase 2.0.x)

- **Engine errors no longer swallowed on Start.** `startCore` is
  now wrapped in a do/catch that publishes any thrown failure to
  `lastError` via `recordError(...)` before re-raising. Pre-2.0,
  view callers had empty catch blocks expecting `lastError` to
  carry the surface — but no path inside `startCore` ever set it
  on failure, so a port collision produced silent UI on the
  click of a mode chip.
- **Phantom "naive stopped unexpectedly" banner gone.** New
  `userStopInFlight` flag set during `stop()` / `stopQuiet()`
  suppresses the recovery branch in
  `handle(event:).stateChanged(false)` while the user's
  intentional shutdown is mid-flight.
- **Menu-bar / window race covered.** The new menu-bar Stop
  routes through `switchMode(.stopped)` so the existing
  `transitionInFlight` guard catches concurrent lifecycle
  transitions.
- **Orphan-naive sweep on launch.** `recoverFromCrashIfNeeded`
  now `pgrep -x naive` + filters PIDs whose parent is launchd
  (PID 1) → SIGTERM → 500 ms grace → SIGKILL. If the previous
  run died with naive holding port 1080, the next launch is
  deterministic.
- **Structured logging across the failure path.** Every
  formerly-empty `catch` in `ControlPanelView` /
  `MenuBarStatusContent` / `LogConsoleView` / `HeaderView` now
  traces through `Logger.cooltunnel("UI.X")` under one
  `subsystem == "space.coolwhite.cooltunnel"` umbrella.

### Brand normalization

- **`PRODUCT_NAME` flipped to `Cool Tunnel`.** Bundle on disk
  renames from `Cool tunnel.app` → `Cool Tunnel.app`; binary
  inside `Contents/MacOS/` renames likewise; `CFBundleName`,
  `CFBundleDisplayName`, App-menu items, and the About panel
  all read `Cool Tunnel` consistently. Bundle identifier
  (`space.coolwhite.naive`) is unchanged so
  `refuseIfMultipleInstalls` still works across the rename.

### Settings contract

- **Removed the `draft: AppSettings` indirection.** Every
  Settings field binds directly to `orchestrator.settings.X`
  via `@Bindable`; a single form-level
  `.onChange(of: bindable.settings)` fires the orchestrator's
  debounced `persistSettings()` on any mutation. `commit()`
  replaced with `dismiss()` that calls `flushSettings()` so a
  Cmd+W followed immediately by Cmd+Q cannot drop the user's
  last keystroke.
- **`⌘,` / "Settings…" menu item** wired through a new
  `CommandGroup(replacing: .appSettings)` that flips the
  inline panel via `NotificationCenter`.

### Menu bar

- **First-class `MenuBarExtra` status item.** Glyph driven by
  orchestrator state (`arrow.up.right.circle` /
  `arrow.up.right.circle.fill` /
  `exclamationmark.triangle.fill`).
- Flat mode rows (Smart / Global / Local) replaced the
  redundant Start-button-plus-Mode-submenu pair. Stop only
  rendered when running. ⌘0 opens window, ⌘, opens Settings,
  ⌘Q quits.

### Visual identity

- **Mode-aware pastel-gradient window background gone.** System
  `.windowBackground` material everywhere; Light / Dark /
  Increased Contrast resolved by AppKit.
- **`HeaderView`** rewritten as a quiet status row — semantic
  colour dot + headline + subtitle. No card, no gradient.
- **`ControlPanelView`** uses real `Picker(.segmented)` for
  mode + `.borderedProminent` Start/Stop with semantic tint.
- **`ConnectionFormView`** is now
  `Form { Section { … } }.formStyle(.grouped)` with standard
  `TextField` / `SecureField` / `Picker` rows.
- **`LogConsoleView`** uses `.regularMaterial` surface with
  `.separatorColor` hairline; `.red` for stderr; `.bordered`
  Clear button.

### Big Sur+ icon

- New procedural icon stack generated by
  `scripts/generate_app_icon.swift` — squircle backdrop with
  cool-blue gradient, three concentric tunnel rings with
  one-point perspective vanishing toward upper-right, bright
  vanishing-point highlight. All 13 sizes (16 px through
  1024 px @1× and @2×) regenerated from one master.

### Firewall deep-link

- The orange "Firewall on" capsule is now a Button that opens
  `x-apple.systempreferences:com.apple.preference.security?Firewall`
  via `NSWorkspace.shared.open`. Two-tier fallback to the
  System Settings root if the pane URL is rejected. Closes the
  audit's "warning with no recourse" finding.

### Open at Login

- New `LoginItemRow` in Settings → Behaviour, backed by
  `SMAppService.mainApp`. Renders `.notRegistered` /
  `.enabled` / `.requiresApproval` cleanly; the
  approval-pending state surfaces a `.link` button that
  deep-links to System Settings → General → Login Items.

### Log export pipeline

- Inline filter (case-insensitive substring); count text
  reads "X of Y" while filtering, "X lines" otherwise.
- `⋯` actions menu: **Copy All** (⌘⇧C), **Save to File…**
  (`.fileExporter` with `PlainTextDocument`), **Share…**
  (`ShareLink`), **Clear**.
- Drag-out: the scroll icon in the log header is
  `.draggable(logAsText)` with a custom drag preview; drop
  into TextEdit / Mail / Slack to export the full log as
  plain text.
- Per-row context menu: **Copy Line** / **Copy with Timestamp**.

### Acknowledgements

- New `AcknowledgementsView` opened from Settings → About →
  Acknowledgements…. Three-entry attribution (NaiveProxy
  BSD-3-Clause, Rust crate graph MIT/Apache-2.0, SF Symbols
  Apple license) with system-material cards, license pills,
  copyright lines, and external-link buttons. Required by
  the bundled dependencies' license terms.

### MalteseTheme retired

- `Views/MalteseTheme.swift` deleted (412 lines). Every live
  UI surface derives colour and typography from system
  tokens: `Color.accentColor`,
  `Color(nsColor: .windowBackgroundColor)`,
  `Color(nsColor: .separatorColor)`, semantic `.red` /
  `.orange` / `.green` / `.secondary`, and
  `.system(.X, design: .monospaced)` for monospace.

### Accessibility

- **Reduce Motion respected.** `LogConsoleView` reads
  `@Environment(\.accessibilityReduceMotion)` and gates both
  the empty-state pulse AND the auto-scroll animation on it
  (in addition to the existing hardware-tier `PerformanceProfile`
  check).
- **Drag-handle a11y.** The log scroll-icon drag handle is no
  longer hidden from VoiceOver — it has an explicit label
  ("Drag the log: N lines.") and hint.
- **Empty-state semantics.** The "Waiting for the first log
  line…" placeholder uses
  `.accessibilityElement(children: .combine)` so VoiceOver
  reads it as one logical statement.

### Tooling

- **`scripts/generate_app_icon.swift`** — new programmatic
  icon generator. Re-run anytime the master changes; the
  full 13-PNG asset stack regenerates in one command.

---

## [0.1.7.21] — 2026-05-04 (LTSC patch — clarity sweep, deletions only)

LTSC patch on the v0.1.7 line. **Net –287 lines.** No new
features, no new fixes, no behavior change. Pure deletion of
indirection wrappers, audit-history narrative, and stale docs
that have stopped earning their place after 11 patches of
accumulation.

The bias: where two equivalent fixes exist for a finding,
prefer deletion over refactor. Code is read 10× more than it
is written; less to read is the highest-value clarity change.

### What was deleted

- **`AppUpdater.sha256(of:)`** — single-line wrapper that just
  forwarded to `SHAVerifier.sha256(of:)`. Two callers now go
  through `SHAVerifier` directly. Indirection saved zero
  semantic content; deletion saves 6 lines + one less symbol
  to grep.
- **`AppUpdater.writeRelaunchScript`** — wrapper that did
  `String → Data + RestrictedFile.write(mode: 0o700) +
  error wrap`. Single caller (`spawnRelaunchHelper`).
  Inlined the four operative lines at the call site;
  deleted the function. Removes ~20 lines and an entry from
  the function-name vocabulary the reader has to keep in
  their head.
- **`AppUpdater.swift` file header — release-history block.**
  The "## v0.1.7.11 Rule-Maker hardening (Fifth audit cycle)"
  section enumerated AU-1 through AU-15 with a ~6-line
  paragraph each (~80 lines of release narrative). That's
  what `CHANGELOG.md` is for; `git blame` finds the same
  information per-line on demand. Header now describes the
  pipeline + posture + open trade-offs in 65 lines instead
  of 145.
- **`docs/v0.1.5-roadmap.md`** — 209 lines of stale planning
  notes. The agent's documentation review explicitly flagged
  this as "now stale" two cycles ago; deferred and forgotten.
  Removed. CONTRIBUTING.md's dangling link to it removed
  too.
- **`docs/session-prompts-summary.xlsx`** — accidentally
  committed via `git add -A` in v0.1.7.16. Was a per-session
  artifact, not project state. Removed.

### What stayed

The decomposition checklist also asked "could this be
deleted?" of:

- The audit-tag inline comments (`v0.1.7.X (FIX):` /
  `R-F#N:` / `Q-F#N:` etc., ~93 hits in `AppUpdater.swift`).
  KEPT for now — they describe genuine *invariants* at the
  point of code, not just history (e.g. "the relaunch helper
  trap installs only after step 4" is a real ordering
  constraint a future reader needs to know). Trimming would
  bleed into refactoring; deletion-only release stays
  scoped.
- The `activeProfileID` field added in v0.1.7.19. KEPT —
  used by exactly one consumer today, but the consumer's
  job (detect "user edited the active profile") cannot be
  derived from existing state.
- The `ProxyActiveFlag` module. KEPT — it's an actual
  state machine (write on enable / clear on disable / read
  on bootstrap), not indirection.

### What this means

For users: nothing. No behavior change.
For maintainers: 287 fewer lines to read on next pass.
File-header history is now where it belongs (the
changelog), and two indirection layers are gone.

### Verification

- `xcodebuild Release` BUILD SUCCEEDED
- No Rust changes; existing 104 lib + 18 chaos tests still
  pass

## [0.1.7.20] — 2026-05-04 (LTSC hotfix — multi-install false-positive)

LTSC hotfix on the v0.1.7 line. Single fix; ships immediately.

**Bug discovered in production:** v0.1.7.16's Edge-F#11
multi-install detector (`refuseIfMultipleInstalls`) ran
`mdfind kMDItemCFBundleIdentifier == "space.coolwhite.naive"`
and treated every hit as a real user install. Spotlight
indexes Xcode build artifacts in
`~/Library/Developer/Xcode/DerivedData/` — for any developer
who has Cool Tunnel checked out and has run `xcodebuild`
even once, that's anywhere from 1 to 10+ extra hits. The
in-app updater then refused with "Multiple copies were
found" even though the user has only one real install in
`/Applications/`.

### What landed (1 fix)

- **`AppUpdater.refuseIfMultipleInstalls` filters Xcode
  build artifacts.** New helper
  `isPlausibleUserInstall(_:)` excludes any `mdfind` hit
  containing `/DerivedData/`, `/Build/Products/`, or
  `/Library/Developer/Xcode/`, plus project-local
  `build/DerivedData/` / `build/Build/Products/` paths.
  Real installs (`/Applications/...`,
  `~/Applications/...`, anywhere not matching those
  patterns) are still detected — defenders against the
  original Edge-F#11 failure mode (genuine duplicate
  installs in `/Applications` + `~/Applications`) stays
  in place.
- **Error message lists the actual paths.** When the
  refusal does fire on a real duplicate, the user-facing
  message now enumerates each path so they don't have to
  hunt in Finder by hand.

### Verification

- `xcodebuild Release` BUILD SUCCEEDED
- No Rust changes; existing 104 lib + 18 chaos tests
  still pass

### Known affected users

Any developer who has Cool Tunnel checked out from GitHub
and has built it locally (Xcode auto-generates
`DerivedData`). Users on the production `.app` who have
NEVER opened the project in Xcode are unaffected.

If you're running **v0.1.7.19 or earlier and seeing this**:
either drag-install v0.1.7.20's `.dmg` over `/Applications`
manually, or run
`rm -rf ~/Library/Developer/Xcode/DerivedData/*` once to
clear the Xcode caches that Spotlight is indexing (Xcode
will regenerate them next build — no source loss).

## [0.1.7.19] — 2026-05-04 (LTSC patch — 10 deferred-high cluster)

LTSC patch on v0.1.7 line. 10 high-severity items pulled
forward from the deferred backlog. Each is contained, each has
real user impact, all 10 ship together as one focused release.

### What landed

- **UX-F#5 (high) — auto-revert proxy on naive crash.** In
  `handle(event:)`, when `.stateChanged(false)` arrives outside
  a user-initiated stop (i.e. naive died on its own — server
  unreachable, segfault, OS killed it), the orchestrator now
  also calls `proxyController.disableAll()` and clears the
  proxy-active sentinel. Without this, macOS keeps routing at
  `127.0.0.1:1080` where nothing is listening — user sees a
  misleading "Idle" header but every browser request stalls.
  Pairs with v0.1.7.17's `lastError` HeaderView banner: user
  sees both that naive stopped AND that the proxy was reverted,
  with a clear retry path.
- **UX-F#16 (high) — engine pipe-death recovery.** When the
  `subscribeToEvents` for-await stream ends outside shutdown
  (cool-tunnel-core itself died — pipe broke, OS killed it),
  the orchestrator now: reverts system proxy, flips
  `didBootstrap = false` so the next mode click re-runs the
  bootstrap path (which calls `core.start()` to respawn the
  engine), and surfaces an actionable error. Previously the
  message said "click Start again" — but Start clicks hit
  `core.send(...)` which throws `.notRunning` since the engine
  was dead. The new message tells users to click a mode chip
  (which now correctly re-bootstraps).
- **Subproc-F#11a (high) — CoreClient stderr drain.** The
  long-lived engine subprocess's stderr was previously
  inherited (no drain). A chatty engine writing >64 KiB to
  stderr fills the kernel pipe buffer, blocks on its next
  stderr write, and the engine deadlocks mid-request. Added
  a detached drain task (`Task.detached(priority: .utility)`)
  that reads stderr to EOF and forwards content to a
  `Logger.cooltunnel("CoreClient.stderr")` for support
  diagnosis.
- **Subproc-F#11b (high) — SystemProxyController via
  `Subprocess.run`.** Previously used the legacy
  `process.waitUntilExit()` + `readDataToEndOfFile()`
  pattern that v0.1.7.10's `Subprocess.swift` was built to
  replace — exactly the pipe-deadlock scenario for
  `networksetup -listallnetworkservices` on a Mac with many
  network services. Now routes through `Subprocess.run` for
  concurrent pipe drain + 30s timeout escalation + sanitized
  env (free benefit from Subproc-F#3 below).
- **Subproc-F#3 (high) — env sanitization in `Subprocess.run`.**
  Previously children inherited the app's full env including
  `DYLD_INSERT_LIBRARIES`, `OBJC_DEBUG_*`, `MallocStackLogging`,
  which could bias trust-boundary tools like `codesign` and
  `networksetup`. Children now receive a minimal env: PATH
  set to `/usr/bin:/bin:/usr/sbin:/sbin` (no user `~/bin`
  shadowing), HOME, LANG=C, LC_ALL=C. Locale-stable output
  parsing is a free side benefit.
- **Subproc-F#1 (med-high) — simplified SIGTERM→SIGKILL.**
  Replaced the 3-step SIGTERM → 250ms → SIGINT → 250ms →
  SIGKILL escalation with SIGTERM → 1s → SIGKILL. SIGINT was
  not an escalation past SIGTERM — any child that traps SIGTERM
  almost always also traps SIGINT (`naive` does both for
  graceful shutdown). The middle step wasted time without
  escalating; SIGTERM gets a longer 1s grace before the kill.
- **Lifecycle-F#7 (high) — transition lock for mode
  switching.** Added `private var transitionInFlight: Bool`
  to `TunnelOrchestrator`. A rapid second click while a prior
  `switchMode` is mid-flight (between `stopQuiet` and
  `startCore`) is now a clean no-op. Without this, two
  concurrent transitions raced on `paths.configFile`,
  `proxyController` state, and `core.send(...)` ordering —
  `naive`'s config file was last-writer-wins, system proxy
  state was whatever the last `enableX` call applied,
  multiple naive children could briefly exist.
- **UX-F#3 (high) — profile mutation while connected
  surfaces a banner.** New `activeProfileID` field captured
  at `startCore` time. The `selectedProfile` setter compares
  the new value against the current `profiles[id]` — if
  they differ AND the engine is running on that profile,
  sets `lastError` to: "Profile edits applied — click Stop,
  then a mode chip to use them. The running connection is
  still on the old config." Surfaces in HeaderView via
  v0.1.7.17 UX-F#1's banner. Previously edits were silently
  buffered with no UX hint.
- **Networksetup localization (med) — `dropFirst(1)` legend
  filter.** `activeServices()` previously filtered the first
  line via `.contains("asterisk")` — broken on non-English
  macOS where the legend is localized. `networksetup` always
  emits exactly one legend line as the first line; the
  stable, locale-independent filter is `dropFirst(1)`.
- **Lifecycle-F#5 (med) — AppDelegate watchdog cancels the
  shutdown Task.** Previously the watchdog fired
  `replied.fire()` after 5s but didn't cancel the shutdown
  Task. If shutdown finished at t=8s, it continued running
  its body (calling `core.stop()` / `disableAll()`) on a
  partially-released graph while AppKit was mid-teardown.
  Now the watchdog explicitly `shutdownTask.cancel()` before
  firing the reply.

### Verification

- `xcodebuild Release` BUILD SUCCEEDED under Swift 6 strict
  concurrency
- No Rust changes; existing 104 lib + 18 chaos tests still
  pass

### What this release changes for users

Users won't notice anything if everything's working — the wins
are in the failure paths:

1. **naive dies on its own** (server unreachable, OS killed
   it): system proxy is auto-reverted, error banner explains
   what happened. Browser keeps working.
2. **cool-tunnel-core dies**: clear recovery path; clicking
   any mode chip re-launches the engine.
3. **Mac sleeps + wakes** with TCP keepalives dropped (from
   v0.1.7.18) AND **engine subprocess deadlocks under heavy
   stderr** (this release): no longer possible.
4. **Profile field edits while connected**: banner explains
   why the new value isn't in effect.
5. **Rapid mode chip clicks**: only the first wins; second
   click is no-op until first transition completes.
6. **Non-English macOS**: `activeServices()` correctly
   identifies network services regardless of system language.
7. **Force-quit via Activity Monitor at the wrong moment**:
   AppDelegate's watchdog fires cleanly without the shutdown
   Task continuing post-mortem.

### Still deferred (3 of the 6-high cluster)

These need infrastructure that doesn't fit a single session,
unchanged from v0.1.7.18's deferral:

- **NaiveProxy SHA pinning** — needs Cool Tunnel-side trusted-
  versions manifest (v0.1.8 target)
- **Password Secret newtype + zeroize** — needs Swift test
  target first (v0.1.8 target)
- **Swift test target** — architectural pbxproj editing risk
  (v0.1.8 target)

## [0.1.7.18] — 2026-05-04 (LTSC patch — focused high-severity cluster)

LTSC patch on v0.1.7 line. Focused release: 3 high-severity
deferred items from prior audit cycles, all with real user
impact, all coordinated rather than grab-bag. The other 3 of
the 6 high-severity outstanding items (NaiveProxy SHA pinning,
Password zeroize newtype, Swift test target) are explicitly
deferred to v0.1.8 — each requires infrastructure that doesn't
fit a single release window.

### What landed (3 fixes)

- **Lifecycle-F#16 (high) — system proxy crash recovery via
  sentinel file.** Previously, if Cool Tunnel crashed (SIGKILL,
  kernel panic, abrupt power loss) while the system proxy was
  enabled, macOS would carry the proxy state across reboots —
  pointing at `127.0.0.1:1080` where nothing was listening.
  Result: every browser request stalled until the user
  manually opened System Settings → Network → Proxies and
  unticked the boxes. Now: when proxy is enabled, write a
  JSON sentinel to `~/Library/Application Support/COOL-TUNNEL/
  proxy-active.flag`. On clean disable, delete it. On every
  app launch, before any other startup work, check if the
  sentinel exists; if it does, the previous run died with
  proxy enabled — force `disableAll()` immediately and clear
  the flag. The user gets back into a working network state
  with no manual recovery.
  - New file: `SystemIntegration/ProxyActiveFlag.swift`
  - Wired into `TunnelOrchestrator.startCore` (write),
    `stop` / `stopQuiet` / `shutdown` (clear), and a new
    `recoverFromCrashIfNeeded` called by `bootstrapIfNeeded`
    BEFORE any other startup work
- **UX-F#4 (high) — `NSWorkspace.didWakeNotification`
  handler.** A Mac that sleeps for >30 minutes often has its
  TCP keepalives dropped. Previously: `naive` was alive but
  every browser request stalled because the upstream
  connection was dead, and the UI kept showing "Active" with
  no recovery hint. Now: AppDelegate subscribes to
  `didWakeNotification`; on wake, the orchestrator sends a
  light-touch probe through the engine pipe. If the probe
  throws (engine pipe died), the orchestrator records a
  `lastError` rendered in the HeaderView banner (per
  v0.1.7.17 UX-F#1) telling the user to click Stop and
  restart their mode.
- **Sw#C4 partial (high) — Rust Core update SHA-256 pinning.**
  Previously, only the `.app` self-updater pinned SHA. Now
  RustCoreUpdater also: downloads the
  `Cool-tunnel-vX.Y.Z.sha256` manifest in parallel with the
  engine binary; parses the line for the
  `cool-tunnel-core-vX.Y.Z-universal` asset; refuses to adopt
  on hash mismatch or missing manifest. Releases without the
  manifest are skipped, not adopted unverified. The
  infrastructure side already shipped in v0.1.7.12's
  `package_release.sh` — every release manifest from then on
  has included the engine line. Closes the
  equivalent-of-Sw#C4 gap for the engine surface.
  - New file: `SystemIntegration/SHAVerifier.swift` — extracted
    from AppUpdater so both updaters share the streaming-SHA
    + manifest-parser primitives
  - `RustCoreUpdater.resolveLatestAsset` returns
    `(tag, downloadURL, manifestURL, assetName)` instead of
    `(tag, downloadURL)` — minimal API surface change

### Verification

- `xcodebuild Release` BUILD SUCCEEDED under Swift 6 strict
  concurrency
- 104 lib + 18 chaos Rust tests still green (no Rust changes
  this release)

### Deferred from the 6-high cluster (3 items)

These need infrastructure work that doesn't fit one session:

- **NaiveProxy SHA pinning** — requires Cool Tunnel-published
  manifest of "trusted upstream Naive versions and hashes".
  Generating that manifest requires manual verification per
  upstream release; the in-app updater would then download
  both upstream's binary and our manifest. **Targeted for
  v0.1.8.**
- **Password Secret newtype + zeroize** — replaces Swift
  `String` storage with a `Secret` newtype that holds bytes
  and zeros them in deinit. Touches CredentialStore,
  FileCredentialStore, KeychainStore, plus every caller. Risk
  too high without test coverage to confirm no regression
  (which is the next item). **Targeted for v0.1.8 after the
  test target lands.**
- **Swift test target** — Adding XCTest target requires
  pbxproj editing that's risky to do without Xcode UI in a
  single session. **Targeted for v0.1.8** as architectural
  work, prerequisite for Password Secret newtype.

## [0.1.7.17] — 2026-05-04 (LTSC patch — 100+ findings, 8 land)

LTSC patch on v0.1.7 line. Eight specialized review agents in
parallel returned **120 findings** across previously-untapped
surfaces (persistence layer, app lifecycle + orchestrator,
SystemIntegration utilities, Rust supervisor + monitor deep,
diagnostics + redaction + protocol, domain types, real-user
UX flows, build determinism + dep audit, subprocess +
entitlements). 8 fixes land here, 112 deferred.

One initial high-severity finding (Build-F#1: claimed `zmij`
was a typo-squat in Cargo.lock) was investigated and
**confirmed false-positive** — `zmij` is a real published
crate ("A double-to-string conversion algorithm based on
Schubfach and YY") that newer serde_json versions use in
place of `ryu`. Cargo cache + checksum verified.

### What landed (8 fixes)

- **UX-F#1 (high) — `lastError` surfaced in HeaderView.**
  `TunnelOrchestrator.recordError()` was setting `lastError`
  on every failure (engine spawn fail, request timeout, naive
  crash, stop fail, anomaly auto-stop, bootstrap disk-full)
  but no view ever read it; errors only appeared as one
  `[error]` line in the log console. The header now shows a
  dismissible cherry-rose error banner directly under the
  status pill — the same surface where users already look for
  status. Added `TunnelOrchestrator.dismissLastError()` to keep
  the public setter `private(set)`.
- **Sup-F#6 (high) — lsof endpoint-aware loopback exclusion.**
  v0.1.7.16 fixed IPv6 `[::1]` exclusion but used
  substring-match against the entire line. A connection like
  `127.0.0.1:54321 -> 1.2.3.4:443` (local client to remote
  server) substring-matches `127.0.0.1` and got misclassified
  as "not remote" — masking a genuine outbound flow that the
  security monitor should be catching. Now: split on `->`,
  check both endpoints separately, and only exclude when
  BOTH are loopback.
- **Domain-F#2 (high) — `Username::parse` rejects control
  chars / `@` / `:`.** Previously the only validation was
  "trimmed not empty"; a username like `"a@b:c\n/d"` parsed
  successfully and produced ambiguous percent-encoding that
  downstream HTTP-header writers could split on. Now: rejects
  control chars (NUL, newlines, ANSI escapes) plus the
  URL-userinfo metacharacters via new
  `InvalidCredentials::IllegalUsernameChar(char)` variant.
- **Diag-F#1 (high) — JSON / k=v credential redaction.**
  Previously only URL userinfo + Authorization + Cookie were
  redacted. naive's config-load errors dump partial JSON
  like `"password":"…"`; curl -v emits `password: hunter2`
  style banners. Both reached the UI verbatim. New
  `JSON_KV_CRED_REGEX` covers `password`, `passwd`, `secret`,
  `token`, `api_key`, `apikey`, `access_token`,
  `refresh_token` — case-insensitive, optional surrounding
  quotes on key + value.
- **Build-F#6 (high) — `rust-toolchain.toml` pinned to
  1.95.0.** Previously `channel = "stable"` floated, letting
  rustc drift across CI runs. The LTSC posture pins
  `Cargo.lock` with `--locked` but letting rustc itself
  float is the inconsistent half. Bumps now require an
  intentional version edit. Also added explicit
  `targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]`
  so universal builds don't need `rustup target add` in CI.
- **Subproc-F#6 (high) — hardened runtime enabled.**
  `pbxproj` had `ENABLE_APP_SANDBOX = NO` (correct — the app
  needs to spawn `naive` and call `networksetup`) but no
  `ENABLE_HARDENED_RUNTIME = YES`. Without it, ad-hoc-signed
  builds run without library-validation gating; an attacker
  with `DYLD_INSERT_LIBRARIES` access could inject. Now both
  Debug and Release configs set `ENABLE_HARDENED_RUNTIME =
  YES` + `OTHER_CODE_SIGN_FLAGS = "--options runtime"`.
- **Pers-F#10 (high) — ProfileStore corrupt-JSON recovery.**
  Previously `try? JSONDecoder().decode(...)` swallowed
  decode errors and returned `[.default]`; the next
  `save(profiles:)` then overwrote the corrupted-but-
  recoverable blob with the default, **silently destroying
  the user's profile list**. Now: on decode failure, copy the
  corrupted blob to a backup key
  (`profiles.broken.<ISO-timestamp>` in UserDefaults) and
  `os_log` an error before falling back. The user (or
  support) can recover via `defaults read`.

### Deferred (112 findings)

By severity tier:

- **High (deferred ~10)**: SystemProxyController revert-on-
  crash safety (sentinel file + LaunchAgent watcher) — needs
  careful design across multiple files; targeted for v0.1.7.18.
  Naive-crash auto-revert (UX-F#5). DNS hijack of
  api.github.com lacks cert pinning (UX-F#11). Update
  mid-connection 5s watchdog leaves system proxy enabled
  (UX-F#8). Sleep/wake handler missing — naive can be a TCP
  zombie with UI showing "Active". `setsocksfirewallproxy`
  only covers SOCKS, not HTTP/HTTPS.
- **Persistence security (~6)**: Password as Swift String
  never zeroed (cred lifetime); Profile.password serialised
  via Codable (storage surface); `selectedProfileID`
  dangling references; `MigratingCredentialStore` orphan
  duplicates; Keychain `WhenUnlocked` instead of
  `ThisDeviceOnly`; SettingsStore `bool/stringArray`
  unset-vs-false ambiguity.
- **Subprocess + entitlement (~6)**: SIGTERM→SIGINT→SIGKILL
  escalation order is suboptimal; env inheritance carries
  DYLD_*/OBJC_* into children; CoreClient.start +
  SystemProxyController.run bypass Subprocess.run; tar
  extraction lacks `refuseExtractionEscapingSymlinks` (only
  ditto path covered); `network.client/server` entitlements
  unconstrained; quarantine xattr handling.
- **Architectural (~5)**: pipeline extraction (Q-F#11
  legacy); shared `Updater` protocol (don't); empty
  `ViewModels/` directory; bundle ID legacy
  `space.coolwhite.naive` vs `…cooltunnel`; build-time
  `canonicalBundleID` from pbxproj.
- **Test coverage (~10)**: NO Swift test target exists;
  zero tests on persistence, SystemIntegration,
  SystemProxyController.disableAll, server_mode HTTP API,
  v0.1.7.13–.17 fixes; chaos suite is liveness-only.
- **State-machine (~5)**: orchestrator transitions not
  atomic; concurrent click handling; profile mutation
  while connected uses stale credentials silently;
  multiple orchestrator phase variables can drift; engine
  death "click Start again" message tells users to do
  something that throws notRunning.
- **Performance (~6)**: log buffer `removeFirst(n)` is O(n);
  `binding(for:)` round-trips on every keystroke; LazyVStack
  autoscroll O(N) per log line; redaction regex without
  `size_limit`; multiple `.lowercased()` calls already
  redundant; `Logger.cooltunnel` reallocates per call.
- **Documentation (~10)**: 23 MB → 45 MB drift caught in
  v0.1.7.16; CONTRIBUTING references wrong package version;
  NOTICE missing fonts; "macOS 26 Liquid Glass" aspirational
  in SUPPORT.md; SECURITY.md "begins with 1999… ends with
  ***REDACTED***" hint; jurisdiction missing in Disclaimer.md;
  AppUpdater self-updater documented in v0.1.7.16 already.
- **Domain validation (~6)**: ProfileId accepts empty;
  Username/Password no max length; Password trim mutation;
  ServerAddress accepts RFC-violating hostnames; Port
  accepts `+0001080`; ProxyMode lacks Default; serde
  `deny_unknown_fields` missing; no `#[serde(alias)]` for
  future renames.
- **CI hygiene (~5)**: actions/cache restore-keys allows PR
  cross-branch poisoning; `--all-features` on clippy/test
  enables features that never ship; `taiki-e/install-action@v2`
  not pinned to SHA; license allow-list confidence threshold
  0.93 risks false positives; deny.toml multiple-versions
  brittle.
- **Style + naming (~10)**: audit-tag comment density
  (89+ refs); magic numbers (1024, 100MB, 64KiB, 30s, 120s)
  overloaded; `Refusing to install/update/proceed` verb
  drift; force-unwraps; logger placement (file-scope vs
  static member) inconsistent.
- **Don't-do-it (~25)**: AsyncStream pipeline migration;
  shared Updater protocol; bash heredoc → resource file;
  exact-allowlist hostname; `AvailableRelease` asymmetry;
  several others. Flagged so the next reviewer doesn't
  propose them.

The full per-finding output is preserved in the review-agent
transcripts at the time of this commit.

## [0.1.7.16] — 2026-05-04 (LTSC patch — broad-surface deep audit)

LTSC patch on v0.1.7 line. Seven specialized review agents in
parallel (Rust core, SwiftUI views, shell + tooling, test
coverage, documentation, cross-cutting consistency, updater
edge cases) returned **100 findings** — well above the 50+ asked
for. Tight triage: **13 fixes land here**, 87 deferred with
explicit categorization below.

The fixes are spread across the surfaces that prior reviews
hadn't deeply mined: the Rust core's protocol contract, the
sibling updaters' API + logging discipline, real-user edge cases
(disk full, multi-install), CI hardening, and documentation
drift.

### Rust core (3 fixes)

- **Rust-F#1 — `validate_profile` contract honesty.** The
  client-mode dispatcher's `RequestKind::ValidateProfile` arm
  took an already-deserialized `Profile`, so the `ok:false`
  branch of `ValidationReport` was structurally unreachable —
  the same bug pattern SM-3 fixed in `server_mode.rs`. The
  variant now carries `RawProfile` and the dispatcher runs
  `Profile::try_from(raw)` itself, surfacing both branches.
- **Rust-F#2 — IPv6 loopback in `lsof` remote classifier.**
  `monitor::lsof::parse` only excluded `127.0.0.1` from the
  "remote" classification. macOS uses `[::1]:port->[::1]:port`
  for IPv6 ESTABLISHED lines; without the v6 loopback exclusion
  an IPv6-first system's own loopback fanout could synthesize
  a `TooManyRemote` anomaly. Now also excludes `[::1]`.
- **Rust-F#4 — `unimplemented_method` Debug-format wire-side
  scrub.** The wildcard arm in `dispatch()` previously embedded
  `format!("…{kind:?}")` in the wire payload — a forward-compat
  exfil channel: any future `RequestKind` variant with
  attacker-influenceable fields would have its Debug
  representation reach the client. Wire body is now a stable
  payload-free string; the unknown variant goes to
  `tracing::warn!` only.

### Sibling updaters parity with AppUpdater (2 fixes)

- **Cross-F#1 — `NaiveUpdater` + `RustCoreUpdater` API surface
  narrowed to `internal`.** `AU-15` (v0.1.7.12) demoted only
  AppUpdater. Both sibling updaters were still `public final
  class …` with 9 `public` symbols each, despite SettingsView
  being the sole consumer. Now matches AppUpdater + GitHubTrust:
  `internal` (default) on the class and all members.
- **Cross-F#2 — `Logger.cooltunnel("NaiveUpdater")` and
  `…("RustCoreUpdater")` added.** Only AppUpdater had a Logger
  before; the sibling updaters' security-relevant rejects
  (untrusted host, oversize, network failure) had no
  os_log breadcrumb. Now `error`-level on host/oversize hits,
  `warning`-level on network failures — matching the discipline
  AppUpdater established.

### Updater edge cases (2 fixes)

- **Edge-F#1 — disk-space pre-flight on tempRoot.**
  `runPipeline` now calls `requireFreeSpace(at:atLeast:)` BEFORE
  initiating the .zip download, requiring 300 MB available on
  the volume containing tempRoot (≈ 100 MB .zip + 50 MB
  extracted bundle + slack for the relaunch helper's STAGED
  copy). Prevents the failure mode where a near-full volume
  surfaces an attacker-influenceable "No space left on device"
  ditto stderr message — and avoids the worst case where the
  parent has terminated AND the helper hits ENOSPC mid-swap.
- **Edge-F#11 — multi-install detection via Spotlight.**
  Before any pipeline work, AppUpdater shells out to
  `mdfind 'kMDItemCFBundleIdentifier == "space.coolwhite.naive"'`
  to find every installed copy. If more than one exists
  (e.g. `/Applications` + `~/Applications`), the update is
  refused with: "Multiple copies of Cool Tunnel were found on
  this Mac. Move all but one to the Trash, restart the app
  you want to keep, and try Update again." Without this, the
  helper updates one install but LaunchServices may launch the
  other on next double-click — leaving a "successful" update
  that doesn't appear to have changed anything.

### CI + tooling (2 fixes)

- **Shell-F#5 — `cargo build --locked` everywhere.**
  `scripts/build_rust_core.sh` and three `cargo` invocations
  in `.github/workflows/ci.yml` (clippy, test, build) now pass
  `--locked`. Without it, a missing or out-of-date `Cargo.lock`
  would be silently regenerated against newer transitive deps
  — defeating the LTSC reproducibility posture the rest of the
  build infrastructure tries to enforce.
- **Shell-F#6 — least-privilege CI permissions + GitHub-token
  scrub on checkout.** `.github/workflows/ci.yml` now declares
  `permissions: { contents: read }` at the workflow level, and
  every `actions/checkout@v4` invocation passes
  `with: persist-credentials: false`. Without these, the
  inherited org-default permissions could include `contents:
  write` (or worse), and a compromised dependency or test
  fixture could exfiltrate the GITHUB_TOKEN that
  `actions/checkout` left in `.git/config`.

### Documentation honesty (4 fixes)

- **Doc-F#1 — Disclaimer corrected.** The "no data collection"
  paragraph claimed credentials live in the macOS Keychain
  with the rest in UserDefaults — both wrong. The actual
  storage is `~/Library/Application Support/COOL-TUNNEL/
  credentials.json` (mode 0600, parent dir 0700). Updated to
  match reality and to mention the exact GitHub hosts the app
  contacts during in-Settings updates.
- **Doc-F#2 — README disk size from 23 MB to ~45 MB.** The
  installed `.app` is now ~45 MB (universal `naive` Mach-O +
  universal `cool-tunnel-core` engine + Swift app + assets);
  the 23 MB figure was accurate pre-v0.1.7. Memory unchanged.
- **Doc-F#3 — README documents the in-app self-updater.** The
  user-facing "Updating without reinstalling the app" section
  previously listed only the Naive Binary and Rust Core update
  buttons, omitting the Cool Tunnel → Update button that
  actually has SHA pinning. All three are now documented; the
  SHA-pin gap on the other two is acknowledged with the v0.1.8
  target.
- **Doc-F#5 — SECURITY.md threat-model honesty about SHA-pin
  gap.** The threat model now explicitly lists "Bit-flips
  inside GitHub's release-asset CDN during a Naive Binary or
  Rust Core update" under "Does NOT protect against", with the
  full reasoning: redirect guard + size cap mitigate most of
  the threat surface, but a CDN-internal byte tamper would
  serve substituted bytes that local ad-hoc re-signing would
  launder. Tracked for v0.1.8.

### Tests + verification

- `cargo check` clean (0 errors, 0 warnings)
- `xcodebuild Release` BUILD SUCCEEDED under Swift 6 strict
  concurrency
- All 104 lib + 18 chaos tests still pass
- `cargo test --locked --all-features` passes (the new
  `--locked` flag enforces lockfile freshness)

### Deferred (87 findings)

Triaged into clear categories so the next maintainer (or
release cycle) can pick up without re-reading the agent
reports. The full per-finding output is preserved in the
review-agent transcripts at the time of this commit.

**SHA pinning for Naive + RustCore (v0.1.8 target)**: The
single most-impactful deferred item. Both sibling updaters
download attacker-influenceable bytes; only the .app's own
self-updater pins SHA-256. The redirect guard + 100 MB cap
help, but a CDN-internal tamper would serve substituted bytes
that ad-hoc re-signing would launder. Sw#C4 was originally
v0.2.0; SECURITY.md now commits to v0.1.8.

**Test coverage (15 deferred)**: server-mode HTTP API has zero
tests; the 7 Swift fixes shipped in v0.1.7.13/.14/.15 have NO
tests of any kind; no end-to-end integration test for the JSON
protocol or the HTTP server; chaos suite is liveness-only, no
security boundaries; property-based testing missing for parsers;
test fixtures hardcode "hunter2"/"secret". Whole test cycle
worth scheduling.

**SwiftUI render efficiency (8 deferred)**: `binding(for:)`
round-trips full Profile on every keystroke causing global
re-renders; `LazyVStack` autoscroll is O(N) per log line;
`@State updater = NaiveUpdater(...)` re-instantiates on body
recompute; `@Environment(\.colorScheme)` reads in three views
duplicate work the dynamic NSColor provider already does.

**Localization readiness (1 deferred)**: zero `String(localized:)`
calls in the entire UI. Every visible string is a hardcoded
Swift literal. The line-count display is grammatically wrong
in English ("1 lines"). Untranslatable as-is.

**Accessibility (1 deferred)**: decorative pulsing dot,
gradient app icon, scroll/lightbulb icons all lack
`.accessibilityHidden(true)` — VoiceOver walks into them
unlabeled. Status pill should be a single combined element.

**Architectural debt (4 deferred)**: extract
`AppUpdaterPipeline` from AppUpdater (1402-line file is 85%
nonisolated statics on a `@MainActor @Observable` class);
build-time `canonicalBundleID` from pbxproj; `parse_args`
clap migration; pipeline-actor split for the cross-platform
v0.2.0 refactor.

**Bash + supply chain (10 deferred)**: `fetch_naive.sh` claims
to verify SHA but doesn't (writes the SHA from downloaded bytes,
no pinned manifest); `taiki-e/install-action@v2` not pinned to
SHA; `package_release.sh` doesn't actually invoke `gh release
create`; `secret_check.sh` excludes `dist/` from the scan;
cargo-deny advisory list lacks expirations; dependabot lacks
`groups:`; `build.rs` doesn't honour `SOURCE_DATE_EPOCH`.

**Documentation polish (8 deferred)**: SECURITY.md's
"begins with 1999… ends with …***REDACTED***" gives away the password
structure; SUPPORT.md's "macOS 26 Tahoe Liquid Glass" claim
is aspirational; CONTRIBUTING references wrong package version;
NOTICE doesn't mention Apple system fonts; no PR template;
no "run a single test" snippet in CONTRIBUTING.

**UI race conditions (1 deferred)**: ControlPanelView's Stop /
Diag / Latency buttons spawn `Task { ... }` without sync gates.
Lower priority because the underlying ops are idempotent at
the orchestrator layer.

**Performance / memory micro-opts (15 deferred)**: regex with
default features pulls 1.5 MB unicode tables; `pid_alive`
shells out per 5s tick instead of using
`monitor_lifecycle`'s child.wait(); `EncodedCredentials::Drop`
documents itself as theatre; redundant `.lowercased()` calls
on already-canonical Foundation types; etc.

**Style + naming (10 deferred)**: bundle-ID legacy
(`space.coolwhite.naive` vs `…cooltunnel`); empty
`ViewModels/` directory; audit-tag comment density; magic
number `1024` overloaded; "Refusing to install/update/
proceed" verb drift across error messages.

**Don't-do-it findings (15)**: AsyncStream pipeline migration
(callback shape is fine), shared `Updater` protocol (the three
state machines diverge structurally), bash heredoc → resource
file (current shape is more secure + auditable),
`AvailableRelease` asymmetry (reflects real product asymmetry),
exact-allowlist hostname (suffix matching is fine), several
others. Flagged as "don't do" so the next reviewer doesn't
propose them.

## [0.1.7.15] — 2026-05-04 (LTSC patch — deep audit, MainActor freeze fix)

LTSC patch on v0.1.7 line. Deep three-angle review (adversarial
security, Swift 6 concurrency, architectural design) returned 32
findings; 7 land here, 25 deferred (low-severity / "don't do it"
recommendations / future-cycle work).

The headline finding is real: **NaiveUpdater + RustCoreUpdater
were freezing the UI during updates** because their
`runProcess(executable:arguments:) throws` synchronously called
`Process.waitUntilExit()` from `@MainActor` context. AppUpdater
fixed this pattern back in v0.1.7.10 by routing `ditto`
through the async `Subprocess.run` helper, but the two cousin
updaters were missed by that audit.

### v0.1.7.15 fixes

- **CONC-F#1 (high) — UI freeze during NaiveProxy + Rust core
  updates.** Both updaters' `runProcess` is now async and routes
  through `Subprocess.run` (concurrent pipe drain + 120 s timeout
  escalation), matching `AppUpdater.unzip`. Their pipeline
  helpers (`extractNaive`, `lipoCreate`, `adhocSign`,
  `RustCoreUpdater.adhocSign`) are now `nonisolated async` and
  awaited from `update()`. NaiveUpdater additionally extracts
  the two arches in parallel via `async let` (~2× speedup on
  the cold path). The Process-blocks-MainActor pattern is gone
  from the codebase.
- **SEC-F#8 (medium) — hard-link rejection in extraction
  walker.** `refuseExtractionEscapingSymlinks` previously only
  inspected `isSymbolicLink == true` entries; PKZip's
  `ditto`-extension preserves hard links, so a malicious zip
  that survives SHA verification could embed
  `Cool tunnel.app/Contents/Resources/foo` as a hard link to
  `/etc/passwd` or `~/.ssh/config`, leaving the bundle a
  side-channel into user files. Now: any regular file with
  `nlinks > 1` rejects with refuse-and-bail.
- **SEC-F#6 (low) — `fchmod()` after `open()` in
  `RestrictedFile.write`.** POSIX `open(2)` ANDs the supplied
  mode with `~umask`; on a system with an unusual umask
  (corporate-managed `0o077`, or a future caller passing
  `0o755`) the file would be created with FEWER permissions
  than requested. `fchmod(2)` doesn't honour umask, so calling
  it explicitly after `open` guarantees the requested mode
  regardless of environment. For the existing call sites
  (credentials at 0o600, relaunch script at 0o700) the umask
  interaction was a no-op, but locking the contract here means
  future callers can rely on the requested mode.
- **SEC-F#7 (low) — defend `~/Library/Logs/cool-tunnel/
  relaunch.log` against pre-planted symlinks.** An attacker
  with prior file-write access in the user's home (Threat T4)
  could pre-create the log path as a symlink to `/dev/full` or
  a root-owned location. The bash helper's `exec 2>>"$LOG"`
  redirect would silently fail, defeating Q-F#2's whole point
  (no diagnostic anywhere on update failure). Swift now
  checks `isSymbolicLink` on the path before returning it; if
  the file exists and isn't a regular file, it's unlinked so
  bash creates a fresh one.
- **ARCH-F#1 (medium) — single shared `UpdaterError` enum.**
  Three updaters carried three identical
  `enum X: Error, Sendable, Equatable { case message(String) }`
  declarations: `AppUpdater.UpdaterError` (nested),
  `NaiveUpdater.UpdaterError` (file-scope), and
  `RustCoreUpdater.RustUpdaterError` (file-scope, renamed to
  prevent collision with NaiveUpdater's). Consolidated to a
  single module-level `UpdaterError` in
  `SystemIntegration/UpdaterError.swift`; all three updaters
  now share it.
- **ARCH-F#2 (medium) — size cap on shared
  `GitHubRedirectGuard.download`.** Previously only
  `AppUpdater.download` had a per-asset cap (.sha256 1 MB,
  .zip 100 MB). NaiveUpdater + RustCoreUpdater inherited none,
  so a confused-deputy or attacker-shaped API response
  pointing at a 4 GB file at a trusted GitHub host would
  happily fill the user's disk. Added `maxBytes: Int64 = 100
  * 1024 * 1024` parameter (default = 100 MB) and an
  `OversizeDownloadError` carrier; the two cousins inherit
  the cap as defense-in-depth.
- **SEC-F#11 (low) — `Cache-Control: no-cache` header on
  metadata fetches.** A network-position attacker (Threat T1)
  serving a captured pre-security-fix `/releases/latest`
  response could otherwise downgrade the offered version even
  through HTTPS (replay of integrity-protected bytes is still
  replayable). All three updaters' GitHub releases-API
  requests now send `Cache-Control: no-cache` to discourage
  edge caching / 0-RTT replay.

### Tests + verification

- `xcodebuild Release` BUILD SUCCEEDED under Swift 6 strict
  concurrency (every helper conversion to `nonisolated async`
  type-checked clean).
- No Rust changes; existing 104 lib + 18 chaos tests still
  pass from v0.1.7.13.
- v0.1.7.15 ships the same five assets as v0.1.7.14
  (`.dmg`, `.pkg`, `.zip`, `cool-tunnel-core` engine,
  `.sha256` manifest).

### Deferred (25 findings)

The deep review's most impactful deferred items, with rationale:

- **SEC-F#1 + F#2 (high) — SHA pinning for NaiveUpdater +
  RustCoreUpdater.** The redirect guard (v0.1.7.13) and size
  cap (this release) cover most of the threat surface, but a
  CDN-internal byte tamper at `objects.githubusercontent.com`
  would still serve substituted bytes. Cool Tunnel-published
  SHA manifests for both binaries close that gap. **Targeted
  for v0.1.8** rather than v0.2.0 — the security agent's
  argument that the v0.2.0 timeline isn't defensible if it's
  more than ~30 days out is correct. Tracked.
- **SEC-F#4 + F#5 (medium) — relaunch helper recovery
  improvements (notify on `mv` failure, verify post-launch).**
  Real UX gaps but each requires careful design (osascript
  notifications, post-launch poll). Punt to a polish cycle.
- **CONC-F#3 (medium) — `.relaunching` recovery deadline.**
  Theoretical (`applicationShouldTerminate` always returns
  `.terminateLater` with a watchdog in this app); track for
  the v0.2.0 cross-platform refactor.
- **CONC-F#4 (medium) — Task cancellation handling.** Storing
  the in-flight `Task` and cancelling on `reset()` /
  `deinit`. Real but cooperative-cancellation semantics need
  careful design across the three updaters.
- **ARCH-F#3 (medium) — extract `AppUpdaterPipeline` from
  `AppUpdater`.** Q-F#11 deferred; same answer.
- **ARCH-F#4 (low) — build-time `canonicalBundleID`.**
  Pre-empting a hypothetical fork rename; no fork imminent.
- 19 other findings are low-severity (style, micro-opts,
  comment trim, "don't do it" recommendations).

## [0.1.7.14] — 2026-05-04 (LTSC patch — second simplify pass)

LTSC patch on v0.1.7 line. Second-pass simplify review of
v0.1.7.13 found 18 follow-on findings; 7 land in this release
(1 high-impact dedup, 2 medium real-bug fixes, 4 quick wins).
11 deferred (subjective comment trim, stylistic placement,
trivial micro-opts where churn outweighs gain).

### Highlights

- **R-F#2 (high) — Naive/RustCore download dedup.** v0.1.7.13
  applied the same "host check + URLRequest +
  download(for:delegate:) + status check + fileExists/
  removeItem/moveItem" sequence to both `NaiveUpdater.download`
  and `RustCoreUpdater.download`. The two implementations
  drifted into line-for-line twins (~22 lines × 2). Extracted
  to `GitHubRedirectGuard.download(url:to:)` static helper.
  Both call sites collapse to a 3-line `do/catch` mapping
  `UntrustedGitHubHostError` to their respective updater
  error types. AppUpdater's `download` stays bespoke because
  it layers a per-asset size cap (.sha256 1 MB / .zip 100 MB)
  that the others don't need.
- **Q-F#1 (med) — bash mkdir-before-redirect silent fail.**
  v0.1.7.13's `Q-F#2` redirect (`exec 2>>"$LOG"`) was preceded
  by a bash-side `mkdir -p "$(dirname "$LOG")"` — but the
  Swift `makeRelaunchLogPath()` already creates the directory
  before spawning the script, AND the bash mkdir's failure
  path was silent (with `set -eu`, mkdir failure aborts; with
  `task.standardError = nil` on the parent's spawn, the
  diagnostic vanished). The bash mkdir is now removed; Swift
  alone owns the dir creation. The exec failure path is still
  silent on a degenerate "dir exists but file can't be opened"
  case but that's vanishingly rare on macOS and no worse than
  pre-Q-F#2 behaviour.
- **R-F#1 (med) — `Logger.cooltunnel(_:)` factory extension.**
  Three Logger declarations (`CoreClient.logger`,
  `AppUpdater.appUpdaterLogger`, `GitHubTrust.trustLogger`)
  each spelled out
  `Logger(subsystem: "space.coolwhite.cooltunnel", category: ...)`
  with the subsystem string as a literal. The
  orphan-subsystem regression that R-F#2 just fixed in v0.1.7.13
  (the legacy `"com.cool-tunnel.app"` string) becomes
  structurally impossible: only one place knows the subsystem
  identifier now.

### Quick wins

- **Q-F#2 (low) — `makeRelaunchLogPath` force-unwrap fixed.**
  `FileManager.default.urls(for:in:).first!` violated the
  project's documented avoid-bare-`!` convention from the
  v0.1.5.9 audit. Replaced with a throwing guard that surfaces
  an `UpdaterError.message` if the user Library directory is
  somehow unreachable.
- **E-F#3 (low) — dropped redundant `.lowercased()`.**
  `isTrustedGitHubURL` was calling `.lowercased()` on
  `url.scheme` and `url.host`. Foundation already canonicalises
  both to lowercase per RFC 3986 §3.1 / §3.2.2; the explicit
  lowercase was wasted allocation per call.
- **Q-F#5 (low) — `canonicalPathComponents` returns Optional.**
  Removed the `errorMessage:` parameter that threaded a
  user-facing error string through the realpath wrapper. The
  helper now returns `[String]?`; the two call sites
  (container + per-symlink-target) handle their own throws
  with their own messages. Cleaner separation of "is this
  POSIX call possible" from "what UX wording does the caller
  want".
- **Q-F#7 (low) — trimmed stale `AU-1` doc on
  `writeRelaunchScript`.** The function body was simplified
  in v0.1.7.13's R-F#1 (delegate to `RestrictedFile.write`)
  but the old doc still described the bespoke
  `O_CREAT|O_EXCL` + write + fsync + close FD-lifecycle that
  the function no longer does. Trimmed to a one-liner that
  describes the new shape.

### Tests + verification

- `xcodebuild Release` BUILD SUCCEEDED (Swift 6 strict
  concurrency)
- No Rust changes in this release; existing 104 lib + 18 chaos
  tests still pass
- `Cool-tunnel-v0.1.7.14.dmg` ships the same five assets as
  v0.1.7.13 (`.dmg`, `.pkg`, `.zip`, `cool-tunnel-core` engine,
  `.sha256` manifest)

### Deferred (11 findings)

- **Q-F#3 — Logger placement (file-scope vs static member).**
  Stylistic; either is defensible.
- **Q-F#4 — `trustedHostSuffixes` placement.** Module-level
  fine for one consumer.
- **Q-F#6 — `RestrictedFile.write` doc duplicate paragraphs.**
  Subjective.
- **Q-F#8 — `assetURL` defence-in-depth check is dead on a
  hardcoded URL.** Kept as a tripwire if `assetURL` ever
  takes dynamic input.
- **Q-F#9 — error wording drift between Naive and RustCore.**
  Now mostly resolved by R-F#2 (both go through the same
  helper); minor text differences in the wrap remain.
- **Q-F#10 — `MAX_PAC_DOMAIN_BYTES` audit-trail comment.**
  Same Q-F#3 deferral pattern as last release.
- **R-F#3 — `~/Library/Logs/cool-tunnel/` derivation in
  `AppSupportPaths`.** One call site; not worth churn.
- **R-F#4 — `InvalidServer::TooLong` hardcodes 253.**
  thiserror format-string limitation; punt.
- **E-F#1 — drop one of two host validations per download.**
  Effectively addressed by R-F#2 (the helper validates once;
  the upstream `validateInstallAssets` / `resolveLatestAsset`
  / `assetURL` checks remain as defence-in-depth at a
  different seam).
- **E-F#2 — URL roundtrip in `canonicalPathComponents`.**
  Gated by the 1024-symlink cap; not hot.
- **E-F#4 — bake `"."` prefix into suffix list.** Trivial
  micro-opt; allocations are negligible at 2 entries / call.

## [0.1.7.13] — 2026-05-04 (LTSC patch — post-cycle simplify pass)

LTSC patch on the v0.1.7 line. Simplify-pass review of
v0.1.7.11 + v0.1.7.12 found **31 follow-on findings** across
three review angles (reuse, quality, efficiency); 12 are
landed in this release, 19 are deferred (subjective comment
narrative, architectural pipeline-actor split, and trivial
allocation cleanups documented as won't-fix). Cross-cutting
theme: the audit cycle hardened `AppUpdater` extensively but
left `NaiveUpdater` and `RustCoreUpdater` exposed to the same
class of redirect / host-substitution attacks. v0.1.7.13
closes that gap.

### Cross-updater hardening (R-F#4 — security)

- **New `SystemIntegration/GitHubTrust.swift`.** Extracts
  `isTrustedGitHubURL(_:)` and `GitHubRedirectGuard` from
  `AppUpdater.swift` (where they were `fileprivate`) into a
  shared module. `GitHubRedirectGuard.shared` is a stateless
  singleton (E-F#3 fix — the prior per-request allocation
  became wasted work).
- **`NaiveUpdater.swift` adopts the trust boundary.** The
  upstream-binary fetch (klzgrad/naiveproxy releases) now uses
  `URLSession.shared.data/download(for:delegate:
  GitHubRedirectGuard.shared)` and validates every URL via
  `isTrustedGitHubURL` before download. Without this, the
  un-pinned binary fetch could be redirected to an attacker-
  controlled host with no SHA verification to catch the
  substitution. (SHA pinning for NaiveUpdater + RustCoreUpdater
  is still deferred to v0.2.0 per Sw#C4 — but the redirect
  guard means a CDN takeover or upstream redirect
  misconfiguration alone is no longer sufficient to ship a
  substituted binary.)
- **`RustCoreUpdater.swift` adopts the trust boundary.** Same
  changes for the `cool-tunnel-core` binary fetch from
  coo1white/cool-tunnel releases.

### AppUpdater cleanup + correctness (7 findings)

- **Q-F#1 (R4) — `@discardableResult` removed from
  `markEnteringCheck` / `markEnteringDownload`.** The whole
  point of the Bool return added in v0.1.7.12 (AU-13) was that
  the caller MUST consume it before spawning the follow-up
  Task; `@discardableResult` defeated that — a future site
  writing `appUpdater.markEnteringCheck(); Task { … }` would
  re-introduce the race silently. Removing the attribute makes
  the warning machinery enforce the AU-13 invariant at compile
  time.
- **Q-F#2 (R4) — bash relaunch helper redirects stderr to a
  log file.** AU-11's `preswap_trap` echoes recovery hints
  (paths to `$TEMP_ROOT` and `$BACKUP`) to stderr — but the
  spawning Swift code sets `task.standardError = nil`
  (helper runs detached after `NSApp.terminate`), so the
  output went to `/dev/null`. The script now `exec 2>>"$LOG"`
  to `~/Library/Logs/cool-tunnel/relaunch.log` so the
  recovery hint actually reaches a file the user (or support)
  can `tail`. Added `makeRelaunchLogPath()` Swift helper that
  ensures the log directory exists.
- **R-F#1 (reuse) — `writeRelaunchScript` delegates to
  `RestrictedFile.write`.** Generalised `RestrictedFile.write`
  with a `mode: mode_t = 0o600` parameter (default preserves
  every existing call site for credential files); AppUpdater's
  bespoke `O_CREAT|O_EXCL` + write + fsync + close FD-lifecycle
  code (~50 lines) collapses to a single
  `RestrictedFile.write(data, to: scriptURL, mode: 0o700)`
  call. Removes the second-implementation drift risk.
- **R-F#2 (reuse) — `os.Logger` migration.** Replaced the
  legacy `OSLog(subsystem:category:)` + `os_log` pair with the
  modern `Logger(subsystem:category:)` API matching
  `CoreClient.swift`'s convention. Also fixed the orphan
  subsystem string `"com.cool-tunnel.app"` to the project-wide
  `"space.coolwhite.cooltunnel"` so support's
  `log show --predicate 'subsystem == "..."'` queries surface
  every component under one umbrella. Calls now use typed
  interpolation with explicit `, privacy: .public` — the
  values being logged (URLs, version strings, status codes)
  are deliberately diagnostic, not user secrets.
- **R-F#7 (reuse) — `canonicalPathComponents` helper.**
  Centralised the `realpath(3)` + `String(cString:)` + `free` +
  `URL.pathComponents` extraction the symlink-escape walker
  was doing twice (once for the container, once per symlink
  target). Both call sites are now one-liners; the rename-and-
  free dance lives in one place where future tightening
  (e.g. switching to `realpath(_, buf)` to avoid the
  caller-frees pattern) only touches one site.
- **E-F#1 (R3) — parallel .zip + .sha256 download.** The two
  fetches are independent (manifest doesn't gate the .zip
  request) but ran serially. `async let` joins them in
  parallel; the manifest fetch typically completes during the
  .zip's TLS handshake, ~2× speedup on the user-visible cold
  path.
- **E-F#6 (R3) — drop TOCTOU `fileExists` / `removeItem`
  before `moveItem`.** `tempRoot` is freshly mkdtemp'd per
  pipeline run; destination collision is impossible by
  construction. The pre-check was wasted work AND a TOCTOU
  anti-pattern. `moveItem` alone is correct.
- **E-F#8 (R2) — entry-count cap on extraction symlink walk.**
  An attacker-shaped zip could plant 10k+ symlinks (each ~30
  bytes; the 100 MB Sw-H3 cap allows ~3M empty entries); each
  triggers a `realpath(3)` syscall, an attacker-controlled
  work multiplier on the user's update path. Now bails after
  1024 symlinks (far above any legitimate macOS bundle).

### Other ((4 findings)

- **Q-F#7 — bare `Sendable` (commented) on
  `GitHubRedirectGuard`.** Class is `final` with zero stored
  properties; the `@unchecked Sendable` is required only
  because `NSObject` ancestor isn't `Sendable`-marked — but
  the conformance is genuinely sound. Moved to `GitHubTrust.swift`
  with a comment explaining specifically why `@unchecked` is
  the right shape (unchecked because of NSObject, but no
  mutable state to be unsafe about).
- **R-F#3 (reuse) — single-source `MAX_PAC_DOMAIN_BYTES`.**
  v0.1.7.12 introduced `MAX_PAC_DOMAIN_BYTES: usize = 253`
  in `server_mode.rs` with a comment about RFC 1035; the
  same number was already declared in
  `domain::server::ServerAddress::MAX_LEN` (private). Promoted
  the latter to `pub const` and made `server_mode` reference
  it. Future revisions to the limit propagate automatically;
  no drift risk.
- **R-F#1 sibling effect — generalised `RestrictedFile.write`
  for `mode: mode_t`.** Touched separately because the
  signature is part of the project's atomic-write API — every
  call site (currently credential storage at 0o600 mode +
  AppUpdater at 0o700 mode) now flows through the same
  primitive.
- **E-F#3 (R3) — single shared `GitHubRedirectGuard`
  instance.** `static let shared = GitHubRedirectGuard()`
  replaces the per-request allocation. Trivial in absolute
  terms; the value is symbolic alignment.

### Deferred (19 findings)

Worth noting which findings did NOT land:

- **Q-F#3 (med) audit-trail comment narrative.** The fix-history
  comments (`v0.1.7.10 fix:`, `**AU-1 fix:**`, etc.) are
  subjective; they help reviewers correlate code with
  CHANGELOG entries. Punt.
- **Q-F#11 (low) — pipeline-actor architectural split.** A
  ~40% rewrite where `AppUpdater` keeps only state and the
  pipeline becomes a `struct AppUpdaterPipeline`. Real value
  but the right time is v0.2.0 when the cross-platform
  refactor lands.
- **Q-F#8 (low) — `parse_args` clap migration.** Audit
  explicitly rejected clap as overkill at two flags; this
  punt continues at four.
- **R-F#5, R-F#6 (low) — SHA / semver helper extraction.**
  No second caller exists yet (hash verification on
  Naive/RustCore is deferred to v0.2.0 with SHA pinning);
  premature without one.
- The remaining 14 are all low-severity (allocation
  micro-opts, comment style, minor refactor) where the cost
  of churn outweighs the gain. Documented in the simplify
  agent reports for the record.

### Tests + verification

- `cargo check` clean (0 errors, 0 warnings)
- `cargo test --lib` 104/104 pass
- `cargo test --test chaos` 18/18 pass
- `xcodebuild Release` BUILD SUCCEEDED (Swift 6 strict
  concurrency)

## [0.1.7.12] — 2026-05-04 (LTSC patch — Fifth audit cycle, batch 2)

LTSC patch on the v0.1.7 line. Lands the remaining 11 findings
from the Fifth audit cycle's Rule Maker rubric — the medium /
low quality-pass tier. Each fix addresses a root cause
identified by the audit; v0.1.7.11 covered the 8 critical /
high security-critical fixes plus 5 medium/low where the call
was unambiguous. With this release the audit cycle's full
findings list is closed.

### AppUpdater.swift (7 findings)

- **AU-6 (R2, R4) — canonical bundle ID const, not
  `Bundle.main.bundleIdentifier`.** `verifyExtractedApp` now
  compares the new bundle's `CFBundleIdentifier` against a
  hard-coded `canonicalBundleID = "space.coolwhite.naive"`
  baked into the binary, instead of against
  `Bundle.main.bundleIdentifier` (which reads from the running
  process's plist — attacker-controllable if the running app
  was ever substituted, anchoring the trust comparison in the
  attacker's input). The constant matches
  `PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project; if the
  bundle ID legitimately changes, both must update in
  lock-step.
- **AU-8 (R1) — download error message scrubs asset filename.**
  The user-facing message no longer names the failing artifact
  (.zip vs .sha256) or the HTTP status. The asset name isn't
  directly attacker-controlled but the stage tells an
  observer-on-the-wire which artifact failed, helping calibrate
  a partial-block attack against the manifest specifically
  (the SHA-pin root of trust). Stage detail goes to `os_log`
  for support.
- **AU-9 (R2, R4) — read-only check covers bundle perms and
  parent writability.** `refuseReadOnlyInstall` now tests
  three things: the parent volume isn't read-only (DMG mount),
  the parent folder is writable for the current user (admin
  ACL, MDM lockdown), AND the bundle itself isn't immutable
  (Get Info → Locked, `chflags uchg`). Previously only the
  first was checked; the other two failure modes slipped
  through pre-terminate, leaving the user with no app and no
  UI to report once `NSApp.terminate` had fired.
- **AU-10 (R4) — relaunch helper uses `open PATH`, not
  `open -a NAME`.** `open -a` performs name-based app lookup;
  with bundle paths containing spaces ("/Applications/Cool
  tunnel.app") bash word-splits and `-a` treats "Cool" as
  the app name and "tunnel.app" as a document, misfiring the
  relaunch. The bareword form opens the bundle directly.
- **AU-11 (R4) — pre-swap trap preserves recovery materials.**
  The bash relaunch helper installs a `preswap_trap` at the
  top that *retains* `$TEMP_ROOT` (containing the
  verified-good extracted .app) and the `$BACKUP` (if mid-
  rollback) on any error before the swap commits. Only after
  step 4 (BACKUP removed → swap fully succeeded) does the
  trap get replaced with the destructive cleanup. Previously
  a rollback failure during step 3 would also delete
  `$TEMP_ROOT`, leaving the user with neither the new app
  nor a known-good copy to recover from.
- **AU-13 (R1, R4) — `markEnteringCheck` /
  `markEnteringDownload` return `Bool`; spawn is conditional
  on the actual flip.** Settings click handlers used to call
  `guard !appUpdater.isInFlight else { return };
  appUpdater.markEnteringCheck(); Task { ... }` — three
  separate steps that allowed a redundant `Task` to spawn
  when a fast double-click hit the second click's
  `!isInFlight` check before SwiftUI re-rendered (or when
  state was reset by another path between the two flags).
  Now the flip and the spawn are atomic: the click handler
  is `guard appUpdater.markEnteringCheck() else { return };
  Task { ... }`, where the bool return value is the actual
  flip outcome.
- **AU-14 (R2) — `locateAppBundle` filter requires
  `isDirectory`.** A malicious zip can contain an entry
  named `Cool tunnel.app` that is a regular file or symlink
  rather than a bundle directory. Without this filter, the
  next step (`verifyExtractedApp` reading
  `Contents/Info.plist`) failed with a generic "couldn't
  read Info.plist" message instead of a clean "structural
  shape wrong" reject. The filter now demands both the
  `.app` extension AND
  `resourceValues(forKeys: [.isDirectoryKey]).isDirectory ==
  true`.

### server_mode.rs (3 findings) + pac.rs (1 finding)

- **SM-4 (R2, R3) — `naive_pac` caps `direct_domains` at
  1024 entries × 253 bytes each.** The 64 KiB router-wide
  body limit is the outer ceiling, but inside that envelope
  a single request could carry ~16k single-char domain
  entries — each becoming a `to_lowercase()` allocation, a
  `serde_json::to_string` pass, and a `format!` insertion,
  pushing PAC generation past the R3 ≤10 ms target on a
  busy worker. The 1024-entry cap is far above any
  legitimate proxy-bypass list (Cool Tunnel ships ~16 by
  default); 253 bytes matches the RFC 1035 hostname
  maximum. Over-cap requests reject with
  `ApiError::BadRequest` and a `tracing::warn!` for support.
- **SM-6 (R3) — resolved by SM-4.** The audit had flagged
  PAC generation as potentially blocking the tokio worker
  but explicitly warned against `spawn_blocking`-without-cap
  (which would just move the unbounded work elsewhere).
  With SM-4 caps in place the synchronous cost is bounded
  well under 10 ms; no `spawn_blocking` is needed. Documented
  as a comment in the handler to lock in the reasoning.
- **SM-7 (R4) — `encode_js_string_array` uses `expect`,
  not `unwrap_or_default`.** `serde_json::to_string` over
  `&[String]` is structurally infallible — `String` has no
  `Serialize` failure modes. The defensive
  `unwrap_or_default()` silently emitted `String::new()` on
  the unreachable path: if a future refactor swapped
  `&[String]` for a type that *can* fail, the PAC body
  would become `var directDomains = ;` (invalid JS) with
  zero diagnostic. `expect()` restores the failure signal
  and names the invariant for whoever reads the trace.
- **SM-10 (R3) — router gets
  `tower::limit::ConcurrencyLimitLayer(64)`.** Caps total
  in-flight requests across all routes. Far above any
  legitimate Filament admin UI workload but bounds the
  worst-case for a slow-loris client dripping bytes into a
  64 KiB body — the connection still has to wait, but the
  server can't be made to hold more than 64 simultaneously.
  Combined with hyper's default keepalive timeout, the
  resource exhaustion path is capped without needing the
  `tower::timeout::TimeoutLayer` boilerplate (which
  introduces a non-Infallible error type and requires
  `HandleErrorLayer` plumbing). A proper body-read timeout
  is deferred to a later cycle. New direct dep: `tower =
  { version = "0.5", features = ["limit"] }` (already in
  the tree transitively via axum; no new crates pulled in).

### Tests

- 104 lib tests + 18 chaos tests pass on this revision (no
  test changes — all existing invariants preserved by the
  fixes).
- Swift app compiles clean under Swift 6 strict concurrency.

### Audit cycle closed

With this release the full Fifth audit cycle's findings list
(25 across `server_mode.rs` and `AppUpdater.swift`) is closed:

- v0.1.7.11 landed: AU-1, AU-2, AU-3, AU-4, AU-5, AU-7,
  AU-12, AU-15, SM-1, SM-2, SM-3, SM-5, SM-9 (13 fixes).
- v0.1.7.12 lands: AU-6, AU-8, AU-9, AU-10, AU-11, AU-13,
  AU-14, SM-4, SM-6, SM-7, SM-10 (11 fixes). SM-8
  (logging policy) was folded into v0.1.7.11's
  `server_mode.rs` header doc.

Net audit-driven change across the cycle: 24 fixes against
4 source files (`server_mode.rs`, `AppUpdater.swift`,
`config/naive_config.rs`, `config/pac.rs`) plus supporting
files (`Cargo.toml`, `main.rs`, `SettingsView.swift`).

## [0.1.7.11] — 2026-05-04 (LTSC patch — Fifth audit cycle, batch 1)

LTSC patch on the v0.1.7 line. Fifth audit cycle, with the
findings rated against the **Rule Maker** rubric (R1 fail-secure,
R2 boundary enforcement, R3 ≤10ms latency on the core path, R4
no theatre — every fix addresses the root cause, not the
symptom). 25 findings total across `core/src/server_mode.rs` and
`COOL-TUNNEL/SystemIntegration/AppUpdater.swift`; this release
lands the must-fix tier (8 critical/high) plus 5 medium/low
where the fix was small and the call unambiguous. Remaining 12
findings ship in v0.1.7.12.

### Critical / high (8)

- **AU-1 (R2, R4) — relaunch helper script no longer in `/tmp`.**
  Previously `String.write(to:atomically:)` created the script
  with default umask perms (typically 0644), then a separate
  `setAttributes(0o700)` call tightened them — leaving a tiny
  but real window where a same-UID attacker could swap the
  script via symlink before `task.run()`. The script now lives
  in the per-update `tempRoot` and is created via
  `open(O_CREAT|O_EXCL|O_WRONLY, 0o700)` so it is born with the
  right mode and never exists with any other. New helper
  `writeRelaunchScript` owns the FD lifecycle, fsyncs before
  close, and surfaces `errno` on failure for support.
- **AU-2 (R2) — GitHub asset URLs validated before fetch.**
  `validateInstallAssets` now requires both the `.zip` and
  `.sha256` `browser_download_url`s to be HTTPS on a host that
  ends in `github.com` or `githubusercontent.com`. A compromised
  or attacker-shaped API response that pointed the manifest
  fetch at an attacker host would defeat SHA pinning by
  substituting the verification root-of-trust; this gate cuts
  that path at the seam where operator intent ("releases come
  from GitHub") is encoded.
- **AU-3 (R2) — HTTP redirects constrained to GitHub-served
  hosts.** All four updater fetches (releases API, .zip,
  .sha256, plus future) now use a per-task `URLSessionTaskDelegate`
  (`GitHubRedirectGuard`) that rejects any HTTP redirect whose
  target isn't on the same trusted suffix list AU-2 enforces.
  `URLSession.shared.download(from:)` was previously following
  up to ~20 redirects with no host check — a CDN takeover or
  misconfigured GitHub edge could substitute the manifest at
  this layer, defeating SHA pinning end-to-end.
- **AU-4 (R3) — SHA hashing + plist read off `@MainActor`.**
  The pipeline helpers (`run`, `runPipeline`, `download`,
  `verifyZipAgainstManifest`, `unzip`, `verifyExtractedApp`,
  `refuseExtractionEscapingSymlinks`, `refuseReadOnlyInstall`,
  `spawnRelaunchHelper`, plus all helpers and parsers) are now
  `nonisolated`. `verifyZipAgainstManifest` streams the .zip
  through `FileHandle.read(upToCount:)` 64 KiB at a time
  instead of `Data(contentsOf: zipURL)` — a 12 MB allocation on
  the main thread previously froze the Settings UI on slow
  disks, especially Intel Macs with HDDs. Plist parsing now
  runs in `Task.detached(priority: .userInitiated)` and returns
  a `Sendable` carrier struct (`ExtractedAppInfo`) rather than
  the non-Sendable `[String: Any]`.
- **AU-5 (R2, R4) — `realpath(3)` + path-component ancestor
  check in symlink-escape walk.** `refuseExtractionEscapingSymlinks`
  no longer uses `String.hasPrefix(containerPath)`, which gave
  two classes of false negatives: (1) sibling-path collision
  (`/extracted-evil` passed against `/extracted` — no trailing
  separator), and (2) symlink-target traversal
  (`URL.resolvingSymlinksInPath()` resolves the link itself but
  doesn't normalise `..` *through* the resolved target).
  `realpath(3)` returns a fully-canonical absolute path; the
  comparison is now `targetComponents.starts(with:
  containerComponents)`. Broken symlinks now reject outright
  rather than passing silently.
- **SM-1 (R1, R2) — `JsonRejection` scrubbed at every handler
  boundary.** Every `axum::Json<T>` handler now takes
  `Result<Json<T>, JsonRejection>` and converts the rejection
  via `ApiError::from_json_rejection` — which logs the verbatim
  serde error server-side via `tracing::warn!` and returns
  `{"error":"bad request"}` to the wire. Previously axum's
  default 400 body included the verbatim serde error
  (containing internal field names and the engine's domain
  validation rules — e.g. `"server: contains forbidden ':/​/'"`),
  which is a free probe of internal validation logic for an
  unauthenticated caller.
- **SM-2 (R1) — `ApiError` carries no payload.** Both
  `ApiError::BadRequest` and `ApiError::Internal` are now
  unit variants. The wire body is a stable opaque string per
  HTTP status (`"bad request"` / `"internal error"`); the
  cause-of-failure detail goes to `tracing::error!` only. The
  previous `Internal(String)` field structurally invited callers
  to interpolate `serde_json::Error` (which embeds line/column/
  field info) — removing the field forces logging-only.
- **SM-3 (R4, R2) — `naive_validate` honours its advertised
  contract.** Previously the handler took `Json<Profile>` and
  dropped the value with `_`; deserialize failures became 400s
  from the axum extractor, so the `ok:false` branch of
  `ValidationReport` was structurally unreachable. The handler
  now accepts any JSON value, runs the `Profile` deserializer
  itself, and returns `{ok:false, reason:"invalid profile"}`
  on failure (with the detailed cause logged server-side) and
  `{ok:true}` on success. Both wire-shape branches are now
  reachable by well-behaved callers.

### Medium / low (5)

- **AU-7 (R1) — version-mismatch error scrubs attacker-
  controlled plist value.** The error string in
  `verifyExtractedApp` no longer interpolates the new bundle's
  `CFBundleShortVersionString`. An attacker who got past SHA
  pinning could plant a Unicode bidi-override or fake
  "click here to bypass" text in that string and have it
  rendered into the Settings panel; the actual value now goes
  to `os_log` for support tickets.
- **AU-12 (R1, R2) — `versionIsNewer` rejects non-numeric
  segments + pre-release suffixes.** The previous `Int($0) ?? 0`
  silently coerced `"0-rc1"` to 0, making `1.0.0-rc1` compare
  *equal* to `1.0.0`. New helper `parseVersionSegments` returns
  `nil` if the version contains `-` (pre-release marker) or
  any segment fails to parse strictly; `versionIsNewer` then
  short-circuits to `false` (no upgrade offered).
  `/releases/latest` already excludes pre-releases, so the
  legitimate path is unaffected.
- **AU-15 (R2) — `public` removed from within-module symbols.**
  `AppUpdater`, `State`, `AvailableRelease`, `UpdaterError`,
  the public-state property, the lifecycle methods
  (`init`, `checkForUpdates`, `downloadAndInstall`, `reset`,
  `isInFlight`, `markEnteringCheck`, `markEnteringDownload`)
  and their associated types all dropped to `internal`
  (the default). Cool Tunnel ships as a single app target —
  no cross-module consumer needs `public`. Shrinks the API
  surface a future code path can accidentally reach.
- **SM-5 (R2) — `NaiveConfig` fields are `pub(crate)`.** The
  struct's invariants (`listen` is `socks://127.0.0.1:<port>`,
  `proxy` embeds percent-encoded credentials) are guaranteed
  by `from_profile` and lost the moment an external caller can
  construct `NaiveConfig { listen: "...", proxy: "..." }`
  directly. Locking the constructors closes that back-door
  without affecting `Serialize` (derive sees private fields
  fine) or any current call site (handlers only ever go
  through `from_profile` + `to_pretty_json`).
- **SM-9 (R2) — `--listen` non-loopback requires
  `--allow-public`.** `server_mode::run` now refuses to bind a
  non-loopback address unless the caller explicitly passed
  `allow_public: true` (set by `--allow-public` on the CLI),
  returning `io::ErrorKind::PermissionDenied` with a message
  that tells the operator exactly what the flag is for. The
  loopback-only deployment posture was previously documented
  but not enforced; a `--listen 0.0.0.0:8787` typo silently
  exposed an unauthenticated engine. With the gate, the
  exposure is now a one-flag-acknowledgement decision instead
  of a silent security hole.

### Tests

- 104 lib tests + 18 chaos tests pass on this revision (no
  changes — the audit fixes preserve every test invariant).
- Swift app compiles clean under Swift 6 strict concurrency
  with `nonisolated` propagation through the entire pipeline.

### Logging policy (new — `core/src/server_mode.rs` header)

Codified as a doc comment at the top of `server_mode.rs`:
handlers MUST NOT log the request body, the resolved `Profile`,
or `ApiError::*` payloads. `Profile` carries `Password::expose_secret`,
and a "let's log the failing body for debug" PR would silently
leak credentials. When you need diagnostic detail, log the
*cause* (a `serde_json::Error`'s `Display` is fine — it only
references field paths, never values) but never the payload
itself.

### Deferred to v0.1.7.12 (12 findings)

AU-6 (bundle-ID ASCII-only impersonation), AU-8 (download HTTP
status leak), AU-9 (read-only check tests parent only),
AU-10 (`open -a "$OLD_APP"` semantics with spaces),
AU-11 (helper trap order), AU-13 (click race in
`markEnteringCheck`), AU-14 (`locateAppBundle` accepts
files/symlinks), SM-4 (`NaivePacRequest.direct_domains` cap value
needs decision), SM-6 (`spawn_blocking` only matters if SM-4
lands), SM-7 (`encode_js_string_array` `unwrap_or_default`),
SM-8 (logging policy as a checked lint, not just a doc comment),
SM-10 (router timeout/concurrency tower layers).

## [0.1.7.10] — 2026-05-04 (LTSC patch — comprehensive audit + security)

LTSC patch on the v0.1.7 line. Two parallel comprehensive audits
(Swift + Rust) plus a tooling self-audit. Fixes one real
regression I shipped in v0.1.7.9, several security-relevant
hardenings on the in-app updater, and a wire-ordering race in
the engine's stop path.

### Regression fix (urgent)

- **AppUpdater Check + Update buttons were broken in v0.1.7.9.**
  The `markEnteringCheck()` / `markEnteringDownload()` sync
  flag I added flipped `state` to the placeholder phase
  *before* the async method's `guard !isInFlight` check, so the
  guard returned early and the network call never fired. Click
  the button → state stuck at `.checking` forever. Fixed:
  relaxed the guards in `checkForUpdates` and
  `downloadAndInstall` to refuse only when a *genuinely active*
  later phase (downloading, verifying, extracting, relaunching)
  is in flight, treating the placeholder `.checking` /
  `.downloading(0.0)` as "we are the in-flight check".

### Security — Swift in-app updater

- **Sw-H1 — Bundle-identifier comparison hardened.** Both the
  running app and the new app's bundle IDs are now
  `precomposedStringWithCanonicalMapping`-normalised, and any
  non-ASCII character causes outright rejection. Defence in
  depth against Unicode-confusable bundle IDs if SHA pinning
  were ever defeated.
- **Sw-H2 — SHA mismatch error message no longer echoes the
  hashes.** Echoing both expected and got values into the
  user-facing error helps a MITM observe what hash they need
  to forge. New message just says verification failed; tracing
  retains both values for debugging via support tickets. Plus:
  manifest entries are now hex-validated before SHA compare so
  a corrupted-but-64-chars manifest line gives a clean
  "manifest may be corrupted" message instead of a misleading
  "SHA-256 mismatch".
- **Sw-H3 — Download size cap.** `URLSession.shared.download`
  will happily fetch a multi-GB file. New caps: .zip ≤ 100 MB,
  .sha256 ≤ 1 MB. A confused-deputy URL or compromised release
  can no longer fill the user's disk. Real streaming-cancel
  needs `URLSessionDownloadDelegate`, deferred to v0.2.
- **Sw-H4 — Symlink-escape walk after extraction.** `ditto -x
  -k` (PKZip mode) preserves symlinks INSIDE the archive,
  including ones pointing OUTSIDE the extraction directory. A
  malicious zip whose only deviation from a known-SHA copy was
  an attacker-controlled symlink (e.g. `Resources/foo →
  ~/.ssh/config`) would have planted a side-channel pointer.
  New post-extraction walk rejects any symlink whose realpath
  escapes the extraction dir.
- **C1 — `AppUpdater.unzip` pipe-buffer deadlock fixed.**
  `Process` with shared stdout/stderr pipe → `waitUntilExit`
  blocks if `ditto` writes >64 KB to stderr (the kernel pipe
  buffer fills, ditto blocks on next write, deadlock). Routed
  through `Subprocess.run` which drains both pipes
  concurrently with timeout escalation. (Same bug class
  `Subprocess.swift` was created to fix in v0.1.7.3 — AppUpdater
  shipped in v0.1.7.6 and inherited the older buggy pattern.)
- **C2 — Relaunch helper script now does atomic .new staging
  with rollback.** Previous `rm -rf "$OLD_APP" && ditto …`
  was destructive with no recovery. If `ditto` failed
  mid-copy (ENOSPC, signal), the user was left with NO Cool
  Tunnel installed. New flow: ditto into `$OLD_APP.new` →
  `mv $OLD_APP $OLD_APP.old-update` → `mv $OLD_APP.new
  $OLD_APP` → `rm -rf $OLD_APP.old-update`. Restores from
  backup on any failure. Plus `set -eu` and `trap cleanup
  EXIT` so the temp tree is removed on every exit path.
- **C4 — `RestrictedFile.write` fsync check + double-close
  fix.** The `fsync(fd)` return value was discarded, so a
  silent disk EIO meant the atomic rename pointed at unflushed
  bytes — a crash right after rename would yield an empty/partial
  credentials.json. Plus a real double-close in the catch path
  (could corrupt an unrelated fd that macOS reused). Both
  fixed; a `didClose` flag tracks state across paths.
- **H5 — `AppUpdater.run` tempRoot leak fixed.** Every failed
  validation path used to leak the temp tree forever. Wrapped
  in a do/catch that cleans up on any throw. Plus
  `Bundle.main.bundleURL.resolvingSymlinksInPath()` so
  symlinked install paths (rare, sometimes seen on managed
  Macs) are evaluated by their real destination for the
  read-only check.

### Wire-protocol correctness — Rust engine

- **Ru-A1 — Single-emitter discipline for `state_changed:false`.**
  The v0.1.7.5 message-pump refactor moved user-stop event
  emission to the dispatcher, but `monitor_lifecycle` retained
  the natural-death emit. Two paths could fire for the same
  transition if naive crashed concurrently with a user-stop.
  Fixed: `monitor_lifecycle` no longer emits state-changed at
  all; `client_mode::monitor_loop`'s natural-death detection
  (PID polling) now owns natural-death emission, gated by an
  at-most-once flag (`emitted_stopped`) in `EngineState` so it
  yields to the dispatcher's user-stop emission. Validated by
  new `siege_natural_death_then_user_stop_emits_once` chaos
  scenario.
- **Ru-A2 — `Proxy-Authorization` header now redacted.** The
  log-line redaction regex required the literal `Authorization:`
  prefix; `naive`/curl emit `Proxy-Authorization: Basic
  <b64-of-user:pass>` on upstream-proxy failure and the prior
  regex let it through verbatim, undoing the rest of the
  credential-hygiene effort. New regex: `(?:Proxy-)?Authorization:`.
  Two new unit tests in `redaction.rs` lock in the fix.
- **Ru-A3 — Stop-side TOCTOU race fixed.** The dispatcher
  released the engine lock between `take()` and
  `supervisor.stop().await`. During the (potentially 2-second)
  window, `EngineState.supervisor` was `None`, so a concurrent
  `start_proxy` would spawn a *second* `naive` while the first
  was still draining. Symmetric to the start-side fix from
  Ru#C2 (v0.1.7.3). Now: dispatcher sets `stopping = true`
  under the lock; `start_proxy` checks both `supervisor.is_some`
  AND `stopping` to refuse. Validated by new
  `siege_concurrent_stop_proxy_race` chaos scenario.
- **Ru-A4 — `stdout_writer` fallback on serialize failure.**
  `serde_json::to_vec` is essentially infallible for our
  current `Outbound` shape, but if a future field ever fails
  (NaN float, non-UTF-8), the writer logged and continued —
  silently dropping the response, leaving the Swift waiter
  pending forever. New fallback writes a hand-built error
  frame with the original `id` so the waiter resolves with a
  real error.
- **Ru-B6 — `ProxySupervisor::Drop` aborts the monitor task.**
  Previously only signalled kill via `kill_tx`; the JoinHandle
  was leaked on the runtime if the supervisor was dropped
  without `stop()` being called.

### Chaos suite extended

- 18 → 18 + 2 new scenarios:
  - `siege_concurrent_stop_proxy_race` — verifies Ru-A1+A3
    (exactly one `Stopped` response, one `not_running` error,
    one `state_changed:false` event for one transition).
  - `siege_natural_death_then_user_stop_emits_once` — verifies
    Ru-A1 single-emitter discipline holds when both paths
    could fire.
- Two new redaction unit tests cover Ru-A2.
- **20 chaos + 104 unit + 6 integration + 2 doctest = 132
  tests total**, all green.

### Tooling

- `cargo deny check` now runs in CI. The `deny.toml` policy
  (advisory-as-error, license allow-list, crates.io-only
  source) was previously policy-without-enforcement.
- `multiple-versions = deny` (was `warn`) in deny.toml. Cargo.lock
  has zero duplicates today; new ones must be allow-listed
  via `skip` going forward.
- swift-format CI step hard-fails if the tool isn't on PATH
  (was soft-fail → silent no-op).

### Items deliberately not delivered

- **Ru-B1 (oneshot for pid_alive):** the `/bin/kill -0`
  polling adds ~17k spawns/day under sustained operation.
  Replacing with a oneshot from `monitor_lifecycle` is the
  right design but requires plumbing a new channel. Defer.
- **Ru-B5 (Password/Username `Drop::clear`):** parity item.
  Defer with the rest of the encryption-at-rest work.
- **Sw-H6 (KeychainStore `WhenUnlockedThisDeviceOnly`):** the
  legacy migration backend; touch surface is small but
  changing the accessibility flag affects credential
  syncability for users mid-migration. Defer.
- **Sw-H8 (Subprocess race on terminationHandler):** the race
  window is theoretical (Foundation's documented behaviour).
  Defer with the broader Subprocess refactor.
- **Sw-H9 (CoreClient.stdin write blocking):** sits with the
  deferred Sw#5/6 broken-pipe + race-y shutdown work.
- **T2 (security_check.sh in CI):** would require building
  the full .app on CI (currently CI builds only
  cool-tunnel-core). Significant scope expansion. Document
  the manual-pre-tag run as the contract.

### Files

- `core/src/client_mode.rs` — EngineState gets `stopping` +
  `emitted_stopped` flags; StopProxy holds lock + pre-claims
  emission gate; start_proxy refuses if stopping; monitor_loop
  natural-death path claims the gate; stdout_writer fallback.
- `core/src/supervisor/mod.rs` — `monitor_lifecycle` no longer
  emits StateChanged; ProxySupervisor::Drop aborts monitor;
  unit test updated.
- `core/src/redaction.rs` — `(?:Proxy-)?Authorization` regex;
  two new unit tests.
- `core/tests/chaos.rs` — two new siege scenarios.
- `COOL-TUNNEL/SystemIntegration/AppUpdater.swift` — relaxed
  re-entry guards (M1 regression fix); unzip via Subprocess
  (C1); helper script atomic swap with rollback (C2);
  tempRoot cleanup on validation failure (H5); bundle-id
  precomposed normalize + ASCII-only (Sw-H1); SHA hex
  validate + scrub error message (Sw-H2); download size cap
  (Sw-H3); symlink-escape walk after extraction (Sw-H4).
- `COOL-TUNNEL/SystemIntegration/AppSupportPaths.swift` —
  fsync check + double-close fix (C4).
- `.github/workflows/ci.yml` — cargo-deny step; swift-format
  hard-fail.
- `core/deny.toml` — multiple-versions: warn → deny.

## [0.1.7.9] — 2026-05-03 (LTSC patch — UI/UX stress audit)

LTSC patch. Fourth UI audit on the v0.1.7.x line, this time
focused on the surfaces added since the last visual audit
(in-app updater UI, dark-mode dynamic palette, updater state
machine). Audit returned 38 findings; this patch closes the
high-confidence visible bugs + dark-mode contrast issues.

### Honest progress text (was: "Downloading 0%…" forever)

The in-app updater showed `"Downloading \(Int(p * 100))%…"`
with `p` always 0.0 because `URLSession.shared.download(from:)`
doesn't report byte-level progress. Users on slow connections
would stare at "Downloading 0%…" for minutes and reasonably
conclude the app had hung.

**Fixed:** subtitle now reads `"Downloading… (typically a few
seconds on broadband)"` — honest about the indeterminate
nature of the operation.

### Sync re-entry guard on the Check + Update buttons

The naive/rust updater buttons in this same file flip a
synchronous `isInspecting = true` flag in the click handler
*before* spawning the Task — so a fast double-tap can't
queue two operations. The new AppUpdater Check/Update
buttons didn't follow this pattern; rapid clicks queued
multiple Tasks that each fired their own re-entry guard
*after* the first completed.

**Fixed:** added `markEnteringCheck()` / `markEnteringDownload()`
methods on `AppUpdater` that flip `state` synchronously; the
Settings handlers call them before `Task { ... }`. Mirrors
the proven naive/rust pattern.

### Dark-mode card edges restored (`PupCardModifier`)

Three problems on dark stacked together:

- `.shadow(color: Color.black.opacity(0.06))` — invisible on
  near-black window backgrounds; cards floated with no edge.
- `borderInk.opacity(0.45)` border — barely visible because
  the dark `borderInk` variant is itself muted (RGB 0.55).
- `paper.opacity(0.4)` overlay — defeated the
  `.regularMaterial` vibrancy in dark mode, making cards
  read as opaque rectangles.

**Fixed:** `PupCardModifier` now reads `@Environment(\.colorScheme)`
and picks mode-aware values:
- Shadow: `Color.black.opacity(0.55)` in dark, 0.06 in light.
- Border opacity: 0.65 in dark, 0.45 in light.
- Paper overlay: 0.18 in dark, 0.40 in light (lets the
  vibrancy material show through).

### Status pill backgrounds — mode-aware opacity

Six sites used `.opacity(0.10)` for the green/red OK/NG
verdict pills, the macBlue release-notes pill, and the red
failed pill. On dark backgrounds 10% opacity vanishes; pills
stop being a visual cue. New `CTSurface.statusPillAlpha(scheme)`
helper returns 0.22 in dark, 0.10 in light. All six sites
migrated.

### LogConsole inner surface inverted in dark

The log scrollview's `paper.opacity(0.55)` background made
the surface read *lighter* than the surrounding pupCard in
dark mode (mental model: "logs should be recessed/darker, not
highlighted"). Now uses `Color.black.opacity(0.35)` in dark
to recess the surface like the user expects.

### Updater UX polish

- **`.relaunching` delay bumped 500 ms → 1.2 s.** The 500 ms
  was below SwiftUI's render budget on Intel Macs — users
  often never saw the "Relaunching…" state before AppKit
  began terminating.
- **`appUpdaterSection` wrapped in single VStack** so the
  title row + status row read as one Form-section row, not
  two with intra-row padding between them.
- **Wording fix:** `"(was 0.1.7.8)"` → `"— you're on
  0.1.7.8"`. "was" implied past tense; the user is currently
  on the older version, not historically.
- **Update button gets `.layoutPriority(1)`** so it can't
  get clipped at min window width (780pt) when the subtitle
  is long.
- **Release-notes Link**: combined into single self-describing
  link (`"View release notes for v0.1.7.9"`) instead of two
  disconnected elements; added trailing `arrow.up.right`
  glyph; underlined. VoiceOver hears one unambiguous link.
- **Failed-state row**: switched to `HStack(alignment: .top)`,
  added `fixedSize(vertical:)` + `frame(maxWidth: .infinity)`
  so multi-line errors render cleanly with the icon and
  Dismiss button anchored at the top. "Reset" → "Dismiss"
  (more accurate semantically).
- **`appUpdater.reset()` added to `onDisappear`** so a
  `.failed` or `.upToDate` state doesn't survive the
  Settings dismiss/re-open cycle. (True orphan-download
  cancellation deferred to v0.2.)

### Connection form first-run hint — dark-mode contrast

`macBlueSoft.opacity(0.18)` was nearly invisible on dark
backgrounds. New mode-aware `firstRunHintFill` keeps the
existing light look and uses `macBlue.opacity(0.22)` in dark.

### Add Domain field accepts Return

Previously, pressing Return inside the "Add direct domain"
TextField fell through to the Done button's
`.keyboardShortcut(.defaultAction)` and dismissed Settings
without adding the typed value. New `.onSubmit { addDomain() }`
on the TextField does the obvious thing.

### Accessibility improvements

- **Appearance picker** now exposes the current selection via
  `.accessibilityValue(draft.appearanceMode.displayName)` —
  VoiceOver hears "App appearance, Dark, picker" instead of
  just "App appearance, picker".
- **Updater progress spinner** carries
  `.accessibilityLabel(...)` describing the current phase
  ("Downloading update", "Verifying download integrity",
  etc.) instead of the generic "progress indicator".
- **Release notes link** has explicit `accessibilityLabel`
  noting it opens in browser.

### Files

- `COOL-TUNNEL/Views/MalteseTheme.swift` — `PupCardModifier`
  reads colorScheme; new `CTSurface.statusPillAlpha`.
- `COOL-TUNNEL/Views/SettingsView.swift` — VStack wrap, sync
  guards, Dismiss button, status-row redesign, onDisappear
  reset, picker accessibilityValue, Add Domain onSubmit, all
  pillAlpha conversions.
- `COOL-TUNNEL/Views/LogConsoleView.swift` — dynamic surface
  fill.
- `COOL-TUNNEL/Views/ConnectionFormView.swift` — dynamic
  firstRunHint fill.
- `COOL-TUNNEL/SystemIntegration/AppUpdater.swift` —
  `markEnteringCheck/Download` methods, `isInFlight` made
  `public`, relaunching delay bumped.

### Engine + chaos suite

Unchanged. UI-only patch. All 126 tests still pass.

### Deferred to v0.2.0

- Real cancel button + URLSessionDownloadDelegate
  (orphan-download lifecycle)
- Promote AppUpdater out of SettingsView's @State so download
  state survives Settings dismiss/re-open
- Real download progress bar (would replace
  `URLSession.shared.download` with a delegate-driven flow)

## [0.1.7.8] — 2026-05-03 (LTSC patch — updater bugfix)

LTSC patch. Two real bugs surfaced when the v0.1.7.7
in-app updater was first used in production:

### Bug 1 (release process) — `.sha256` manifest missing from GitHub releases

`scripts/package_release.sh` has been generating a
`Cool-tunnel-vX.Y.Z.sha256` integrity manifest for every
release since v0.1.4, but my `gh release create` commands
never included that file. So the manifest existed in
`dist/` locally but never made it onto the GitHub release
page. The v0.1.7.6 in-app updater (which depends on the
manifest for SHA-256 pinning) had no way to verify any
release, including the same one it was running on.

**Fixed:**
- Backfilled the missing `.sha256` manifests onto v0.1.7.5,
  v0.1.7.6, v0.1.7.7 release pages.
- `scripts/package_release.sh` now prints the canonical
  `gh release create` command at the end of every package
  run, with all five required assets pre-filled, so future
  publishes copy-paste the right thing instead of typing
  it from memory.

### Bug 2 (updater UX) — "up to date" reported as failure

The in-app updater fetched the latest release and validated
that both `.zip` and `.sha256` assets existed BEFORE
comparing the latest version to the running version. So a
release missing the manifest threw "Update failed: missing
manifest" even when the user was already on the latest
version (no install would happen anyway). The right
behaviour is to compare versions first and only require
the manifest when there's actually something to install.

**Fixed:** `AppUpdater.fetchLatestRelease` split into
`fetchLatestReleaseMetadata` (cheap, returns the bare
release info) + `validateInstallAssets` (returns the
fully-validated `AvailableRelease`). The `checkForUpdates`
flow now calls metadata first, compares versions, and only
calls `validateInstallAssets` when an upgrade is actually
on offer. Same-version-as-running shows "You're on the
latest version" cleanly.

### Files

- `COOL-TUNNEL/SystemIntegration/AppUpdater.swift` —
  metadata/validation split; `checkForUpdates` reordered.
- `scripts/package_release.sh` — emits the canonical
  publish command at the end.

### Engine + chaos suite

Unchanged. UI + release-process patch only. All 126 tests
still pass.

## [0.1.7.7] — 2026-05-03 (LTSC patch — light/dark mode)

LTSC additive feature. Closes the **Sw#24 deferred audit item**
(dark-mode dynamic palette) and adds a user-controlled appearance
preference. Three options in Settings → Appearance:

- **Match System** (default) — follows the macOS appearance.
- **Light** — locks to the System 7 / Platinum-era palette.
- **Dark** — locks to a tuned dark palette regardless of macOS.

### What changed

**`CTPalette` is now fully dynamic.** Every token (`paper`,
`platinum`, `borderInk`, `bodyInk`, `macBlue`, `macBlueSoft`,
`cherryRose`, `bunnyPink`, `lilac`, `mint`) resolves to a
light or dark variant via `NSColor(name:dynamicProvider:)`. The
view layer is unchanged — same names, same call sites — so
every existing pane, chip, badge, and card adapts
automatically. Light variants are byte-identical to what
shipped through v0.1.7.6 (no visual change for existing users
on light mode); dark variants are tuned for the same System 7
mood with inverted luminance and slightly brighter accents to
compensate for the dark surround.

**`AppearanceMode` enum** added to `AppSettings`:
`.system` / `.light` / `.dark`. Persisted as a string in
UserDefaults under the new `appearanceMode` key. Unknown
stored values fall back to `.system` so a forward-incompatible
write from a future build downgraded back to v0.1.7.7 doesn't
crash.

**`ContentView`** applies `.preferredColorScheme(orchestrator.settings.appearanceMode.colorScheme)`
on the root. `.system` returns nil → SwiftUI follows the
macOS appearance; `.light`/`.dark` lock the app regardless.
The dynamic palette resolves itself the moment the appearance
changes — no view-tree invalidation needed.

**Settings → Appearance section** — new segmented picker
(Match System / Light / Dark) with a one-line subtitle
explaining the chosen option. Bound to `draft.appearanceMode`
with an `.onChange` that pushes the change through the
orchestrator + `persistSettings()` immediately, so the live
preview happens *before* the user clicks Done.

### Existing v0.1.7.6 users on dark mode

If you've been running on macOS dark mode, the app has been
rendering with the light palette (near-white surfaces). After
updating to v0.1.7.7 with the default `.system` setting, the
app picks up your dark mode automatically. If you preferred
the old behaviour (always light regardless of system), set
Settings → Appearance → Light.

### Files

- **Modified:** `COOL-TUNNEL/Persistence/SettingsStore.swift`
  — new `AppearanceMode` enum, new field on `AppSettings`,
  load/save in UserDefaults.
- **Modified:** `COOL-TUNNEL/Views/MalteseTheme.swift` — every
  `CTPalette` static is now a dynamic `NSColor`. Added a
  private `dynamic(light:dark:)` helper.
- **Modified:** `COOL-TUNNEL/Views/ContentView.swift` —
  `.preferredColorScheme` modifier on the root.
- **Modified:** `COOL-TUNNEL/Views/SettingsView.swift` — new
  Appearance Section with the segmented picker.

### Engine + chaos suite

Unchanged. This is a UI-only patch. All 126 tests still pass.

## [0.1.7.6] — 2026-05-03 (LTSC patch — in-app self-updater)

LTSC additive feature. New "Cool Tunnel" Settings section with
**Check for Updates** + **Update to vX.Y.Z** buttons. Mirrors
the existing Naive Binary / Rust Core sections; clicks the
release flow for the user — no manual drag-to-Applications, no
terminal, no `sudo`.

### What it does

1. **Check** — `GET /releases/latest` from the GitHub API.
   Compares the tag to the running app's
   `CFBundleShortVersionString`. Renders one of:
   *up-to-date*, *update available with release-notes link*,
   or *failed with error message + Reset button*.
2. **Update** — when a newer release exists:
   - Downloads the `Cool-tunnel-vX.Y.Z.zip` asset.
   - Downloads the matching `Cool-tunnel-vX.Y.Z.sha256`
     manifest.
   - Computes SHA-256 of the .zip via CryptoKit; refuses to
     install on any mismatch.
   - Extracts via `ditto -x -k` (preserves macOS metadata
     including the bundle's code signature).
   - Verifies the new app: bundle identifier matches,
     `CFBundleShortVersionString` matches the release tag,
     `CodeSignVerifier` accepts.
   - Refuses to install if the running app is on a read-only
     volume (DMG mount or quarantine staging).
   - Writes a tiny bash relaunch helper to `/tmp` and spawns
     it detached. The helper waits for the parent PID to
     exit, ditto-replaces the bundle, runs `open -a` on the
     new copy, then cleans up.
   - The app quits.

### Security posture — **closes Sw#C4 for this surface**

The Sw#C4 audit finding called out that the existing
NaiveUpdater + RustCoreUpdater download a binary, ad-hoc sign
it, and then accept it on next launch — defeating the
`CodeSignVerifier` check against a MITM on the GitHub asset
URL. The audit said the real fix is "a release-SHA-256
manifest the updaters can pin against" but flagged it as
deferred because it required a release-process change.

`scripts/package_release.sh` already publishes that manifest
for every release — it just wasn't being consumed. The new
AppUpdater consumes it. The MITM hole is closed for the .app
itself; retrofitting NaiveUpdater + RustCoreUpdater stays
queued for v0.2.0.

### What it deliberately does NOT do

- **Does not request admin escalation.** `/Applications` is
  admin-group writable on default macOS installs; no `sudo` or
  auth dialog ever fires. If the user is non-admin and the
  app is in a non-writable location, the update fails with a
  clear message rather than prompting.
- **Does not auto-check on launch.** The "Check" button is
  user-initiated only. Cool Tunnel still makes zero network
  calls at launch unless the user clicks something.
- **Does not auto-update.** Every step is explicit click.

### Files

- New: `COOL-TUNNEL/SystemIntegration/AppUpdater.swift` (~410
  lines) — pipeline, SHA verification, helper-script writer.
- Modified: `COOL-TUNNEL/Views/SettingsView.swift` — new
  "Cool Tunnel" section with the Check/Update affordance.
- Engine and chaos suite unchanged.

## [0.1.7.5] — 2026-05-03 (LTSC patch — chaos siege)

LTSC siege patch. The chaos engineering work returned three real
fixes plus four new siege-grade tests that hold the engine to a
stricter wire-ordering contract under burst.

### Engine fix — Ru#C4 wire ordering (no longer deferred)

The engine previously emitted `Event::StateChanged { running: true }`
from inside `ProxySupervisor::spawn`, *before* `start_proxy`
returned the `Started { pid }` response. The two flowed through
different channels (event_tx + event_bridge vs outbound_tx) and
the event could overtake the response on the wire. Same shape
on the stop side: `monitor_lifecycle` emitted
`StateChanged { running: false }` regardless of who triggered
the kill.

Fixed by moving the user-initiated transition events into
`handle_request`, emitted on the same outbound channel as the
response, AFTER the response writes. FIFO ordering on the
channel now guarantees `response → state_changed event`.
`monitor_lifecycle` retains the natural-death event (naive
crashes on its own — there's no associated response to order
against). Wire shapes unchanged; only the ordering contract
tightens.

Verified by new siege test `siege_wire_ordering_holds_under_burst`
which fires 10 start/stop cycles back-to-back and asserts the
ordering invariant on every transition.

### Credential storage fixes — focused audit

- **MigratingCredentialStore.password promotion bug.** The
  legacy-to-primary promotion path used two independent
  `try?` calls, so a failed primary write followed by a
  successful legacy delete would lose the password entirely.
  Now uses do/catch: legacy delete only runs if the primary
  write succeeded. Worst case is now an extra Keychain prompt
  on the next read, not data loss.
- **FileCredentialStore NSLock reentrancy footgun.** The
  empty-password branch in `setPassword` used to call
  `deletePassword`, which takes the lock again. NSLock isn't
  reentrant — the only reason this didn't deadlock today was
  the empty-check ran *before* taking the lock. Refactored to
  inline the delete logic under the held lock so a future
  maintainer reordering the empty-check below `lock.lock()`
  cannot produce a deadlock by mistake.

### Chaos test suite extended (12 → 16 scenarios)

Four new siege scenarios added to `core/tests/chaos.rs`:

| # | Scenario | Guards against |
|---|---|---|
| 13 | Concurrent request burst with random 1–100 ms inter-recv delays | Slow-consumer back-pressure regressions |
| 14 | 100 start/stop cycles with random 1–30 ms jitter | FD/resource leaks across spawn cycles |
| 15 | Random-delay race start→stop (30 cycles, 1–50 ms span) | Lock-across-spawn (Ru#C2) regression under randomized timing |
| 16 | Wire ordering under burst (10 start/stop cycles) | Ru#C4 regression — events outrunning responses |

Inline xorshift64 PRNG (no `rand` dep added). Total chaos suite
runtime: ~3 s on a modern Mac.

### Items deliberately not delivered

- **Memory-pressure simulation.** Requires OS-level controls
  (jetsam, memory_pressure framework) outside LTSC scope.
  Engine memory is bounded structurally: `MAX_FRAME_BYTES`,
  `EVENT_BUFFER`, `OUTBOUND_BUFFER`, log-buffer trim, debouncer
  prune. No leak path identified.
- **AES-256-GCM crypto audit.** No such code exists in the
  project — credential format is base64-of-plaintext + 0600
  POSIX mode + Keychain fallback. Encryption-at-rest stays on
  the v0.2.0 deferred list (would be on-disk format change,
  contract-locked under LTSC).

## Unreleased — chaos test infra (no binary change)

LTSC test-infrastructure addition. `core/tests/chaos.rs` —
12 deliberate-misbehavior scenarios that exercise the engine
under the failure modes the v0.1.7.x audits identified or
fixed. Asserts each invariant the audits are supposed to
guarantee, so a future regression that breaks one fails CI
loudly instead of shipping silently.

Scenarios:

1. Oversized frame survival — engine returns
   `frame_too_large` and continues processing.
2. No-newline flood — discard cap (`16 × MAX_FRAME_BYTES`)
   triggers; engine fails fast instead of looping forever
   (verifies Ru#H4 fix).
3. Malformed-frame burst (1000 invalid lines) — engine
   stays responsive; sentinel valid request still answered.
4. Concurrent `start_proxy` race — exactly one
   `started` reply + one `already_running` error, no
   double-spawn (verifies Ru#C2 TOCTOU fix).
5. Stdin EOF mid-frame — engine exits cleanly.
6. Empty + whitespace lines — silently skipped, no
   error frames.
7. Invalid UTF-8 — `malformed_request` error, engine
   alive.
8. ID correlation under interleaved valid/invalid — every
   reply carries its associated id (verifies the two-phase
   parse contract).
9. `stop_proxy` when idle — `not_running` error.
10. `stop_proxy` spam (20× back-to-back) — stable error
    replies, no crash.
11. 100k pure-newline flood — empty-line short-circuit
    holds; zero error frames emitted.
12. `shutdown` during in-flight requests — engine exits
    cleanly with status 0.

No engine changes. The artifact bytes for v0.1.7.4 are
unaffected; this commit only adds test infrastructure that CI
runs on every push.

Surfaced one known design quirk (audit Ru#C4): the engine
emits `state_changed: true` event *before* the `started`
response. Documented; deferred to v0.2.0 where the wire
contract opens.

## [0.1.7.4] — 2026-05-03 (LTSC patch)

LTSC in-line patch — debounce-design audit. Single-line tuning
change with two-doc-comment touch-up: anomaly debouncer window
tightened from 100 ms to **50 ms**.

The audit inventoried every coalescing/throttle/debounce site
across both crates. Only one site is semantically a "debouncer"
in the user's sense (anomaly suppression in the security
monitor); the other timing sites are animations, signal-grace
windows, request deadlines, or UI-typing coalescers — each
correctly scaled to its own concern and left unchanged:

| Site | Window | Role | Decision |
| --- | --- | --- | --- |
| Anomaly `Debouncer::default()` | **100ms → 50ms** | per-key suppression | tightened |
| `persistSettings` task sleep | 250ms | UserDefaults coalesce | unchanged (typing) |
| LogConsole scroll `withAnimation` | 100ms | render duration | unchanged (animation) |
| AppDelegate terminate watchdog | 5s | shutdown ceiling | unchanged (safety) |
| Subprocess kill-escalation grace | 250ms | TERM→INT→KILL spacing | unchanged (signal) |
| `CoreClient.send` per-request deadline | 120s | engine timeout | unchanged |

The 50 ms anomaly window halves the worst-case latency between
naive emitting a real anomaly (e.g. starting to listen outside
loopback) and the orchestrator's auto-stop reaction. The
suppression goal is unchanged — collapse a flapping-naive
anomaly storm into one event per key per window — but the
window is now tight enough to feel near-instant. Burst-flooding
the UI is bounded by the per-key map: distinct reasons admit
independently; the same reason emits at most once per 50 ms.

The existing `Debouncer` test suite (single-key suppression,
distinct-key independence, 100k-event stress, prune semantics,
default-window assertion) all continue to pass; only the
default-window assertion was retargeted from 100 ms to 50 ms.

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
