# Changelog

All notable changes to Cool Tunnel land here. Versions follow
roughly-semver: bumps in the third digit are features; bumps in
the fourth digit are pre-release polish on the same line.

The pre-release `v0.1.5.x` series soaked from May 2 to May 3, 2026.
**v0.1.6** is the first stable release; **v0.1.7** is the first
release on the Long-Term Servicing Channel line — see
[SUPPORT.md](./SUPPORT.md) for the support contract.

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
