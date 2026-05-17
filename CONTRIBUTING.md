# Contributing to Cool Tunnel

The bar for changes: does this make the user's day better without making the codebase harder to reason about.

## Filing an issue

[GitHub Issues](https://github.com/coo1white/cool-tunnel/issues). Include macOS version (`sw_vers`), Mac model, Cool Tunnel version (Settings → About), expected vs. actual, and relevant Live-log lines.

Security issues: **don't** open a public issue — use a private [GitHub Security Advisory][advisory]. See [SECURITY.md](./SECURITY.md).

[advisory]: https://github.com/coo1white/cool-tunnel/security/advisories/new

## Building from source

Prereqs: Xcode 16+, Rust via [rustup](https://rustup.rs/) (`rustup target add aarch64-apple-darwin x86_64-apple-darwin`), `shellcheck` (`brew install shellcheck`), `cargo deny` (`cargo install cargo-deny`), `swift-format` (Xcode toolchain), [Bun](https://bun.sh) 1.1+ (`brew install bun`).

```sh
git clone https://github.com/coo1white/cool-tunnel
cd cool-tunnel
bin/ct release 2.0.55   # one-command pipeline: verify pin, build, audit, package
```

`bin/ct commands` lists every verb; `bin/ct help <command>` shows usage. The verbs wrap `scripts/*.sh` files — direct invocation still works.

## Running the test sweep

```sh
bin/ct doctor   # preflight + audit --strict + try? ratchet, one summary
```

`bin/ct preflight` alone covers `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo deny check`, `xcrun swift-format lint --strict`, and `shellcheck scripts/*.sh` — every check `.github/workflows/ci.yml` runs, with the same flags.

## Pull request guidelines

- **One concern per PR.**
- **Update CHANGELOG.md** in the same PR.
- **Don't introduce dependencies** lightly. Justify in the PR description.
- **Don't break the audit gates.** All seven CI jobs must be green.
- **Don't commit secrets.** `security_check.sh` catches obvious patterns; be careful with anything new.

## CI gates

### `try?` ratchet

`try?` silently discards the underlying error — data loss the operator never sees. Every `try?` in `COOL-TUNNEL/` must be either converted to logging `do/catch` OR annotated `// try-ok: <reason>` on the same or immediately preceding line. Legitimate cleanup (closing a `FileHandle` whose error doesn't matter, sleep cancellation, best-effort proxy revert on shutdown) qualifies; swallowing a real error (disk full, decode failure, keychain lock) does not.

`scripts/try_question_ratchet.sh` counts unannotated `\btry\?` and fails on any drift from `TRY_QUESTION_CAP` (currently 0). Drift in either direction fails. `bash scripts/try_question_ratchet.sh --list` prints every unannotated site.

### `xcodebuild test` — H2/H3/M1 regression coverage

`COOL-TUNNELTests/` covers: credential-store write failure must NOT strip the password from `UserDefaults` (H2); read failure must propagate via `ProfileStore.password(forProfileID:) throws`, never collapse to `""` (H3); best-effort cleanup must log and continue, never bubble (M1).

When you change `ProfileStore` / `MigratingCredentialStore` / `KeychainStore` / `FileCredentialStore`, run `xcodebuild test -project COOL-TUNNEL.xcodeproj -scheme COOL-TUNNEL -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO`. (The flag is required on systems without an Apple Developer ID — ad-hoc-signed test hosts otherwise crash during bootstrap with a misleading "Early unexpected exit".)

`fileSystemSynchronizedGroups` auto-picks-up any new `*.swift` under `COOL-TUNNELTests/` — no project-file edit needed.

### sing-box pin verification

`COOL-TUNNEL/singbox-core.upstream.json` is authoritative for the bundled `sing-box` binary (upstream tag + per-artifact SHA-256). `scripts/fetch_singbox-core.sh` modes: default verifies the bundled binary's SHA matches the manifest (no network, runs in `cut_release.sh` + PR-time `singbox-core-pin` job); `--check-only` re-downloads at the pinned tag and verifies SHAs (daily `singbox-core-pin-audit.yml`); `--repin [TAG]` is operator-explicit, requires `CT_REPIN_CONFIRM=1`, lands as a single audited commit.

Never let `cut_release.sh` "auto-pin" — that path was the H1 supply-chain finding.

### Other gates

`cargo fmt --check`, `cargo clippy --pedantic -D warnings`, `cargo test`, `cargo deny check`; `xcrun swift-format lint -r --strict` on `COOL-TUNNEL/` + `COOL-TUNNELTests/`; `shellcheck` on every `scripts/*.sh`; Bun argv-parser tests for `cut_release.ts` / `fetch_singbox-core.ts`.
