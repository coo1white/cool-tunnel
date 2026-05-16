# Changelog

All notable changes to Cool Tunnel land here. Versions follow
roughly-semver: bumps in the third digit are features; bumps in
the fourth digit are pre-release polish on the same line.

The pre-release `v0.1.5.x` series soaked from May 2 to May 3, 2026.
**v0.1.6** was the first stable release on the original line.
The **v2.0.x** series is the current Long-Term Servicing Channel
line — see [SUPPORT.md](./SUPPORT.md) for the support contract.

## [2.0.56] — 2026-05-16 — Streamline Pass 3 — ADR + Audit Reports + CONTRIBUTING

PR #83 trims ADR 0001, both 2026-05 audit reports (UI + Code), and
CONTRIBUTING.md to core content. Net −483 lines. OPSEC scrub: drops
a stale reference to a personal-directory path and adjacent-project
tech stack in the ADR. No code change.

## [2.0.55] — 2026-05-16 — Doc + Comment Streamline Pass

PR #82 trims remaining docs (SECURITY, SECURITY-WEB3, CONTRIBUTING,
Disclaimer, NaiveProxy_Server_Setup) and verbose code comments across
9 hot Swift / Rust files. Net −2642 lines, no runtime change. Threat-
model and legal clauses, SAFETY blocks, and WHY-non-obvious invariants
preserved. 156 Swift, 178 Rust, 10 Bun, 7/7 CI.

## [2.0.54] — 2026-05-16 — Streamlined Debug-Handshake Log + VPS-Egress Hint Wired

PR #79 (v2.0.53) shipped `DebugHandshakeFailureClass` + `operatorHint`
but never wired them; PR #81 wires the classifier and collapses the
debug-handshake live log from six hex-dump lines to verdict + hint.
156 Swift (+18 new), 178 Rust, 10 Bun, 7/7 CI. No wire change.

## [2.0.53] — 2026-05-14 — VPS-Egress Classifier + TypeScript+Bun Maintenance Scripts

PR #79 adds `DebugHandshakeFailureClass` — a four-case classifier
on `DebugHandshakeReport` that distinguishes "VPS RSTed CONNECT
after 200 OK" from generic unreachable with `operatorHint` strings.
PR #80 ports `cut_release.sh` + `fetch_naive.sh` to TypeScript+Bun
behind thin .sh shims, with a new `bun-tests` CI job.

## [2.0.52] — 2026-05-14 — bin/ct — Brew-Style Maintenance Wrapper

PR #78 adds `bin/ct` as a single brew-style verb entry point over
the nine existing maintenance scripts (e.g. `bin/ct release
2.0.52` → `bash scripts/cut_release.sh`). New `ct doctor`
composite runs preflight + audit --strict + ratchet. Every
existing `bash scripts/...` invocation still works.

## [2.0.51] — 2026-05-14 — OPSEC Audit: Close 6 Redaction Gaps

PR #77 closes 6 OPSEC redaction gaps (H1/H2/H3/M1/M2 + L1 rule)
in the in-memory log, lifecycle-telemetry JSONL, and `os_log`.
Notable: H1 was a subscription-URL token leak via `url.host ??
urlString` fallback in `importFromSubscriptionURL` — the token-
in-path shape didn't match any credential-shaped redaction
pattern. New L1 query-string rule added with explicit
ordering-before-bare-token-kv so the redacted token can't re-match
and eat the URL tail.

## [2.0.50] — 2026-05-14 — Remove Ruby; Tests Target → fileSystemSynchronizedGroups

PR #76 drops Ruby from the project toolchain. The 132-line
`scripts/add_test_target.rb` existed solely to register new test
files into `COOL-TUNNELTests`'s explicit pbxproj entries; tests
target now uses Xcode 16's `fileSystemSynchronizedGroups`. New
files in `COOL-TUNNELTests/` auto-pick-up with no `gem install`.
Toolchain is Swift + Rust + POSIX shell.

## [2.0.49] — 2026-05-14 — HTTP-407 Credential Auto-Sync

PR #75 — Mac-side counterpart to cool-tunnel-server's auto-sync
watchdog. When the engine reports an HTTP-407-class auth failure
on stderr and the active profile carries a saved subscription
URL, the orchestrator re-fetches credentials and restarts
transparently. Three pieces: new optional
`Profile.subscriptionURL`, an `isProxyAuthFailureLine` classifier
(Chromium chips + bare 407 bounded by non-alphanums), and a
30-second-cooldown single-flight scheduler.

## [2.0.48] — 2026-05-14 — Beginner-Friendly README Rewrite

PR #74 restructures README.md to lead with the first-time
reader's path: plain-English intro, 5-minute Quick Start, ASCII
diagram, then "Architecture details (for the curious)" further
down. Every operational artefact preserved verbatim (VPS install
command, 4 curl probes, error-layer table, uninstall sequence).
Net diff +37 lines.

## [2.0.47] — 2026-05-14 — Telemetry Hostname Redaction

PR #73 closes a redaction gap in the lifecycle-telemetry JSONL:
Debug Handshake events were carrying the operator's proxy
hostname in plaintext under `server` / `target`. Fix is at the
emit site in `TunnelOrchestrator`, not the redaction layer
(redaction is deliberately scoped to credential-shaped strings,
not bare `host:port` — kept that way for triage readability;
`testBareHostnamePortPassesThroughUnredacted` pins the gap).

## [2.0.46] — 2026-05-14 — Test Fixture Convention: Alice / Bob

PR #72 adopts the canonical Alice / Bob crypto-test convention
for the sample username across 8 Rust + Swift test files (`alice`
happy-path, `Alice123` case-preservation, `alice@bad` etc.
parse-rejection). Driver: prior placeholder was a name-shaped
string with no canonical-test value, and the repo is the public
face of coolwhite LLC. ±47 lines, no test cases added/removed.

## [2.0.45] — 2026-05-14 — UI Compact + Layout-Stable Pass

