<div align="center">

# Cool Tunnel

**A non-custodial macOS client for borderless, surveillance-resistant communication.**

*Transparency over profit. Freedom over control.*

[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-1c5cdc)](./LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coo1white/cool-tunnel?label=latest)](https://github.com/coo1white/cool-tunnel/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%2B-blue)](#compatibility)
[![CI](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml)
[![Engine: Rust](https://img.shields.io/badge/engine-Rust-orange)](./core)
[![Universal binary](https://img.shields.io/badge/Mac-Apple%20Silicon%20%2B%20Intel-success)](#compatibility)

</div>

---

## ⚖️ Manifesto

Digital borders are policy, not topology. Surveillance is a posture, not an inevitability. Cool Tunnel exists because the right to private, undirected communication is older than the networks that mediate it.

We do not run a service. We publish a tool, sign no certificate of trust, host no user state, and operate no fleet. The user is sovereign. The protocol is the only authority.

> **Read this first.** This software has the technical capability to circumvent network restrictions. The [Disclaimer](./Disclaimer.md) covers what it is for, what it is not for, and the rules you should know before installing. By installing, you agree you have read it.

---

## ⚓ The Covenant — AGPL-3.0-only as Stewardship

This software ships under the **GNU Affero General Public License v3, no-or-later qualifier (AGPL-3.0-only)**. Copyright © 2026 coolwhite LLC. The covenant is precise:

| You may | You must |
|---|---|
| Use, study, modify, redistribute the source | Preserve the licence and source-availability |
| Run private modifications without disclosure | (no obligation while the modification stays private) |
| Operate a modified version as a network service | Publish those modifications under AGPL-3.0 |
| Sell, package, or vendor the source | Preserve the licence; charge for service, not the gift |

The covenant is not a fence. It is the guarantee that no future hand can take this code from the commons. Every release tagged on or before `v2.0.25` was distributed under Apache-2.0 and remains available under that licence to anyone who downloaded it; AGPL-3.0-only applies prospectively from `v2.0.26`.

---

## 🛡️ Heng — Constancy over Feature Velocity

Roadmaps invite scope creep. We practise *Heng* — constancy. Releases ship on what we cannot leave in the field, not on what we could demonstrate at a keynote.

| What we ship on | What we do not ship on |
|---|---|
| Reproducibility regressions | Marketing dates |
| Operator-reported defects | Influencer roadmaps |
| Audit-cycle findings | Feature-velocity targets |
| Upstream protocol drift | "Innovation theatre" |

Each release is a fix or an architectural correction. Each release is reproducible from public source via `cargo build --locked` + `xcodebuild`. Every prior release remains downloadable and independently buildable.

---

## Protocol is Truth

We do not ask for trust. We make trust unnecessary.

| Property | Mechanism |
|---|---|
| Indistinguishable transport | NaiveProxy traffic is the wire-shape of Chrome talking to a regular HTTPS site. No fingerprint a network observer can attribute to the proxy class. |
| No central authority | No telemetry, no identity service, no key registry. The connection is a function of *your* server and *your* credentials. |
| Reproducible binary | Every release is buildable bit-for-bit from public source. The signed `.app` corresponds to a public commit. |
| Pinned updates | The in-app updater verifies SHA-256 against a published manifest before adopting any new binary. |
| Hardened runtime + ad-hoc signature | Library-injection blocked at runtime; the App is signed with our own key (no Apple Developer subscription required for the project to ship). |

The protocol is the contract. The contract is verifiable. We are not asking for your trust; we are showing you our work.

---

## ⚡ Quick Start

A non-technical user can finish in one sitting.

### Step 1 — Download the latest `.dmg`

Go to **[github.com/coo1white/cool-tunnel/releases/latest][releases]**. Pick the **`Cool-tunnel-v2.0.x.dmg`** asset.

### Step 2 — Drag into Applications

Double-click the `.dmg`. Drag the Cool Tunnel icon onto the **Applications** folder shortcut.

### Step 3 — First launch (one-time approval)

Open `/Applications`, find **Cool Tunnel**, and **right-click → Open**. Click **Open** in the dialog macOS shows. After that, normal launch every time. Required because the app is signed with our key, not Apple's $99-per-year Developer ID — the right-click gesture is the user-side trust acknowledgement.

### Step 4 — Configure your server

You need a NaiveProxy server somewhere on the internet. Fill in the address, username, and password. Leave **Local Port** at `1080` unless you have a reason. Without a server: spin one up via [`coo1white/cool-tunnel-server`](https://github.com/coo1white/cool-tunnel-server) — Debian + Docker, ~15 minutes.

### Step 5 — Pick a mode

| Mode | When |
| --- | --- |
| **Smart** | Most of the time. Routes blocked sites through your server, lets local sites skip the proxy for speed. |
| **Global** | Maximum privacy — every TCP connection through your server. |
| **Local** | Listens on `127.0.0.1:1080` without altering system network settings. For pointing one specific app at the proxy. |

Status pill at the top turns pink and pulses; that means it is working.

[releases]: https://github.com/coo1white/cool-tunnel/releases/latest

---

## How it works

```
┌─────────────────────┐
│   You + your Mac    │
│   (Cool Tunnel app) │
└─────────┬───────────┘
          │  encrypted HTTPS — looks like a normal Chrome visit
          ▼
┌─────────────────────┐
│  Your NaiveProxy    │
│  server somewhere   │  ← you run this
└─────────┬───────────┘
          │  the actual website request
          ▼
┌─────────────────────┐
│  any-website.com    │
└─────────────────────┘
```

A network observer between you and your server sees only the top arrow — encrypted traffic indistinguishable from any other HTTPS request.

---

## Security posture

| Control | What it does |
| --- | --- |
| Hardened runtime | macOS blocks library injection and runtime tampering against the app process. |
| Mode-0600 credentials | NaiveProxy password lives in `~/Library/Application Support/COOL-TUNNEL/credentials.json`, readable only by your user. Not Keychain (intentional — see [SECURITY.md](./SECURITY.md)). |
| SHA-256 update pinning | The updater downloads a manifest separately and refuses to install if bytes don't match. |
| Trusted-host redirect guard | All update flows refuse any HTTP redirect that leaves `*.github.com` / `*.githubusercontent.com`. |
| Hard-link / symlink-escape rejection | A malicious archive cannot plant a hard link to a system file. The extraction walker rejects it. |
| Anomaly auto-stop | If `naive` ever binds outside `127.0.0.1`, the engine auto-stops the proxy within ≤5 seconds. |
| Log redaction | Lines touching credentials, `Authorization` / `Cookie` headers, or JSON `password` fields are redacted before reaching the live log. |

What we cannot defend against: a malicious app running as your macOS user; physical access to an unlocked Mac; a NaiveProxy server *you* picked that decides to log you. Pick a server you trust or run your own.

Full threat model: [SECURITY.md](./SECURITY.md).

---

## Updating without reinstalling

Settings (⚙️) shows three **Update** buttons:

| Update | What it does |
| --- | --- |
| Cool Tunnel → Update | Downloads the latest app, verifies SHA-256, relaunches. |
| Naive Binary → Update | Pulls latest NaiveProxy upstream, lipo-merges arm64 + x86_64, ad-hoc signs. |
| Rust Core → Update | Pulls the latest engine binary from the Cool Tunnel release. |

All three: one click, no terminal, host-validated, size-capped.

---

## Where things live

| What | Where |
| --- | --- |
| The app | `/Applications/Cool Tunnel.app` |
| Saved password | `~/Library/Application Support/COOL-TUNNEL/credentials.json` (mode 0600) |
| Proxy config | `~/Library/Application Support/COOL-TUNNEL/config.json` |
| Smart-mode rules | `~/Library/Application Support/COOL-TUNNEL/smart-proxy.pac` |
| Updated `naive` | `~/Library/Application Support/COOL-TUNNEL/naive-managed` |
| Updated engine | `~/Library/Application Support/COOL-TUNNEL/cool-tunnel-core-managed` |

Uninstall: drag app to Trash, delete `~/Library/Application Support/COOL-TUNNEL/`.

---

## Compatibility

| Need | Detail |
| --- | --- |
| Mac model | Any Mac that runs macOS 14 (Apple Silicon, or 2018+ Intel + 2017 iMac Pro) |
| macOS | 14 (Sonoma) or newer |
| Disk | About 45 MB installed |
| Memory | About 30 MB while running |
| Admin password | Never required |

---

## Community

| Action | How |
| --- | --- |
| **Contribute** | Open a PR. CI gates the merge: Rust (build + clippy + test), Swift (format lint --strict), ShellCheck. |
| **Fork** | AGPL-3.0 grants the right; preserve the licence and source-availability under § 13. |
| **Audit** | Every release passes a synthetic CI gate (`scripts/preflight.sh` + `scripts/security_check.sh`). The full per-release security audit is recorded in `CHANGELOG.md`. |

Architecture, build steps, contribution guide: [CONTRIBUTING.md](./CONTRIBUTING.md). Long-term support contract: [SUPPORT.md](./SUPPORT.md).

---

## Enterprise

The code is free. Time and expertise are the premium tier.

| Engagement | Outcome |
| --- | --- |
| Architecture review | Formal third-party assessment of your deployment shape, threat model, and operational runbook. |
| Consultancy | Non-trivial integrations, custom packaging, security-posture review. |
| Excellence | Durable engineering judgement on demand. |

For commercial inquiries: open an issue tagged `enterprise:` on this repository.

---

<sub>**Jurisdiction:** Wyoming, USA · **Posture:** Non-Custodial · **Philosophy:** AGPL-3.0 Hard-Copyleft · **Steward:** coolwhite LLC</sub>

<sub>Cool Tunnel wraps upstream [NaiveProxy](https://github.com/klzgrad/naiveproxy) (BSD-3). Without it there would be nothing to wrap. Per-component attribution: [NOTICE](./NOTICE).</sub>
