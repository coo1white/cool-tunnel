# Support policy

Cool Tunnel ships on a **Long-Term Servicing Channel (LTSC)** model. The
current line is **v2.0.x** (started 2026-05). Public surface — UI flows,
`cool-tunnel-core` CLI flags, the JSON-over-stdio engine protocol, and
file paths under `~/Library/Application Support/COOL-TUNNEL/` — does
not break inside an LTSC line. Security fixes and upstream NaiveProxy
updates land for **at least 18 months** from the line's initial release.

## Supported

| macOS | Status |
| --- | --- |
| 14 Sonoma, 15 Sequoia, 26 Tahoe | ✅ |
| 13 and earlier | ❌ (deployment-target floor) |

| Hardware | Status |
| --- | --- |
| Apple Silicon (M1+) | ✅ `arm64` slice |
| Intel Mac 2018+ | ✅ `x86_64` slice |
| Intel Mac 2017 and earlier | ❌ (no macOS 14) |

Universal Mach-O for `.dmg`, `.pkg`, `.zip`, and the standalone core
binary. Build toolchain is pinned in [core/rust-toolchain.toml](./core/rust-toolchain.toml).

## What counts as breaking

These **never** ship inside an LTSC line; they bump the line:

1. Rename / remove / re-semantic any `cool-tunnel-core` CLI flag.
2. Change the JSON schema of any `Request` / `Outbound` / `Event` frame.
3. Change the on-disk path or format of `credentials.json`, `config.json`, or `smart-proxy.pac`.
4. Change the `--mode server` HTTP API surface.
5. Raise the macOS deployment floor.
6. Bump the pinned Rust toolchain.
7. Change the first line of `--version` (the macOS app's `RustCoreResolver` greps it).

Hotfixes — wording, performance, NaiveProxy upstream bumps without
protocol change — ship in-line and are documented in
[CHANGELOG.md](./CHANGELOG.md).

## Reporting issues

| Kind | Where |
| --- | --- |
| **Security vulnerability** | Private GitHub Security Advisory — see [SECURITY.md](./SECURITY.md) |
| **Bug** | [GitHub Issues](https://github.com/coo1white/cool-tunnel/issues) — include `cool-tunnel-core --version` and macOS version |
| **Feature request** | GitHub Issues, `enhancement` label |
| **Question** | GitHub Discussions |

`cool-tunnel-core --version`'s second line embeds the build SHA and date
so a binary can be matched back to a commit.

## End of life

When the v2.0.x line ends, this file is updated to point at the next
active LTSC line and a final patch on the old line surfaces the upgrade
hint in the GitHub release page. No silent abandonment.