PR #71 closes 7 state-driven layout-shift bugs across the SwiftUI
surface. All share one technique: reserve the column / frame /
glyph slot unconditionally so changing state never reflows
neighbouring controls (toolbar Start↔Stop reflow, five-icon row,
Import-button spinner collapse, log-filter capsule growth, etc.).
Plus two extracted components — `VerdictPill` and `SummaryRow` —
into a new `UIComponents.swift`.

## [2.0.44] — 2026-05-14 — SHA Manifest CRLF Fix + LipoOutputParser Extraction

PR #70 fixes a real bug: the in-app updater's SHA-256 manifest
parser silently failed against CRLF manifests because Swift's
`Character` merges `\r\n` into a single extended grapheme cluster
that equals neither single-codepoint literal. Both call sites
used `whereSeparator: { $0 == "\n" || $0 == "\r" }`, so a CRLF
manifest round-tripped as one giant line. Fix is one char per
site: `\.isNewline`. PR #69 extracts `LipoOutputParser`. Suite
80 → 118.

## [2.0.43] — 2026-05-14 — README: First Deployment Walkthrough + Maintenance Chapter

README answers two questions it didn't: first deployment and
ongoing maintenance. Two new H2 sections — First Deployment
(four-step arc + prerequisites table) and Maintenance (updater,
error-layer triage, state-on-disk topology, credential rotation,
clean uninstall + networksetup recovery commands). README +147
/ −2 lines.

## [2.0.42] — 2026-05-13 — Web3 Privacy Posture (Telemetry Redaction + SECURITY-WEB3.md)

W1/W2/W3: `LifecycleTelemetryLogger.redact` brought to parity
with the Rust core's `redaction::redact` (five sequential regex
passes), 16 mirrored regression tests, and new SECURITY-WEB3.md
documenting architectural guarantees + the naive stderr
identifier-leakage surface. Pre-fix Swift handled only
`scheme://user:pass@host`, so `Authorization:` headers and
`"password":"…"` JSON dumps reached the 0o600 telemetry file
verbatim.

## [2.0.41] — 2026-05-13 — Panel Trust-Gate Regression Coverage

29 new regression tests on `SubscriptionManifestV1.validate(now:)`
and `isBlockedHost(_:)` — the two panel-import trust gates that
had been documented but unpinned. Coverage hits the critical
`172.15.255.255` / `172.32.0.0` CIDR-adjacency boundaries and
IPv6 bracketed-literal admission. Strictly additional, no
production change. Suite 35 → 64.

## [2.0.40] — 2026-05-12 — Robustness Test Surface + CI Gate Refinement

PRs #60/#61/#62/#65 close post-v2.0.39 debt: PR #60 makes the
`try?` ratchet annotation-aware (cap 54 → 0, every remaining site
carries `// try-ok: <reason>`); PR #61 lands the Swift unit-test
target with `COOL-TUNNELTests` + 16 starters; PR #65 adds 19 more
including `GitHubTrustTests`; PR #62 fixes `cut_release.sh`
pre-flight via `CODE_SIGNING_ALLOWED=NO`. Suite 16 → 35.

## [2.0.39] — 2026-05-11 — M1 Ratchet + Sweep + GitHubTrust Fail-Closed

PR #58 adds the toolchain-free `try_question_ratchet.sh` that
counts `\btry\?` and hard-fails on any drift from
`TRY_QUESTION_CAP` (bi-directional, wins land atomically).
PR #59 sweeps 7 `try?` sites that swallowed real errors — notably
`AppSupportPaths`'s `setResourceValues(.isExcludedFromBackup)`
warn whose silent worst case was credentials in Time Machine
snapshots. Cap 59 → 54. Plus `GitHubTrust.download` fail-closed
mirroring PR #55.

## [2.0.38] — 2026-05-11 — Robustness Review Pass (H1 + H2 + H3 + M2 — M8 + L1 + L2)

