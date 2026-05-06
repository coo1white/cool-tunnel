# ADR 0001 — Audit Rules Locked (2026-05-05)

**Status:** Accepted · In Force on `main`
**Date:** 2026-05-05
**Audit reference:** [`docs/audits/code/2026-05-05T164718Z.md`](../audits/code/2026-05-05T164718Z.md)
**Closing PRs:** [#9](https://github.com/coo1white/cool-tunnel/pull/9), [#10](https://github.com/coo1white/cool-tunnel/pull/10), [#11](https://github.com/coo1white/cool-tunnel/pull/11)

## Context

Prior to this audit, the repository's posture was:

- **Code health: excellent.** `#![forbid(unsafe_code)]` enforced; regex `.expect()` callsites all wrapped in `LazyLock` + `#[allow(clippy::expect_used)]` with explanatory comments; all five shell scripts opened with `set -Eeuo pipefail`; the IPC contract between the Rust core and Swift client documented as a single source of truth with a `protocol_roundtrip` integration test verifying lockstep.
- **CI: comprehensive but not load-bearing.** The workflow at [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml) ran `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo deny check`, `swift-format lint --strict`, `shellcheck`, plus universal-target release builds. Branch protection on `main` required PR review (1 approval) but did **not** require status checks to pass before merge.
- **Result: silent drift.** With CI advisory rather than gating, three drift classes accumulated invisibly: rustfmt deltas across four Rust files, ShellCheck SC2012 in `cut_release.sh`, ~40 swift-format violations across 13 Swift files, and a no-op-since-landing Swift CI job (the bare `swift-format` invocation was exiting 127 because Xcode's toolchain bin isn't on the runner's default PATH). All three were red on `main` at audit time.

The audit identified **8 findings** and grouped them into ship-batches. Execution surfaced **F8a/F8b** (CI-infra + Swift drift) that were not visible during read-only Phase 1 because `swift-format` wasn't installed locally on the audit machine.

## Decision

### What landed in code (`main` after the three audit PRs squash-merged)

| Finding | Severity | Resolution | Commit |
|---|---|---|---|
| **F1-1** rustfmt drift | Low | `cargo fmt --all` absorbed 6 deltas across `redaction.rs`, `client_mode.rs`, `main.rs`, `tests/chaos.rs` | [`bfac7d0`](https://github.com/coo1white/cool-tunnel/commit/bfac7d0) |
| **F2-1** ShellCheck SC2012 in `cut_release.sh:92` | Low | `# shellcheck disable=SC2012` annotation with five-line justification (Xcode DerivedData paths are constrained, BSD `find` lacks `-printf`) | [`625490f`](https://github.com/coo1white/cool-tunnel/commit/625490f) |
| **F3-1** `cargo-deny` not surfaced as a contributor prereq | Medium | `CONTRIBUTING.md` now lists `cargo install cargo-deny` as a build prerequisite and includes `cargo deny check` in the test-sweep section | [`bfac7d0`](https://github.com/coo1white/cool-tunnel/commit/bfac7d0) |
| **F4-1** `fetch_naive.sh` rewrites `naive.upstream.json` even when SHAs unchanged | Low | SHA-comparison guard: rewrite only when one of the three SHA-256 fields actually changed, preserving `fetched_at` otherwise | [`625490f`](https://github.com/coo1white/cool-tunnel/commit/625490f) |
| **F8a** Swift CI exited 127 because bare `swift-format` not on runner PATH | Low | Invoke via `xcrun swift-format` — canonical macOS shim that resolves binaries against the active toolchain | [`bfac7d0`](https://github.com/coo1white/cool-tunnel/commit/bfac7d0) |
| **F8b** ~40 swift-format violations + 9 lint-only `UseLetInEveryBoundCaseVariable` warnings | Low (high count) | `xcrun swift-format format -i` for the mechanical class (13 files), plus 9 manual `catch let X.Y(z)` → `catch X.Y(let z)` rewrites for the lint-only rule | [`08a72e6`](https://github.com/coo1white/cool-tunnel/commit/08a72e6) |

### What landed in repository settings

| Finding | Severity | Decision | Mechanism |
|---|---|---|---|
| **F5-1** Required status checks not enabled | **High** | **Enabled**, with `strict: true` (PR branch must be up to date with `main` to merge). Required contexts: `Rust (build + clippy + test)`, `ShellCheck`, `Swift (format lint)`. | `gh api -X PUT repos/coo1white/cool-tunnel/branches/main/protection` |
| **F6-1** Repo topics empty | Low | Topics set: `proxy`, `naive`, `naiveproxy`, `tunnel`, `macos`, `swiftui`, `rust`, `censorship` | `gh api -X PUT repos/coo1white/cool-tunnel/topics` |
| **F7-1** Signed commits not required | Medium | **Deferred.** Local environment lacks `gpg` and `commit.gpgsign` config — enabling `required_signatures` would block the maintainer's next push to `main`. Re-evaluate after maintainer signing setup. | n/a |

### Final branch-protection state on `main`

```json
{
  "required_status_checks": {
    "strict": true,
    "contexts": [
      "Rust (build + clippy + test)",
      "ShellCheck",
      "Swift (format lint)"
    ]
  },
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "dismiss_stale_reviews": false,
    "require_last_push_approval": false
  },
  "required_signatures": { "enabled": false },
  "enforce_admins": { "enabled": false },
  "allow_force_pushes": { "enabled": false },
  "allow_deletions": { "enabled": false },
  "required_conversation_resolution": { "enabled": true }
}
```

`enforce_admins: false` is intentional — it preserves the admin-override path that broke this audit's CI interleave (PRs #9 and #11 had circular CI dependencies until the gate was active; admin merge cleared the deadlock without compromising the gate's protection of *future* contributions).

## Consequences

### What contributors must now do

1. **CI must pass before merge.** All three contexts (`Rust (build + clippy + test)`, `ShellCheck`, `Swift (format lint)`) must report `success` on the PR's head commit.
2. **PR branches must be up to date with `main`.** `strict: true` rejects merges where the PR has not absorbed recent `main` commits. Use the GitHub UI's "Update branch" button or `gh pr update-branch <#>`.
3. **PR review required.** One approving review per PR. Self-approval is rejected by GitHub.
4. **Local lint floor matches CI.** Run before pushing:
   ```sh
   cd core
   cargo fmt --all -- --check
   cargo clippy --release --all-targets -- -D warnings
   cargo test --release
   cargo deny check
   cd ..
   xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL
   shellcheck scripts/*.sh
   ```
   If any fail locally, expect CI to fail. The CI runner uses Apple's swift-format toolchain, which ships with rules not present in older swift-format versions (`UseLetInEveryBoundCaseVariable` is a known case as of 2026-05-05); when in doubt, format with `xcrun swift-format` exclusively.

### What admins (current sole maintainer) can do

`enforce_admins: false` means admins can `--admin`-merge. Use sparingly. Acceptable cases:
- Breaking a CI interleave between two stacked-but-cyclically-blocked PRs (this audit used it once on PR #10).
- Emergency hotfix where waiting for the next CI cycle would extend a P0 incident.
- Initial bootstrap of a new gate where existing PRs predate the gate.

Not acceptable cases:
- Routine "I read it and it looks fine" merges. Get the review.
- Bypassing red CI to ship a fix faster. The fix isn't shipped if it doesn't survive the gate.

### Open work

- **F7-1 (signed commits)** — depends on maintainer adopting commit signing (gpg / SSH-signing / Sigstore). Once `git commit.gpgsign` is configured locally and recent commits show `sig=G`, run:
  ```sh
  gh api -X PATCH repos/coo1white/cool-tunnel/branches/main/protection \
    -f 'required_signatures=true'
  ```
  This is the last gate to lock for the LTSC posture described in [`SECURITY.md`](../../SECURITY.md).
- **Audit prompt suite alignment** — the polyglot audit prompt (a sister document at `~/Documents/Alice/Code Audit Prompt - Rust+PHP Polyglot.md`) assumed a Rust + PHP/Laravel polyglot. This project is Rust + Swift. Future audits should use a polyglot-Rust+Swift variant or the macOS UI sibling for the Swift surface, not the PHP-targeted prompt.

## Verification

- `git log --oneline origin/main` shows the three audit PRs squash-merged: `08a72e6` (F8b) → `bfac7d0` (F1-1, F3-1, F8a) → `625490f` (F2-1, F4-1) → `6ac2324` (prior tip).
- `gh api repos/coo1white/cool-tunnel/branches/main/protection/required_status_checks --jq '{strict, contexts}'` returns the locked-in shape above.
- `gh api repos/coo1white/cool-tunnel --jq '.topics'` returns the eight topics.
- `cargo test` 130/130 pass (104 + 18 chaos + 6 protocol_roundtrip + 2 doc-tests). All other lints clean.

## References

- Audit report (uncommitted, kept locally): [`docs/audits/code/2026-05-05T164718Z.md`](../audits/code/2026-05-05T164718Z.md)
- Prior UI audit (uncommitted): [`docs/audits/ui/2026-05-04T144534Z.md`](../audits/ui/2026-05-04T144534Z.md)
- Closing PRs: [#9](https://github.com/coo1white/cool-tunnel/pull/9), [#10](https://github.com/coo1white/cool-tunnel/pull/10), [#11](https://github.com/coo1white/cool-tunnel/pull/11)
- Audit prompt suite (external): `~/Documents/Alice/` — `Code Audit Prompt - Rust+PHP Polyglot.md`, `Release Check Gates.md`, `Deploy Gate Prompt.md`
