<div align="center">

# Cool Tunnel

**Privacy-first macOS proxy app. You run the server, Cool Tunnel runs the client. No analytics, no third parties.**

[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-1c5cdc)](./LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coo1white/cool-tunnel?label=latest)](https://github.com/coo1white/cool-tunnel/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%2B-blue)](./SUPPORT.md)
[![CI](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml)

</div>

---

## What it is

A macOS app that routes your traffic through a server you own. SwiftUI client, Rust supervisor, bundled NaiveProxy data plane. Non-custodial — you supply the server, the credentials, and the jurisdictional judgment.

Not for: someone-else-provides-the-server use, or anonymity against an observer with visibility at both ends — see [SECURITY.md](./SECURITY.md).

---

## Quick Start

1. Download the latest `.dmg` from [Releases](https://github.com/coo1white/cool-tunnel/releases/latest).
2. Drag `Cool Tunnel.app` into `/Applications`.
3. First launch: right-click → **Open** (the app isn't notarized through Apple's paid channel).
4. Enter server hostname, username, password. Leave the local port at `1080`.
5. Pick a mode and click Start.

| Mode | What it does |
|---|---|
| **Smart** | Routes only blocked / international sites through the tunnel. The default. |
| **Global** | Routes *all* TCP traffic through the tunnel. |
| **Local** | Just runs the SOCKS listener on `127.0.0.1:1080`; doesn't change system proxy. |

---

## Server setup (one-time, ~10 minutes per VPS)

Full step-by-step: [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md). Short version — SSH in as root:

```bash
export CT_DOMAIN="proxy.example.com"
export CT_EMAIL="admin@example.com"
export CT_USER="cool"
export CT_PASSWORD="$(openssl rand -base64 32)"
# then run the install block in NaiveProxy_Server_Setup.md
```

At the end the installer prints `server=`, `user=`, `password=`. Paste those three into the Mac app.

**Verify before installing the client:**

```bash
curl -v --proxy "https://$CT_USER:$CT_PASSWORD@$CT_DOMAIN:443" https://ipinfo.io
```

Should return JSON showing the **VPS's** public IP, not yours.

---

## Building from source

```bash
git clone https://github.com/coo1white/cool-tunnel.git
cd cool-tunnel
bin/ct doctor          # preflight + audit + ratchet
bin/ct release 2.0.54  # full release build
```

`bin/ct` is the brew-style single-entry CLI. `bin/ct commands` lists everything. Toolchain pins live in [core/rust-toolchain.toml](./core/rust-toolchain.toml); maintenance scripts are POSIX shell + Bun TypeScript ([scripts/](./scripts)).

---

## Reference

| File | What's in it |
|---|---|
| [CHANGELOG.md](./CHANGELOG.md) | Release history. |
| [SUPPORT.md](./SUPPORT.md) | LTSC support contract, supported macOS / hardware, breaking-change list. |
| [SECURITY.md](./SECURITY.md) | Threat model and disclosure process. |
| [SECURITY-WEB3.md](./SECURITY-WEB3.md) | Privacy model including known leak surfaces. |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Contributor workflow and local-check gates. |
| [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md) | Standalone VPS deployment reference. |
| [Disclaimer.md](./Disclaimer.md) | Legal/operator disclaimer. |
| [NOTICE](./NOTICE) | Third-party attribution. |

---

AGPL-3.0-only. macOS 14+, universal (arm64 + x86_64). Steward: coolwhite LLC. Non-custodial, hard-copyleft, zero analytics.
