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

Then:

```sh
git clone https://github.com/coo1white/cool-tunnel
cd cool-tunnel

# Pull the upstream NaiveProxy binary into COOL-TUNNEL/naive (universal)
scripts/fetch_naive.sh

# Build the .app
xcodebuild -scheme COOL-TUNNEL -configuration Release \
    -derivedDataPath build/DerivedData \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    clean build

# Run the pre-package security audit
EXPECTED_VERSION=0.1.7 scripts/security_check.sh

# Package .dmg + .pkg + .zip + standalone cool-tunnel-core
scripts/package_release.sh 0.1.7
```

## Running the test sweep

Before sending a pull request, run:

```sh
# Rust
cd core
cargo fmt --all -- --check
cargo clippy --release --all-targets -- -D warnings
cargo test --release           # unit + protocol_roundtrip + chaos

# Chaos suite alone (12 scenarios — oversized frames, no-newline
# floods, concurrent start_proxy races, malformed bursts, stdin
# EOF mid-frame, etc.). Verifies the engine survives the failure
# modes the v0.1.7.x audits identified or fixed. Add a new
# scenario here whenever you fix a robustness bug, so the
# regression can't re-ship silently.
cargo test --test chaos --release

# Swift
cd ..
swift format lint --recursive --strict --configuration .swift-format COOL-TUNNEL

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
- **Don't break the audit gates.** All four green checks
  (Rust + Swift + shell + security) are required.
- **Don't commit secrets.** The `security_check.sh` secret scan
  will catch obvious patterns (AWS keys, GitHub PATs, the pinned
  historical leak), but be careful with anything new.

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
