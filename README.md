<div align="center">

# Cool Tunnel

**Privacy-first macOS proxy app. You run the server, Cool Tunnel runs the client.**

[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-1c5cdc)](./LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coo1white/cool-tunnel?label=latest)](https://github.com/coo1white/cool-tunnel/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%2B-blue)](./SUPPORT.md)

</div>

---

## What it is

A macOS app that routes your traffic through a server you own. SwiftUI client, Rust supervisor, bundled sing-box data plane (VLESS + Reality). Non-custodial — you supply the server and credentials. See [SECURITY.md](./SECURITY.md) for the threat model.

---

## Quick Start

1. Download the latest `.dmg` from [Releases](https://github.com/coo1white/cool-tunnel/releases/latest).
2. Drag `Cool Tunnel.app` into `/Applications`.
3. First launch: right-click → **Open**.
4. Enter server hostname, username, password. Leave the local port at `1080`.
5. Pick a mode and click Start.

| Mode | What it does |
|---|---|
| **Smart** | Routes only blocked / international sites through the tunnel. The default. |
| **Global** | Routes *all* TCP traffic through the tunnel. |
| **Local** | Just runs the SOCKS listener on `127.0.0.1:1080`; doesn't change system proxy. |

---

## Server setup

The server side lives in a separate repo: [coo1white/cool-tunnel-server](https://github.com/coo1white/cool-tunnel-server) (v0.4.0+ pairs with the v3.0.0 client). It deploys a sing-box endpoint with VLESS + Reality and prints the `server=`, `username=`, `uuid=` triple you paste into the Mac app.

---

## Reference

- [CHANGELOG.md](./CHANGELOG.md) — release history
- [SUPPORT.md](./SUPPORT.md) — supported macOS / hardware
- [SECURITY.md](./SECURITY.md) — threat model and disclosure
- [CONTRIBUTING.md](./CONTRIBUTING.md) — contributor workflow

---

AGPL-3.0-only. macOS 14+, universal (arm64 + x86_64). Steward: coolwhite LLC.
