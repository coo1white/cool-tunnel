# ADR 0001 — Audit Rules Locked (2026-05-05)

**Status:** Accepted · In Force on `main`
**Closing PRs:** [#9](https://github.com/coo1white/cool-tunnel/pull/9), [#10](https://github.com/coo1white/cool-tunnel/pull/10), [#11](https://github.com/coo1white/cool-tunnel/pull/11)

## Context

Pre-audit posture: code health was good (`#![forbid(unsafe_code)]`, regex `.expect()` wrapped in `LazyLock`, shell scripts had `set -Eeuo pipefail`, IPC contract had `protocol_roundtrip` integration tests) but CI was advisory rather than gating. Branch protection required PR review (1 approval) but did **not** require status checks. Result: silent drift — rustfmt deltas across 4 files, ShellCheck SC2012, ~40 swift-format violations, and a no-op Swift CI job (bare `swift-format` exited 127 because the binary isn't on the runner's default PATH). The audit identified 8 findings.

## Decision

### Code (`main` after three audit PRs squash-merged)

| Finding | Resolution |
|---|---|
| **F1-1** rustfmt drift | `cargo fmt --all` absorbed 6 deltas |
| **F2-1** ShellCheck SC2012 in `cut_release.sh:92` | `# shellcheck disable=SC2012` with justification (Xcode DerivedData paths, BSD `find` lacks `-printf`) |
| **F3-1** `cargo-deny` not in contributor prereqs | `CONTRIBUTING.md` lists `cargo install cargo-deny` |
| **F4-1** `fetch_naive.sh` rewriting `naive.upstream.json` on no-op | SHA-comparison guard preserves `fetched_at` when SHAs unchanged |
| **F8a** Swift CI exited 127 | Invoke via `xcrun swift-format` |
| **F8b** ~40 swift-format violations | `xcrun swift-format format -i` for 13 files + 9 manual `catch let X.Y(z)` → `catch X.Y(let z)` for `UseLetInEveryBoundCaseVariable` |

### Repository settings

- **F5-1** Required status checks **enabled** with `strict: true`. Required: `Rust (build + clippy + test)`, `ShellCheck`, `Swift (format lint)`.
- **F6-1** Repo topics set: `proxy`, `naive`, `naiveproxy`, `tunnel`, `macos`, `swiftui`, `rust`, `censorship`.
- **F7-1** Signed commits — **deferred** pending maintainer signing setup.

### Locked branch-protection on `main`

```json
{
  "required_status_checks": { "strict": true,
    "contexts": ["Rust (build + clippy + test)", "ShellCheck", "Swift (format lint)"] },
  "required_pull_request_reviews": { "required_approving_review_count": 1 },
  "required_signatures": { "enabled": false },
  "enforce_admins": { "enabled": false },
  "allow_force_pushes": { "enabled": false },
  "allow_deletions": { "enabled": false },
  "required_conversation_resolution": { "enabled": true }
}
```

`enforce_admins: false` is intentional — preserves the admin-override path that broke this audit's CI interleave (PRs #9 and #11 had circular CI dependencies); the gate still protects future contributions.

## Consequences

Contributors must: (1) all three CI contexts must `success` on the PR head; (2) PR branches must be up to date with `main` (`strict: true`); (3) one approving review; (4) local lint floor matches CI — run `cargo fmt --check`, `cargo clippy -- -D warnings`, `cargo test`, `cargo deny check`, `xcrun swift-format lint -r --strict`, `shellcheck scripts/*.sh` before pushing.

Admin `--admin`-merge is acceptable for CI-interleave deadlocks, emergency hotfix, or initial gate bootstrap. Not acceptable for routine merges or bypassing red CI.

Open work: F7-1 (signed commits) — once maintainer signing is configured locally, run `gh api -X PATCH repos/coo1white/cool-tunnel/branches/main/protection -f 'required_signatures=true'`.