Five-PR sweep (#53/#54/#55/#56/#57) closing 13 audit findings
H1–H3 + M2–M8 + L1/L2. Notable: M2 stderr decode was using
`String(data:encoding:)` which dropped chunks at multi-byte 4 KiB
boundaries; replaced with `String(decoding:as: UTF8.self)`. Plus
H2/H3 credential-store fail-safe (`loadProfiles`/`save` no longer
destroy legacy passwords on backend failure). M1 deferred to
v2.0.39 ratchet.

## [2.0.37] — 2026-05-11 — README Refresh + Bundled NaiveProxy Bump

README surfaces v2.0.36 features that shipped without
operator-facing prose: drops the misleading `sing-box-class`
wording in the architecture diagram (only `sing-box` mention left
is a separate-topology comment in `preflight.rs`), surfaces
subscription-URL import, adds an Operator Diagnostics section.
Bundled `naive` rolled `v148.0.7778.96-2` → `-5` with universal
SHA repinned in `COOL-TUNNEL/naive.upstream.json`.

## [2.0.36] — 2026-05-10 — Post-CONNECT Tunnel Diagnostics

Debug Handshake now distinguishes CONNECT acceptance from real
tunnel payload forwarding — the previous probe reported success
on HTTP 200 even when target bytes were RSTed immediately after.
New flow sends a deterministic TLS `ClientHello` through the
established tunnel and reports `ok=true` only after target bytes
come back. VPS health overlay now hydrates credentials before
probing and labels failure as `Probe error`.

## [2.0.35] — 2026-05-10 — Debug Handshake Probe

New `debug_handshake` Rust RPC + control-panel action: spawns a
temporary reference `naive` client, drives one deterministic
local CONNECT probe, reports success / elapsed / first-byte hex /
redacted child logs. Temporary NaiveProxy config goes to a 0600
file and deletes on drop so credentials never enter command
arguments while reference-client handshake behaviour is preserved.

## [2.0.34] — 2026-05-09 — Operator Start Gate

Every Start path now rejects ambiguous profile settings before
the engine is touched. New `selectedProfileCanRequestStart` on
`CoolTunnelViewState` aligns the main control row + menu-bar
mode rows on whether a stopped tunnel can request Start.
`TunnelOrchestrator.perform(_:)` records a local-kernel rejection
and returns before the engine sees malformed intents.

## [2.0.33] — 2026-05-09 — Observability Certainty

Observability release for support sessions. New append-only
lifecycle-telemetry JSONL with wall-clock + monotonic-microsecond
timestamps and redacted details, plus a non-interactive Developer
Overlay HUD (throughput, TLS handshake delta, VPS reachability,
PID health). Rust traffic-snapshot events reuse the existing
bounded lsof parse that powers anomaly detection.

## [2.0.32] — 2026-05-09 — Declarative UI State Schema

Architecture release: SwiftUI surface now renders from an
explicit `CoolTunnelViewState` schema and emits named
`TunnelIntent`s through `TunnelOrchestrator.perform(_:)`, instead
of hiding tunnel side effects inside leaf views. No engine
protocol change; existing lifecycle, self-healing, and menu-bar
controls preserved behind the cleaner boundary.

## [2.0.31] — 2026-05-09 — Self-Healing Stability + Log Pressure Hardening

PR #46 stability release for long-running menu-bar sessions. New
self-healing orchestrator loop retries on unexpected core-stream
termination + proxy stop, sleep/wake health verification probes
the running proxy and clears stale sentinel state, and
performance-profile-derived caps bound monitor interval + log
flush + batch size + max log-line length. Stdout ingestion is
now frame-bounded at the Swift side so malformed newline-free
output can't blow up `AsyncLineSequence`.

## [2.0.30] — 2026-05-09 — Defensive Input Logic ("First Scold, Then Do Good")

Closes audit findings D-1 through D-4 on `ConnectionFormView` +
Direct Domains so a typo'd port or pasted full URL never reaches
the engine. New `Profile.serverValidation` enum, `localPortValue`
≥1024 guard, idempotent `normaliseServer` paste-stripper, and
`isPlausibleDomainShape` for the domain list. `Profile.isStartable`
is now gated on the structured verdict (was: non-empty-after-trim,
which let typo'd ports through to engine validate).

## [2.0.29] — 2026-05-09 — Deterministic Error Reporting (`ErrorLayer` taxonomy)

The connection-failure banner now pinpoints the broken node:
`[Local]` / `[Upstream]` / `[VPS]` so operators don't have to run
Diag manually. New `ErrorLayer` enum + parallel reachability
probe (Apple NCSI + direct TCP to the VPS, 3s budget); decision
matrix maps the four NCSI×VPS outcomes to a single layer chip
above the existing banner. Classifier only runs on failure, so
the v2.0.28 energy posture is preserved.

## [2.0.28] — 2026-05-09 — Seamless Recovery Protocol (sleep/wake survival)

Closes F-1/F-2/F-4 to end "click Stop, then restart your mode"
after sleep. New `sleepObserver` on `NSWorkspace.willSleep*`
drains the engine and pins `modeBeforeSleep`; `didWake` Path A
re-applies the prior mode via `switchMode(to:)` after a 500 ms
settle. `SleepWakeState` enum drives the `HeaderStatusPill`
labels. Side benefit: the 5s lsof `monitor_loop` exits naturally
once the supervised PID is gone, so zero lsof invocations during
sleep.

## [2.0.27] — 2026-05-09 (Hotfix: NaiveUpdater self-heals stale lastInstalledTag)

Single-line fix mirroring v2.0.24's `RustCoreUpdater` fix on the
bundled-`naive` panel: `checkForUpdates` clears stale
`lastInstalledTag` when `installedURL` doesn't exist on disk
(reproducible via Application Support cleanup, manual delete, or
iCloud-synced UserDefaults from a previous host). Sister bug we
should have caught at v2.0.24.

## [2.0.26] — 2026-05-08 (Licence: Apache-2.0 → AGPL-3.0-only)

Forward-only licence transition under the coolwhite LLC copyright
anchor, aligned with the simultaneous switch on the upstream
Cool Tunnel Server stack. Every release tagged on or before
v2.0.25 remains Apache-2.0; AGPL-3.0-only applies prospectively.
LICENSE replaced with verbatim FSF AGPLv3, 67 source files gain
SPDX headers, bundled-component compatibility table preserved
(all AGPL-3.0-compatible). Closes the SaaS loophole via AGPL §13.

## [2.0.25] — 2026-05-08 (Hotfix: subscription-imported password persists)

Silent persistence bug: subscription-URL import appeared to work
but the password never reached `credentials.json`. Root cause:
`TunnelOrchestrator.selectedProfile` setter was update-in-place
only (`if let index = profiles.firstIndex`), so a fresh-UUID
profile from `importFromSubscriptionURL` got silently dropped —
the ID advanced, `profiles` and the credential store never saw
it. Setter now appends-when-not-found.

## [2.0.24] — 2026-05-08 (Hotfix: managed-engine self-heal)

PR #31 — Rust Core panel could show "You're on the latest version
()." with empty parens next to "binary not found" because a stale
`lastInstalledTag` in UserDefaults claimed currency against a
missing `cool-tunnel-core-managed`. `checkForUpdates` now clears
`lastInstalledTag` when `installedURL` doesn't exist on disk, so
the next state is `.available(tag)`. Defence in depth: empty
`currentVersion` falls back to the resolved tag.

## [2.0.23] — 2026-05-07 (Auto-updater fix: macOS 15+/26 incompatibility)

AppUpdater silently failed on macOS 15/26 (Sequoia/Tahoe) for
`.pkg`-installed root-owned bundles. Pre-fix the privileged shell
spawned the real helper via `nohup ... &; disown`, but macOS
15+/26 kills children of the authorization-elevated shell on exit
regardless of nohup/disown — Apple changed the rules. New flow:
osascript does only a fast atomic `chown` to the current user
then falls through to the regular user-owned spawn path;
`lstat()` verifies. `.dmg`/user-owned bundles unchanged.

---

## [2.0.22] — 2026-05-07 (v2.0.21 review-fallout: 4 rounds of code review, ~30 fixes)

Four review rounds, ~30 fixes on top of v2.0.21, no wire change.
Headline: every client error type except one carried stored
`localizedDescription` without `LocalizedError` conformance, so
the `(error as? LocalizedError)?.errorDescription` cast fell
through to `"…CoreClientError error N."` everywhere; fixed across
9 types. Plus `ServerAddress::parse` rfind(':') mis-parse on bare
IPv6, body-cap + redirect guards, and SSRF gate in
`Subscription.validate(now:)`.

## [2.0.21] — 2026-05-06 (Connection robustness: handshake, pre-flight probe, subscription validation)

PR #17 hardens the Swift↔Rust JSON-over-stdio bridge and the
subscription-import path. New `Hello`/`HelloReply` handshake
(`PROTOCOL_VERSION = 1`), structured `ProbeServer` pre-flight,
`SubscriptionManifestV1` Swift mirror + `SubscriptionClient` actor.
Real bug fix in the middle: subscription import was dropping the
manifest's `port` field, so non-default panels silently fell back
to `:443`. NaiveProxy v148.0.7778.96-2 unchanged.

## [2.0.20] — 2026-05-06 (Xcode 26.4 macOS-SDK build hotfix)

The subscription-import field's `.textInputAutocapitalization(.never)`
is an iOS-only View modifier; on Xcode 26.4 macOS SDK the call
trips `error: value of type 'some View' has no member 'textInputAutocapitalization'`.
Added in v2.0.18 (#15) but tolerated by the prior SDK. Wrapped
in `#if !os(macOS)` — semantically a no-op on the only target
this project ships, ready for an eventual iOS target. Caught at
v2.0.19 binary cut, fixed at 50c511b post-tag, released here.

## [2.0.19] — 2026-05-06 (Engine-side validation gap closed)

PR #14 closes the engine-side `validate_profile` gap:
`RequestKind::ValidateProfile` previously took an
already-deserialised `Profile` so invalid input tripped the outer
serde `try_from` and surfaced as `invalid_request` instead of
`Response{ok:false}`. Variant now carries `RawProfile` and the
handler runs `Profile::try_from(raw)` itself. Defence in depth
for the empty-password class fixed in v2.0.17.

## [2.0.17] — 2026-05-06 (Start-button validation + audit gate locked)

PR #12 fixes the empty-Password Start path — Start was previously
launching `naive` with empty creds, upstream rejected auth, and
diagnostics surfaced a generic `× upstream_via_socks` with no
hint that the cause was an unfilled form field. Companion PRs
#9/#10/#11 lock the CI lint floor (rustfmt, swift-format,
shellcheck) with `strict: true` required-status enforcement on
main; ADR 0001 records the audit rules.

---

## [2.0.16] — 2026-05-05 (hotfix v2.0.15: Xcode project version drift)

v2.0.15 shipped with `core/Cargo.toml` at 2.0.15 but
`MARKETING_VERSION` still at 2.0.14, and AU-7's
`verifyExtractedApp` correctly refused to install. v2.0.16 bumps
MARKETING_VERSION. Plus U#7 — `package_release.sh` now verifies
the freshly-built .app's `CFBundleShortVersionString` before
packaging, so the same drift can never reach a tag.

## [2.0.15] — 2026-05-05 (post-swap liveness probe + updater hardening)

Closes UX-F#7: v2.0.14's `transitionInFlight` gate suppressed
`stateChanged(false)` during the ~50 ms hot-swap window, so if
naive died in that exact window (OOM, kernel signal, panic) the
orchestrator declared the swap successful while naive was dead.
New `probe_naive_live` RPC + `verifyNaiveLiveAfterHotSwap`; throw
falls through to the existing full-restart path. Plus a
`RustCoreUpdater.download` manifest cap (was riding the 100 MB
binary default for a ~250-byte file).

## [2.0.14] — 2026-05-05 (mode switch is now invisible to traffic too)

PR #4 functional companion to v2.0.13: pre-fix `switchMode` was
`stopQuiet(); startQuiet()` so every Smart↔Global↔Local click
tore down naive and broke every TCP connection through the SOCKS5
listener (~200–500 ms of `connection refused`). New
`applyModeWithoutRestart` only touches `networksetup` + PAC; naive
stays at the same PID. Falls through to full restart on
`activeProfileEdited` or throw.

## [2.0.13] — 2026-05-05 (mode-switch UX: no more Stop→Start→Stop button blink)

Clicking through Smart / Global / Local while connected made the
primary action button flicker Stop→Start→Stop. Root cause:
`switchMode(to:)` was `stopQuiet(); startQuiet()` and both halves
+ engine `stateChanged` events rewrote `isRunning` / `activeMode`
across `await` yields. Three coordinated fixes: a
`publishStoppedState` flag on `stopQuiet`, an early-return on
`transitionInFlight` in `handle(event:)`, and `modeBinding.get`
reading `pendingMode` for the picker.

## [2.0.12] — 2026-05-05 (logic-integrity sweep: validate_profile semantics + clippy clean)

PR #3 fixes stdio-vs-HTTP `validate_profile` divergence: since
v0.1.7.16 the stdio dispatcher returned `Response{ok:false}`
when stdio mode should treat bad data as `Outbound::Error`. Wire
variant reverts to carrying a fully-validated `Profile` so invalid
input fails the outer `from_value::<Request>` and emits
`invalid_request`; HTTP `/naive/validate` retains 200 + ok:false
per SM-3 (now spelled out in both sides' doc comments). 130/130.

## [2.0.11] — 2026-05-05 (lsregister fix: app no longer shows old version after in-app update)

After in-app update (especially `.pkg`-installed root-owned), the
Dock launched the old version because the `mv`-pair bundle swap
changes the inode at `$OLD_APP` and LaunchServices retains stale
cache for the old inode. Fix: relaunch script calls
`lsregister -f "$OLD_APP"` after the swap (routed via
`launchctl asuser ${ORIG_UID}` on the elevated path so the
per-user DB rebuilds).

## [2.0.10] — 2026-05-05 (.pkg installer poka-yoke: blocks when app is running)

Poka-yoke gate on the manual `.pkg` installer — if Cool Tunnel
is running, the installer refuses to proceed. Pre-fix the
installer either failed with EACCES on the executable segment
(partial bundle) or replaced bytes on disk while the running
process kept old code in memory. New distribution-package
`installation-check` JavaScript calls `pgrep -x "Cool Tunnel"`
and blocks with a "quit and re-open" message. Output identifier
unchanged so signed updates upgrade in place.

## [2.0.9] — 2026-05-05 (.pkg-installed bundles can now self-update)

Pre-fix the in-app Update on a `.pkg`-installed bundle told the
user to drag-Trash and reinstall manually. Now
`preflightInstallability` returns `needsAdminElevation: Bool`
and `spawnRelaunchHelper` routes through `osascript … with
administrator privileges` for the root-owned case; the privileged
helper does the atomic swap, then `chown`s back to `ORIG_UID`
so future updates take the no-prompt path. User-owned bundles
are byte-identical to v2.0.8.

## [2.0.8] — 2026-05-05 (UI compaction + appearance scroll-jump fix)

Two screenshot-driven fixes. (1) Upper-window chrome collapses
to a single horizontal row, `HeaderView` splits into
`HeaderStatusPill` + `FirewallBadge`. (2) Appearance picker
scroll-jump root cause: v2.0.5's `conditionallyPreferredColorScheme`
toggled between nil and a concrete value, counting as a view-tree
structural change and rebuilding SettingsView's ScrollView. Fixed
by driving appearance through `NSApp.appearance` (AppKit) so the
SwiftUI tree is unchanged.

## [2.0.7] — 2026-05-05 (relaunch-stuck hotfix)

Update flow could stall at "Relaunching…" indefinitely — under
rare conditions (in-flight URLSession holding the run loop,
window-close animation racing the reply), neither
`applicationShouldTerminate`'s shutdown Task nor its 5s watchdog
fired soon enough and the helper kept waiting on our PID. Fix:
schedule a `Task.detached` immediately before `NSApp.terminate`
that calls `Darwin.exit(0)` after 8 seconds, unconditionally.
Clean shutdown still wins under normal conditions.

## [2.0.6] — 2026-05-05 (resizable Live log + release-pipeline hygiene)

Two changes. (1) Live log no longer hides the Server form — main
layout switched to `VSplitView` with explicit min frames so the
unbounded `frame(minHeight: 220)` can't eat the password + port
rows on tall windows. (2) New `scripts/cut_release.sh <VERSION>`
runs every freshness step in order with hard preconditions
(fetch_naive, cargo clean, Cargo.toml match, version verify,
SHA verify, package). Closes the "2.0.3 inside a 2.0.5 .app"
class of stale-bundle shipping.

## [2.0.5] — 2026-05-05 (hotfix bundle: AppUpdater pre-flight + Match System appearance)

Three v2.0.4 user-test issues. (1) "Match System" appearance
stayed locked because `.preferredColorScheme(nil)` doesn't mean
"follow system" on macOS — once applied with a concrete value and
re-applied with nil, the scheme stays locked. New
`conditionallyPreferredColorScheme` helper skips the modifier when
nil. (2) v2.0.3's `Darwin.access(W_OK)` pre-flight was
over-restrictive on macOS 14+ (TCC grants don't propagate to
access(2)); dropped. (3) Update-failed banner `lineLimit(3)` → 12
+ Reveal-in-Finder button.

## [2.0.4] — 2026-05-05 (hotfix — phantom spinner next to "You're on the latest version")

Settings → Naive Binary and Settings → Rust Core left a small
`ProgressView` spinner permanently spinning next to the
"You're on the latest version (X)" text after a successful
Check. Cosmetic. `updaterRow` and `rustUpdaterRow` use an
inner switch over `updater.state` for the spinner slot; v2.0.2
added `.checking / .upToDate / .available` states but only
added their text to `updaterMessage`, so `.upToDate` and
`.available` fell into the `default: ProgressView()` arm.
Two-line fix adds them to the `EmptyView` arm in both rows.

## [2.0.3] — 2026-05-05 (hotfix — false-positive "bundle is locked" on Update)

`AppUpdater.refuseReadOnlyInstall` over-reported "bundle is
locked" because `URLResourceKey.isWritableKey` returns false for
a superset of conditions (chflags-lock, Time Machine ACL/POSIX
quirks, macOS 14+ App-Management TCC denials, signed-bundle
metadata states). Fix: probe `chflags` directly via `lstat` +
`st_flags & (UF_IMMUTABLE | SF_IMMUTABLE)` for the authoritative
detection; fall back to `access(W_OK)` with an App-Management
message for non-chflags causes.

## [2.0.2] — 2026-05-05 (Check-then-update for naive + rust core)

`NaiveUpdater` and `RustCoreUpdater` now mirror `AppUpdater`'s
check-then-update pattern. Pre-fix every Update click did a full
download regardless; naive upstream tags like `v148.0.7778.96-2`
re-publish the same binary under new suffixes so downloads
produced cosmetically different bytes for a `--version`-identical
binary. New `checking / upToDate / available` states + persisted
`lastInstalledTag` against the resolved tag.

## [2.0.1] — 2026-05-05 (hotfix — Rust core version drift + updater verification)

`core/Cargo.toml` was never bumped from `0.1.7` in v2.0.0 so the
Rust binary self-reported `cool-tunnel-core 0.1.7`; SHA matched,
the Update appeared to succeed, but the verdict pill never
advanced. U#1 bumps Cargo.toml; U#2/U#5/U#6 add three layered
defences (post-install `--version` check, Cargo.toml precondition
in `package_release.sh`, bundled-engine version verify) so the
same class of drift can't ship.

## [2.0.0] — 2026-05-05 (full identity rebuild — first-class macOS app)

Major rebuild — v0.1.x was custom-painted; v2.0 rebuilds every
surface from platform primitives. 27 files changed, +1479 / −1199;
`MalteseTheme.swift` (412 lines) removed. Closes every P0/P1
from a third-party UX audit + forensic engine/lifecycle audit
(startCore do/catch + `lastError`, `recoverFromCrashIfNeeded`,
SIGTERM ladder). New first-class `MenuBarExtra`, log export
pipeline, procedural icon stack, `SMAppService` login item.

## [0.1.7.21] — 2026-05-04 (LTSC patch — clarity sweep, deletions only)

LTSC patch — net −287 lines, no behaviour change. Removes
`AppUpdater.sha256(of:)` wrapper, the 80-line AU-1…AU-15 history
block in the AppUpdater header (that's what CHANGELOG is for),
stale `docs/v0.1.5-roadmap.md`, and a per-session
`session-prompts-summary.xlsx` accidentally committed via
`git add -A` in v0.1.7.16. Kept: audit-tag inline comments
(invariants, not history) and `activeProfileID`.

## [0.1.7.20] — 2026-05-04 (LTSC hotfix — multi-install false-positive)

LTSC hotfix — v0.1.7.16's `refuseIfMultipleInstalls` ran `mdfind
kMDItemCFBundleIdentifier == "space.coolwhite.naive"` and counted
every hit, including Spotlight-indexed Xcode `DerivedData`
artifacts. New `isPlausibleUserInstall` filters DerivedData and
Build/Products before the count, so the in-app updater no longer
refuses on dev machines with a single `/Applications/` copy.

## [0.1.7.19] — 2026-05-04 (LTSC patch — 10 deferred-high cluster)

LTSC patch — 10 deferred-high items closing UX-F#3/#5/#16,
Subproc-F#1/#3/#11a/#11b, Lifecycle-F#5/#7, and a non-English
`activeServices` legend filter. Notable: CoreClient inherited
engine stderr with no drain, so a chatty engine writing >64 KiB
filled the kernel pipe buffer and deadlocked mid-request.

## [0.1.7.18] — 2026-05-04 (LTSC patch — focused high-severity cluster)

LTSC patch — 3 deferred-high items closing Lifecycle-F#16,
UX-F#4, Sw#C4 (partial). Notable: a crash with the system proxy
enabled left macOS routing through `127.0.0.1:1080` across reboot
with nothing listening; new `ProxyActiveFlag` sentinel +
`recoverFromCrashIfNeeded` `disableAll()`s on next launch.
RustCoreUpdater now pins SHA-256 via `.sha256` manifest.

## [0.1.7.17] — 2026-05-04 (LTSC patch — 100+ findings, 8 land)

LTSC patch — 120 findings, 8 land. Notable: Sup-F#6 fixes a
v0.1.7.16 regression where the lsof loopback substring-match
misclassified `127.0.0.1->1.2.3.4` as both-loopback; new
endpoint-aware split on `->`. Plus `lastError` HeaderView banner,
`Username::parse` rejects `:`/`@`/control chars, JSON_KV_CRED
regex coverage extension.

## [0.1.7.16] — 2026-05-04 (LTSC patch — broad-surface deep audit)

LTSC patch — 100 findings, 13 land. Notable: `[::1]` lsof
loopback-exclusion gap on macOS (lsof reports
`[::1]:port->[::1]:port` so the parser was synthesising
`TooManyRemote` anomalies on plain loopback). Plus
`validate_profile` dispatcher RawProfile rework (re-broke +
re-fixed in v2.0.12), 300 MB free-space pre-flight, multi-install
`mdfind` guard.

## [0.1.7.15] — 2026-05-04 (LTSC patch — deep audit, MainActor freeze fix)

LTSC patch — 3-angle review (32 findings, 7 land) closing
CONC-F#1, SEC-F#6/#7/#8/#11, ARCH-F#1/#2. Notable: NaiveUpdater +
RustCoreUpdater froze the UI mid-update because `runProcess`
synchronously called `Process.waitUntilExit()` from MainActor;
AppUpdater had been fixed in v0.1.7.10 via `Subprocess.run` but
the cousins were missed.

## [0.1.7.14] — 2026-05-04 (LTSC patch — second simplify pass)

LTSC patch — simplify-review, 7 of 18 follow-ons land closing
R-F#1/#2, Q-F#1/#2/#5/#7, E-F#3. Notable: Naive/RustCore
download paths had drifted into ~22-line line-for-line twins;
extracted to `GitHubRedirectGuard.download(url:to:)` so both
call sites are now 3-line do/catch. AppUpdater's download stays
bespoke for its per-asset size cap.

## [0.1.7.13] — 2026-05-04 (LTSC patch — post-cycle simplify pass)

LTSC patch — simplify-review, 12 of 31 findings land. Theme:
v0.1.7.11/.12 hardened AppUpdater but left NaiveUpdater +
RustCoreUpdater exposed to the same redirect / host-substitution
attacks. New shared `SystemIntegration/GitHubTrust.swift`
extracts `isTrustedGitHubURL` + `GitHubRedirectGuard` so both
sibling updaters validate before download. Plus orphan
`os.Logger` subsystem fix + RestrictedFile generalisation.

## [0.1.7.12] — 2026-05-04 (LTSC patch — Fifth audit cycle, batch 2)

LTSC patch — closes Fifth audit cycle with 11 medium/low fixes
across AU-6/#8/#9/#10/#11/#13/#14 and SM-4/#7/#10. Notable: AU-6
swaps `Bundle.main.bundleIdentifier` (attacker-controllable in
`verifyExtractedApp`) for a canonical constant. New `tower`
dep for the `ConcurrencyLimitLayer(64)` on the server-mode
router.

## [0.1.7.11] — 2026-05-04 (LTSC patch — Fifth audit cycle, batch 1)

LTSC patch — Fifth audit cycle (Rule Maker R1-R4), 13 of 25 land
closing AU-1/#2/#3/#4/#5/#7/#12/#15 + SM-1/#2/#3/#5/#9. Notable:
AU-5 closes a `/extracted-evil` sibling false-negative in the
relaunch-helper ancestor check via `realpath(3)` + path-component
check. `server_mode::run` now refuses non-loopback bind without
`--allow-public`.

## [0.1.7.10] — 2026-05-04 (LTSC patch — comprehensive audit + security)

LTSC patch — parallel Swift + Rust audit + tooling self-audit.
Notable: C1 closes an `AppUpdater.unzip` pipe-buffer deadlock
where ditto writing >64 KB to stderr stalled mid-extraction;
routed through `Subprocess.run`. Plus Ru-A1 single-emitter
discipline for `state_changed:false` (monitor_lifecycle no longer
emits; `monitor_loop` owns via `emitted_stopped`) and Sw-H4
post-extract symlink-escape walk. 132 tests.

## [0.1.7.9] — 2026-05-03 (LTSC patch — UI/UX stress audit)

LTSC patch — 4th UI audit, 38 findings; visible bugs + dark-mode
contrast issues land. Notable: "Downloading 0%…" stuck because
`URLSession.shared.download(from:)` doesn't report byte-level
progress; replaced with "Downloading… (typically a few seconds on
broadband)". Plus dark-mode `PupCardModifier` recalibration and
rapid-click guards on AppUpdater Check/Download.

## [0.1.7.8] — 2026-05-03 (LTSC patch — updater bugfix)

LTSC patch — two updater bugs from v0.1.7.7. (1) `.sha256`
manifests were missing from every release page because
`package_release.sh` generated them since v0.1.4 but `gh release
create` commands never uploaded them; backfilled onto v0.1.7.5/6/7
and the script now prints the canonical asset list. (2) "Up to
date" reported as failure because `fetchLatestRelease` validated
`.zip + .sha256` BEFORE comparing versions; split into cheap
metadata + on-demand validation.

## [0.1.7.7] — 2026-05-03 (LTSC patch — light/dark mode)

LTSC patch — closes Sw#24 (dark-mode dynamic palette) plus
user-controlled Appearance preference. Every `CTPalette` token
resolves to a light/dark variant via `NSColor(name:dynamicProvider:)`;
view layer unchanged. New `AppearanceMode` enum (.system / .light
/ .dark) persisted in UserDefaults. Existing v0.1.7.6 users on
system-dark had been rendering with the light palette.

## [0.1.7.6] — 2026-05-03 (LTSC patch — in-app self-updater)

LTSC patch — closes Sw#C4 for the .app self-updater surface
by consuming the SHA-256 manifest `package_release.sh` was
already publishing but no caller was reading. New Settings
section with Check + Update buttons, ditto-extract + bundle
verification, atomic bash relaunch helper. NaiveUpdater +
RustCoreUpdater SHA retrofit deferred to v0.2.0. No admin
escalation, no auto-check, no auto-update by design.

## [0.1.7.5] — 2026-05-03 (LTSC patch — chaos siege)

LTSC patch closing Ru#C4 wire ordering plus two credential-store
fixes. Notable: `state_changed:true` event could overtake the
`Started{pid}` response (different channels), so transition events
moved into `handle_request` for FIFO order against the response.
Plus `MigratingCredentialStore` legacy-delete now gated on primary-
write success, and `FileCredentialStore.setPassword` NSLock-reentrancy
on empty-password branch. Chaos suite 12 → 16.

## Unreleased — chaos test infra (no binary change)

New `core/tests/chaos.rs` — 12 deliberate-misbehaviour scenarios
pinning v0.1.7.x audit invariants (oversized frames, malformed
bursts, concurrent `start_proxy` race, `shutdown` during
in-flight). Surfaced Ru#C4 (`state_changed:true` overtakes
`started` response) which v0.1.7.5 then fixed.

## [0.1.7.4] — 2026-05-03 (LTSC patch)

LTSC patch — anomaly debouncer window tightened 100 ms → 50 ms,
halving worst-case latency between naive emitting an anomaly
(e.g. listening outside loopback) and orchestrator auto-stop.
Audit confirmed this is the only site whose meaning was a
debouncer; the other timing sites are correctly scaled to their
own concerns.

## [0.1.7.3] — 2026-05-03 (LTSC patch)

LTSC patch — robustness audit, 103 findings, ~15 land. Notable:
`monitor_loop` was using `/bin/kill -0` without ruling out PID
rollover, so a recycled PID after engine crash + slow respawn
would have been a confused-deputy hazard; loop now exits on miss.
Plus `Subprocess.run` replaces three pipe-deadlock-prone callers
and `RestrictedFile.write` moves to atomic rename.

## [0.1.7.2] — 2026-05-03 (LTSC patch)

LTSC patch — module-design audit, 113 findings, ~15 land. Notable:
`redaction.rs` regex statics were `OnceLock<Option<Regex>>` which
silently passthrough'd on compile failure, so a bad-regex edit
would have leaked credentials. Switched to `LazyLock<Regex>` with
`.expect(...)`. Plus Cmd+Q `DispatchSemaphore` main-thread
deadlock and `client_mode::start_proxy` TOCTOU (two concurrent
starts both spawning naive) closed.

## [0.1.7.1] — 2026-05-03 (LTSC patch)

LTSC patch — UI/UX audit closing drift between v0.1.7 ship and
the v0.1.5.7 platinum-theme intent. Engine stays `0.1.7` (cargo
doesn't accept four-segment versions); .app `MARKETING_VERSION`
is `0.1.7.1`. Roughly two dozen visual adjustments (corner
radii, latency-menu border, localised connection-form label
widths, About footer string, Direct Domains scrollable frame).
No engine change.

## [0.1.7] — 2026-05-03 (**LTSC**)

First Long-Term Servicing Channel release. Public surface (UI
flows, CLI flags, engine protocol, on-disk paths) locked for the
lifetime of the v0.1.7 line per SUPPORT.md; only patch + minor
security fixes and upstream NaiveProxy updates land in-line. New
LTSC infrastructure: `rust-toolchain.toml` pins Rust 1.80.0,
weekly dependabot ignoring majors, `core/deny.toml` allow-list,
section 9 LTSC-posture audit, build SHA + date embedded in
`--version`.

## [0.1.6] — 2026-05-03 (stable)

First stable release. Everything from v0.1.5.x plus in-line
hotfixes: platinum-theme border alignment, mode-chip text-wrap
(`.lineLimit(1) + .fixedSize`), one "switched X to Y" log line
per direct mode switch, engine-crash surface in live log,
first-run hint banner, VoiceOver labels. NaiveProxy bumped to
v148.0.7778.96-2. New CHANGELOG/SECURITY/CONTRIBUTING.

## [0.1.5.9] — 2026-05-03 (pre-release)

Swift + Rust API guidelines polish. Removed two production
force-unwrapped URLs in updaters. Replaced `#if DEBUG print()`
in `CoreClient` with `os.Logger`. Justified every
`@unchecked Sendable` with an explicit safety invariant. Doc
summaries on every public View. Cargo.toml C-METADATA fields.

## [0.1.5.8] — 2026-05-03 (pre-release)

Multi-window-on-reopen bug fixed by switching `WindowGroup` to
`Window(_:id:)` and moving engine shutdown out of `.onDisappear`.
`cool-tunnel-core` gains `--mode server [--listen ADDR]` with
five HTTP endpoints; same Mach-O serves both stdio + server
tiers. Audit fixes: engine-state mutex no longer held across
`ProxySupervisor::spawn`, anomaly debouncer survives restarts.

## [0.1.5.7] — 2026-05-03 (pre-release)

Theme retuned to System 7 / Platinum with Monaco for monospaced
surfaces. `MACOSX_DEPLOYMENT_TARGET` lowered 26.4 → 14.0. Rust
release profile (LTO fat, panic=abort, strip=symbols) shrank
`cool-tunnel-core` from ~6 MB to 2 MB single-arch. New
`PerformanceProfile` auto-tunes animation on older Intel
hardware (skips repeating pulse + window-background fade +
caps log buffer at 300 entries on `.light` tier).

## [0.1.5.6] — 2026-05-03 (pre-release)

Settings → "This Mac" panel shows CPU brand, P+E core counts,
memory, model identifier via `HostMachine` / `sysctlbyname`.
Naive Binary `Test` produces a single OK/NG verdict line. New
`Update` button downloads upstream NaiveProxy, lipo-merges
arm64 + x86_64, ad-hoc signs, adopts as custom binary path.

## [0.1.5.5] — 2026-05-03 (pre-release)

Profile passwords moved off the macOS Keychain by default —
no system password prompt before the UI appears. New
`FileCredentialStore` (mode 0600) is primary; Keychain stays
as the legacy leg of a `MigratingCredentialStore` so v0.1.5.4
upgraders don't lose saved passwords. `security_check.sh`
secret scan now covers the whole project folder.

## [0.1.5.4] — 2026-05-02 (pre-release)

Tapping a Smart / Global / Local chip while running hot-swaps
modes via `TunnelOrchestrator.switchMode(to:)` (no more
"Stop first, then Start in the new mode" dance). Pastel palette
+ Liquid Glass surfaces (macOS 26+) with regular-material
fallback. `.symbolEffect(.bounce/.pulse)` + `.sensoryFeedback`
on key interactions. Chip identity renamed from NewJeans-style
to Maltese-pup.

## [0.1.5.3] — 2026-05-02 (pre-release)

Repo tidying. Removed four loose dev scripts containing a
hardcoded development-server password; cleaned the same value
from `NaiveProxy_Server_Setup.md` and Rust test fixtures
(rotation note in SECURITY.md). `Debouncer` gains lazy
pruning, `prune_stale(now)`, `Default` impl, `window()`
accessor. New pinned check in `security_check.sh` rejects any
future commit reintroducing the literal.

## [0.1.5.2] — 2026-05-02 (pre-release)

Desensitisation audit closes credential leak gaps.
`Username::Debug` and `Display` redact (matching `Password`).
Redaction regex extended to SOCKS, FTP, `naive+https://` URLs
and `Authorization` / `Cookie` headers. curl stderr is now
redacted before crossing the wire. `naive --version` output
validated against the canonical `naive <semver>` pattern;
arbitrary subprocess output can no longer reach the Settings
UI.

## [0.1.5.1] — 2026-05-02 (pre-release)

LICENSE replaced with canonical Apache 2.0 text. New NOTICE
with copyright + bundled-component attribution. README
expanded with architecture diagram + build-from-source steps
+ repository layout. Audit fixes: diagnostic-event ordering
race, monotonic clock for elapsed timing, defensive
`formatMs` against NaN, naive refresh re-entrancy guard.

## [0.1.5] — 2026-05-02 (pre-release)

Live ms timing for diagnostics + latency tests. Per-probe
`DiagnosticProgress` events with wall-clock `elapsed_ms`;
per-sample latency breakdown lines
(`total= dns= connect= tls= ttfb=`); latency probes labelled
`baseline (direct, no proxy)` vs `via proxy`.

## [0.1.4.1] — 2026-05-02

Bootstrap now performs exactly one code-signature check
(`cool-tunnel-core`); naive verification deferred to Settings
or proxy start.

## [0.1.4] — 2026-05-02

Bundled `naive` + `cool-tunnel-core` are now genuine universal
Mach-Os (arm64 + x86_64) — v0.1.3 silently shipped arm64-only
builds despite the universal claim. New `NaiveBinaryResolver`
with chip detection + Settings panel surfacing arch slices,
version, code signature. New `scripts/fetch_naive.sh`,
`build_rust_core.sh`, `security_check.sh`, `package_release.sh`.
100 ms `Debouncer` for monitor anomalies with 100k-event
stress test. AGPL-3.0 license + Disclaimer (later relicensed
to Apache 2.0 in v0.1.5.1).

## [0.1.3] — 2026-05-02

First public release. Rebrand from `naive` to `COOL TUNNEL`;
modular Swift split
(`App/Core/Persistence/SystemIntegration/Views`); new Rust
core crate.
