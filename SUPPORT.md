# Support policy

Cool Tunnel runs on a **Long-Term Servicing Channel (LTSC)**
release model. The current LTSC line is **v2.0.x** (started
2026-05; the historical v0.1.7 line is superseded). The LTSC
posture is a deliberate trade-off:

- **Stable.** Public surface — UI flows, CLI flags on
  `cool-tunnel-core`, JSON-over-stdio engine protocol, file paths
  in `~/Library/Application Support/COOL-TUNNEL/` — does not
  break inside an LTSC line.
- **Conservative.** Dependency upgrades, Rust toolchain bumps,
  and macOS-floor moves happen at LTSC boundaries, not in
  patches. Pinned in `rust-toolchain.toml` and
  `core/Cargo.toml`.
- **Long-supported.** Security fixes and upstream NaiveProxy
  updates land on the active LTSC line for **at least 18 months
  from initial release** of that line.

> **Note (round-3 review fix):** This file's version-specific
> dates and example commands below still reference the historical
> `v0.1.7` line for example purposes. The substance of the policy
> applies identically to the current v2.0.x LTSC line; full
> rewrite of dates and example versions is tracked separately.

This document is the contract.

---

## Supported configurations

### macOS

| Version | Status |
| --- | --- |
| macOS 14 (Sonoma) | ✅ Supported |
| macOS 15 (Sequoia) | ✅ Supported |
| macOS 26 (Tahoe) | ✅ Supported (Liquid Glass surfaces light up) |
| macOS 13 and earlier | ❌ Not supported (deployment target floor) |

### Hardware

| Hardware | Status | Notes |
| --- | --- | --- |
| Apple Silicon (M1, M2, M3, M4, future) | ✅ Native | `arm64` slice |
| Intel Mac, 2018+ | ✅ Native | `x86_64` slice |
| Intel Mac, 2017 and earlier | ❌ | macOS 14 doesn't run on these |

The `.app` is a universal Mach-O for all four shipped artefacts.

### Rust toolchain (for building from source)

| Channel | Status |
| --- | --- |
| 1.80.0 (pinned) | ✅ Build target — see `rust-toolchain.toml` |
| 1.81 .. latest stable | ✅ Builds, but not what we ship |
| 1.79 and earlier | ❌ Below MSRV |

---

## What counts as a breaking change

LTSC patches **never** introduce any of these inside a release
line (e.g. v0.1.7 → v0.1.7.x):

1. Renaming, removing, or changing the semantics of any CLI flag
   on `cool-tunnel-core`.
2. Changing the JSON schema of any `Request` / `Outbound` /
   `Event` frame in the engine protocol.
3. Changing the on-disk path or file format of
   `credentials.json`, `config.json`, or `smart-proxy.pac`.
4. Changing the HTTP API surface of `--mode server` (paths,
   request bodies, response shapes, status codes).
5. Raising the macOS deployment floor.
6. Bumping the pinned Rust toolchain.
7. Changing the canonical first line of `--version` output
   (`cool-tunnel-core <semver>`) — the macOS app's
   `RustCoreResolver` greps it.

Hotfixes (border tweaks, log-line wording, performance
adjustments, NaiveProxy upstream bumps that don't change protocol)
**do** ship in-line on the LTSC tag and are documented in
[CHANGELOG.md](./CHANGELOG.md).

The next time any of items 1–7 changes, the release line bumps
(e.g. v0.1.7 → v0.2.0) and the new line declares its own LTSC
window.

---

## Reporting issues

| Kind | Where |
| --- | --- |
| **Security vulnerability** | Private GitHub Security Advisory — see [SECURITY.md](./SECURITY.md) |
| **Bug** | [GitHub Issues](https://github.com/coo1white/cool-tunnel/issues) — include `cool-tunnel-core --version` output and macOS version |
| **Feature request** | GitHub Issues with the `enhancement` label |
| **Question** | GitHub Discussions |

When reporting a bug, run `cool-tunnel-core --version` and
include the second line — it embeds the build SHA and date so we
can match your binary to a commit:

```
cool-tunnel-core 0.1.7
build:    abc1234 2026-05-03 (release)
```

---

## Update policy inside the v0.1.7 LTSC line

| Change type | Lands in patch | Bumps line |
| --- | --- | --- |
| NaiveProxy upstream patch (no protocol change) | ✅ | — |
| Security fix in our code | ✅ | — |
| Visual tweak / wording | ✅ | — |
| Performance fix | ✅ | — |
| Dependency security patch (no API change) | ✅ | — |
| New CLI flag (additive) | ✅ | — |
| Major Rust toolchain bump | — | ✅ |
| Major dependency major-version bump | — | ✅ |
| New macOS deployment floor | — | ✅ |
| Anything in the "breaking" list above | — | ✅ |

---

## End of life

When the v0.1.7 LTSC line ends, this file is updated to point at
the new active LTSC line. We do not silently abandon LTSC lines
— a final patch on the old line tells users where to upgrade,
and the GitHub release page is annotated accordingly.
