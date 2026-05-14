# Contributing to Cool Tunnel

Thanks for considering a contribution. Cool Tunnel is small and
opinionated; the bar for changes is "does this make the user's
day better without making the codebase harder to reason about".

## Filing an issue

Use [GitHub Issues](https://github.com/coo1white/cool-tunnel/issues).
Please include:

- macOS version (`sw_vers`)
- Mac model (Apple → About This Mac → Chip + RAM)
- Cool Tunnel version (Settings → About at the bottom)
- What you expected to happen
- What actually happened
- The relevant lines from the **Live log** in the app

For security issues, **don't** open a public issue. Use a private
[GitHub Security Advisory][advisory] — see [SECURITY.md](./SECURITY.md).

[advisory]: https://github.com/coo1white/cool-tunnel/security/advisories/new

## Building from source

You'll need:

- Xcode 16+
- Rust via [rustup](https://rustup.rs/) with both Apple targets:
  ```sh
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  ```
- `shellcheck` (`brew install shellcheck`)
- `swift format` (ships with the Xcode toolchain)
- `cargo deny` (`cargo install cargo-deny`) — gates the dep tree
  against duplicate versions, advisories, and non-permissive
  licences per `core/deny.toml`. CI enforces it; running it
  locally avoids the round-trip when a new crate or feature flag
  trips a rule.

Then:

```sh
git clone https://github.com/coo1white/cool-tunnel
cd cool-tunnel

# One-command release pipeline (verify pin, build, audit, package).
# Substitute the next version; pre-flight rejects a mismatched value.
bin/ct release 2.0.52
```

If you'd rather drive each step manually, every `ct …` verb wraps
a `scripts/*.sh` file. Discover them with:

```sh
bin/ct commands         # full list
bin/ct help <command>   # full usage for one verb
```

The underlying scripts (`scripts/preflight.sh`, `scripts/cut_release.sh`,
etc.) still work directly — `bin/ct` is the discoverable surface,
not a replacement.

## Running the test sweep

Before sending a pull request:

```sh
bin/ct doctor
```

That's the composite — runs preflight + audit --strict + the try?
ratchet, with one summary at the end. Exits 0 if every gate passed,
1 with a failure list otherwise.

The individual verbs are also available (`bin/ct preflight`,
`bin/ct audit --strict`, `bin/ct ratchet`). `bin/ct preflight` alone
covers `cargo fmt --check`, `cargo clippy -- -D warnings`,
`cargo test`, `cargo deny check`, `xcrun swift-format lint --strict`,
and `shellcheck scripts/*.sh` — every check `.github/workflows/ci.yml`
runs, with the same flags.

If you prefer to run the checks manually (or to debug a single one),
the underlying commands are:

```sh
# Rust
cd core
cargo fmt --all -- --check
cargo clippy --release --all-targets -- -D warnings
cargo test --release           # unit + protocol_roundtrip + chaos
cargo deny check               # advisories, dup versions, licences

# Chaos suite alone (12 scenarios — oversized frames, no-newline
# floods, concurrent start_proxy races, malformed bursts, stdin
# EOF mid-frame, etc.). Verifies the engine survives the failure
# modes the v0.1.7.x audits identified or fixed. Add a new
# scenario here whenever you fix a robustness bug, so the
# regression can't re-ship silently.
cargo test --test chaos --release

# Swift — invoke via `xcrun` so the toolchain binary is found
# regardless of $PATH state. Bare `swift-format` exits 127 on the
# CI runner; F8a in 2026-05-05's audit absorbed the same lesson.
cd ..
xcrun swift-format lint --recursive --strict --configuration .swift-format COOL-TUNNEL

# Shell
shellcheck scripts/*.sh

# End-to-end audit (run once before tagging)
scripts/security_check.sh
```

Everything should be silent / pass. If the security check fails on
the `cool-tunnel-core` signature, rebuild Release first — Cargo's
linker leaves a stub signature that the build script's
`codesign --force --sign -` step replaces with a proper ad-hoc one.

## Pull request guidelines

- **One concern per PR.** Easier to review, easier to revert if
  something turns out badly.
- **Update CHANGELOG.md** in the same PR — drop a new entry under
  the next version heading.
- **Don't introduce dependencies** lightly. Every new crate or
  Swift package adds binary size and surface area. Justify in the
  PR description.
- **Don't break the audit gates.** All six green CI jobs
  (Rust, Swift format lint, Swift xcodebuild test, ShellCheck,
  NaiveProxy pin verification, `try?` ratchet) are required. See
  "CI gates and invariants" below for what each enforces and why.
- **Don't commit secrets.** The `security_check.sh` secret scan
  will catch obvious patterns (AWS keys, GitHub PATs, the pinned
  historical leak), but be careful with anything new.

## CI gates and invariants

The CI workflow at `.github/workflows/ci.yml` runs six jobs in
parallel on every push and pull request. A separate
`naive-pin-audit.yml` workflow runs daily on a schedule. Each gate
exists because some past PR broke the invariant it now enforces.

### `try?` ratchet — the "Zero `try?`" rule

`try?` silently discards the underlying error. In a credential
store or persistence path that's data loss the operator never
sees; H2 and H3 in the 2026-05-11 robustness review were both
this exact bug class.

**Every `try?` in the Swift production tree (`COOL-TUNNEL/`) must
be either:**

1. **Converted** to logging `do/catch`:

   ```swift
   do {
       try credentials.deletePassword(forProfileID: id)
   } catch {
       Logger.cooltunnel("ProfileStore").warning(
           "credential delete failed for \(id, privacy: .public): "
           + "\(error.localizedDescription, privacy: .public)"
       )
   }
   ```

2. **Annotated** as legitimate cleanup with a one-line rationale:

   ```swift
   try? handle.close()  // try-ok: handle teardown on terminate
   ```

   The annotation goes on the same line as the `try?` token, OR
   on the immediately preceding line (used when the inline form
   would exceed the 110-column `EndOfLineComment` lint rule).

Legitimate cleanup is roughly: closing a `FileHandle` whose
error doesn't matter, `defer { try? FileManager.…removeItem(at:
tempRoot) }`, sleep cancellation (`try? await Task.sleep(...)`),
best-effort proxy revert on shutdown, defensive resource-value
lookups whose `nil` flows to a sane default. Anything that
swallows a *real* error — disk full, decode failure, keychain
lock, credential write rejection — is not cleanup and must be
converted.

`scripts/try_question_ratchet.sh` enforces this in CI. It counts
unannotated `\btry\?` occurrences and fails on any drift from
the committed `TRY_QUESTION_CAP` (currently 0). Drift in either
direction fails — converting a site lowers the count, so the
same commit must update the cap. `bash scripts/try_question_ratchet.sh
--list` prints every unannotated site for "what's left" review.

### `xcodebuild test` — H2/H3/M1 regression coverage

`COOL-TUNNELTests/` is the XCTest target. Currently 16 tests
across `ProfileStoreTests` + `MigratingCredentialStoreTests`,
each pinning a specific failure mode from the robustness review:

- H2: credential-store write failure must NOT strip the password
  from `UserDefaults` (both on load-time migration and on save).
- H3: credential-store read failure must propagate via the
  `ProfileStore.password(forProfileID:) throws` API, NOT
  collapse to `""`.
- M1: best-effort cleanup paths (`legacy.deletePassword` after
  successful primary write) must log and continue, never bubble.

When you change `ProfileStore`, `MigratingCredentialStore`,
`KeychainStore`, or `FileCredentialStore`, run the suite
locally first:

```sh
xcodebuild test \
    -project COOL-TUNNEL.xcodeproj \
    -scheme COOL-TUNNEL \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO
