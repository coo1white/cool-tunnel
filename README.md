<div align="center">

# Cool Tunnel

**A privacy-first macOS proxy app. You run the server, Cool Tunnel runs the client. No analytics, no tracking, no third parties.**

[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-1c5cdc)](./LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coo1white/cool-tunnel?label=latest)](https://github.com/coo1white/cool-tunnel/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%2B-blue)](#compatibility)
[![CI](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml)
[![Engine: Rust](https://img.shields.io/badge/engine-Rust-orange)](./core)
[![Swift 6](https://img.shields.io/badge/Swift-6-critical)](./COOL-TUNNEL)

</div>

---

## What is Cool Tunnel?

Cool Tunnel is a macOS app that routes your internet traffic through a server you own. Think of it like a tunnel: your laptop talks to your server, your server talks to the rest of the internet, and anyone watching your local network just sees encrypted traffic to a single web address.

You use it when:

- You're on a network that censors or monitors traffic and you want a quieter path out.
- You want a static exit IP under your control.
- You want a privacy tool that doesn't phone home to any company — including the people who made the app.

You do **not** use it when:

- You expect someone else to provide the server. Cool Tunnel is non-custodial: **you supply the server, the credentials, and the legal/jurisdictional judgment.**
- You expect anonymity against an attacker who can see both ends of the tunnel. That's a different threat model — see [SECURITY.md](./SECURITY.md).

### Three things that make this app different

1. **You own everything.** No accounts, no subscriptions, no central server. You rent a $5/month VPS, run a one-line install command, paste three values into the Mac app, and you're done.
2. **The code can be read.** The app is AGPL-3.0-only and roughly 11,000 lines of Swift + Rust. New-to-coding readers can study it as a real-world example of a small, focused, modern Mac app — see [Reading this code](#reading-this-code) below.
3. **Zero analytics.** The app makes exactly two kinds of outbound connections: (a) one HTTPS call to `api.github.com` when you click "Check for Updates," and (b) the proxy traffic you asked for. There is no telemetry, no crash reporter, no third-party SDK, no anonymous metrics.

---

## Quick Start (5 minutes)

If you already have a server and just want to install the Mac app:

1. **Download** the latest `.dmg` from [Releases](https://github.com/coo1white/cool-tunnel/releases/latest).
2. **Drag** `Cool Tunnel.app` into `/Applications`.
3. **First launch**: right-click the app, choose **Open**. macOS asks for confirmation the first time because this app isn't notarized through Apple's paid developer channel.
4. **Enter your server details**: hostname, username, password. Leave the local port at `1080` unless you know you need something else.
5. **Pick a routing mode and click Start.**

| Mode | What it does | Good for |
|---|---|---|
| **Smart** | Routes only blocked / international sites through the tunnel; local traffic stays direct. | Daily use. The default. |
| **Global** | Routes *all* TCP traffic through the tunnel. | When you want everything to look like it's coming from your VPS. |
| **Local** | Just runs the local SOCKS listener on `127.0.0.1:1080`. Doesn't change system proxy. | When you want to point individual apps at the tunnel manually. |

If you don't have a server yet, jump to [Setting up the server](#setting-up-the-server-once) below — that's a one-time 10-minute task per VPS.

---

## How does it work? (Plain-English version)

The app is split into four moving parts. Each part has one job. The boundaries are deliberate — if any one part crashes, the others keep working.

```
   ┌──────────────────────┐     ┌─────────────────────┐
   │   The Mac app (UI)   │     │  Your server (VPS)  │
   │ ─────────────────── │     │ ─────────────────── │
   │  • SwiftUI windows  │     │  • Caddy webserver  │
   │  • Menu bar icon    │     │  • NaiveProxy add-on│
   │  • Settings, logs   │     │  • TLS certificate  │
   └────────┬─────────────┘     └──────────▲──────────┘
            │ asks Rust to do things       │ HTTPS CONNECT
            ▼                              │  (regular TLS to
   ┌──────────────────────┐                │   anyone watching)
   │  Rust supervisor      │                │
   │ ─────────────────── │                │
   │  • Talks to UI over │                │
   │    JSON over stdio  │                │
   │  • Spawns + watches │                │
   │    NaiveProxy       │                │
   └────────┬─────────────┘                │
            │ fork/exec                    │
            ▼                              │
   ┌──────────────────────┐                │
   │ NaiveProxy client    │────────────────┘
   │ (binds 127.0.0.1)    │
   └──────────────────────┘
```

In one paragraph: you click Start in the Mac app. The Swift UI tells the Rust supervisor "start a tunnel." The Rust supervisor spawns the bundled NaiveProxy binary and watches it. NaiveProxy opens a TLS connection to your VPS and sends an HTTPS `CONNECT` request — to a passive observer it looks like an ordinary HTTPS page load. Your VPS forwards the actual destination traffic. When you stop the app, Swift tells Rust to stop, Rust kills NaiveProxy, and the system proxy gets restored.

### Why three different languages?

| Layer | Language | Why this language? |
|---|---|---|
| UI + lifecycle | Swift 6 | SwiftUI is the right tool for native Mac UI. Swift 6's strict concurrency catches data races at compile time. |
| Supervisor | Rust | The engine handles untrusted bytes from the proxy data path. Rust's memory safety + `#![forbid(unsafe_code)]` means a crafted server response can't corrupt the process. |
| Data plane | C++ (NaiveProxy) | NaiveProxy is the upstream open-source proxy client. We don't rewrite it; we bundle it and supervise it. |
| Server deploy | POSIX shell | Servers don't have Swift or Rust toolchains. Plain shell + Docker is the lowest-common-denominator install path. |

There is **no foreign-function-interface (FFI) bridge** between Swift and Rust. They talk over a pipe (Rust's stdin/stdout) using JSON messages. If Rust panics, the operating system reaps that child process and the Swift app surfaces an error to the user — the UI never crashes because the supervisor died.

---

## Setting up the server (once)

The server side is a small Debian box with [Caddy](https://caddyserver.com/) (a modern webserver) and the [NaiveProxy fork](https://github.com/klzgrad/forwardproxy) of Caddy's forward-proxy module. The installer is one shell block.

### Before you start

You need:

| What | Why |
|---|---|
| A VPS with Debian and at least 1 GB of RAM | The proxy runs in Docker; 1 GB is comfortable. |
| A domain or subdomain pointing at the VPS (`A` or `AAAA` record) | Caddy gets a free TLS certificate from Let's Encrypt for that name. |
| Root or `sudo` access on the VPS | The installer writes to `/opt/cool-tunnel` and listens on ports 80 + 443. |
| A fresh random password | Generate with `openssl rand -base64 32`. **Never reuse passwords from examples**. |

If any of those four items isn't ready, stop and fix it. A proxy stood up on shaky DNS or a half-open firewall isn't secure — it's a future incident.

### The install command

SSH into the VPS as `root` and run:

```bash
export CT_DOMAIN="proxy.example.com"       # your domain
export CT_EMAIL="admin@example.com"        # for Let's Encrypt
export CT_USER="cool"                      # any username
export CT_PASSWORD="$(openssl rand -base64 32)"
bash -s <<'EOF'
set -Eeuo pipefail
: "${CT_DOMAIN:?set CT_DOMAIN}"
: "${CT_EMAIL:?set CT_EMAIL}"
: "${CT_USER:?set CT_USER}"
: "${CT_PASSWORD:?set CT_PASSWORD}"

command -v docker >/dev/null 2>&1 || curl -fsSL https://get.docker.com | sh

install -d -m 0755 /opt/cool-tunnel/site
cd /opt/cool-tunnel

cat > Dockerfile <<'DOCKER'
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
DOCKER

cat > Caddyfile <<CADDY
{
    order forward_proxy before file_server
}

:443, ${CT_DOMAIN} {
    tls ${CT_EMAIL}
    forward_proxy {
        basic_auth ${CT_USER} ${CT_PASSWORD}
        hide_ip
        hide_via
        probe_resistance
    }
    root * /srv
    file_server
}
CADDY

cat > docker-compose.yml <<'COMPOSE'
services:
  cool-tunnel:
    build: .
    container_name: cool-tunnel
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv:ro
      - naive_caddy_data:/data
      - naive_caddy_config:/config

volumes:
  naive_caddy_data:
  naive_caddy_config:
COMPOSE

printf 'OK\n' > site/index.html
docker compose build --no-cache
docker compose up -d
docker exec cool-tunnel caddy list-modules | grep forward_proxy
printf 'server=%s\nuser=%s\npassword=%s\n' "$CT_DOMAIN" "$CT_USER" "$CT_PASSWORD"
EOF
```

At the end, the script prints `server=...`, `user=...`, `password=...`. **Save those three values.** You'll paste them into the Mac app.

### Reading the install script

Even if you don't want to run the script blindly, the file [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md) is the same setup explained step by step. New-to-coding readers can use it as a real example of:

- A multi-stage Docker build (`FROM caddy:builder AS builder`)
- A Caddyfile (Caddy's domain-specific config language)
- Docker Compose for one-service setups
- Defensive shell scripting (`set -Eeuo pipefail` + `: "${VAR:?msg}"`)

### Verify the server before installing the Mac app

Four checks. They take 30 seconds and they catch every "I thought the server was working" mistake:

| Check | Command | Expected |
|---|---|---|
| HTTPS works at all | `curl -v https://$CT_DOMAIN` | The word `OK` from the fallback page. |
| The proxy module loaded | `docker exec cool-tunnel caddy list-modules | grep forward` | `forward_proxy` is listed. |
| The credentials work | `curl -v --proxy "https://$CT_USER:$CT_PASSWORD@$CT_DOMAIN:443" https://ipinfo.io` | A JSON blob showing **the VPS's public IP**, not yours. |
| (Later, after Mac install) | `curl -x socks5h://127.0.0.1:1080 -vk --max-time 30 https://www.google.com/generate_204` | `HTTP/2 204` over the tunnel. |

If the third check shows your home IP instead of the VPS's, the proxy isn't actually being used — debug here, not in the Mac app.

---

## Reading this code

If you're learning to write code and want to read a real-world Mac app, here's a map of what's where and why. The codebase is intentionally small (~11k LOC total) so a careful reader can fit it in their head.

### Recommended reading order

1. **[`COOL-TUNNEL/Views/ContentView.swift`](./COOL-TUNNEL/Views/ContentView.swift)** — the SwiftUI root view. Shows how the main window is composed from smaller views (`HeaderView`, `ControlPanelView`, `ConnectionFormView`, `LogConsoleView`). Good intro to SwiftUI's "one view per file" idiom.

2. **[`COOL-TUNNEL/Views/Components/UIComponents.swift`](./COOL-TUNNEL/Views/Components/UIComponents.swift)** — three small reusable UI building blocks (`IconBarButton`, `VerdictPill`, `SummaryRow`). Read this to see how a tiny shared component library reduces duplication.

3. **[`COOL-TUNNEL/Core/CoolTunnelState.swift`](./COOL-TUNNEL/Core/CoolTunnelState.swift)** — the schema for everything the UI sees. The principle is "the UI is a pure function of state." If you can describe the screen, you can render the screen.

4. **[`COOL-TUNNEL/Core/TunnelOrchestrator.swift`](./COOL-TUNNEL/Core/TunnelOrchestrator.swift)** — the brain of the app. `@MainActor`-isolated, handles every lifecycle event (start, stop, mode switch, sleep, wake, error). The file is long but each method does one thing. Read the comment headers — they explain *why*, not just *what*.

5. **[`core/src/main.rs`](./core/src/main.rs)** — entry point of the Rust supervisor. A real example of `#![forbid(unsafe_code)]` Rust talking to the outside world over stdio.

6. **[`core/src/protocol.rs`](./core/src/protocol.rs)** — the JSON message format Swift and Rust use to talk to each other. Read this with `core/tests/protocol_roundtrip.rs` to see how a typed protocol is built and tested.

7. **[`scripts/cut_release.sh`](./scripts/cut_release.sh)** — the release pipeline. Shows how to chain `cargo fmt` / `clippy` / tests / Swift format / `xcodebuild` / signing / packaging into one command. Good for understanding what "CI" actually does under the hood.

### Things worth studying

| Pattern | Where to find it | What it teaches |
|---|---|---|
| Swift 6 strict concurrency | `TunnelOrchestrator.swift`, search for `@MainActor` | How to keep UI code on the main thread without explicit locks. |
| Schema-driven UI | `CoolTunnelState.swift` → `ContentView.swift` | The "render from state, emit intents" pattern that React popularized. |
| Process supervision | `core/src/supervisor.rs` | How to fork a child process, watch its stdout, and restart it on crash. |
| JSON-over-stdio RPC | `core/src/protocol.rs` + `CoreClient.swift` | A simple alternative to gRPC / FFI for two processes that need to talk. |
| Credential redaction | `core/src/redaction.rs` + `LifecycleTelemetryLogger.swift` | Regex patterns that strip passwords from log lines before they reach disk. |
| Atomic file writes | `RestrictedFile.swift` | The `O_CREAT \| O_EXCL` + rename trick that makes "write a config file" crash-safe. |
| Defensive shell | `scripts/*.sh` | `set -Eeuo pipefail`, `: "${VAR:?msg}"`, `trap` cleanup — the building blocks of scripts that don't silently corrupt state. |

### Why is the code organized this way?

The "three layers" diagram in [How does it work?](#how-does-it-work-plain-english-version) isn't just a marketing picture — it's the actual code layout:

- `COOL-TUNNEL/` is the macOS app (Swift)
- `core/` is the Rust supervisor (compiled into the bundled `cool-tunnel-core` binary)
- `scripts/` and `NaiveProxy_Server_Setup.md` cover the server side

A read-only contributor who understands those three boundaries can predict where any given feature lives without searching.

---

## When things go wrong

When the Mac app's banner flips red, the error chip names which **layer** failed. This is the operator's most-used troubleshooting table:

| Chip | What it means | Your first move |
|---|---|---|
| `Local Kernel` | Something on your Mac. NaiveProxy didn't start, credentials are malformed, a local firewall is blocking loopback. | Click **Run Diagnostics** in the control panel. It will name DNS, TCP, or TLS at the local layer. |
| `ISP` | The path between your Mac and the public internet. Wi-Fi flap, captive portal, ISP DNS hijack, blocked route to your VPS. | Open the **VPS Health overlay**. If it says `Probe error · DNS ?`, your resolver is broken. If it says `Blocked · DNS ✓ · TCP ?`, your ISP is dropping the connection. |
| `VPS` | The server itself. Caddy stopped, the certificate expired, basic-auth rejected the password. | Re-run the four [server verification checks](#verify-the-server-before-installing-the-mac-app) on the VPS. |

The classifier is deterministic — same inputs always produce the same layer attribution — so two operators triaging the same incident reach the same conclusion without coordinating.

### Common failures

| Symptom | Likely cause | First action |
|---|---|---|
| `Unlock the Keychain and try again` banner | macOS Keychain is locked or the prompt was dismissed. | Unlock the login keychain in Keychain Access, click Start again. |
| `Refusing to install — checksum failed` | The update artifact bytes don't match the published `.sha256` manifest. | Don't retry blindly. Check the release tag on GitHub; if it's a CDN cache issue, retry in a few minutes. Otherwise report as a [security incident](./SECURITY.md). |
| Banner says `Local Kernel · naive stopped unexpectedly` | The NaiveProxy child died. The supervisor retries 3 times with backoff (0.5s / 2s / 5s). | Watch the log for `self-healing aborted: …` — that names the permanent cause (invalid credentials, missing binary, etc.). |
| Wake from sleep, header shows `Active` but no traffic | Sleep-wake checkpoint missed (rare). | Click the active mode chip to re-enter it. The orchestrator hot-swaps the connection. |
| `lifecycle-telemetry.jsonl` slowly grows | Normal. The file is append-only, schema-versioned, credential-redacted, never sent off-device. | If you'd rather not keep session metadata at all, delete the file between sessions. |

For everything else, the [SUPPORT.md](./SUPPORT.md) file names the LTSC support contract.

---

## Where your data lives

Three files in `~/Library/Application Support/space.coolwhite.cooltunnel/`, all mode `0o600` (only your user can read), atomic-write, excluded from Time Machine backups:

| File | What's in it | Lifecycle |
|---|---|---|
| `config.json` | The NaiveProxy config Cool Tunnel generates each start — embeds your `https://user:pass@host` URL. | Written fresh on every Start, deleted on graceful Stop. **Never hand-edit.** |
| `credentials.json` | Base64-encoded profile passwords. | Survives launches. Migrates from the macOS Keychain on first run under the file backend. |
| `lifecycle-telemetry.jsonl` | Append-only log of state-machine transitions (start / stop / sleep / wake / error layer). | Credential-redacted before write (the redaction regex set is regression-tested in [LifecycleTelemetryRedactionTests](./COOL-TUNNELTests/LifecycleTelemetryRedactionTests.swift)). **Never sent off-device.** |

The full operator-facing privacy model — including known surfaces where information *can* leak in error paths — lives in [SECURITY-WEB3.md](./SECURITY-WEB3.md). Read it once before routing sensitive traffic.

### Uninstalling cleanly

```bash
# Stop the tunnel from the menu bar, then:
osascript -e 'quit app "Cool Tunnel"'

# Remove the app
rm -rf "/Applications/Cool Tunnel.app"

# Remove local state (config, credentials, telemetry, PAC file)
rm -rf "$HOME/Library/Application Support/space.coolwhite.cooltunnel"

# Remove the in-app updater's staging dirs (cosmetic; auto-cleaned anyway)
rm -rf "$(getconf DARWIN_USER_TEMP_DIR)cool-tunnel-* "
```

If you're tearing down the VPS too:

```bash
docker compose -f /opt/cool-tunnel/docker-compose.yml down -v && rm -rf /opt/cool-tunnel
```

System proxy settings are reverted automatically on every clean Stop and on `applicationWillTerminate`. If the app crashed without reverting (rare), run `networksetup -setautoproxystate <service> off` and `networksetup -setsocksfirewallproxystate <service> off` for each active network service in **System Settings → Network**.

---

## Keeping the app up to date

Cool Tunnel ships its own SHA-256-pinned in-app updater. Updates are operator-initiated, never silent.

| Action | What it does |
|---|---|
| Settings → **Check for Updates** | One HTTPS request to `api.github.com` to read the `latest` release tag. No background polling. |
| Click **Update** when offered | Downloads the `.zip` AND its `.sha256` manifest from GitHub-controlled hosts. Refuses to install if either is missing. Verifies the `.zip` bytes against the manifest before extracting. |
| App relaunch | The old `Cool Tunnel.app` is replaced atomically. A 5-second watchdog forces exit if shutdown stalls. |

To verify a manually-downloaded DMG without the updater UI:

```bash
shasum -a 256 -c Cool-tunnel-vX.Y.Z.sha256
# Expected: "Cool-tunnel-vX.Y.Z.dmg: OK"
```

A mismatch means the bytes you have don't match the bytes the release cutter signed. Don't open the DMG — report it via [SECURITY.md](./SECURITY.md).

---

## Building from source

You'll need Xcode (with Swift 6 and the macOS 14 SDK), the Rust toolchain pinned by [core/rust-toolchain.toml](./core/rust-toolchain.toml), `cargo-deny`, and `shellcheck`.

```bash
git clone https://github.com/coo1white/cool-tunnel.git
cd cool-tunnel
bin/ct doctor                   # is my checkout healthy? (preflight + audit + ratchet)
```

`bin/ct` is a brew-style single-entry-point CLI over the build / release / audit scripts. Add `bin/` to your `$PATH` if you want `ct …` instead of `bin/ct …`. Discover everything with:

```bash
bin/ct commands         # full list
bin/ct help <command>   # full usage for one verb
```

For a release build (substitute the next version — pre-flight rejects any value that doesn't match `core/Cargo.toml` and `MARKETING_VERSION`):

```bash
bin/ct release 2.0.52
```

The release pipeline verifies version sync, refreshes the bundled NaiveProxy binary, runs the strict audit suite, rebuilds Rust and Swift, runs `ct security`, and packages `.dmg`, `.pkg`, `.zip`, the universal core binary, and the SHA-256 manifest.

> Every `ct …` subcommand is a thin wrapper over a `scripts/*.sh` file. Running `bash scripts/preflight.sh` etc. directly still works — `bin/ct` is the discoverable surface, not a replacement.

---

## Architecture details (for the curious)

For readers who want the longer technical story behind the four-part diagram above:

### The boundary contract

| Boundary | Mechanism | Why this design |
|---|---|---|
| Swift ↔ Rust | Out-of-process JSON over stdio | A Rust panic terminates a subprocess, not the macOS app. The UI stays state-driven and recoverable. |
| Rust ↔ proxy engine | Supervised child process | The data plane can be restarted, replaced, SHA-pinned, or killed without corrupting orchestrator state. |
| Client ↔ VPS | HTTPS CONNECT through a Caddy-built NaiveProxy server | Network observers see ordinary TLS traffic to the operator's own domain. |
| Repo ↔ release | Local shell gate with locked toolchain checks | "Local PASS == CI PASS": formatter, clippy, tests, ShellCheck, Swift format, binary checks, package security. |

Swift 6 owns lifecycle: window state, menu-bar state, system-proxy changes, sleep/wake notifications, and strict-concurrency UI updates. Rust owns the hardened control plane: typed protocol handling, process supervision, anomaly detection, local-bind enforcement, diagnostics, and credential redaction. The packet router (NaiveProxy itself) is kept outside the app's address space — that separation is the stability model.

There is no FFI bridge. The JSON schema is the contract; if either side breaks it, tests fail and the process boundary contains the blast radius.

```mermaid
flowchart LR
    subgraph Mac["macOS Client"]
        UI["Swift 6 UI<br/>SwiftUI, @MainActor, strict concurrency"]
        ORC["TunnelOrchestrator<br/>sleep/wake, state machine, system proxy"]
        UI <-->|state updates| ORC
    end

    subgraph Core["Rust Core"]
        RPC["JSON-over-stdio RPC<br/>typed protocol contract"]
        SUP["Supervisor<br/>process lifecycle, probes, log redaction"]
        RPC --> SUP
    end

    subgraph Data["Data Plane"]
        NP["Bundled NaiveProxy client<br/>supervised child, loopback bind"]
    end

    subgraph VPS["Operator VPS"]
        SH["POSIX shell deployment<br/>idempotent Docker setup"]
        WEB["Caddy + forward_proxy<br/>TLS, basic-auth, fallback site"]
        SH --> WEB
    end

    ORC <-->|stdin/stdout JSON| RPC
    SUP -->|fork/exec, SIGTERM| NP
    NP -->|HTTPS CONNECT, TLS camouflage| WEB
    WEB --> Internet["Public Internet"]
```

### Rotating VPS credentials

Cool Tunnel doesn't auto-rotate. Rotation is an explicit operator action:

1. On the VPS, regenerate the password and restart Caddy:
   ```bash
   export CT_USER="cool"
   export CT_PASSWORD="$(openssl rand -base64 32)"
   sed -i "s/basic_auth .* .*/basic_auth ${CT_USER} ${CT_PASSWORD}/" /opt/cool-tunnel/Caddyfile
   docker compose -f /opt/cool-tunnel/docker-compose.yml restart
   ```
2. On the Mac, open the connection form, paste the new password, save. The old password lingers in `credentials.json` until the next save; the new save replaces it.
3. Click **Run Diagnostics** to confirm the new credentials work.

The password is 32 bytes from `/dev/urandom`; it doesn't weaken with age. Rotate if you suspect a leak, otherwise leave it alone.

### Rolling the bundled NaiveProxy pin

The `naive` binary inside the app bundle is pinned by `COOL-TUNNEL/naive.upstream.json`. `cut_release.sh` verifies the bundled binary's SHA against the manifest on every release and refuses to ship a mismatch. A daily scheduled CI workflow ([`naive-pin-audit.yml`](./.github/workflows/naive-pin-audit.yml)) re-downloads the upstream tarballs at the pinned tag and verifies the SHA still reproduces — an upstream tag rewrite or mirror tampering surfaces within 24 hours.

Operators don't normally touch the pin. Maintainers who want to roll it intentionally:

```bash
git pull origin main
CT_REPIN_CONFIRM=1 bin/ct naive --repin v148.0.7778.96-7
# Inspect the printed OLD → NEW diff.
git add COOL-TUNNEL/naive COOL-TUNNEL/naive.upstream.json
git commit -m "chore(naive): repin to v148.0.7778.96-7"
```

The `--repin` flag refuses to write anything without `CT_REPIN_CONFIRM=1`. The pin change must land as a single commit (binary + manifest) naming the old → new transition in the message.

---

## Quality bar: the same failure classes are forced through the same gates on every release

A release ships when these all pass, not when the UI looks calm:

### Sleep / wake recovery

With Cool Tunnel connected, run `pmset sleepnow`. Wake the Mac after ~15 seconds. The app must:

| Phase | Required behavior |
|---|---|
| `willSleep` | App receives `NSWorkspace.willSleepNotification` and enters pausing state. |
| Sleep checkpoint | Proxy state is made explicit before the machine suspends. |
| `didWake` | App receives `NSWorkspace.didWakeNotification` and begins recovery. |
| Recovery | Orchestrator restarts or reconciles the supervised process. |
| Return to idle | UI returns to connected/ready state within the healthy-uplink budget. |

Failure to recover is a release blocker.

### Error classification

The error classifier must distinguish local, upstream, and VPS failures. Operators verify by injecting each fault:

| Injection | Expected layer |
|---|---|
| Wrong saved password | `Local Kernel` |
| Disable Wi-Fi / Ethernet | `ISP` |
| Block VPS `:443` while internet is healthy | `VPS` |

Misclassification is a product defect — pointing the operator at the wrong layer wastes time and hides the real incident.

### Release reproducibility

The release gate is a command, not a checklist in someone's memory:

```bash
bin/ct preflight
bin/ct release 2.0.52
```

If you can't run those locally, you can't ship a release.

---

## Security posture

| Control | Enforcement |
|---|---|
| Credential minimization | Credentials stay local to your Mac and your chosen VPS. |
| Log redaction | Authorization headers, cookies, JSON passwords, and credential-bearing URL fragments are redacted before UI display and before disk write. |
| Local-bind guard | The supervised proxy is expected to bind only to loopback. Public-bind anomalies are stopped. |
| SHA-256 update pinning | The updater refuses artifacts whose bytes don't match the manifest. |
| Trusted-host update guard | Update redirects are constrained to GitHub-controlled hosts. |
| Hardened runtime | macOS runtime hardening limits injection and tampering against the app process. |

Cool Tunnel **cannot** protect against: a malicious macOS user process, an unlocked stolen laptop, a hostile VPS operator, or a global observer with visibility at both tunnel ends. **The server is a trust boundary — own it accordingly.**

Full threat model: [SECURITY.md](./SECURITY.md) and [SECURITY-WEB3.md](./SECURITY-WEB3.md).

---

## License

Cool Tunnel is licensed under **AGPL-3.0-only**. The summary below is operational posture, not a replacement for [LICENSE](./LICENSE).

| Axis | Position |
|---|---|
| Copyleft floor | Network service modifications must remain source-available under AGPL terms. |
| Warranty | None. The software is provided as-is. |
| Liability | Operators carry their own legal, operational, financial, and jurisdictional risk. |
| Commercial use | Services around the software are tolerated; proprietary capture is not. |
| Relicensing | No proprietary fork grant, no CLA aggregation, no open-core conversion path. |
| LTSC-Heng | Maintenance favours long-term corrective releases over feature velocity. Incident history stays in the codebase as ballast. |

Read [Disclaimer.md](./Disclaimer.md) before use. The software can be used in legally restricted network environments; compliance is the operator's burden.

---

## Compatibility

| Need | Detail |
|---|---|
| macOS | 14 Sonoma or newer. |
| Mac architecture | Apple Silicon and Intel (universal release artifacts). |
| Installed size | About 45 MB. |
| Runtime memory | About 30 MB on the Mac. |
| VPS floor | 1 GB RAM Debian host for Docker + Caddy. |
| Admin password | Not required for normal Mac client operation. |

---

## Reference

| File | What's in it |
|---|---|
| [CHANGELOG.md](./CHANGELOG.md) | Release history. Every entry names the incident or feature that drove it. |
| [SUPPORT.md](./SUPPORT.md) | Long-term support contract. |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Contributor workflow and the local checks you must pass before sending a PR. |
| [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md) | Standalone VPS deployment reference. |
| [SECURITY.md](./SECURITY.md) | Threat model and disclosure process. |
| [SECURITY-WEB3.md](./SECURITY-WEB3.md) | Privacy model including known leak surfaces. |
| [Disclaimer.md](./Disclaimer.md) | Legal/operator disclaimer. |
| [NOTICE](./NOTICE) | Third-party attribution, including upstream NaiveProxy. |

<sub>Steward: coolwhite LLC. Posture: non-custodial, hard-copyleft, zero analytics.</sub>
