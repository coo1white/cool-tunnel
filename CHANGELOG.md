# Changelog

All notable changes to Cool Tunnel land here. Versions follow
roughly-semver: bumps in the third digit are features; bumps in
the fourth digit are pre-release polish on the same line.

The pre-release `v0.1.5.x` series soaked from May 2 to May 3, 2026.
**v0.1.6** was the first stable release on the original line.
The **v2.0.x** series is the current Long-Term Servicing Channel
line — see [SUPPORT.md](./SUPPORT.md) for the support contract.

## [2.0.54] — 2026-05-16 — Streamlined Debug-Handshake Log + VPS-Egress Hint Wired

PR #79 (v2.0.53) shipped `DebugHandshakeFailureClass` + `operatorHint`
but never wired them; PR #81 wires the classifier and collapses the
debug-handshake live log from six hex-dump lines to verdict + hint.
156 Swift (+18 new), 178 Rust, 10 Bun, 7/7 CI. No wire change.

## [2.0.53] — 2026-05-14 — VPS-Egress Classifier + TypeScript+Bun Maintenance Scripts

Two improvements bundled. PR #79 adds `DebugHandshakeFailureClass` —
a four-case classifier (`connectFailed` / `proxyAuthRejected` /
`vpsEgressBlocked` / `other`) on `DebugHandshakeReport` that reads
byte-level evidence and projects it onto actionable classes with
an `operatorHint` string per case (the egress-blocked class
distinguishes "VPS RSTed CONNECT after 200 OK" from generic
unreachable). PR #80 ports `cut_release.sh` and `fetch_naive.sh`
to TypeScript+Bun for cross-repo toolchain consolidation; the
other 7 scripts stay POSIX shell, and the .sh files become thin
shims that exec the .ts via Bun so every existing `bash scripts/X.sh`
invocation continues to work. New `bun-tests` CI job runs the
10 argv-parser tests. 138 Swift, 178 Rust, 10 Bun, 7/7 CI.

## [2.0.52] — 2026-05-14 — bin/ct — Brew-Style Maintenance Wrapper

PR #78 adds `bin/ct` as a single brew-style verb-based entry
point over the existing nine maintenance scripts (e.g.
`bin/ct release 2.0.52` → `bash scripts/cut_release.sh`).
Driver: collapse "remember nine script paths and their argv"
into one discoverable interface with `--help` per verb. New
`ct doctor` composite runs preflight + audit --strict + ratchet
and prints one summary. Brew-style colour output (TTY-only).
`bin/ct` is added to the ShellCheck CI gate. Every existing
`bash scripts/...` invocation continues to work unchanged.
6/6 CI green; no production code change.

## [2.0.51] — 2026-05-14 — OPSEC Audit: Close 6 Redaction Gaps