```

`CODE_SIGNING_ALLOWED=NO` is required on systems without an
Apple Developer ID identity — the ad-hoc-signed test host
otherwise crashes during bootstrap with a misleading "Early
unexpected exit" error.

When you add a new credential / persistence regression test:

1. Drop the `*.swift` file into `COOL-TUNNELTests/`.

That's the entire step. Both targets (`COOL-TUNNEL` and
`COOL-TUNNELTests`) use Xcode 16's `fileSystemSynchronizedGroups`,
so any new file under the target directory is auto-picked-up by
the next `xcodebuild` run — no project-file edit, no script,
no Ruby toolchain.

### NaiveProxy pin verification — the supply-chain anchor

`COOL-TUNNEL/naive.upstream.json` is the authoritative pin for
the bundled `naive` binary. It records the upstream tag this
repo claims to ship and the SHA-256 of every artifact in the
build chain. `scripts/fetch_naive.sh` has three modes:

- (default, no flag) — verify the bundled binary's SHA matches
  the manifest. No network. Run by `cut_release.sh` and the
  PR-time `naive-pin` CI job.
- `--check-only` — re-download at the pinned tag, verify every
  SHA still reproduces. Run daily by `naive-pin-audit.yml`.
- `--repin [TAG]` — operator-explicit rollover. Requires
  `CT_REPIN_CONFIRM=1`. Lands as a single audited commit.

Never let `cut_release.sh` "auto-pin" again — that path was the
H1 supply-chain finding from the robustness review.

### Other gates

- **Rust** — `cargo fmt --check`, `cargo clippy --pedantic
  -D warnings`, `cargo test`, `cargo deny check`. On push (not
  PR) also builds the universal `cool-tunnel-core` binary.
- **Swift format lint** — `xcrun swift-format lint -r --strict`
  on both `COOL-TUNNEL/` and `COOL-TUNNELTests/`.
- **ShellCheck** — every `*.sh` in `scripts/`.

## Code style

Mostly already enforced by the formatters and linters above:

- **Rust**: `rustfmt` defaults; clippy `--pedantic` is on with
  `unwrap_used` / `expect_used` / `panic` / `todo` /
  `unimplemented` denied in production code; tests can opt out
  via `#[allow(...)]`.
- **Swift**: `.swift-format` config in the repo root sets 4-space
  indent + 110-column wrap; `AllPublicDeclarationsHaveDocumentation`
  is off but every public type still gets a one-line doc summary.
- **Shell**: bash with `set -Eeuo pipefail` at the top; quote
  every variable expansion; prefer `[[ ]]` over `[ ]`.

## Architecture notes

The project is split into three concerns. Edits stay within the
relevant column:

| | UI | Glue (cross-platform) | Proxy |
| --- | --- | --- | --- |
| **Server** | Filament (PHP) — TODO | RUST (`cool-tunnel-core --mode server`) | Naïve Proxy |
| **macOS today** | SwiftUI (`COOL-TUNNEL/`) | RUST (`cool-tunnel-core` in `core/`) | bundled `naive` Mach-O |
| **Future Win/Linux/iOS/Android** | Kotlin / Swift / C++ / GTK | RUST (same `core/` crate) | platform-built `naive` |

If your change touches more than one column, that's fine — but
note it in the PR description so reviewers know to look both
sides.

## Code of conduct

Be kind. We're all volunteers.
