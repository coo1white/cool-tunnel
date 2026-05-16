# Contributing to Cool Tunnel

The bar for changes: does this make the user's day better without making the codebase harder to reason about.

## Filing an issue

Use [GitHub Issues](https://github.com/coo1white/cool-tunnel/issues). Include:

- macOS version (`sw_vers`)
- Mac model (Apple → About This Mac → Chip + RAM)
- Cool Tunnel version (Settings → About at the bottom)
- What you expected vs. what happened
- Relevant lines from the **Live log** in the app

For security issues, **don't** open a public issue — use a private [GitHub Security Advisory][advisory]. See [SECURITY.md](./SECURITY.md).

[advisory]: https://github.com/coo1white/cool-tunnel/security/advisories/new

## Building from source

You'll need:

- Xcode 16+
- Rust via [rustup](https://rustup.rs/) with both Apple targets: `rustup target add aarch64-apple-darwin x86_64-apple-darwin`
- `shellcheck` (`brew install shellcheck`)
- `swift format` (ships with the Xcode toolchain)
- `cargo deny` (`cargo install cargo-deny`) — gates the dep tree against duplicate versions, advisories, and non-permissive licences per `core/deny.toml`
- [Bun](https://bun.sh) 1.1+ (`brew install bun`) — the two complex maintenance scripts (`scripts/cut_release.ts`, `scripts/fetch_naive.ts`) are TypeScript+Bun. Other scripts under `scripts/` stay POSIX shell. Legacy `scripts/cut_release.sh` and `scripts/fetch_naive.sh` are thin shims that exec `bun scripts/*.ts`.

Then:

```sh
git clone https://github.com/coo1white/cool-tunnel
cd cool-tunnel
bin/ct release 2.0.52   # one-command pipeline: verify pin, build, audit, package
```

Every `ct …` verb wraps a `scripts/*.sh` file. `bin/ct commands` lists everything; `bin/ct help <command>` shows usage. Underlying scripts (`scripts/preflight.sh`, `scripts/cut_release.sh`, etc.) still work directly — `bin/ct` is the discoverable surface, not a replacement.

## Running the test sweep

Before sending a pull request:

```sh
bin/ct doctor
```

Composite — runs preflight + audit --strict + the try? ratchet, one summary at the end. Exits 0 if every gate passed.

`bin/ct preflight` alone covers `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo deny check`, `xcrun swift-format lint --strict`, and `shellcheck scripts/*.sh` — every check `.github/workflows/ci.yml` runs, with the same flags.

To run checks manually:

```sh
# Rust
cd core
cargo fmt --all -- --check
cargo clippy --release --all-targets -- -D warnings
cargo test --release           # unit + protocol_roundtrip + chaos
cargo deny check               # advisories, dup versions, licences
cargo test --test chaos --release   # 12 scenarios: oversized frames, no-newline floods,
                                    # concurrent start_proxy races, malformed bursts,
                                    # stdin EOF mid-frame, etc. Add a new scenario
                                    # whenever you fix a robustness bug.

# Swift — invoke via xcrun so the toolchain binary is found
cd ..
xcrun swift-format lint --recursive --strict --configuration .swift-format COOL-TUNNEL

# Shell
shellcheck scripts/*.sh

# End-to-end audit (run once before tagging)
scripts/security_check.sh
```

Everything should be silent / pass. If `security_check.sh` fails on the `cool-tunnel-core` signature, rebuild Release first — Cargo's linker leaves a stub signature that the build script's `codesign --force --sign -` step replaces.

## Pull request guidelines

- **One concern per PR.**
- **Update CHANGELOG.md** in the same PR.
- **Don't introduce dependencies** lightly. Justify in the PR description.
- **Don't break the audit gates.** All six green CI jobs (Rust, Swift format lint, Swift xcodebuild test, ShellCheck, NaiveProxy pin verification, `try?` ratchet) are required.
- **Don't commit secrets.** `security_check.sh` will catch obvious patterns (AWS keys, GitHub PATs, the pinned historical leak), but be careful with anything new.

## CI gates and invariants

CI workflow at `.github/workflows/ci.yml` runs six jobs in parallel on every push and PR. A separate `naive-pin-audit.yml` workflow runs daily on schedule.

### `try?` ratchet — the "Zero `try?`" rule

`try?` silently discards the underlying error. In a credential store or persistence path that's data loss the operator never sees; H2 and H3 in the 2026-05-11 robustness review were both this exact bug class.

Every `try?` in the Swift production tree (`COOL-TUNNEL/`) must be either:

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

   Annotation goes on the same line as the `try?` token, OR on the immediately preceding line (when the inline form would exceed the 110-column `EndOfLineComment` lint rule).

Legitimate cleanup is roughly: closing a `FileHandle` whose error doesn't matter, `defer { try? FileManager.…removeItem(at: tempRoot) }`, sleep cancellation (`try? await Task.sleep(...)`), best-effort proxy revert on shutdown, defensive resource-value lookups whose `nil` flows to a sane default. Anything that swallows a *real* error — disk full, decode failure, keychain lock, credential write rejection — is not cleanup.

`scripts/try_question_ratchet.sh` enforces this in CI. It counts unannotated `\btry\?` occurrences and fails on any drift from the committed `TRY_QUESTION_CAP` (currently 0). Drift in either direction fails — converting a site lowers the count, so the same commit must update the cap. `bash scripts/try_question_ratchet.sh --list` prints every unannotated site.

### `xcodebuild test` — H2/H3/M1 regression coverage

`COOL-TUNNELTests/` is the XCTest target. Currently 16 tests across `ProfileStoreTests` + `MigratingCredentialStoreTests`:

- **H2**: credential-store write failure must NOT strip the password from `UserDefaults` (both on load-time migration and on save).
- **H3**: credential-store read failure must propagate via the `ProfileStore.password(forProfileID:) throws` API, NOT collapse to `""`.
- **M1**: best-effort cleanup paths (`legacy.deletePassword` after successful primary write) must log and continue, never bubble.

When you change `ProfileStore`, `MigratingCredentialStore`, `KeychainStore`, or `FileCredentialStore`:

```sh
xcodebuild test \
    -project COOL-TUNNEL.xcodeproj \
    -scheme COOL-TUNNEL \
    -destination 'platform=macOS' \
    CODE_SIGNING_ALLOWED=NO
```

`CODE_SIGNING_ALLOWED=NO` is required on systems without an Apple Developer ID identity — the ad-hoc-signed test host otherwise crashes during bootstrap with a misleading "Early unexpected exit" error.

When you add a new credential / persistence regression test: drop the `*.swift` file into `COOL-TUNNELTests/`. That's the entire step. Both targets use Xcode 16's `fileSystemSynchronizedGroups`, so any new file under the target directory is auto-picked-up by the next `xcodebuild` run.

### NaiveProxy pin verification — the supply-chain anchor

`COOL-TUNNEL/naive.upstream.json` is the authoritative pin for the bundled `naive` binary. Records the upstream tag this repo claims to ship and the SHA-256 of every artifact. `scripts/fetch_naive.sh` modes:

- (default, no flag) — verify the bundled binary's SHA matches the manifest. No network. Run by `cut_release.sh` and the PR-time `naive-pin` CI job.
- `--check-only` — re-download at the pinned tag, verify every SHA still reproduces. Run daily by `naive-pin-audit.yml`.
- `--repin [TAG]` — operator-explicit rollover. Requires `CT_REPIN_CONFIRM=1`. Lands as a single audited commit.

Never let `cut_release.sh` "auto-pin" again — that path was the H1 supply-chain finding.

### Other gates

- **Rust** — `cargo fmt --check`, `cargo clippy --pedantic -D warnings`, `cargo test`, `cargo deny check`. On push (not PR) also builds the universal `cool-tunnel-core` binary.
- **Swift format lint** — `xcrun swift-format lint -r --strict` on both `COOL-TUNNEL/` and `COOL-TUNNELTests/`.
- **ShellCheck** — every `*.sh` in `scripts/`.

## Code style

Mostly enforced by the formatters and linters above:

- **Rust**: `rustfmt` defaults; clippy `--pedantic` with `unwrap_used` / `expect_used` / `panic` / `todo` / `unimplemented` denied in production code; tests can opt out via `#[allow(...)]`.
- **Swift**: `.swift-format` config sets 4-space indent + 110-column wrap; every public type gets a one-line doc summary.
- **Shell**: bash with `set -Eeuo pipefail`; quote every variable expansion; prefer `[[ ]]` over `[ ]`.

## Architecture notes

Three concerns. Edits stay within the relevant column:

| | UI | Glue (cross-platform) | Proxy |
| --- | --- | --- | --- |
| **Server** | Filament (PHP) — TODO | RUST (`cool-tunnel-core --mode server`) | Naïve Proxy |
| **macOS today** | SwiftUI (`COOL-TUNNEL/`) | RUST (`cool-tunnel-core` in `core/`) | bundled `naive` Mach-O |
| **Future Win/Linux/iOS/Android** | Kotlin / Swift / C++ / GTK | RUST (same `core/` crate) | platform-built `naive` |

If your change touches more than one column, note it in the PR description.

## Code of conduct

Be kind. We're all volunteers.