OPSEC audit identified six leak sites that surface operator
infrastructure metadata or subscription tokens into the in-memory
log, lifecycle-telemetry JSONL file, or `os_log` under specific
failure modes. All six fixed in PR #77. Closed: H1 subscription
URL token leak via `url.host ?? urlString` fallback in
`TunnelOrchestrator.importFromSubscriptionURL` (token-in-path
shape doesn't match credential-shaped redaction patterns); H2
subscription redirect URL logged at `privacy: .public` in
`SubscriptionClient`; H3 transport-error description leak via
`URLError.localizedDescription` embedding the failing URL with
token (now redacted before both log and re-throw); M1
operator-hostname leak in import-success log; M2 updater
untrusted-host URL exposure (3 sites). Added L1 query-string
credential redaction rule in both `core/src/redaction.rs` and
`COOL-TUNNEL/Core/LifecycleTelemetryLogger.swift`:

```
([?&](token|api_key|access_token|refresh_token|session|auth|password|secret)=)[^&\s\x23]+
→ $1***
```

Ordering matters: the query-string rule runs BEFORE the bare-token
kv rule, and the bare-token rule's value-terminator class now
includes `&` and `\x23` so it can't re-match the redacted token
and eat the URL tail. 138 Swift (+5 redaction tests), 178 Rust
(+5), 6/6 CI. Subprocess HOME passthrough and bare hostname:port
redaction stay deferred (callsite-by-callsite review remains the
correct shape for the latter; M1 is the second callsite handled
that way after v2.0.47).

## [2.0.50] — 2026-05-14 — Remove Ruby; Tests Target → fileSystemSynchronizedGroups

PR #76 drops Ruby from the project toolchain. The 132-line
`scripts/add_test_target.rb` existed solely to register new test
source files into the `COOL-TUNNELTests` target's explicit
pbxproj entries; the tests target now uses Xcode 16's native
`fileSystemSynchronizedGroups` (same pattern the app target
already used), so new files in `COOL-TUNNELTests/` auto-pick-up
with no script invocation or `gem install`. Pbxproj diff -47
lines (24 explicit entries → 2 synchronized-group entries). The
toolchain is now Swift + Rust + POSIX shell only. 133 Swift,
173 Rust, 6/6 CI.

## [2.0.49] — 2026-05-14 — HTTP-407 Credential Auto-Sync

PR #75 closes the Mac-side counterpart to cool-tunnel-server's
auto-sync watchdog (server v0.1.1). When the engine reports an
HTTP-407-class auth failure on stderr and the active profile
carries a saved subscription URL, the orchestrator transparently
re-fetches credentials from the panel and restarts against the
refreshed values — no operator action. Three pieces: (1) new
optional `Profile.subscriptionURL` field (Rust ignores unknown
fields so additive in both directions; legacy decode to nil
regression-tested); (2) `TunnelOrchestrator.isProxyAuthFailureLine`
classifier matching Chromium `ERR_PROXY_AUTH_*` / `ERR_TUNNEL_AUTH_*`
chips, the `407 Proxy Authentication Required` line, the phrase
"authentication required", and bare `407` bounded by non-alphanums
(so byte counts don't fire); (3) `scheduleCredentialAutoSync` —
single-flight with 30-second cooldown so the panel sees at most
two requests per minute under retry loops. The auto-sync
suppresses the "Profile edits applied — click Stop" banner the
`selectedProfile` setter raises, and is cancelled on shutdown,
stop, and switchMode (matching the existing `selfHealTask`
pattern). 133 Swift (+13 new), 173 Rust, 6/6 CI.

## [2.0.48] — 2026-05-14 — Beginner-Friendly README Rewrite

PR #74 restructures README.md to lead with the first-time
reader's path: opens with "What is Cool Tunnel?" (plain-English
intro), then "Quick Start (5 minutes)", then "How does it work?
(Plain-English version)" with an ASCII diagram and a "why three
languages" table. Mermaid diagram and boundary-contract table
moved to "Architecture details (for the curious)" further down.
New "Reading this code" chapter walks 7 source files in
recommended order with a patterns-to-file-paths table mapping 8
idioms. Repository Metadata section (GitHub-topic salad) dropped
in favour of the GitHub repo description+topics surface. Every
operational artefact preserved verbatim (VPS install command,
4 curl probes, error-layer table, uninstall sequence, credential
rotation, naive-pin rolling, all sibling-file cross-links). Net
diff: +37 lines, README 521 → 558. 6/6 CI.

## [2.0.47] — 2026-05-14 — Telemetry Hostname Redaction

PR #73 closes a redaction gap in the on-disk lifecycle telemetry
file at `~/Library/Application Support/COOL-TUNNEL/lifecycle-telemetry.jsonl`
(mode 0600). Debug Handshake events were carrying the operator's
proxy server hostname in plaintext under the `server` and `target`
detail fields. The Swift redaction pipeline correctly let them
through (it is scoped to credential-shaped strings — URL userinfo,
Authorization headers, Cookie headers, JSON credential pairs —
not bare `host:port` values, deliberately so for triage
readability). Fix is at the emit site in `TunnelOrchestrator`,
not the redaction layer: drop both fields from the details
payload (operator still sees them in the live `LogConsoleView`
buffer, exported on demand). 2 regression tests:
`testBareHostnamePortPassesThroughUnredacted` pins the deliberate
gap so the next developer adding a hostname-bearing field sees
they need a different defense; the second is an end-to-end
record/read-back assertion. Historical records on disk are not
retroactively redacted; fix prevents new hostname records from
being written. 120 Swift (+2), 173 Rust, 6/6 CI.

## [2.0.46] — 2026-05-14 — Test Fixture Convention: Alice / Bob

PR #72 adopts the canonical Alice / Bob crypto-test convention
for the sample username across 8 Rust + Swift test files (`alice`
for happy-path, `Alice123` for case-preservation, `alice@bad` /
`alice:bad` / `alice bad` / `alice.bad` for parse-rejection,
`alice_bob` and `alice-bob` for allowed punctuation, `alice:hunter2`
in redaction URL fixtures). Driver: prior placeholder was a
name-shaped string with no canonical-test value, and the repo
is the public face of `coolwhite LLC`. Two expected-output URLs
(`protocol_roundtrip.rs`, `naive_config.rs`) and one prose comment
in `ProfileStore.swift` move in lockstep so assertions and
surrounding text stay consistent. ±47 lines, no test cases
added/removed, no production change. 173 Rust, 118 Swift, 6/6 CI.

## [2.0.45] — 2026-05-14 — UI Compact + Layout-Stable Pass

PR #71 closes seven state-driven layout-shift bugs and consolidates
two duplicated structures across the SwiftUI surface. All fixes
share one technique: reserve the column / frame / glyph slot
unconditionally so changing state never reflows neighbouring
controls. Fixes: toolbar reflowing on Start↔Stop (primary button
`minWidth` 60→72); uneven five-icon secondary button row (new
`IconBarButton` pinning every cell to 30×22 with 16×16 image
frame); Import-button collapsing to spinner width (ZStack overlays
spinner on hidden-opacity always-rendered Import label); Developer
Overlay tiles clipping long status (separate width/minHeight
frames; HStack equalises to tallest); log filter capsule growing
on first keystroke (X always present at zero opacity, hit-testing
disabled); menu-bar mode rows drifting sideways on activate
(`Label`+icon-opacity instead of `Label`-vs-Text branching). Two
extracted components: `VerdictPill` (4 inline OK/NG pills in
SettingsView consolidated, mode-aware alpha 0.10 light / 0.22
dark moved inside) and `SummaryRow` (label/value diagnostic row
parameterised by `labelWidth`). Net diff −21 lines across modified
views; new `UIComponents.swift` adds 322 lines absorbing the
deletions plus #Preview blocks. SettingsView stays at 1,726 lines
(no structural rewrite). 118 tests, 6/6 CI.

## [2.0.44] — 2026-05-14 — SHA Manifest CRLF Fix + LipoOutputParser Extraction

PR #70 fixes a real bug: the in-app updater's SHA-256 manifest
parser silently failed to verify against CRLF-formatted manifests
because Swift's `Character` merges `\r\n` into a single extended
grapheme cluster that equals neither single-codepoint literal.
`SHAVerifier.expectedHash` and `AppUpdater.verifyZipAgainstManifest`
both used `split(whereSeparator: { $0 == "\n" || $0 == "\r" })`,
so a CRLF manifest round-tripped as one giant line, the
asset-name match never fired, and the UI surfaced "Refusing to
install — checksum failed" even when the bytes matched. Fix is
one character per site: `whereSeparator: \.isNewline` (true for
both LF and the CRLF grapheme). Production-impact bound:
release-cutter `shasum -a 256` emits LF; the bug bites only on
hand-edited or tool-rewritten manifests. Caught by
`SHAVerifierTests.testHandlesCrlfLineEndings`. PR #69 refactors
duplicated `lipo -info` parsing from `NaiveBinaryResolver` and
`RustCoreResolver` into `LipoOutputParser` — the known-arch
allow-list now lives in one place. 38 new regression tests
across `SHAVerifierTests` (12), `ProxyActiveFlagTests` (12),
and `LipoOutputParserTests` (14). Suite 80 → 118. 6/6 CI.

## [2.0.43] — 2026-05-14 — README: First Deployment Walkthrough + Maintenance Chapter

README answers two questions it didn't: "how do I deploy this
the first time?" and "how do I maintain a running version?"
Two new H2 sections — First Deployment (four-step arc with
prerequisites table) and Maintenance (in-app updater, error-layer
triage, state-on-disk topology, VPS credential rotation, naive-pin
rolling, common-failure quick reference, clean uninstall with
networksetup recovery commands). Plus a small fix in Build From
Source: `cut_release.sh 2.0.36` example bumped to v2.0.42 with
a note that pre-flight rejects mismatched versions. No code
change. README +147 / −2 lines. 6/6 CI.

## [2.0.42] — 2026-05-13 — Web3 Privacy Posture (Telemetry Redaction + SECURITY-WEB3.md)

W1 brings `LifecycleTelemetryLogger.redact` to parity with the
Rust core's `cool_tunnel_core::redaction::redact` — five
sequential `NSRegularExpression` passes, order-equivalent to the
Rust impl: strict-quoted JSON, then bare-token, then a final
Authorization sweep for header-shaped credentials inside JSON
dumps. Previously the Swift side handled only `scheme://user:pass@host`,
so a `URLError.localizedDescription` wrapping a userinfo URL, a
Foundation error embedding an `Authorization:` header, or a
third-party `"password":"…"` JSON dump would have reached the
0o600 telemetry file verbatim. Defense-in-depth — the Rust-side
redaction already catches engine-originated strings; W1 closes
the gap for Swift-only paths. Compile-time discipline tightened:
the previous `replacingOccurrences` returning an optional became
an explicit `do/catch` with `fatalError` so a bad regex edit
surfaces the actual NSError. W2 adds 16 regression tests in
`LifecycleTelemetryRedactionTests.swift` covering sanity,
userinfo (https + every SOCKS variant + multi-`@` + two-URLs-on-one-line),
Authorization (Bearer / Basic / Proxy-Authorization), Cookie /
Set-Cookie, and JSON quoted/bare; test names mirror the Rust-side
tests so contract drift stays visible. W3 adds `SECURITY-WEB3.md`
sibling to `SECURITY.md` with three sections — Architectural
guarantees (what Cool Tunnel does NOT see), What persists on
disk (the three 0o600 files), Known surfaces (the honest section
naming naive's stderr identifier-leakage path and operator
guidance for wallet/RPC routing). No production-runtime change;
bundled `naive` and `cool-tunnel-core` byte-equivalent to v2.0.41.
Suite 64 → 80, 6/6 CI.

## [2.0.41] — 2026-05-13 — Panel Trust-Gate Regression Coverage

`SubscriptionManifestV1.validate(now:)` and `isBlockedHost(_:)`
— the two security-trust gates protecting the panel-import flow
against counterfeit / hijacked panels — were documented in code
but had zero regression tests. Closed with 29 new tests covering
every documented rejection rule plus boundary cases. `validate`
coverage (15): version != 1 → unsupportedVersion, empty profiles
→ noProfiles, profile-cap and exact-cap boundary, blocked-host
wiring, counterfeitCapabilities (`http3 == true`), invalidIssuedAt
(zero sentinel + future-beyond-60s-skew + future-within-skew
boundary), malformedExpiry, validityTooLong (with exact-1-year
boundary), expired, stale (with exact-maxAge boundary), and
saturating-add overflow safety at UInt64.max. `isBlockedHost`
coverage (14): localhost (case + whitespace), `*.local` mDNS,
every RFC 1918 / loopback / link-local / unspecified block, the
critical adjacency boundaries `172.15.255.255` / `172.32.0.0`
that catch off-by-one CIDR regressions, public IPv4 allowed,
IPv6 bracketed literals (`[::1]` / `[::]` / `[fe80::]` / `[fc00::]`
/ `[fd00::]` blocked, `[2001:db8::]` / `[2001:4860:4860::8888]`
allowed). Strictly additional coverage — no production change.
Suite 35 → 64, 6/6 CI.

## [2.0.40] — 2026-05-12 — Robustness Test Surface + CI Gate Refinement

Closes the post-v2.0.39 debt. PR #60 makes the `try?` ratchet
annotation-aware: a `// try-ok: <reason>` annotation on the same
line or the line immediately preceding renders the site zero-cost
against the cap. Cap lowered from 54 to 0; every remaining `try?`
in `COOL-TUNNEL/` carries a one-line rationale, and bi-directional
enforcement means introducing or removing a `try?` without
updating the cap fails CI in the same commit. PR #61 lands the
Swift unit-test target — new `COOL-TUNNELTests` XCTest target
wired into the project + scheme + CI (`swift-tests` job on
macos-latest), plus `scripts/add_test_target.rb` for idempotent
target maintenance and 16 starter tests in `ProfileStoreTests`
(6) and `MigratingCredentialStoreTests` (10). PR #65 adds 19
more: `GitHubTrustTests` (11) covering `isTrustedGitHubURL`
exhaustively (HTTP downgrade, look-alike hosts, IP literals,
sibling GitHub services) plus `GitHubRedirectGuard.download`
rejection paths; `ProfileStoreTests` +2 for `deletePassword`
M1 contract; `TunnelOrchestratorTests` (6) pinning H3 plumbing
(`OrchestratorError.credentialReadFailed` mapping). Internal
seam: `TunnelOrchestrator.hydratePasswordIfNeeded` extracted
into a `nonisolated static func hydratePassword` helper so the
contract is pinnable without constructing a real orchestrator.
PR #62 fixes `cut_release.sh` pre-flight by passing
`CODE_SIGNING_ALLOWED=NO` to the audit's `xcodebuild test` step
(PR #61 activated the previously-skipped step; ad-hoc-signed
test host crashed bootstrap on machines without an Apple
Developer ID). CONTRIBUTING.md gains a "CI gates and invariants"
section documenting the Zero `try?` rule with do/catch +
annotation examples, the test-target conventions, and the
six-gate green requirement. Suite 16 → 35, 6/6 CI on PRs #60/#61/#62/#65.

## [2.0.39] — 2026-05-11 — M1 Ratchet + Sweep + GitHubTrust Fail-Closed

PR #58 adds `scripts/try_question_ratchet.sh` — a standalone
toolchain-free script that counts `\btry\?` in `COOL-TUNNEL/**/*.swift`
and hard-fails on any drift from `TRY_QUESTION_CAP`. Bi-directional
by design: converting a `try?` site forces the same commit to
lower the cap, so wins land atomically. New `try-ratchet` CI job
runs the standalone on every push/PR, and `scripts/audit.sh`
section 8 delegates to it. PR #59 sweeps 7 `try?` sites that
swallowed real errors: `ProfileStore.deletePassword` /
`ProfileStore.persistStripped` JSON encode, three
`MigratingCredentialStore` cleanups (after promote / setPassword
/ deletePassword), and `AppSupportPaths.init`'s
`setResourceValues(.isExcludedFromBackup)` failure warn (silent
worst case: credentials in Time Machine snapshots). Cap 59 → 54.
Plus a fail-closed fix on `GitHubTrust.download` mirroring the
AppUpdater fix in PR #55: when `attributesOfItem` throws or
`.size` is missing, the previous `if let attrs = try? ..., let
size = ...` short-circuited silently to no-action; the new path
throws `OversizeDownloadError` with sentinel `actual = -1` so
callers can distinguish unreadable from too-large. 5/5 CI jobs
green at `688eb8f`.

## [2.0.38] — 2026-05-11 — Robustness Review Pass (H1 + H2 + H3 + M2 — M8 + L1 + L2)

Five-PR robustness sweep. **H1 supply-chain (#53):** `fetch_naive.sh`
no longer auto-pins; `naive.upstream.json` is the authoritative
pin with three modes — default (verify, no network, < 100 ms,
called by `cut_release.sh` so pin drift blocks the release),
`--check-only` (re-downloads at the pinned tag, wired into a
daily `naive-pin-audit.yml`), and `--repin [TAG]` (operator-explicit,
requires `CT_REPIN_CONFIRM=1`, prints OLD → NEW SHA diff). New
`naive-pin` CI job runs the default verify on every PR. **H2/H3
credential storage (#54):** `ProfileStore.loadProfiles` and
`save` no longer silently destroy legacy passwords on
credential-store write failure (failed-migration ids tracked;
UserDefaults rewrite preserves the legacy entry until the
backend is reachable again). `password(forProfileID:)` throws
backend failures instead of collapsing every error to `""`. New
`OrchestratorError.credentialReadFailed(reason:)` distinguishes
"keychain locked" from "no password set" at three call sites
(Start, Debug Handshake, VPS Health) and the start-intent gate.
**M2-M8 I/O hygiene (#55):** M2 — engine stderr decode switched
from `String(data:encoding: .utf8)` (silently drops chunks on
multi-byte glyphs split across 4 KiB read boundaries) to
`String(decoding:as: UTF8.self)` (lossy never nil); M3 —
`SubscriptionClient` body read pre-allocates `maxBytes` capacity
and uses `bytes.prefix(maxBytes + 1)` + post-loop check; M4 —
`AppUpdater` ditto-failed UI string no longer interpolates raw
subprocess stderr (logged privately, generic message); M5 —
size cap is now fail-closed when `attributesOfItem` throws or
`.size` is missing; M8 — `SubscriptionClient.parseURL` rejects
hostless URLs at parse time. **M7 self-heal classifier (#56):**
new `isPermanentStartFailure(_:)` aborts the Start retry loop
for bad profile shape / missing naive / wire-protocol drift with
"permanent failure — not retrying"; transient failures still
retry. **M6/L1/L2 redaction (#57):** M6 splits credential
redaction into two passes — strict-JSON quoted-value matcher
runs first and consumes any non-quote char or escaped pair
until the closing quote, so a password with embedded spaces
(`Tr0ub4dor 3 cat-pic`) inside a naive JSON dump is now fully
redacted instead of leaking past the first space; existing
bare-token matcher runs second for `k=v` / `k: v` plain text.
L2 — userinfo regex changed from `[^@\s/]+@` to `[^/\s]+@` so
`user:p@ssword@host` is redacted in full instead of stopping at
the first `@`. L1 — curl probe inserts `--` before the URL so
a probe target beginning with `-` can't be interpreted as a
flag. 7 new tests in `redaction.rs`. M1 (53 unlogged `try?`
sites) deferred to a dedicated sweep with ratchet (lands v2.0.39).
142 Rust tests, 4/4 CI at `8c5231a`. Wire- and disk-compatible
with v2.0.37 in both directions.

## [2.0.37] — 2026-05-11 — README Refresh + Bundled NaiveProxy Bump

README surfaces v2.0.36 features that shipped without
operator-facing prose: architecture diagram now labels the macOS
data plane as the bundled NaiveProxy client (drops the misleading
`sing-box-class` wording — the only `sing-box` mention in the
tree is a `core/src/preflight.rs` comment about the separate
cool-tunnel-server topology); macOS Installation step 4 surfaces
subscription-URL import alongside manual entry; routing-modes
table gains a Mechanism column; new `Operator Diagnostics`
section documents the four control-panel probes
(`RunDiagnostics`, `DebugHandshake`, `RunLatencyTest`,
`ProbeServer`) plus the optional `DeveloperOverlayView` HUD.
Bundled `naive` rolled `v148.0.7778.96-2` → `v148.0.7778.96-5`,
universal SHA pinned at
`8e07a0f5ec8ccfbe15f90aeedf0c4151e56decdfe2c848f5a1372f336638aa5c`
in `COOL-TUNNEL/naive.upstream.json`. Rust core source unchanged
from v2.0.36; bundled binary differs only via the version stamp
roll. CI green at `fdb8ea0`.

## [2.0.36] — 2026-05-10 — Post-CONNECT Tunnel Diagnostics

Debug Handshake now distinguishes CONNECT acceptance from real
tunnel payload forwarding. The previous probe reported success
when the local reference `naive` returned `HTTP 200` for CONNECT
even if first target payload bytes were reset immediately after.
Now sends a deterministic TLS `ClientHello` through the
established tunnel and reports `ok=true` only after target bytes
come back; GUI log prints `connect_ok` and `post_connect_recv` so
operators can tell whether failure is at proxy CONNECT acceptance
or post-CONNECT forwarding. VPS health overlay now hydrates
stored profile credentials before probing and labels
credential/probe failures as `Probe error` instead of a false
`Blocked · DNS ? · TCP ?`. CI green.

## [2.0.35] — 2026-05-10 — Debug Handshake Probe

Adds a `debug_handshake` Rust RPC that spawns a temporary
reference `naive` client, drives one deterministic local CONNECT
probe through it, and reports success, elapsed time, first-byte
hex, and redacted child-process logs. New Debug Handshake
control-panel action validates and hydrates the selected profile,
resolves the bundled `naive`, and writes the diagnostic into the
live GUI log. Driver: operators on servers running aggressive
stealth/anti-tracking need a way to compare the reference-naive
handshake path against hardened server suppression logs. The
diagnostic stores temporary NaiveProxy config in a 0600 file
and deletes on drop so credentials never enter command arguments
while reference-client handshake behaviour is preserved. Swift/Rust
protocol models plus round-trip coverage for the new request/response
payloads. CI green.

## [2.0.34] — 2026-05-09 — Operator Start Gate

Every Start path now rejects ambiguous profile settings before
the engine is touched. New `selectedProfileCanRequestStart` on
`CoolTunnelViewState` aligns the main control row and the
menu-bar mode rows on whether a stopped tunnel can request Start;
menu-bar mode rows stay disabled until the selected profile has
a valid server shape, non-empty username, and valid local port.
The primary Start button distinguishes malformed profile shape
from password hydration (stored credentials still checked only
after explicit Start intent). `TunnelOrchestrator.perform(_:)`
records a local-kernel rejection and returns before the engine
sees malformed Start or mode-switch intents. CI green.

## [2.0.33] — 2026-05-09 — Observability Certainty

Observability release for support sessions. New append-only
lifecycle telemetry at
`Application Support/Cool Tunnel/lifecycle-telemetry.jsonl` —
each transition row carries wall-clock and monotonic microsecond
timestamps, mode/running state, optional failure layer, and
redacted details. New Developer Overlay toggle in the control
bar — non-interactive HUD showing live throughput, TLS handshake
delta, VPS reachability, and local kernel/`naive` PID health.
Rust traffic-snapshot events reuse the existing bounded lsof
parse that powers anomaly detection. Error-layer language aligns
with the operator-facing taxonomy: ISP / VPS / Local Kernel.
Connection start, stop, switch, hot-swap, diagnostics, latency,
engine stream end, and error paths now emit deterministic
lifecycle records. CI green.

## [2.0.32] — 2026-05-09 — Declarative UI State Schema

Architecture release: the SwiftUI surface now renders from an
explicit state schema and emits named operator intents instead
of hiding tunnel side effects inside leaf views. New
`CoolTunnelViewState` is the structured schema for connection,
header, controls, menu-bar, profiles, activity log, diagnostics,
settings, and resource-descriptor state; `CoolTunnelUIState`
holds local view draft state (Settings visibility, pending mode);
`TunnelIntent` is the named UI-to-orchestrator command surface
(mode changes, Start/Stop, diagnostics, latency tests, error
dismissal, log clearing). Main-window header, control panel,
menu-bar content + glyph, and log-clear action now render from
the schema and dispatch through `TunnelOrchestrator.perform(_:)`.
No engine protocol change; existing lifecycle, self-healing, and
menu-bar controls preserved behind the cleaner boundary. CI green.

## [2.0.31] — 2026-05-09 — Self-Healing Stability + Log Pressure Hardening

Stability release for long-running menu-bar sessions. New
self-healing orchestrator loop schedules retry attempts on
unexpected core stream termination and proxy stop events
(non-stopped modes auto-retry instead of leaving "click to retry"
state). Sleep/wake health verification probes the running proxy
after wake; on unreachability the orchestrator clears the stale
sentinel, disables the system proxy, marks the mode stopped, and
lets self-healing restart the requested mode. Performance-profile-derived
pressure caps for monitor interval, log flush interval, log batch
size, and max retained log-line length. Core stdout ingestion is
now frame-bounded at the Swift side (no more unbounded
`AsyncLineSequence` buffering on malformed or newline-free output);
Rust child-log forwarding is byte-bounded before redaction (oversized
naive log lines truncated with marker); log publishing is batched
on short timer (errors still flush immediately); log-console
auto-scroll throttled with shorter animation. CI green on PR #46.

## [2.0.30] — 2026-05-09 — Defensive Input Logic ("First Scold, Then Do Good")

Final UX hardening on `ConnectionFormView` + Direct Domains, no
more "Couldn't start" failures from a typo'd port or pasted full
URL. New `Profile.serverValidation: ServerValidation` is a pure
validator on the wire-shape contract (bare host or `host:port`,
no scheme, no path) returning `.valid` / `.empty` / `.hasScheme(String)`
/ `.hasPath` / `.malformed(reason:)`. `Profile.localPortValue:
UInt16?` parses `localPort` requiring ≥ 1024 (well-known ports
require setuid root the app shouldn't have). `Profile.normaliseServer(_:)`
auto-strips scheme prefix (`https?://`, `naive+https://`, …) and
trailing path from a pasted URL — idempotent. Inline red
captions under Server and Local port fields render only on
concrete problems. `onChange`-driven paste normaliser on Server
self-corrects to `example.com` on the next runloop tick. New
`@State domainAddError: String?` in `SettingsView` surfaces
rejection reasons inline. `Profile.isStartable` is now gated on
`serverValidation == .valid` AND `localPortValue != nil` (was:
non-empty after trim, which let typo'd ports through to engine
validate). `SettingsView.addDomain` routes through `normaliseServer`
plus a new `isPlausibleDomainShape` (loose RFC-1123 shape, ≤ 253
chars, must contain a dot, no leading/trailing dot, no empty
labels — rejects scheme prefixes, paths, and single-label like
`localhost`). Closes audit findings D-1 through D-4. Process
note: a Swift 6 strict-concurrency gap was caught during local
Debug xcodebuild before the PR, same class as v2.0.29 which had
surfaced only at `cut_release.sh` time; local Debug build added
to the pre-PR ritual.

## [2.0.29] — 2026-05-09 — Deterministic Error Reporting (`ErrorLayer` taxonomy)

The connection-failure banner now pinpoints the broken node:
`[Local]` / `[Upstream]` / `[VPS]` so operators don't have to run
Diag manually. New `ErrorLayer` enum (public Sendable Codable
Equatable) with three cases, each carrying `diagnosticLabel`
(chip text) and `humanExplanation` (used by Disclaimer.md §
"Reporting issues" + the Diag transcript export). New
`TunnelOrchestrator.lastErrorLayer: ErrorLayer?` observable slot
clears on successful start / mode-switch. `classifyConnectionFailure()`
runs two parallel reachability probes — Apple's NCSI endpoint
for general upstream + direct TCP to the user's VPS hostname
bypassing the system proxy — with a 3-second budget; decision
matrix: Apple✓+VPS✓ → `.local`, Apple✗+VPS✓ → `.upstream` (ISP
NCSI block / captive portal letting user's VPS through),
Apple✓+VPS✗ → `.vps`, Apple✗+VPS✗ → `.upstream`. New
`recordClassifiedError(_:)` async helper used by `startCore`
connection-failure paths and the wake-recovery branch of
`handleSystemDidWake`. `recordError(_:layer:)` defaults
`layer:` to nil so existing call sites are byte-equivalent.
`HeaderView.errorBanner` renders a compact uppercase pill
(`LOCAL` / `UPSTREAM` / `VPS`) above the message when layer is
present; accessibility reads "Error in `<Layer>` layer".
Three call sites are local-by-construction and skip the
classifier (engine bootstrap throw, naive binary unusable,
anomaly auto-stop). Passive — classifier only runs on failure;
v2.0.28 energy posture preserved.

## [2.0.28] — 2026-05-09 — Seamless Recovery Protocol (sleep/wake survival)

End of "click Stop, then restart your mode" after sleep. F-1:
new `sleepObserver` in `AppDelegate` subscribes to
`NSWorkspace.willSleepNotification` and routes to
`TunnelOrchestrator.handleSystemWillSleep()` which pins the
active mode in `modeBeforeSleep`, flips
`sleepWakeState = .pausing`, and calls `stop()` to drain cleanly
before suspend (Local-only mode exempt — no upstream TCP).
F-2: `handleSystemDidWake()` has two paths — Path A (clean
checkpoint, preferred) flips to `.recovering`, waits 500 ms for
DNS/routes/Wi-Fi to settle, then re-applies the prior mode via
`switchMode(to:)` with no operator click; Path B (missing
checkpoint, fallback) falls through to v0.1.7.18 probe-only
behaviour so a zombie state still surfaces if `willSleep` was
missed. New `SleepWakeState` enum (`.idle / .pausing / .paused
/ .recovering`) drives new `HeaderStatusPill` labels — `Pausing
for sleep…` (amber), `Asleep` (secondary), `Recovering after
wake…` (amber). F-4: the 5-second lsof `monitor_loop` was
unconditional pre-fix and ran through every system suspend;
because `handleSystemWillSleep` now stops the engine cleanly,
the supervised PID is gone and `monitor_loop` exits naturally
on its existing "supervised process gone" check — zero lsof
invocations during sleep vs one every 5 seconds. F-3 (engine
auto-respawn on crash) deliberately out of scope per the
system-resilience-not-unauthorised-persistence boundary.

## [2.0.27] — 2026-05-09 (Hotfix: NaiveUpdater self-heals stale lastInstalledTag)

Single-line fix mirroring the v2.0.24 `RustCoreUpdater` fix
(PR #31) at the bundled-`naive` panel. `NaiveUpdater.checkForUpdates`
now clears stale `lastInstalledTag` from UserDefaults at the top
when the file at `installedURL` doesn't exist on disk, so the
panel can no longer report "You're on the latest version" while
the binary is missing (reproducible via Application Support
cleanup, manual delete, or fresh Mac with iCloud-synced UserDefaults
from a previous host). Next state is `.available(tag)` with a
real "Update to vX.Y.Z" button. Sister bug we should have caught
when fixing `RustCoreUpdater`; if a third updater-asymmetry
surfaces, that's the trigger to codify a parity-required audit
gate.

## [2.0.26] — 2026-05-08 (Licence: Apache-2.0 → AGPL-3.0-only)

Strategic licence transition under the coolwhite LLC copyright
anchor, aligned with the simultaneous switch on the upstream
Cool Tunnel Server stack. Forward-only — every release tagged
on or before v2.0.25 remains Apache-2.0; AGPL-3.0-only applies
prospectively. LICENSE replaced with verbatim FSF GNU AGPLv3
text. 67 source files (`.rs` + `.swift` under `core/` +
`COOL-TUNNEL/`) gain an SPDX header:

```
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
```

`core/Cargo.toml`: `license = "AGPL-3.0-only"`,
`authors = ["coolwhite LLC"]`. README, NOTICE, Disclaimer,
and AcknowledgementsView rewritten. Bundled-component
compatibility table preserved (NaiveProxy BSD-3, Rust crate
set MIT/Apache-2.0/BSD-3/ISC/MPL-2.0 — all AGPL-3.0-compatible);
Apple SDK headers + SF Symbols used by reference, not
redistributed in source form, so their proprietary terms do
not propagate. Closes the SaaS loophole for any future
modified server-side variant via AGPL §13 source-availability,
keeps the client fully open. End-users see no install change;
forks/packagers must release under AGPL-3.0 with source
available.

## [2.0.25] — 2026-05-08 (Hotfix: subscription-imported password persists)

Single fix to a silent persistence bug: importing a subscription
URL appeared to work (fields populated, success banner) but the
password never reached `credentials.json` and was missing on
next launch. `TunnelOrchestrator.selectedProfile` setter was
update-in-place only (`if let index = profiles.firstIndex`); a
profile assigned through `selectedProfile =` whose id wasn't
already in `profiles` got silently dropped — `selectedProfileID`
advanced but `profiles` and the credential store never saw it.
`importFromSubscriptionURL` falls back to `UUID().uuidString`
when no profile is selected, so the fresh UUID was never in
`profiles`. Append-when-not-found makes any value assigned
through `selectedProfile =` durable. Existing call sites
(ConnectionFormView field bindings, addProfile) assign profiles
already in the array, so they were unaffected and remain so.

## [2.0.24] — 2026-05-08 (Hotfix: managed-engine self-heal)

Rust Core panel in Settings could surface a contradictory state
when the managed binary at `cool-tunnel-core-managed` was missing
— green "You're on the latest version ()." with empty parens
alongside red "binary not found." A stale `lastInstalledTag` in
UserDefaults claimed currency against a non-existent binary, and
the empty `currentVersion` bled through. `RustCoreUpdater.checkForUpdates`
now self-heals: if `installedURL` doesn't exist on disk,
`lastInstalledTag` is cleared before the tag-currency check, so
the next state is `.available(tag)` with a real "Update to vX.Y.Z"
button. Defence in depth: `SettingsView.rustUpdaterMessage` falls
back to the resolved release tag if `currentVersion` is empty so
parens never render blank. Pre-fix the panel was unrecoverable
except via `Choose…` / `Reset`, neither discoverable from the
NG state.

## [2.0.23] — 2026-05-07 (Auto-updater fix: macOS 15+/26 incompatibility)

AppUpdater silently failed on macOS 15/26 (Sequoia/Tahoe) when
the bundle was `.pkg`-installed (root-owned in `/Applications`).
Pre-fix flow ran the entire relaunch helper inside a privileged
shell via `osascript ... with administrator privileges`, with
`wrapper.sh` supposed to detach the real helper via `nohup ... &;
disown`. macOS 15+/26 **kills children of the authorization-elevated
shell on exit regardless of `nohup`/`disown`** — `nohup`+`disown`
worked for decades but Apple changed the rules. Symptom: wrapper
exited 0, osascript reported success, app terminated, real helper
was killed before its first non-trivial line. New flow: osascript
runs ONLY a fast atomic `chown` to transfer ownership to the
current user, then falls through to the regular user-owned spawn
path. Subsequent updates skip the password prompt entirely.
Defence in depth: `lstat()` after the osascript call verifies the
chown took effect. Diagnosed via `log show` against a failed
v2.0.21→v2.0.22 attempt: authd authorized the right, the wrapper
ran as root and exited 0, the parent app exited cleanly — yet
the helper's first `echo` to its log never appeared. `.dmg`-installed
user-owned bundles unchanged.

---

## [2.0.22] — 2026-05-07 (v2.0.21 review-fallout: 4 rounds of code review, ~30 fixes)

Four review rounds against the v2.0.21 cycle (correctness,
security, concurrency, perf, UX, supply-chain, docs) landed
~30 distinct fixes, no features, no wire-protocol change.
Biggest single-finding payoff: every client-side error type
except one defined `var localizedDescription` as a plain
stored property without conforming to `LocalizedError`, so the
`(error as? LocalizedError)?.errorDescription` cast at user-facing
catch sites silently fell through and users saw Swift's default
`"…CoolTunnel.CoreClientError error N."` instead of the
carefully-written enum strings. Round 3 fixed every type
(`CoreClientError`, `OrchestratorError`, `NaiveResolverError`,
`RustCoreResolverError`, `CodeSignError`, `KeychainError`,
`FileCredentialError`, `SubscriptionClientError`,
`SubscriptionValidationError`) with `var errorDescription: String?`.

Security: `SubscriptionClient` body-size cap (1 MB) now enforced
during the read via streaming `bytes(for:)` accumulation — the
mid-cycle `data(for:)` cap was reverted in round 4 because on
a fast network a hostile panel could land ~1.25 GB before the
post-hoc check fired. New `NoRedirectGuard` delegate refuses
every redirect (default `URLSession` follows up to ~16 to any
host). `Content-Type` sniff before JSON decode rejects cover-site
HTML; multi-value `Content-Type` (RFC violation, observed in
the wild) is parsed by splitting on `,` first then `;`.
`Subscription.validate(now:)` now enforces 9 rules (was 4):
`version == 1`, non-empty `profiles[]`, `profiles.count ≤ 16`,
SSRF gate on host (loopback / private / link-local / `localhost`
/ `*.local`), `capabilities.http3 == false`, `issued_at != 0`,
`issued_at <= now + 60 s` skew, `expires_at >= issued_at`,
`expires_at - issued_at <= 1 year`, `expires_at > now`,
`now - issued_at <= 7 days`. `AntiTrackingFeature` decode is
forward-compatible (manual Codable with `unknown(String)` sink
— pre-fix unknown variants threw `tokenInvalid` and bricked the
client). CI actions pinned to commit SHAs (tag-takeover defense).
`security_check.sh` now runs from `cut_release.sh` step 8b
(was opt-in); `cargo deny check` runs from `audit.sh` step 3b.
`isExcludedFromBackupKey` set on Application Support directory
(config.json carries cleartext proxy URL, credentials.json
carries base64 passwords; both 0600 on disk but Time Machine
snapshots are accessible to admin restoring user home).
**IPv6 host parsing:** `ServerAddress::parse` previously used
`rfind(':')` and silently mis-parsed bare `2001:db8::1` as
host=`2001:db8:` port=`1`. Now accepts bracketed
`[2001:db8::1]:443`, rejects bare multi-colon as
`AmbiguousIPv6` with bracket-fix pointer. `RawProfile` redacted
`Debug` pre-empts a future `tracing::warn!(?raw)` from leaking
cleartext credentials. `engineStderrLogger` flipped to
`privacy: .private`. `url.lastPathComponent` instead of `url.path`
in resolver error strings (`url.path` leaks `/Users/<name>/`).
`Text(verbatim:)` on panel-supplied `displayName` in
ConnectionFormView (string-literal interpolation on
`Text(_: LocalizedStringKey)` auto-renders markdown — a
hostile `host: "**evil**.com"` would render bolded).

Correctness: `CoreClient` stderr-drain Task is now cancelled
on `terminate()` (previously `Task.detached` was never stored,
so rapid start/stop churn parked one worker per attempt on
synchronous `availableData` until kernel EOF; switched read
primitive to `read(upToCount:)` so close-then-cancel works).
`CoreClient.start()` TOCTOU closed via new `starting: Bool`
set before the first `await`. `StopProxy` Err-path now emits
`StateChanged{false}` — pre-fix when `supervisor.stop()`
returned `Err(stop_failed)` the user-emit was gated on
`response_succeeded == true` and never fired; combined with
`monitor_loop`'s pre-claim of `emitted_stopped = true`, the
orchestrator never learned the engine was stopped and UI stuck
on "running" indefinitely. Saturating arithmetic in
`Subscription.validate(now:)` — `nowSecs &+ UInt64(maxForwardSkew)`
wrapped at the `UInt64.max - 60` edge producing
`skewCeiling ≈ 0` so every legitimate `issuedAt` flagged.
Swapped to `addingReportingOverflow` saturating to UInt64.max.
New tests: Hello/HelloReply + ProbeServer/ProbeReport wire
round-trip (none of the new variants had pinning);
`monitor_interval_secs` clamp helper + 4 unit tests for
None/in-range/Some(0)/above-ceiling; 7 ServerAddress IPv6
parse tests. Removed orphans: `ProxyMode::title()` /
`ProxyTestMode::title()` (Swift mirror at `Core/Protocol.swift`
carries its own strings; no Rust caller read them). Bundled
NaiveProxy v148.0.7778.96-2 unchanged.

## [2.0.21] — 2026-05-06 (Connection robustness: handshake, pre-flight probe, subscription validation)

Two-phase hardening of the Swift↔Rust JSON-over-stdio bridge
and the subscription-import path. New `Hello` / `HelloReply`
handshake (`PROTOCOL_VERSION = 1`) runs immediately after
spawning the engine; engines that lack the method (return
`invalid_request`) are accepted as legacy, hard mismatch
surfaces `CoreClientError.protocolVersionMismatch` and tears
the subprocess down before `start()` returns. New
`ProbeServer { profile, timeout_secs }` request in
`core/src/preflight.rs` runs DNS lookup + TCP connect with
per-step deadlines (clamped 1–30 s, default 5 s); resolves to
a structured `ProbeReport` with `dns_resolve_ms` /
`tcp_connect_ms` for both reachable and unreachable cases.
`monitor_interval_secs` is now configurable on `StartProxy`
(clamped 1–60 s, default 5 s). Per-request `tracing` span
wraps the dispatch body so log lines under a handler carry the
Swift caller's `Request.id`. New `SubscriptionManifestV1`
Swift mirror at `Core/Subscription.swift` (full schema:
version, profiles, capabilities, issued_at, expires_at, note,
signature) plus `validate(now:)`. New `SubscriptionClient`
actor fetches with ephemeral `URLSession`
(`reloadIgnoringLocalCacheData`, `urlCache=nil`, 10 s timeout)
and decodes; throws structured `SubscriptionClientError`.
HMAC deliberately skipped — panel signs with server-only
`APP_KEY` so client-side HMAC is impossible; trust anchor is
TLS to the panel domain. **Real bug fix:** subscription
import previously dropped the manifest's `port` field, so
subscribers on non-default panels silently fell back to `:443`;
now serialises `host:port` straight from `ProfileV1`.
`importFromSubscriptionURL` refactored to use the new client
via `translate(_:)`; three new error cases
(`unsupportedVersion(got:)`, `manifestExpired`,
`manifestStale(daysOld:)`). Old per-orchestrator private
`SubscriptionManifest` struct removed. Audit schema-sync probe
now greps `Core/*.swift` recursively (the v2.0.21 cut failed
on the hard-coded `ORCH_FILE` path after the decoder moved out
of TunnelOrchestrator). Landed in #17. NaiveProxy
v148.0.7778.96-2 unchanged.

## [2.0.20] — 2026-05-06 (Xcode 26.4 macOS-SDK build hotfix)

The subscription-import field's `.textInputAutocapitalization(.never)`
is an iOS-only View modifier; on Xcode 26.4 macOS SDK the call
trips `error: value of type 'some View' has no member 'textInputAutocapitalization'`.
Added in v2.0.18 (#15) but tolerated by the prior SDK. Wrapped
in `#if !os(macOS)` — semantically a no-op on the only target
this project ships, ready for an eventual iOS target. Caught at
v2.0.19 binary cut, fixed at 50c511b post-tag, released here.

## [2.0.19] — 2026-05-06 (Engine-side validation gap closed)

Closes the audit ADR's engine-side validation gap.
`RequestKind::ValidateProfile` previously took an already-deserialised
`Profile`, so an invalid profile tripped serde's `try_from`
rejection at the outer `Request` deserialiser, surfacing as
`Outbound::Error` `code: "invalid_request"` — the right shape
for "you sent me bad data" but the wrong shape for a probe
asking "is this profile valid?". The variant now carries
`RawProfile`; the handler runs `Profile::try_from(raw)` itself
and emits `Outbound::Response` with `ValidationReport { ok,
reason }` in both valid and invalid cases. Aligns stdio mode
with HTTP server-mode (which already returned 200 + ok:false).
The Swift caller already had the `validation.ok == false`
branch coded; pre-fix that branch was dead code. Wire-format
bytes unchanged. Defence in depth for the empty-password class
PR #12 fixed at the UI layer in v2.0.17. Plus Dependabot bumps:
`actions/checkout` v4→v6, `actions/cache` v4→v5. 132/132 tests
(+2 new). Fixed in #14.

## [2.0.17] — 2026-05-06 (Start-button validation + audit gate locked)

Start button now refuses to launch on an incomplete profile.
Pre-fix a profile with empty Password (or Username, Server,
Local Port) was still considered "selected" by the enabled-check,
so clicking Start spawned `naive` with empty credentials,
upstream rejected the auth, and diagnostics surfaced a generic
`× upstream_via_socks` failure with no signal the cause was an
unfilled form field. Now: Start is disabled until every required
field is filled (whitespace-trim), tooltip names what's missing,
VoiceOver announces the same. Stop stays enabled while running
preserving the recovery invariant. Fixed in #12. Plus
repository-discipline cycle: required status checks on `main`
now enforced with `strict: true` (Rust, ShellCheck, Swift format
lint must all be green before merge — CI was previously advisory
and drift had accumulated across all three axes). Lint-floor
reconciliation: `cargo fmt --all` (#9) absorbed rustfmt drift;
`xcrun swift-format format -i` (#11) absorbed ~40 violations
across 13 files; ci.yml now invokes `xcrun swift-format` instead
of bare `swift-format` so the toolchain binary is found on
macos-14 runners (the lint job had been silently exiting 127
since the `--lint` step landed). Script hygiene (#10):
explicit shellcheck disable on `cut_release.sh:92` DerivedData
lookup; `fetch_naive.sh` no longer rewrites `naive.upstream.json`
when SHAs are unchanged (kills the permanently-dirty working
tree). CONTRIBUTING.md adds `cargo install cargo-deny` +
`cargo deny check` (#9). GitHub topics set. ADR recorded at
`docs/adr/0001-audit-rules-locked-2026-05-05.md`.
`required_signatures` deferred. NaiveProxy v148.0.7778.96-2
unchanged.

---

## [2.0.16] — 2026-05-05 (hotfix v2.0.15: Xcode project version drift)

v2.0.15 shipped with bundled `cool-tunnel-core` + Cargo.toml at
2.0.15 but the .app's Info.plist `CFBundleShortVersionString`
still at 2.0.14 — Xcode's `MARKETING_VERSION` wasn't bumped in
lock-step. The in-app updater's `verifyExtractedApp` (AU-7)
correctly caught the mismatch and refused to install ("Refusing
to install"), exactly as designed — but the user-visible result
was an unusable update for anyone on v2.0.14. v2.0.16 bumps
`MARKETING_VERSION` to 2.0.16 (Debug + Release) so Info.plist
matches Cargo.toml + the bundled binary `--version`. Plus U#7:
`package_release.sh` now verifies the freshly-built .app's
`CFBundleShortVersionString` matches the requested version BEFORE
producing the .dmg/.pkg/.zip (same shape as the existing U#5
check). If MARKETING_VERSION is ever missed again, the release
fails at packaging time on the build machine.

## [2.0.15] — 2026-05-05 (post-swap liveness probe + updater hardening)

UX-F#7: v2.0.14's `applyModeWithoutRestart` left naive
untouched during Smart/Global/Local switches and the
`transitionInFlight` gate suppressed `stateChanged(false)`
during the ~50 ms window so the UI didn't blink. Corner case:
if naive died in that exact window (OOM, kernel signal,
panic), the suppression hid the genuine death and the
orchestrator declared the swap successful while naive was
dead. Now `switchMode` calls a new `verifyNaiveLiveAfterHotSwap()`
AFTER `applyModeWithoutRestart` succeeds and BEFORE the
success log line; backed by a new `probe_naive_live` engine
RPC returning `{ running, pid }` under the engine state lock.
Throw is caught and logged at `.notice` to the `HotSwap`
os_log category, then falls through to the existing
full-restart path. User sees no error — recovery is a ~250 ms
restart, with exactly one "switched from X to Y" log line per
click. Belt-and-suspenders: catch arm sets
`activeProfileEdited = true` to remove a future-refactor
footgun. Plus updater hardening: `RustCoreUpdater.download`
previously rode the shared `GitHubRedirectGuard.download`
default of 100 MB for both engine binary AND SHA-256 manifest;
manifest is ~250 bytes so 100 MB cap was 2 orders of magnitude
loose (attacker-shaped 100 MB "manifest" would land on disk
before `SHAVerifier.expectedHash` read it). `maxBytes` now
threaded through `RustCoreUpdater.download` (default 100 MB for
binary; manifest call site passes `1 * 1024 * 1024`), matching
the existing AppUpdater cap. NaiveUpdater intentionally still
has no SHA pin (tracked in SECURITY.md). 130/130 tests.

## [2.0.14] — 2026-05-05 (mode switch is now invisible to traffic too)

Functional companion to v2.0.13. Pre-fix, `switchMode` was
implemented as `stopQuiet(); startQuiet()` — naive was sent
`.stopProxy`, killed, then re-spawned with a freshly-resolved
binary and config. Smart / Global / Local actually only differ
in system proxy configuration (`networksetup` operation outside
the engine) and PAC file regeneration; naive binds to
`127.0.0.1:port` with the same config in all three modes, so
restarting it was wasted work that broke every TCP connection
flowing through the SOCKS5 listener (~200–500 ms of `connection
refused` during the swap). New private
`applyModeWithoutRestart(_ newMode:)` regenerates the PAC file
(Smart only), applies the system-proxy configuration via the
existing `SystemProxyController` API, updates the
`ProxyActiveFlag` sentinel, and publishes `activeMode = newMode`
as a single observable transition. naive is untouched — same
PID, same listener, same TCP connections. `switchMode` tries
this first; falls through to full restart on
`activeProfileEdited == true`, `selectedProfileID != activeProfileID`,
or any throw (fallback's `disableAll` cleans up partial state).
New `activeProfileEdited` orchestrator flag set by the existing
UX-F#3 detection and cleared at every successful `startCore` —
together with profile-parity it's the gate for "naive's running
config matches the current profile". Dedicated
`Logger.cooltunnel("HotSwap")` os_log subsystem captures
`.notice`-level diagnostics on fallback. Manual validation: `nc
-v 127.0.0.1 1080` survives unbroken across rapid mode clicks;
`pgrep -f Resources/naive` stays at the same PID. PR #4.

## [2.0.13] — 2026-05-05 (mode-switch UX: no more Stop→Start→Stop button blink)

Clicking through Smart / Global / Local modes while connected
made the primary action button visibly flicker `Stop → Start
→ Stop`. Root cause: `switchMode(to:)` was `stopQuiet();
startQuiet()` with both halves writing `isRunning` / `activeMode`
and SwiftUI getting render opportunities at every `await` yield.
Engine `stateChanged(false)` / `stateChanged(true)` events also
rewrote those values via `handle(event:)`, so silencing
`stopQuiet` wasn't enough. Plus the picker's binding read
`orchestrator.activeMode` while running and `pendingMode` while
stopped, so it became laggy once the orchestrator stopped
flickering. Three coordinated fixes: (1) `stopQuiet(publishStoppedState:
Bool = true)` parameter suppresses the public-state flips
(switchMode passes `false`, legacy callers default to `true`);
(2) `handle(event:).stateChanged` early-returns when
`transitionInFlight` (natural-death recovery banner still fires
outside transitions); (3) `ControlPanelView.modeBinding.get`
reads `pendingMode` directly so the picker reflects the clicked
mode instantly. Failure recovery: if `startQuiet` throws after
a silent stop, `switchMode` restores truthful state
(`isRunning = false`, `activeMode = .stopped`) before
re-throwing — UI must not lie about a non-running engine.

## [2.0.12] — 2026-05-05 (logic-integrity sweep: validate_profile semantics + clippy clean)

Closes a stdio-vs-HTTP divergence and restores the clippy
baseline. Test
`protocol_roundtrip.rs::rejects_invalid_profile_during_deserialization`
had been failing since v0.1.7.16: it sends `validate_profile`
with `localPort: "0"` and expects `Outbound::Error` code
`invalid_request`, but the engine returned a successful
`Outbound::Response` with `ValidationReport { ok: false }`. The
v0.1.7.16 change had moved `RequestKind::ValidateProfile` to
carry an unvalidated `RawProfile` so the dispatcher could
surface `ok: false` — right shape for HTTP server mode (clients
want uniform 200-with-payload per SM-3), wrong for stdio mode
which treats bad data as `Outbound::Error`. Fix reverts the
wire variant to carry a fully-validated `Profile`; validation
runs at serde deserialization through Profile's `try_from
= "RawProfile"`, so invalid profiles fail the outer
`from_value::<Request>` and emit `invalid_request`. Dispatcher
arm collapses to unconditional `Ok(ValidationReport { ok: true,
reason: None })`. `server_mode.rs` HTTP `/naive/validate`
unchanged — still returns 200 + ok:false per SM-3, deliberate
divergence now spelled out in doc comments on both sides. PR #3.
Plus clippy: `needless_pass_by_value` on
`ApiError::from_json_rejection` switched to `&JsonRejection`;
`doc_overindented_list_items` on the naive_validate doc list
continuation reduced from 16 to 5 spaces. 130/130 tests
(was 129/130).

## [2.0.11] — 2026-05-05 (lsregister fix: app no longer shows old version after in-app update)

After in-app update (especially from a `.pkg`-installed
root-owned bundle), restarting from the Dock showed the old
version. The relaunch helper swaps the bundle via an `mv`-pair
so the inode at `$OLD_APP` changes, and LaunchServices may
retain a stale cache entry for the old inode and serve the
cached metadata on the next `open` from the Dock/Finder. Fix:
relaunch script now calls `lsregister -f "$OLD_APP"`
immediately after the chown (admin-elevated path) or bundle
swap (regular path), before the `open` / `launchctl asuser
open`. `-f` forces LaunchServices to invalidate and rebuild
its database entry. On the admin-elevated path the call is
routed through `launchctl asuser ${ORIG_UID}` so the user-scoped
database is updated (running lsregister as root alone leaves
the per-user database stale). Falls through silently if the
binary is absent.

## [2.0.10] — 2026-05-05 (.pkg installer poka-yoke: blocks when app is running)

Poka-yoke gate on the manual `.pkg` installer: if Cool Tunnel
is currently running, the installer refuses to proceed. Pre-fix
the installer would either fail with text-busy/EACCES on the
executable segment (leaving the user with a partially-replaced
bundle) or succeed at replacing on disk while the running process
continues with old code in memory. The .pkg is now a distribution
package (`productbuild --distribution`) wrapping the existing
component; the distribution descriptor carries an
`installation-check` JavaScript that runs before any install
action and calls `pgrep -x "Cool Tunnel"` — exit 0 blocks with
a clear "quit and re-open the installer" message, non-zero
proceeds. If `pgrep` itself fails to launch (vanishingly rare),
the check falls through to allow rather than block. Build
pipeline: new `scripts/Distribution.xml.template` (XML forbids
`--` in comments, so the file uses `|` in prose); `package_release.sh`
substitutes `{{VERSION}}` via awk then runs `productbuild
--distribution`. Output identifier
(`space.coolwhite.cooltunnel.pkg`) unchanged so signed updates
upgrade in place. Complementary to v2.0.9's in-app updater
path: this handles double-click-in-Finder, that handles
click-Update-inside-app.

## [2.0.9] — 2026-05-05 (.pkg-installed bundles can now self-update)

Pre-fix, the in-app Update button on a .pkg-installed bundle
told the user to drag-Trash and reinstall manually. Bad UX —
the user had already cleared one admin-auth gate. Now
`refuseReadOnlyInstall` is renamed to `preflightInstallability`
and returns `needsAdminElevation: Bool` for the root-owned case
instead of throwing. When set, `spawnRelaunchHelper` routes
through `osascript -e 'do shell script "..." with prompt "..."
with administrator privileges'` showing the standard macOS
auth sheet. After auth: the privileged wrapper runs as root,
`nohup`s the real relaunch helper into the background and
exits fast so osascript returns within ~2 s. The real helper
(running as root, parent = launchd) waits for Cool Tunnel to
exit, performs the atomic ditto/mv/mv swap, then runs
`chown -R ${ORIG_UID}:staff "$OLD_APP"` to restore user
ownership (subsequent updates take the no-prompt path — the
.pkg → first-update transition is the only time the password
dialog appears) and `launchctl asuser ${ORIG_UID} open "$OLD_APP"`
to relaunch in the user's GUI session (a bare `open` from root
would launch the new instance as root and mangle TCC grants +
keychain access). `ORIG_UID` is captured from `getuid()` in
Swift and interpolated (reading inside the privileged shell
returns 0). chflags-locked bundles still throw, as do bundles
owned by another non-root user and read-only volumes. The
user-owned (.dmg/.zip-installed) path is byte-identical to
v2.0.8.

## [2.0.8] — 2026-05-05 (UI compaction + appearance scroll-jump fix)

Two screenshot-driven fixes. (1) The upper-window chrome
collapses to a single horizontal row: `●  Not connected
[Smart│Global│Local]  ▶ Start  ⚕  ⏱⌄  ⚙  [⚠ Firewall on]`.
`HeaderView` is split into `HeaderStatusPill` (single-line
dot + headline) and `FirewallBadge` (separately placeable);
the "Pick a mode below to connect." subtitle is dropped (the
picker IS the action). `ControlPanelView` loses its internal
flexible Spacer; mode picker tightens from maxWidth 260 → 220
so the whole row fits at the 780pt minWidth even with the
firewall badge. Top-pane minHeight drops 360 → 320. Error
banner unchanged. (2) Tapping Match System / Light / Dark in
Settings → Appearance scrolled the ScrollView back to the top.
Root cause: v2.0.5's `conditionallyPreferredColorScheme` used
an `if let scheme { ... } else { self }` branch — toggling
between nil and a concrete value counted as a view-tree
structural change, every subtree (including SettingsView's
ScrollView) was rebuilt. Fix: drive appearance through
`NSApp.appearance` (AppKit-level) instead of `.preferredColorScheme`
(SwiftUI structural). `ContentView.body.task(id: appearanceMode)`
sets `NSApp.appearance = nil` / `NSAppearance(named: .aqua)`
/ `NSAppearance(named: .darkAqua)`; Cocoa propagates via
`effectiveAppearance`. SwiftUI view tree is not rebuilt —
ScrollView keeps its scroll position. The v2.0.5
`conditionallyPreferredColorScheme` extension is deleted.

## [2.0.7] — 2026-05-05 (relaunch-stuck hotfix)

Update flow could stall at "Relaunching…" indefinitely. After
a successful in-app update, UI transitioned to `.relaunching`
and called `NSApp.terminate(nil)`. `applicationShouldTerminate`
returned `.terminateLater` and spawned a shutdown Task plus a
5-second watchdog to fire `reply(toApplicationShouldTerminate:
true)`. In rare conditions (in-flight URLSession holding the
run loop, window-close animation racing the reply), neither
Task fired soon enough and the process never exited; the
relaunch helper kept waiting on our PID and only Force Quit
recovered. Fix: schedule a `Task.detached` immediately before
`NSApp.terminate(nil)` that calls `Darwin.exit(0)` after 8
seconds, unconditionally. Clean shutdown still wins under
normal conditions (5 s watchdog inside 8 s hard exit). Any
system-proxy state normally cleaned in
`orchestrator.shutdown()` is recovered by the
`recoverFromCrashIfNeeded` sweep on next launch — same path
as a real crash. The detached Task doesn't depend on MainActor
or SwiftUI run loop. Recovery for users stuck on v2.0.6: Force
Quit → relaunch → Settings → Update → v2.0.7.

## [2.0.6] — 2026-05-05 (resizable Live log + release-pipeline hygiene)

Two changes. (1) Live log no longer hides the Server form: the
four panes lived in a single `VStack` and Live log had
`frame(minHeight: 220)` but no upper bound, so on a tall window
it ate every extra pixel — Password + Local-port rows + footer
disappeared off the bottom with no scroll. Switched the main
layout to `VSplitView` (draggable divider). Top pane min 360pt
(header + control row + four Server rows + footer); bottom pane
min 80pt, ideal 220pt, no max. (2) New `scripts/cut_release.sh
<VERSION>` runs every freshness step in order with hard
preconditions: `fetch_naive.sh` → `cargo clean` in `core/` →
verify `core/Cargo.toml` matches → `cargo update -p cool-tunnel-core`
→ `xcodebuild Release` → verify freshly-built bundled
`cool-tunnel-core`'s `--version` matches → verify bundled
naive's SHA-256 against the pinned manifest → hand to
`package_release.sh`. Pre-2.0.6 the release flow was implicit;
skipping any step shipped stale bundled binaries (the "2.0.3
inside a 2.0.5 .app" surprise).

## [2.0.5] — 2026-05-05 (hotfix bundle: AppUpdater pre-flight + Match System appearance)

Three v2.0.4 user-test issues. (1) "Match System" appearance
stayed locked: `.preferredColorScheme(nil)` doesn't actually
mean "follow system" on macOS — once applied with a concrete
value and then re-applied with nil, the scheme stays locked
at whatever was last concrete. New
`conditionallyPreferredColorScheme(_:)` view helper simply
doesn't apply the modifier when the value is nil, so SwiftUI
follows the window's `NSAppearance` dynamically. (2) v2.0.3's
`Darwin.access(W_OK)` check was over-restrictive on macOS 14+
— even after toggling App Management ON, `access(W_OK)` kept
returning false (TCC grants don't consistently propagate to
`access(2)` until process restart, and sometimes not even
then). Removed the W_OK pre-flight; pre-flight now only
catches `chflags uchg|schg`, root-owned bundles, and bundles
owned by another non-root user. Anything else (App Management
TCC residue, exotic ACLs) is trusted to surface from the
relaunch helper's actual `mv`/`ditto` call, which logs to
`~/Library/Logs/cool-tunnel-relaunch.log`. (3) Update-failed
banner truncated multi-line guidance: `lineLimit(3)` capped
the .pkg-ownership recovery message, only a Dismiss button.
Raised `lineLimit` to 12, restructured as a VStack with a
button row, added a "Reveal in Finder" button next to Dismiss.

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
locked" because it leaned on `URLResourceKey.isWritableKey`,
which returns false for a superset of conditions (actual
chflags-locked, ACL/POSIX-mode quirks from Time Machine
restores, macOS 14+ App-Management TCC denials, signed-bundle
metadata states on Sequoia). Users without an actually-locked
bundle saw the unchecked-already hint. Fix: probe `chflags`
directly via `lstat` + `st_flags & (UF_IMMUTABLE |
SF_IMMUTABLE)` for the authoritative Locked-checkbox detection,
fall back to `access(W_OK)` for non-chflags causes with a new
"can't modify its own bundle... System Settings → Privacy &
Security → App Management" message. Dropped
`URLResourceKey.isWritableKey` from the bundle-level check;
parent-folder check still uses it.

## [2.0.2] — 2026-05-05 (Check-then-update for naive + rust core)

`NaiveUpdater` and `RustCoreUpdater` now mirror `AppUpdater`'s
check-then-update pattern. Pre-fix every "Update" click did a
full download regardless; naive upstream tags like
`v148.0.7778.96-2` re-publish the same binary under new tag
suffixes so downloads produced cosmetically different bytes
but the binary's `--version` stayed at `148.0.7778.96`. New
states on both updaters: `checking` /
`upToDate(currentVersion:latestTag:)` /
`available(tag:currentVersion:)`. New
`checkForUpdates(currentVersion:)` resolves the latest tag (one
HTTP GET, no binary fetch) and compares via
`tagIsConsideredCurrent(_:forBinaryVersion:lastInstalled:)` —
exact tag match against persisted `lastInstalledTag` OR semver
match after stripping `v` prefix and `-N` suffix.
`lastInstalledTag` persisted in UserDefaults (keys
`NaiveUpdater.lastInstalledTag` / `RustCoreUpdater.lastInstalledTag`);
without persistence every relaunch would falsely report
"Update available". `NaiveUpdater.update()` reuses the
resolved tag from `.available` saving one HTTP roundtrip.
SettingsView morphing button + subtitle (Check for Updates /
Checking… / Update to <tag> / Resolving… / Downloading… /
Extracting… / Merging… / Installing…) mirroring AppUpdater.
Direct invocation of `update()` without a Check still allowed
for any future force-update flow.

## [2.0.1] — 2026-05-05 (hotfix — Rust core version drift + updater verification)

`core/Cargo.toml` was never bumped from `0.1.7` in v2.0.0, so
the Rust binary self-reported `cool-tunnel-core 0.1.7` (what
`env!("CARGO_PKG_VERSION")` resolved to at compile time).
Settings → Rust Core → Update on a v2.0.0 install appeared to
succeed (SHA-256 match passed) but the verdict pill kept
showing 0.1.7. Cargo.toml now at 2.0.1; rebuilt binary
self-reports correctly. U#1. Plus two preventive hardenings:
U#2 — `RustCoreUpdater` runs the new binary's `--version`
after `atomicallyInstall` and refuses to enter `.succeeded`
if the self-reported semver doesn't match the release tag
(would have caught v2.0.0 drift at install). U#6 —
`package_release.sh` Cargo.toml precondition: parse
`core/Cargo.toml`'s `version` field and exit if it doesn't
match the version arg (would have rejected v2.0.0 packaging
with "version is '0.1.7' but you requested '2.0.0'"). U#5 —
verify the .app's bundled engine `--version` matches too.
U#3 / U#4 / U#7 deferred.

## [2.0.0] — 2026-05-05 (full identity rebuild — first-class macOS app)

Major version. The v0.1.x line was a custom-painted experiment;
v2.0 is what the same app looks like when every surface is
built from platform primitives. 27 files changed, +1479 / −1199;
the entire `MalteseTheme.swift` palette module (412 lines) is
removed. Driven by a third-party UX audit applying Apple's
editorial bar and a forensic engine/lifecycle audit; every P0
and P1 finding is closed. Engine + lifecycle: `startCore` is
now wrapped in do/catch that publishes thrown failures to
`lastError` via `recordError(...)` before re-raising (pre-2.0
view callers had empty catch blocks expecting lastError to
carry the surface, but no path inside startCore ever set it
on failure — port collisions produced silent UI). New
`userStopInFlight` flag set during `stop()` / `stopQuiet()`
suppresses the recovery branch in `handle(event:).stateChanged(false)`
during intentional shutdowns (kills the phantom "naive stopped
unexpectedly" banner). Menu-bar Stop routes through
`switchMode(.stopped)` so the existing `transitionInFlight`
guard catches concurrent lifecycle transitions.
`recoverFromCrashIfNeeded` now does `pgrep -x naive` + filters
PIDs whose parent is launchd → SIGTERM → 500ms → SIGKILL, so
if a previous run died with naive holding port 1080 the next
launch is deterministic. Every formerly-empty catch in
ControlPanelView / MenuBarStatusContent / LogConsoleView /
HeaderView now traces through `Logger.cooltunnel("UI.X")`
under one `subsystem == "space.coolwhite.cooltunnel"` umbrella.
Brand normalisation: `PRODUCT_NAME` flipped to `Cool Tunnel`;
bundle on disk renames `Cool tunnel.app` → `Cool Tunnel.app`,
binary inside `Contents/MacOS/` renames likewise, CFBundleName
/ CFBundleDisplayName / App-menu / About panel all read
`Cool Tunnel`. Bundle identifier `space.coolwhite.naive`
unchanged so `refuseIfMultipleInstalls` still works. Settings
contract: removed the `draft: AppSettings` indirection — every
field binds directly to `orchestrator.settings.X` via
`@Bindable`, single form-level `.onChange(of: bindable.settings)`
fires debounced `persistSettings()`. `dismiss()` now calls
`flushSettings()` so Cmd+W + Cmd+Q can't drop the last
keystroke. `⌘,` / "Settings…" wired through a new
`CommandGroup(replacing: .appSettings)`. Menu bar: first-class
`MenuBarExtra` status item with state-driven glyphs; flat mode
rows (Smart / Global / Local) replaced the redundant
Start-button-plus-Mode-submenu pair. ⌘0 opens window, ⌘, opens
Settings, ⌘Q quits. Visual identity: mode-aware pastel-gradient
background gone — system `.windowBackground` material everywhere;
HeaderView rewritten as a quiet status row; ControlPanelView
uses real `Picker(.segmented)` + `.borderedProminent` Start/Stop;
ConnectionFormView is now `Form { Section { … } }.formStyle(.grouped)`;
LogConsoleView uses `.regularMaterial` + `.separatorColor`
hairline. New procedural icon stack via
`scripts/generate_app_icon.swift` (squircle backdrop, three
concentric tunnel rings, one-point perspective). Firewall
deep-link: orange "Firewall on" capsule is now a Button
opening `x-apple.systempreferences:com.apple.preference.security?Firewall`
via `NSWorkspace.shared.open` with two-tier fallback. New
`LoginItemRow` backed by `SMAppService.mainApp` with
approval-pending deep-link. Log export pipeline: inline filter
(case-insensitive substring); `⋯` actions menu with Copy All
(⌘⇧C), Save to File… (.fileExporter), Share… (ShareLink),
Clear; scroll-icon drag-out via `.draggable(logAsText)` with
custom preview; per-row context menu (Copy Line / Copy with
Timestamp). New `AcknowledgementsView` with three-entry
attribution (NaiveProxy BSD-3, Rust crate graph
MIT/Apache-2.0, SF Symbols Apple). Accessibility: Reduce
Motion respected (gates empty-state pulse + auto-scroll
animation); drag-handle has explicit label/hint;
"Waiting for the first log line…" placeholder uses
`accessibilityElement(children: .combine)` so VoiceOver reads
one logical statement.

## [0.1.7.21] — 2026-05-04 (LTSC patch — clarity sweep, deletions only)

Net –287 lines. No behaviour change. Deleted:
`AppUpdater.sha256(of:)` (single-line wrapper forwarding to
`SHAVerifier.sha256(of:)`); `AppUpdater.writeRelaunchScript`
(inlined the four operative lines into `spawnRelaunchHelper`);
`AppUpdater.swift` file-header release-history block (~80
lines of AU-1 through AU-15 narrative — that's what CHANGELOG
is for); `docs/v0.1.5-roadmap.md` (209 lines stale planning,
flagged "now stale" two cycles ago);
`docs/session-prompts-summary.xlsx` (per-session artifact
committed via `git add -A` in v0.1.7.16). Kept: audit-tag
inline comments (describe invariants, not just history);
`activeProfileID` field (used by exactly one consumer but
not derivable from existing state); `ProxyActiveFlag` module
(actual state machine, not indirection).

## [0.1.7.20] — 2026-05-04 (LTSC hotfix — multi-install false-positive)

v0.1.7.16's Edge-F#11 multi-install detector
(`refuseIfMultipleInstalls`) ran `mdfind
kMDItemCFBundleIdentifier == "space.coolwhite.naive"` and
treated every hit as a real install. Spotlight indexes Xcode
build artifacts in DerivedData — any developer with the
checkout who ran xcodebuild once had 1-10+ extra hits, and
the in-app updater refused with "Multiple copies found" even
though `/Applications/` had only one. New helper
`isPlausibleUserInstall(_:)` excludes `mdfind` hits containing
`/DerivedData/`, `/Build/Products/`, `/Library/Developer/Xcode/`,
or project-local `build/DerivedData/` / `build/Build/Products/`.
Real installs anywhere outside those patterns still detected.
Error message now enumerates actual paths on real duplicates.

## [0.1.7.19] — 2026-05-04 (LTSC patch — 10 deferred-high cluster)

10 high-severity items pulled forward as one focused release.
UX-F#5: auto-revert proxy on naive crash —
`handle(event:).stateChanged(false)` outside a user-stop now
calls `proxyController.disableAll()` and clears the sentinel
(pre-fix macOS kept routing at `127.0.0.1:1080` with nothing
listening, browser stalled, header said "Idle"). UX-F#16:
engine pipe-death recovery — when `subscribeToEvents` ends
outside shutdown, orchestrator reverts proxy, flips
`didBootstrap = false` so the next mode click re-bootstraps,
and surfaces an actionable error ("click a mode chip" instead
of "click Start again" which would throw `.notRunning`).
Subproc-F#11a: CoreClient stderr drain — engine stderr was
inherited (no drain); chatty engine writing >64 KiB filled the
kernel pipe buffer and deadlocked mid-request. Added
`Task.detached(priority: .utility)` that reads stderr to EOF
and forwards to `Logger.cooltunnel("CoreClient.stderr")`.
Subproc-F#11b: SystemProxyController now routes through
`Subprocess.run` (was the legacy `waitUntilExit() +
readDataToEndOfFile()` pattern — exact pipe-deadlock scenario
for `networksetup -listallnetworkservices` on a Mac with many
services). Subproc-F#3: env sanitisation — children now receive
minimal env (PATH=`/usr/bin:/bin:/usr/sbin:/sbin`, HOME, LANG=C,
LC_ALL=C) instead of the app's full env including
`DYLD_INSERT_LIBRARIES`, `OBJC_DEBUG_*`, `MallocStackLogging`
which could bias trust-boundary tools like codesign and
networksetup. Subproc-F#1: SIGTERM → 1s → SIGKILL replaces the
3-step SIGTERM → 250ms → SIGINT → 250ms → SIGKILL ladder (SIGINT
wasn't an escalation past SIGTERM; naive traps both for
graceful shutdown, middle step wasted time). Lifecycle-F#7:
new `transitionInFlight: Bool` on TunnelOrchestrator — rapid
second click during a mid-flight `switchMode` is now a clean
no-op (pre-fix two concurrent transitions raced on
`paths.configFile`, `proxyController` state, and `core.send`
ordering, with multiple naive children briefly existing).
UX-F#3: profile mutation while connected surfaces a banner —
new `activeProfileID` captured at `startCore` time; setter
compares against current `profiles[id]` and sets lastError
"Profile edits applied — click Stop, then a mode chip" when
they differ on the running profile. `activeServices()`
`dropFirst(1)` legend filter (was `.contains("asterisk")`,
broken on non-English macOS). Lifecycle-F#5: AppDelegate
watchdog now `shutdownTask.cancel()` before firing the reply
(pre-fix the shutdown Task could continue running its body on
a partially-released graph while AppKit was mid-teardown).

## [0.1.7.18] — 2026-05-04 (LTSC patch — focused high-severity cluster)

Three high-severity deferred items. Lifecycle-F#16: system
proxy crash recovery via sentinel file. Pre-fix, if Cool Tunnel
crashed (SIGKILL / kernel panic / power loss) with the system
proxy enabled, macOS carried the proxy state across reboots
pointing at `127.0.0.1:1080` where nothing listened, stalling
every browser request until the user manually unticked the
boxes in System Settings → Network → Proxies. New
`SystemIntegration/ProxyActiveFlag.swift` writes a JSON
sentinel at `~/Library/Application Support/COOL-TUNNEL/proxy-active.flag`
on enable, deletes on clean disable, and a new
`recoverFromCrashIfNeeded` (called by `bootstrapIfNeeded`
BEFORE any other startup work) forces `disableAll()` and
clears the flag if the sentinel survives a launch. UX-F#4:
`NSWorkspace.didWakeNotification` handler — after >30 minute
sleep, TCP keepalives often drop; pre-fix naive was alive but
every browser request stalled and the UI kept showing "Active"
with no recovery hint. Now AppDelegate subscribes to
didWakeNotification and the orchestrator sends a light-touch
probe through the engine pipe; on throw it records lastError
rendered in the HeaderView banner. Sw#C4 partial: Rust Core
SHA-256 pinning — pre-fix only the .app self-updater pinned
SHA. RustCoreUpdater now downloads the `.sha256` manifest in
parallel with the engine binary, parses for the
`cool-tunnel-core-vX.Y.Z-universal` asset line, and refuses to
adopt on mismatch or missing manifest. Releases without the
manifest are skipped, not adopted unverified. New
`SystemIntegration/SHAVerifier.swift` extracted from AppUpdater
so both updaters share the streaming-SHA + manifest-parser
primitives. NaiveProxy SHA pinning + Password Secret newtype
+ Swift test target stay deferred to v0.1.8 (require
infrastructure outside this window).

## [0.1.7.17] — 2026-05-04 (LTSC patch — 100+ findings, 8 land)

8 specialised review agents returned 120 findings across
persistence, lifecycle, supervisor/monitor, diagnostics,
domain types, UX, build determinism, and subprocess hardening.
8 land here. UX-F#1: `lastError` surfaced in HeaderView —
`recordError()` was setting lastError on every failure but no
view read it; errors appeared only as one `[error]` line in
the log console. Header now shows a dismissible cherry-rose
error banner directly under the status pill. New
`dismissLastError()` keeps the public setter `private(set)`.
Sup-F#6: lsof endpoint-aware loopback exclusion — v0.1.7.16
fixed IPv6 `[::1]` exclusion but used substring-match against
the entire line, so `127.0.0.1:54321 -> 1.2.3.4:443` was
misclassified as "not remote" and masked a genuine outbound
flow. Now split on `->`, check both endpoints separately,
exclude only when BOTH are loopback. Domain-F#2: `Username::parse`
rejects control chars + `@` + `:` (pre-fix `"a@b:c\n/d"`
parsed and produced ambiguous percent-encoding that downstream
HTTP-header writers could split on) via new
`InvalidCredentials::IllegalUsernameChar(char)`. Diag-F#1:
JSON / k=v credential redaction — new `JSON_KV_CRED_REGEX`
covers `password`, `passwd`, `secret`, `token`, `api_key`,
`apikey`, `access_token`, `refresh_token` case-insensitive
(pre-fix only URL userinfo + Authorization + Cookie were
redacted; naive's config-load errors dump `"password":"…"`,
curl -v emits `password: hunter2`, both reached the UI
verbatim). Build-F#6: `rust-toolchain.toml` pinned to 1.95.0
(was `channel = "stable"` which floated across CI runs);
added explicit `targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]`.
Subproc-F#6: hardened runtime enabled in pbxproj —
`ENABLE_HARDENED_RUNTIME = YES` + `OTHER_CODE_SIGN_FLAGS =
"--options runtime"` on both Debug and Release. Pre-fix
ad-hoc-signed builds ran without library-validation gating
so a `DYLD_INSERT_LIBRARIES` attacker could inject.
Pers-F#10: ProfileStore corrupt-JSON recovery — pre-fix
`try? JSONDecoder().decode(...)` swallowed decode errors and
returned `[.default]`, and the next `save(profiles:)`
overwrote the corrupted-but-recoverable blob with the
default, silently destroying the user's profile list. Now on
decode failure: copy the blob to a `profiles.broken.<ISO>`
backup key and os_log an error before falling back. Build-F#1
(`zmij` typo-squat claim) was investigated and confirmed
false-positive — `zmij` is a real published crate that newer
serde_json uses in place of `ryu`. 112 deferred including
SystemProxyController revert-on-crash (→ v0.1.7.18), Password
Secret newtype + zeroize, Swift test target, NaiveProxy SHA
pinning, and ~25 "don't-do-it" findings.

## [0.1.7.16] — 2026-05-04 (LTSC patch — broad-surface deep audit)

7 review agents returned 100 findings across Rust core, Swift
views, shell/tooling, test coverage, docs, and updater edge
cases; 13 land here. Rust-F#1: `validate_profile` contract
honesty — dispatcher arm took already-deserialised Profile so
`ok:false` of ValidationReport was structurally unreachable
(same pattern as SM-3 in server_mode); variant now carries
RawProfile and the dispatcher runs `Profile::try_from(raw)`.
Rust-F#2: `monitor::lsof::parse` IPv6 loopback exclusion —
only `127.0.0.1` was excluded from "remote" classification;
macOS uses `[::1]:port->[::1]:port` for IPv6 ESTABLISHED, so
an IPv6-first system's loopback fanout synthesised
`TooManyRemote` anomalies. Now also excludes `[::1]`. Rust-F#4:
`unimplemented_method` wildcard arm in `dispatch()` previously
embedded `format!("…{kind:?}")` in the wire payload — a
forward-compat exfil channel. Wire body is now stable
payload-free; unknown variant goes to `tracing::warn!` only.
Cross-F#1: NaiveUpdater + RustCoreUpdater API surface
narrowed to `internal` (matches AU-15 v0.1.7.12 demotion of
AppUpdater). Cross-F#2: `Logger.cooltunnel("NaiveUpdater")`
+ `…("RustCoreUpdater")` added — security-relevant rejects
(untrusted host, oversize, network failure) now have os_log
breadcrumbs. Edge-F#1: disk-space pre-flight on tempRoot —
runPipeline calls `requireFreeSpace(at:atLeast:)` requiring
300 MB before .zip download (prevents ENOSPC mid-swap after
parent termination). Edge-F#11: multi-install detection via
`mdfind` — refuse update if `/Applications` + `~/Applications`
both have copies (LaunchServices would launch the
not-updated one). Shell-F#5: `cargo build --locked`
everywhere (`build_rust_core.sh` + ci.yml clippy/test/build
— missing/stale Cargo.lock was silently regenerated against
newer transitive deps, defeating LTSC reproducibility).
Shell-F#6: least-privilege CI permissions
`{ contents: read }` at workflow level + `actions/checkout`
`with: persist-credentials: false` (pre-fix inherited org
defaults could be write or worse, GITHUB_TOKEN left in
.git/config could be exfiltrated). Doc fixes: Disclaimer
"no data collection" paragraph corrected (credentials live
in `credentials.json` 0600, not Keychain); README disk size
23 MB → ~45 MB (drift since v0.1.7); README documents the
in-app self-updater explicitly; SECURITY.md threat-model
acknowledges the SHA-pin gap for Naive + RustCore CDN
tampering, tracked for v0.1.8. 87 deferred (NaiveProxy +
RustCore SHA pinning, test coverage, SwiftUI render
efficiency, localisation, accessibility, architectural
debt, bash hardening, doc polish, performance, style, plus
~15 "don't-do-it" findings flagged so future reviewers
don't re-propose).

## [0.1.7.15] — 2026-05-04 (LTSC patch — deep audit, MainActor freeze fix)

3-angle review (adversarial security, Swift 6 concurrency,
architectural) returned 32 findings; 7 land. CONC-F#1
(headline): NaiveUpdater + RustCoreUpdater were freezing the
UI during updates because `runProcess` synchronously called
`Process.waitUntilExit()` from `@MainActor` context.
AppUpdater fixed this pattern in v0.1.7.10 via `Subprocess.run`
but the cousin updaters were missed. Both `runProcess`
methods are now async and route through Subprocess.run
(concurrent pipe drain + 120 s timeout escalation); helpers
(`extractNaive`, `lipoCreate`, `adhocSign`,
`RustCoreUpdater.adhocSign`) are `nonisolated async`.
NaiveUpdater extracts the two arches in parallel via
`async let` (~2× speedup). SEC-F#8: hard-link rejection in
`refuseExtractionEscapingSymlinks` — pre-fix only inspected
symlinks, so a malicious zip surviving SHA verification could
embed `Cool tunnel.app/Contents/Resources/foo` as a hard
link to `/etc/passwd` or `~/.ssh/config`. Now any regular
file with `nlinks > 1` rejects. SEC-F#6: `fchmod()` after
`open()` in `RestrictedFile.write` — POSIX `open(2)` ANDs
the supplied mode with `~umask`, so an unusual umask
(corporate-managed `0o077`) creates the file with fewer
perms than requested. `fchmod(2)` doesn't honour umask, so
calling it guarantees the requested mode regardless of
environment. SEC-F#7: defend `~/Library/Logs/cool-tunnel/relaunch.log`
against pre-planted symlinks — an attacker with prior
file-write access (T4) could pre-create the path as a
symlink to `/dev/full` or a root-owned location, the bash
helper's `exec 2>>"$LOG"` would silently fail. Swift now
checks `isSymbolicLink` and unlinks if non-regular.
ARCH-F#1: single shared `SystemIntegration/UpdaterError.swift`
replaces three identical `enum X: Error, Sendable,
Equatable { case message(String) }` declarations. ARCH-F#2:
size cap on shared `GitHubRedirectGuard.download` — only
AppUpdater.download had a cap; sibling updaters could fetch
a 4 GB file from a trusted GitHub host with no limit. New
`maxBytes: Int64 = 100 * 1024 * 1024` parameter +
`OversizeDownloadError`. SEC-F#11: `Cache-Control: no-cache`
header on metadata fetches — network-position attacker (T1)
serving a captured `/releases/latest` could otherwise
downgrade the offered version even through HTTPS (replay of
integrity-protected bytes is still replayable). NaiveUpdater
+ RustCoreUpdater SHA pinning (SEC-F#1/2) deferred to v0.1.8.

## [0.1.7.14] — 2026-05-04 (LTSC patch — second simplify pass)

7 of 18 simplify-review follow-ons land. R-F#2: Naive/RustCore
download dedup — v0.1.7.13's host check + URLRequest +
download(for:delegate:) + status check + fileExists/removeItem/moveItem
sequence drifted into line-for-line twins (~22 lines × 2);
extracted to `GitHubRedirectGuard.download(url:to:)` static
helper, both call sites now 3-line `do/catch` mapping
`UntrustedGitHubHostError`. AppUpdater's download stays
bespoke (layers per-asset size cap). Q-F#1: bash
mkdir-before-redirect silent fail — Swift's
`makeRelaunchLogPath()` already creates the dir before
spawning the script, and bash mkdir failure path was silent
(`task.standardError = nil` on parent spawn made the
diagnostic vanish under `set -eu`). Bash mkdir removed. R-F#1:
new `Logger.cooltunnel(_:)` factory extension — three Logger
declarations each spelled out
`Logger(subsystem: "space.coolwhite.cooltunnel", category: ...)`
with the subsystem as a literal; orphan-subsystem regression
(the legacy `"com.cool-tunnel.app"` string fixed in v0.1.7.13)
becomes structurally impossible. Q-F#2: `makeRelaunchLogPath`
force-unwrap replaced with throwing guard. E-F#3: dropped
redundant `.lowercased()` on `url.scheme` and `url.host` in
`isTrustedGitHubURL` (Foundation already canonicalises per
RFC 3986). Q-F#5: `canonicalPathComponents` returns `[String]?`
instead of threading an `errorMessage:` parameter through the
realpath wrapper. Q-F#7: trimmed stale AU-1 doc on
`writeRelaunchScript`. 11 deferred (style, micro-opts).

## [0.1.7.13] — 2026-05-04 (LTSC patch — post-cycle simplify pass)

12 of 31 simplify findings land. Cross-cutting theme:
v0.1.7.11/.12 hardened AppUpdater extensively but left
NaiveUpdater + RustCoreUpdater exposed to the same redirect /
host-substitution attacks. R-F#4: new
`SystemIntegration/GitHubTrust.swift` extracts
`isTrustedGitHubURL(_:)` and `GitHubRedirectGuard` from
AppUpdater (was `fileprivate`) into a shared module;
`GitHubRedirectGuard.shared` is a stateless singleton.
NaiveUpdater + RustCoreUpdater now use
`URLSession.shared.data/download(for:delegate:
GitHubRedirectGuard.shared)` and validate every URL via
`isTrustedGitHubURL` before download. SHA pinning for the
two still deferred per Sw#C4, but a CDN takeover or upstream
redirect misconfiguration alone is no longer sufficient.
Q-F#1: `@discardableResult` removed from `markEnteringCheck`
/ `markEnteringDownload` so the v0.1.7.12 AU-13 invariant is
compile-time-enforced. Q-F#2: bash relaunch helper now
`exec 2>>"$LOG"` to `~/Library/Logs/cool-tunnel/relaunch.log`
so AU-11's `preswap_trap` recovery hints actually reach a
file (pre-fix the Swift spawn set `task.standardError = nil`
sending stderr to `/dev/null`). New Swift
`makeRelaunchLogPath()` helper creates the dir. R-F#1:
`writeRelaunchScript` delegates to a generalised
`RestrictedFile.write(_:to:mode:)` (~50 lines of bespoke
`O_CREAT|O_EXCL` + write + fsync + close FD-lifecycle
collapses to one call). R-F#2: `os.Logger` migration —
replaced legacy `OSLog(subsystem:category:)` + `os_log`
with `Logger(subsystem:category:)`, fixed the orphan
subsystem string `"com.cool-tunnel.app"` to project-wide
`"space.coolwhite.cooltunnel"` so support's `log show`
queries surface every component under one umbrella. Calls
use typed interpolation with explicit `, privacy: .public`.
R-F#7: `canonicalPathComponents` helper centralises
`realpath(3)` + `String(cString:)` + `free` + `pathComponents`
extraction the symlink-escape walker was doing twice. E-F#1:
parallel .zip + .sha256 download via `async let` (manifest
fetch completes during .zip TLS handshake, ~2× speedup on
cold path). E-F#6: drop TOCTOU `fileExists` + `removeItem`
before `moveItem` (`tempRoot` is freshly mkdtemp'd per
pipeline run; destination collision impossible). E-F#8:
entry-count cap on extraction symlink walk — bails after
1024 symlinks (was unbounded; an attacker-shaped zip could
plant 10k+ for a `realpath(3)` work-multiplier inside the
Sw-H3 100 MB cap). R-F#3: `MAX_PAC_DOMAIN_BYTES` promoted
to `ServerAddress::MAX_LEN pub const` (v0.1.7.12 had two
copies of the RFC 1035 limit; drift risk closed).

## [0.1.7.12] — 2026-05-04 (LTSC patch — Fifth audit cycle, batch 2)

Closes the Fifth audit cycle with 11 medium/low fixes
(v0.1.7.11 was the 13 critical/high). AU-6: canonical bundle
ID constant in `verifyExtractedApp` instead of
`Bundle.main.bundleIdentifier` (the latter reads from the
running process's plist — attacker-controllable if the running
app was ever substituted, anchoring trust in attacker input).
`canonicalBundleID = "space.coolwhite.naive"` matches
`PRODUCT_BUNDLE_IDENTIFIER` in the Xcode project. AU-8:
download error message scrubs asset filename — the stage
(.zip vs .sha256) plus HTTP status told an
observer-on-the-wire which artifact failed, helping calibrate
a partial-block attack against the manifest (the SHA-pin
root of trust). Stage detail goes to os_log. AU-9:
`refuseReadOnlyInstall` now tests parent volume read-only +
parent folder writable + bundle not immutable (`chflags
uchg`). Pre-fix only the first was checked; the others
slipped through pre-terminate leaving the user with no app
and no UI. AU-10: relaunch helper uses `open PATH`, not `open
-a NAME` — `open -a` performs name lookup and bash word-splits
"/Applications/Cool tunnel.app" so `-a Cool` treated
`tunnel.app` as a document, misfiring relaunch. AU-11:
pre-swap trap preserves recovery materials — the bash
helper's `preswap_trap` retains `$TEMP_ROOT` (verified-good
extracted .app) and `$BACKUP` (mid-rollback) on any pre-swap
error. Only after step 4 (BACKUP removed → swap fully
succeeded) does the trap get replaced with destructive
cleanup. Pre-fix a rollback failure during step 3 also
deleted $TEMP_ROOT, leaving neither the new app nor a
known-good copy. AU-13: `markEnteringCheck` /
`markEnteringDownload` return Bool — Settings click handlers
used to be three separate steps (guard !isInFlight; mark;
spawn Task), allowing a redundant Task on fast double-click.
Now the flip and the spawn are atomic via `guard
appUpdater.markEnteringCheck() else { return }; Task { ... }`.
AU-14: `locateAppBundle` filter requires `isDirectory` — a
malicious zip can contain an entry named `Cool tunnel.app`
that is a regular file or symlink rather than a bundle dir;
pre-fix the next step failed with "couldn't read Info.plist"
instead of "structural shape wrong". Filter now demands both
`.app` extension AND `isDirectory == true`. SM-4:
`naive_pac` caps `direct_domains` at 1024 entries × 253
bytes each (RFC 1035 hostname max). Pre-fix a single request
could carry ~16k single-char entries under the 64 KiB body
limit, each becoming a `to_lowercase()` allocation +
`serde_json::to_string` pass + `format!` insertion. Cool
Tunnel ships ~16 entries by default; over-cap rejects with
`ApiError::BadRequest`. SM-6: resolved by SM-4 — no
`spawn_blocking` needed because the synchronous cost is now
bounded under 10 ms. SM-7: `encode_js_string_array` uses
`expect`, not `unwrap_or_default` — `serde_json::to_string`
over `&[String]` is structurally infallible, but the
defensive fallback silently emitted `String::new()` on the
unreachable path (a future refactor swapping `&[String]` for
a fallible type would produce invalid JS
`var directDomains = ;` with zero diagnostic). SM-10:
router gets `tower::limit::ConcurrencyLimitLayer(64)` — caps
total in-flight requests across all routes; bounds the
worst-case for a slow-loris client dripping bytes into a
64 KiB body. Body-read timeout deferred. New direct dep:
`tower = { version = "0.5", features = ["limit"] }` (already
transitive via axum).

## [0.1.7.11] — 2026-05-04 (LTSC patch — Fifth audit cycle, batch 1)

Fifth audit cycle, Rule Maker rubric (R1 fail-secure / R2
boundary enforcement / R3 ≤10 ms / R4 no theatre). 13 of 25
land here. AU-1: relaunch helper script no longer in `/tmp` —
`String.write(to:atomically:)` created the script with default
umask perms (~0644), then a separate `setAttributes(0o700)`
tightened them, leaving a tiny window where a same-UID attacker
could swap via symlink before `task.run()`. New
`writeRelaunchScript` opens in the per-update tempRoot via
`open(O_CREAT|O_EXCL|O_WRONLY, 0o700)`, fsyncs before close,
surfaces errno. AU-2: `validateInstallAssets` requires both
`.zip` and `.sha256` `browser_download_url`s to be HTTPS on a
host ending in `github.com` or `githubusercontent.com` (a
compromised API response pointing the manifest fetch at an
attacker host would defeat SHA pinning by substituting the
verification root-of-trust). AU-3: per-task
`URLSessionTaskDelegate` (`GitHubRedirectGuard`) rejects any
HTTP redirect whose target isn't on the same trusted suffix
list. `URLSession.shared.download(from:)` was following up to
~20 redirects with no host check. AU-4: SHA hashing + plist
read off `@MainActor` — pipeline helpers are now
`nonisolated`; `verifyZipAgainstManifest` streams 64 KiB at a
time instead of `Data(contentsOf: zipURL)` (a 12 MB main-thread
allocation froze the Settings UI on slow disks). Plist parsing
in `Task.detached(priority: .userInitiated)` returning a
Sendable `ExtractedAppInfo`. AU-5: `realpath(3)` +
path-component ancestor check in `refuseExtractionEscapingSymlinks`
— pre-fix `String.hasPrefix(containerPath)` gave false
negatives on sibling-path collision (`/extracted-evil` passed
against `/extracted`) and symlink-target traversal
(`URL.resolvingSymlinksInPath()` resolves the link but doesn't
normalise `..` through the resolved target). Comparison is now
`targetComponents.starts(with: containerComponents)`. Broken
symlinks reject outright. SM-1: `JsonRejection` scrubbed at
every handler boundary — every `axum::Json<T>` handler now
takes `Result<Json<T>, JsonRejection>` and converts via
`ApiError::from_json_rejection`, logging the verbatim serde
error server-side and returning `{"error":"bad request"}` on
the wire. Pre-fix axum's default 400 body included the verbatim
serde error (internal field names + validation rules — e.g.
`"server: contains forbidden ':/​/'"`), a free probe of internal
logic for an unauthenticated caller. SM-2: `ApiError` carries
no payload — both `BadRequest` and `Internal` are unit variants
returning a stable opaque body per HTTP status; cause-of-failure
goes to `tracing::error!` only. SM-3: `naive_validate` honours
its advertised contract — handler now accepts any JSON value,
runs `Profile` deserialise itself, returns
`{ok:false, reason:"invalid profile"}` on failure (with detail
logged server-side) and `{ok:true}` on success. Both branches
now reachable. AU-7: version-mismatch error in
`verifyExtractedApp` no longer interpolates
`CFBundleShortVersionString` — attacker past SHA pinning could
plant a Unicode bidi-override / "click here to bypass" text;
value goes to os_log for support. AU-12: `versionIsNewer`
rejects non-numeric segments + pre-release suffixes — pre-fix
`Int($0) ?? 0` coerced `"0-rc1"` to 0 making `1.0.0-rc1`
compare equal to `1.0.0`. New `parseVersionSegments` returns
nil on `-` or non-numeric segments. AU-15: `public` removed
from within-module symbols (single app target, no cross-module
consumer). SM-5: `NaiveConfig` fields are `pub(crate)` — locks
the construction invariants (`listen` is
`socks://127.0.0.1:<port>`, `proxy` embeds percent-encoded
credentials) to `from_profile`. SM-9: `server_mode::run`
refuses to bind a non-loopback address unless
`--allow-public` is passed, returning `PermissionDenied`. The
loopback-only posture was previously documented but not
enforced; a `--listen 0.0.0.0:8787` typo silently exposed an
unauthenticated engine. New logging policy codified as a
top-of-file doc on `server_mode.rs`: handlers MUST NOT log the
request body, the resolved Profile, or `ApiError::*` payloads.
`Profile` carries `Password::expose_secret`; a "log the failing
body for debug" PR would silently leak credentials. 12 fixes
deferred to v0.1.7.12.

## [0.1.7.10] — 2026-05-04 (LTSC patch — comprehensive audit + security)

Parallel Swift + Rust audits plus a tooling self-audit.
Regression fix: AppUpdater Check + Update buttons were broken
in v0.1.7.9 — the `markEnteringCheck()` / `markEnteringDownload()`
sync flag flipped state to the placeholder phase BEFORE the
async `guard !isInFlight` check, so the guard returned early
and the network call never fired. Relaxed the guards to refuse
only when a genuinely active later phase
(downloading/verifying/extracting/relaunching) is in flight.
Swift in-app updater security: Sw-H1 — bundle-identifier
comparison `precomposedStringWithCanonicalMapping`-normalised
on both sides, non-ASCII rejected outright (defence against
Unicode-confusable IDs if SHA pinning were defeated). Sw-H2 —
SHA mismatch error no longer echoes the hashes (helps a MITM
observe what to forge); manifest entries hex-validated before
compare so a corrupted-but-64-chars line gives "manifest may
be corrupted" instead of misleading "SHA-256 mismatch". Sw-H3
— download size cap: .zip ≤ 100 MB, .sha256 ≤ 1 MB. Sw-H4 —
post-extraction symlink-escape walk rejects any symlink whose
`realpath` escapes the extraction dir (`ditto -x -k` PKZip
mode preserves symlinks inside archives; a malicious zip
otherwise identical to a known-SHA copy could plant
`Resources/foo → ~/.ssh/config`). C1 — `AppUpdater.unzip`
pipe-buffer deadlock fixed: Process with shared stdout/stderr
pipe blocked on `waitUntilExit` if ditto wrote >64 KB to
stderr (kernel pipe buffer fills, ditto blocks on next write,
deadlock). Routed through `Subprocess.run` for concurrent
drain. C2 — relaunch helper does atomic .new staging with
rollback: ditto into `$OLD_APP.new` → `mv $OLD_APP
$OLD_APP.old-update` → `mv $OLD_APP.new $OLD_APP` →
`rm -rf $OLD_APP.old-update`. Plus `set -eu` + `trap cleanup
EXIT`. Pre-fix `rm -rf "$OLD_APP" && ditto` was destructive
with no recovery. C4 — `RestrictedFile.write` fsync check +
double-close fix: `fsync(fd)` return was discarded so a
silent disk EIO meant the atomic rename pointed at unflushed
bytes; plus a real double-close in the catch path could
corrupt an unrelated FD macOS reused. New `didClose` flag.
H5 — `AppUpdater.run` tempRoot leak fixed via do/catch that
cleans up on any throw; plus `Bundle.main.bundleURL.resolvingSymlinksInPath()`
so symlinked install paths are evaluated by their real
destination. **Rust engine wire-protocol correctness:**
Ru-A1 single-emitter discipline for `state_changed:false`
— v0.1.7.5 message-pump refactor moved user-stop emission to
the dispatcher but `monitor_lifecycle` retained natural-death
emission, so concurrent crash + user-stop could fire twice.
`monitor_lifecycle` no longer emits state-changed at all;
`client_mode::monitor_loop`'s natural-death detection owns
the natural-death emission via at-most-once `emitted_stopped`
flag yielding to dispatcher's user-stop emission. Ru-A2 —
`Proxy-Authorization` header now redacted via
`(?:Proxy-)?Authorization:` regex (pre-fix the literal
`Authorization:` prefix-only regex let `Proxy-Authorization:
Basic <b64>` through verbatim, undoing the rest of the
credential-hygiene effort). Ru-A3 — stop-side TOCTOU race:
the dispatcher released the engine lock between `take()` and
`supervisor.stop().await`, so during that ~2 s window a
concurrent `start_proxy` could spawn a second naive while the
first was still draining. Now dispatcher sets `stopping =
true` under the lock; start_proxy checks both
`supervisor.is_some` AND `stopping`. Ru-A4 — `stdout_writer`
fallback on serialize failure writes a hand-built error frame
with the original id (pre-fix the writer logged and continued,
silently dropping the response and leaving the Swift waiter
pending forever). Ru-B6 — `ProxySupervisor::Drop` aborts the
monitor task (pre-fix the JoinHandle was leaked on the
runtime). Chaos suite +2 scenarios
(`siege_concurrent_stop_proxy_race` verifies Ru-A1+A3,
`siege_natural_death_then_user_stop_emits_once` verifies the
single-emitter discipline). 20 chaos + 104 unit + 6
integration + 2 doctest = 132 tests. Tooling: `cargo deny
check` now in CI (was policy-without-enforcement);
`multiple-versions = deny` (was warn); swift-format CI step
hard-fails on missing tool (was soft-fail silent no-op).

## [0.1.7.9] — 2026-05-03 (LTSC patch — UI/UX stress audit)

4th UI audit returned 38 findings; high-confidence visible
bugs and dark-mode contrast issues close here. In-app updater
showed `"Downloading \(Int(p * 100))%…"` with p always 0.0
because `URLSession.shared.download(from:)` doesn't report
byte-level progress — users stared at "Downloading 0%…" for
minutes. Now reads "Downloading… (typically a few seconds on
broadband)". Added `markEnteringCheck()` / `markEnteringDownload()`
sync flip methods on AppUpdater so rapid clicks can't queue
multiple Tasks (mirrors the proven naive/rust pattern).
`PupCardModifier` dark-mode card edges restored — shadow,
border opacity, and paper overlay now read
`@Environment(\.colorScheme)` and pick mode-aware values
(shadow `Color.black.opacity(0.55)` dark vs 0.06 light;
border 0.65 vs 0.45; paper overlay 0.18 vs 0.40 so vibrancy
material shows through in dark). Six sites with
`.opacity(0.10)` status-pill backgrounds (OK/NG verdicts,
release-notes pill, failed pill) migrated to new
`CTSurface.statusPillAlpha(scheme)` returning 0.22 dark / 0.10
light. LogConsole inner surface uses `Color.black.opacity(0.35)`
in dark to recess properly. `.relaunching` delay bumped 500 ms
→ 1.2 s (below SwiftUI render budget on Intel Macs). Connection
form first-run hint dark-mode `macBlue.opacity(0.22)`. Add
Domain field's TextField gains `.onSubmit { addDomain() }`
(pre-fix Return fell through to the Done button's defaultAction
and dismissed Settings without adding). Accessibility:
Appearance picker exposes selection via `.accessibilityValue`;
updater progress spinner has per-phase `accessibilityLabel`;
Release notes Link has explicit accessibilityLabel. Real
cancel button via `URLSessionDownloadDelegate` and orphan-download
lifecycle deferred to v0.2.

## [0.1.7.8] — 2026-05-03 (LTSC patch — updater bugfix)

Two production bugs from the v0.1.7.7 in-app updater. (1)
`.sha256` manifest missing from GitHub releases:
`package_release.sh` generated `Cool-tunnel-vX.Y.Z.sha256`
since v0.1.4 but `gh release create` commands never included
it, so the v0.1.7.6 in-app updater had no way to verify any
release. Backfilled `.sha256` onto v0.1.7.5 / v0.1.7.6 /
v0.1.7.7 release pages. `package_release.sh` now prints the
canonical `gh release create` command at the end of every
package run with all five required assets pre-filled. (2)
"Up to date" reported as failure: pre-fix
`AppUpdater.fetchLatestRelease` validated `.zip` + `.sha256`
existence BEFORE comparing versions, so a release missing the
manifest threw "Update failed: missing manifest" even when
the user was already on the latest. Split into
`fetchLatestReleaseMetadata` (cheap) + `validateInstallAssets`
(only called when an upgrade is on offer).

## [0.1.7.7] — 2026-05-03 (LTSC patch — light/dark mode)

Closes Sw#24 (dark-mode dynamic palette) plus user-controlled
appearance preference (Match System / Light / Dark). Every
`CTPalette` token (paper, platinum, borderInk, bodyInk, macBlue,
macBlueSoft, cherryRose, bunnyPink, lilac, mint) resolves to a
light or dark variant via `NSColor(name:dynamicProvider:)`. View
layer unchanged. Light variants byte-identical to v0.1.7.6;
dark variants tuned for the same System 7 mood with inverted
luminance and slightly brighter accents. New `AppearanceMode`
enum on `AppSettings` (`.system / .light / .dark`) persisted in
UserDefaults; unknown values fall back to `.system`. ContentView
applies `.preferredColorScheme(orchestrator.settings.appearanceMode.colorScheme)`
on the root (.system returns nil → SwiftUI follows macOS).
Settings → Appearance segmented picker. Existing v0.1.7.6 users
on dark mode were rendering with the light palette; default
`.system` will pick up dark automatically on upgrade.

## [0.1.7.6] — 2026-05-03 (LTSC patch — in-app self-updater)

New Settings section with Check for Updates + Update to
vX.Y.Z buttons. Check does `GET /releases/latest` from GitHub
API, compares to `CFBundleShortVersionString`, renders
up-to-date / update available / failed. Update downloads the
`.zip` + `.sha256` manifest, computes SHA-256 via CryptoKit
and refuses to install on any mismatch, extracts via
`ditto -x -k` (preserves macOS metadata + code signature),
verifies the new app's bundle identifier + version + code
signature, refuses if on a read-only volume, writes a bash
relaunch helper to `/tmp` and spawns detached (helper waits
for parent PID to exit, ditto-replaces the bundle, runs
`open -a` on the new copy, cleans up), then quits. Closes
Sw#C4 for the .app self-updater surface: pre-fix, NaiveUpdater
+ RustCoreUpdater downloaded binaries, ad-hoc signed them,
and accepted on next launch — defeating CodeSignVerifier
against a MITM on the GitHub asset URL. The real fix is the
release-SHA-256 manifest the updaters can pin against, which
`package_release.sh` already publishes for every release but
wasn't being consumed; the new AppUpdater consumes it.
NaiveUpdater + RustCoreUpdater retrofit deferred to v0.2.0.
Deliberately does NOT request admin escalation
(`/Applications` is admin-group writable on default installs),
does NOT auto-check on launch (Check is user-initiated only),
does NOT auto-update.

## [0.1.7.5] — 2026-05-03 (LTSC patch — chaos siege)

Ru#C4 wire ordering (was deferred): engine emitted
`Event::StateChanged { running: true }` from inside
`ProxySupervisor::spawn` BEFORE `start_proxy` returned
`Started { pid }`; the two flowed through different channels
(event_tx + event_bridge vs outbound_tx) and the event could
overtake the response. Same shape on the stop side via
`monitor_lifecycle`. Moved user-initiated transition events
into `handle_request`, emitted on the same outbound channel
AFTER the response writes; FIFO ordering guarantees
`response → state_changed event`. `monitor_lifecycle` retains
the natural-death event (no associated response to order
against). Wire shapes unchanged. Credential storage:
`MigratingCredentialStore.password` legacy-to-primary
promotion was two independent `try?` calls so a failed primary
write followed by successful legacy delete would lose the
password entirely. Now do/catch — legacy delete only runs if
primary write succeeded. `FileCredentialStore` NSLock
reentrancy footgun: empty-password branch in `setPassword`
called `deletePassword` which takes the lock again (NSLock
isn't reentrant; only worked because empty-check ran BEFORE
locking). Refactored to inline delete logic under the held
lock. Chaos suite extended 12 → 16: concurrent request burst
with random inter-recv delays; 100 start/stop cycles with
jitter; random-delay race start→stop (30 cycles); wire
ordering under burst (10 cycles). Inline xorshift64 PRNG, no
new dep. Runtime ~3s.

## Unreleased — chaos test infra (no binary change)

`core/tests/chaos.rs` — 12 deliberate-misbehaviour scenarios
asserting the invariants the v0.1.7.x audits identified or
fixed: oversized frame survival (`frame_too_large`); no-newline
flood (discard cap `16 × MAX_FRAME_BYTES` per Ru#H4); 1000
malformed-frame burst (sentinel valid request still answered);
concurrent `start_proxy` race (one `started` + one
`already_running`, no double-spawn per Ru#C2); stdin EOF
mid-frame; empty/whitespace lines silently skipped; invalid
UTF-8 → `malformed_request`; id correlation under interleaved
valid/invalid; `stop_proxy` when idle → `not_running`;
`stop_proxy` spam (20×); 100k pure-newline flood; `shutdown`
during in-flight requests (clean exit). Surfaced one known
design quirk (Ru#C4: engine emits `state_changed: true` BEFORE
`started` response) — deferred to where the wire contract
opens; fixed in v0.1.7.5.

## [0.1.7.4] — 2026-05-03 (LTSC patch)

Anomaly debouncer window tightened 100 ms → 50 ms. Halves
worst-case latency between naive emitting a real anomaly (e.g.
listening outside loopback) and the orchestrator's auto-stop
reaction; suppression goal unchanged (collapse flapping-naive
storm into one event per key per window). Audit inventoried
every coalescing/throttle/debounce site — only this one was
semantically a debouncer; the other timing sites
(`persistSettings` 250ms typing coalesce, LogConsole 100ms
animation, AppDelegate 5s terminate watchdog, Subprocess 250ms
TERM→INT→KILL spacing, CoreClient 120s request deadline) are
correctly scaled to their own concerns. Default-window
assertion in the Debouncer test suite retargeted.

## [0.1.7.3] — 2026-05-03 (LTSC patch)

Robustness audit pass: 103 findings, high-confidence
correctness/security fixes land. Swift correctness:
AppDelegate `applicationShouldTerminate` races shutdown
against a 5-second watchdog (pre-fix any signal-blocked
syscall or wedged `networksetup` parked the app in
"terminating…" forever with engine + system proxy alive).
`CoreClient.send` enforces a 120-second per-request deadline
via sibling timeout Task that resumes with `requestTimeout`.
`TunnelOrchestrator.stop()` early-returns when already stopped
(spam-clicking no longer iterates networksetup twice per
service). `clearLogs()` also clears `lastError`.
`listeningOutsideLoopback` auto-stop is single-flighted.
`ProfileStore.loadProfiles` deduplicates by id, drops empty-id
entries, trims whitespace (corrupted UserDefaults blob no
longer produces duplicate profiles where
`removeSelectedProfile` deletes every match in one keystroke).
New `Subprocess.run` helper drains stdout/stderr concurrently
with hard timeout escalation (terminate → interrupt → SIGKILL),
replacing three boot-path callers (FirewallProbe,
NaiveBinaryResolver, RustCoreResolver) that each suffered from
the classic pipe-fills-then-deadlocks bug if the subprocess
wrote >64 KB to stderr. Swift security: `RestrictedFile.write`
no longer chmods AFTER rename — the v0.1.5.5 promise of 0600
on `credentials.json` had a real race window
(`Data.write(.atomic)` writes a temp file with default umask
0644 then renames; if the process crashed or hit ENOSPC
between rename and chmod the file persisted at 0644). New flow
opens with `O_CREAT|O_EXCL|0600`, writes, fsyncs, renames
atomically. `NaiveUpdater` validates upstream tag against
`^v?\d+(\.\d+){0,3}(-[A-Za-z0-9.]+)?$` before URL
interpolation. Rust correctness: `ProxySupervisor::stop()`
passes `&mut handle` to `tokio::time::timeout` so on 2-second
drain expiry the handle can still be aborted (pre-fix moved
the handle into timeout, leaking the task indefinitely;
`Child` was never dropped so `kill_on_drop(true)` never fired
and a subsequent `start_proxy` could spawn a second naive).
`monitor_loop` exits when the supervised PID is gone via
`/bin/kill -0` each tick (pre-fix kept probing the stale PID
forever; on macOS PIDs roll over at 99,998 so a long session
could emit anomalies from someone else's lsof output — a
confused-deputy hazard). `monitor::run` (lsof probe) wrapped
in a 4-second Tokio timeout. `lsof` exit=1 with empty stderr
treated as "no matching open files" instead of
`MonitorError::NonZeroExit` (stops the spurious
`tracing::warn!` on every idle-proxy probe). `run_probe` (curl)
wrapped with `kill_on_drop(true)` + outer Tokio timeout
(`max_time + 5s`). `read_capped_line` enforces hard cap on
bytes discarded in oversized-frame resync mode
(`16 × MAX_FRAME_BYTES`). `client_mode::run` breaks out of
the read loop when an error-frame send fails.
`ProxySupervisor::read_lines` logs the IO error before
returning (was `Err(_)` swallow). Rust hygiene: `init_tracing`
uses `try_init`; dead `ANOMALY_DEBOUNCE` doc reference
cleaned; `MAX_INFLIGHT_REQUESTS` doc-vs-code mismatch fixed
(doc claimed "drop on burst" but code uses `acquire_owned().await`
queue); `axum::serve` body limit lowered from 2 MiB to 64 KiB
via `DefaultBodyLimit::max`. Deferred to v0.2.0: Sw#C4
release-SHA-manifest infra (until then existing CodeSignVerifier
catches arbitrary unsigned binaries but does NOT catch a MITM
on the GitHub asset URL); Sw#H2/H3 remaining subprocess callers;
Ru#H7 channel split for control-plane vs log traffic;
EngineSession enum-state; tower concurrency limit.

## [0.1.7.2] — 2026-05-03 (LTSC patch)

Module-design audit (113 findings, 58 Swift + 55 Rust); high-
confidence correctness fixes + quick wins land. Swift:
`TunnelOrchestrator.bootstrap()` no longer `fatalError`s when
Application Support cannot be created — falls back to a tmp
path and surfaces failure as `lastError` (boots into a
diagnosable state instead of crashing pre-UI).
`bootstrapIfNeeded()` flag is now set on engine-start SUCCESS
rather than entry, so a future Retry button can recover from
transient launch failures. `refreshNaiveDescriptor()` busy-wait
replaced with a shared Task continuation.
`AppDelegate.applicationWillTerminate`'s `DispatchSemaphore`
main-thread block (which deadlocked because MainActor IS the
main thread) replaced with the correct AppKit dance
(`applicationShouldTerminate → .terminateLater →
reply(toApplicationShouldTerminate:)`) — the engine now gets
a clean stop on Cmd+Q. `NaiveUpdater.assetURL` fatalError → typed
`UpdaterError.message`. ContentView `#Preview` `bootstrap()`
wrapped in `#if DEBUG` so it doesn't ship a second engine.
`persistSettings` now debounces 250 ms; `flushSettings` called
from shutdown. Rust correctness: `client_mode::start_proxy`
TOCTOU race fixed — engine mutex held across
`ProxySupervisor::spawn` (pre-fix two concurrent start requests
could both pass the "already running?" check and both spawn
naive, two real PIDs). `ProxySupervisor::stop()` bounds the
monitor-drain wait at 2 s. `ApiError` is now a
`BadRequest`/`Internal` enum with Debug derived (pre-fix
everything was 500 with no Debug for tracing). Rust hygiene:
`redaction.rs` regex statics switched from
`OnceLock<Option<Regex>>` (silently passthrough'd on compile
failure — credentials would have leaked) to `LazyLock<Regex>`
with `.expect(...)`. New `redaction_regexes_compile` test.
`EncodedCredentials` fields private with accessors; Debug
redacts the password; Drop clears strings eagerly (heap-byte
zeroing via `zeroize` deferred — project forbids unsafe).
`ANOMALY_DEBOUNCE` constant deleted (Debouncer::default is
canonical); `GLOBAL_TARGETS` and `SMART_TARGETS` consolidated
to one `LATENCY_TARGETS`; `LOOPBACK_HOST` moved to
`config/mod.rs`. `MAX_FRAME_BYTES` is now `pub`.
`client_mode::dispatch` wildcard arm rewritten with a typed
payload naming the unmapped `RequestKind` variant. Deferred:
Sw#10 god-object split, Sw#8/9 resolver+updater dedup, CoreClient
broken-pipe handling, Ru#C1 stdin drain, client_mode/server_mode
move to lib, wire/on-disk format changes.

## [0.1.7.1] — 2026-05-03 (LTSC patch)

UI/UX audit closes visible drift between v0.1.7 ship and the
v0.1.5.7 platinum-theme intent. Engine binary stays `0.1.7`
(cargo doesn't accept four-segment versions); .app
MARKETING_VERSION is `0.1.7.1`. Settings panel `.background`
flat Rectangle fixes a visible square corner during slide-in
animation. `CoolTunnelApp` window resize uses `.automatic`
(was `.contentSize` + `maxWidth: .infinity` letting users drag
to absurd dimensions). Connection-form labels
`.lineLimit(1) + .frame(minWidth: 130) + .fixedSize` so
localised labels ("Lokaler Anschluss") don't truncate. Settings
→ Direct Domains list scrolls in `.frame(maxHeight: 220)` so a
hundred-domain list doesn't push the binary sections offscreen.
Firewall badge `cherryRose.opacity(0.12)` (was Maltese-holdover
bunnyPink). Header card cornerRadius 10 → 8. Settings inner-card
radii unified at 6pt. Latency menu border swapped from `lilac`
to `borderInk` with `SoftButtonStyle` padding (12/7), disabled
"Local route" entry with tooltip. Profile picker
`minWidth 160 / maxWidth 320` + `.help(displayName)`. About
footer "Classic Mac theme · macOS 14+" (was stale macOS 12+ +
"Maltese theme"). Updater message rows gain `.help` +
`.textSelection(.enabled)`. Header title gradient second stop
`.primary` so it stays legible in dark. Control-panel Divider
swapped for explicit borderInk hairline. LogConsoleView
empty-state pulse + auto-scroll animation gated by
`PerformanceProfile`. SettingsView chip-detection icon and
About pawprint use `CTPalette.macBlue` instead of system
`.tint`. Direct-domain remove button: 22×22 hit target,
`.help`, accessibilityLabel.

## [0.1.7] — 2026-05-03 (**LTSC**)

First Long-Term Servicing Channel release. Public surface (UI
flows, CLI flags, engine protocol, on-disk paths) locked for
the lifetime of the v0.1.7 line per SUPPORT.md; only patch +
minor security fixes and upstream NaiveProxy updates land
in-line. New LTSC infrastructure: `rust-toolchain.toml` pins to
Rust 1.80.0; SUPPORT.md documents ≥18-month support window +
supported macOS/Rust/hardware matrix + breaking-change
definition; ci.yml runs cargo fmt + clippy + tests +
swift-format + shellcheck on every push/PR; dependabot opens
weekly PRs ignoring major bumps inside the LTSC line;
`core/deny.toml` configures cargo-deny with allow-list
licences, advisory-as-error, crates.io as the only trusted
source; `cool-tunnel-core --version` embeds build SHA + date
(first line stays `cool-tunnel-core <semver>` so the Swift
resolver still parses); security_check.sh gains a section 9
LTSC-posture audit. Plus a v0.1.6 hotfix round-3 fix:
SoftButtonStyle (Stop / Diag / Latency / Settings) gains
`.lineLimit(1) + .fixedSize(horizontal: true)` (matches
ModeChipStyle; "Settings" no longer wrapped to "Set-/tings").

## [0.1.6] — 2026-05-03 (stable)

First stable release. Includes everything from v0.1.5.x plus
in-line hotfixes: log-console / connection-form border alignment
to the v0.1.5.7 platinum theme; mode-chip text-wrap fix
(`.lineLimit(1) + .fixedSize`); direct mode switching with one
"switched from X to Y" log line; mode-aware card tints across
all four panes; bundled NaiveProxy bumped to v148.0.7778.96-2.
Engine subprocess crash now surfaces a clear error in the live
log; friendlier Naive/Rust Core update errors; first-run hint
banner on Connection Form when the profile is still the bundled
placeholder; VoiceOver labels on mode chips + Stop/Diag/Latency/Settings.
New CHANGELOG.md, SECURITY.md, CONTRIBUTING.md at the repo
root. README rewritten for beginners.

## [0.1.5.9] — 2026-05-03 (pre-release)

Swift + Rust API guidelines polish. Removed two production
force-unwrapped URLs in updaters. Replaced `#if DEBUG print()`
in `CoreClient` with `os.Logger`. Justified every
`@unchecked Sendable` with an explicit safety invariant. Doc
summaries on every public View. Cargo.toml C-METADATA fields.

## [0.1.5.8] — 2026-05-03 (pre-release)

Multi-window-on-reopen bug fixed by switching `WindowGroup`
to `Window(_:id:)` and moving engine shutdown out of
`.onDisappear`. Cmd+W returns to main from Settings; orderOut
on main. `cool-tunnel-core` gains `--mode server [--listen
ADDR]` with HTTP endpoints `/health`, `/version`,
`/naive/validate`, `/naive/config`, `/naive/pac`. Same Mach-O
serves both client (stdio) and server tiers.
`scripts/package_release.sh` emits a fourth asset
`cool-tunnel-core-vX.Y.Z-universal`. Audit fixes: engine-state
mutex no longer held across `ProxySupervisor::spawn`; anomaly
debouncer survives proxy restarts; every
Test/Update/Choose/Reset button has a synchronous re-entry
guard.

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
