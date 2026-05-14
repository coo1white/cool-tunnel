<div align="center">

# Cool Tunnel

**Industrial macOS proxy control plane: Swift 6 orchestration, Rust supervision, NaiveProxy data path, zero analytics.**

[![License: AGPL-3.0-only](https://img.shields.io/badge/license-AGPL--3.0--only-1c5cdc)](./LICENSE)
[![Latest release](https://img.shields.io/github/v/release/coo1white/cool-tunnel?label=latest)](https://github.com/coo1white/cool-tunnel/releases/latest)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%2B-blue)](#compatibility)
[![CI](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml)
[![Engine: Rust](https://img.shields.io/badge/engine-Rust-orange)](./core)
[![Swift 6](https://img.shields.io/badge/Swift-6-critical)](./COOL-TUNNEL)

</div>

---

## Repository Metadata

GitHub description, kept under the 160-character repository limit:

> High-performance macOS proxy control plane: Swift 6 UI, Rust supervisor, NaiveProxy data path, zero analytics.

Recommended topics:

`rust` `swift` `swift6` `macos` `macos-app` `macos-proxy` `proxy` `naiveproxy` `sing-box` `caddy` `frankenphp` `docker` `shell` `high-concurrency` `privacy` `anti-tracking` `agplv3`

---

## Operating Posture

Cool Tunnel is not a hosted proxy service. It is a non-custodial macOS client plus hardened operator tooling. The user supplies the server, credentials, domain, and jurisdictional risk assessment.

| Rule | Enforcement |
|---|---|
| **Zero analytics** | No telemetry endpoint, no identity service, no tracking SDK, no event export. |
| **Zero footprint VPS floor** | Server deployment is expected to run on a 1 GB RAM VPS. Anything heavier must justify itself. |
| **Immutable ballast** | Code and docs preserve incident history. Regressions are recorded, not cosmetically erased. |
| **Deterministic release gate** | `scripts/cut_release.sh` runs the local synthetic CI gate before release artifacts leave the tree. |
| **Non-custodial operation** | The repository ships no public servers and no embedded credentials. |

Read [Disclaimer.md](./Disclaimer.md) before use. The software can be used in legally restricted network environments; compliance is the operator's burden.

---

## Architecture Blueprint

Cool Tunnel is built as a three-layer defense system. Each layer has one job. The boundary is intentional: Swift is allowed to orchestrate, Rust is allowed to supervise, the proxy engine is allowed to move packets, and shell is allowed to deploy infrastructure.

```mermaid
flowchart LR
    subgraph Mac["macOS Client"]
        UI["Swift 6 UI<br/>SwiftUI, @MainActor, strict concurrency"]
        ORC["TunnelOrchestrator<br/>sleep/wake handlers, state machine, system proxy"]
        UI <-->|state updates| ORC
    end

    subgraph Core["Rust Core"]
        RPC["JSON-over-stdio RPC<br/>typed protocol contract"]
        SUP["Supervisor<br/>process lifecycle, probes, log redaction"]
        RPC --> SUP
    end

    subgraph Data["Data Plane"]
        NP["Bundled NaiveProxy client<br/>supervised child process, loopback bind"]
    end

    subgraph VPS["Operator VPS"]
        SH["POSIX Shell deployment<br/>idempotent Docker setup"]
        WEB["FrankenPHP + Caddy<br/>TLS, forward_proxy, fallback site"]
        SH --> WEB
    end

    ORC <-->|stdin/stdout JSON| RPC
    SUP -->|fork/exec, health checks, SIGTERM| NP
    NP -->|HTTPS CONNECT, TLS camouflage| WEB
    WEB --> Internet["Public Internet"]
```

### Boundary Contract

| Boundary | Mechanism | Why it exists |
|---|---|---|
| Swift -> Rust | Out-of-process JSON over stdio | A Rust panic terminates a subprocess, not the macOS app. The UI remains state-driven and recoverable. |
| Rust -> proxy engine | Supervised child process | The data plane can be restarted, replaced, SHA-pinned, or killed without corrupting orchestrator state. |
| Client -> VPS | HTTPS CONNECT through NaiveProxy-compatible Caddy | Network observers see ordinary TLS traffic to the operator's own domain. |
| Repo -> release artifact | Shell gate with locked toolchain checks | Local PASS must mean CI PASS: formatter, clippy, tests, ShellCheck, Swift format, binary checks, and release packaging. |

Swift 6 owns lifecycle: window state, menu bar state, system proxy changes, sleep/wake notifications, and strict-concurrency UI updates. Rust owns the hardened control plane: typed protocol handling, process supervision, anomaly detection, local bind enforcement, diagnostics, and credential redaction. The packet router is kept outside the app address space. That separation is the stability model.

There is no FFI bridge. There is no shared memory contract. The JSON schema is the contract; if either side breaks it, tests fail and the process boundary contains the blast radius.

---

## First Deployment

A working Cool Tunnel deployment is **server + client + first connection**. The detailed playbooks for each step live in the sections below; this walkthrough names the sequence so the order is unambiguous on a first install.

### What you need before you start

| Resource | Why |
|---|---|
| A Debian VPS with at least 1 GB RAM | The data plane. See [One-Click VPS Installation](#one-click-vps-installation). |
| A domain (or subdomain) with an `A` / `AAAA` record pointed at the VPS | Caddy issues a TLS cert via ACME; the cert is anchored to a name that resolves to the host. |
| `root` (or `sudo`) on the VPS | The installer owns `/opt/cool-tunnel`, Docker, and ports 80/443. |
| A Mac on macOS 14 Sonoma or newer | The control plane. Apple Silicon or Intel. |
| ~10 minutes | First deployment is one VPS command + one DMG install + one form. |

If any of those are missing, fix them first. Skipping a prerequisite produces an incident later that costs more time than fixing it now.

### The four steps

1. **Stand up the VPS.** Follow [One-Click VPS Installation](#one-click-vps-installation). The installer is idempotent — re-running converges the host to the declared state, not parallel services. At the end of step 1 you have a working HTTPS proxy listening on `:443` and a `server=`, `user=`, `password=` triple printed to the operator's terminal.

2. **Verify the VPS in isolation.** Before installing the client, confirm the VPS forwards traffic correctly. The [Server Verification](#one-click-vps-installation) table at the end of step 1 lists four `curl` probes; the `Proxy path` probe in particular proves the basic-auth credentials and the upstream egress before the Mac is involved. A VPS that fails this table will fail the Mac client too — fix it here, not after.

3. **Install the macOS client.** Follow [macOS Installation](#macos-installation). Paste the credentials from step 1 (or import them from a `cool-tunnel-server` panel subscription URL if you're using the panel-based deployment). Pick `Smart` as the default routing mode unless you have a reason for `Global` or `Local`.

4. **Verify end-to-end.** With the tunnel connected, run [Operator Diagnostics](#operator-diagnostics) → `Run Diagnostics`. The probe drives a CONNECT through the live tunnel and reports DNS, TCP, TLS, and end-to-end timings. Anything other than a green pass at this step means a hop between the Mac and the destination is wrong, and the diagnostic names which hop. The [VPS Health overlay](#operator-diagnostics) is the right next click — it runs an out-of-band reachability probe against the VPS so you can tell whether the failure is local or upstream.

Once step 4 passes, the deployment is done. The Mac will surface a `Connected · Smart` (or `· Global`, `· Local`) pill in the menu bar and the header view; the system proxy is configured automatically based on the chosen mode. From that point forward the operator's job is the [Maintenance](#maintenance) chapter below.

---

## One-Click VPS Installation

### First Scold: Do Not Run This Blind

The server side is infrastructure. Treat it like infrastructure.

| Requirement | Non-negotiable reason |
|---|---|
| Debian VPS, 1 GB RAM minimum | The deployment target is deliberately small. Higher memory is acceptable; lower memory is operator negligence. |
| Root shell or equivalent sudo | The installer owns `/opt/cool-tunnel`, Docker, ports `80` and `443`, and system services. |
| DNS `A` or `AAAA` record already pointed at the VPS | Caddy cannot issue a valid certificate for a domain that does not resolve to the host. |
| Ports `80/tcp`, `443/tcp`, `443/udp` open | ACME, HTTPS CONNECT, and HTTP/3 require these paths. |
| Fresh random credentials | Never reuse examples. Generate with `openssl rand -base64 32`. |

If any prerequisite is false, stop. Fix the host first. A proxy deployed on ambiguous DNS, reused credentials, or a half-open firewall is not a hardened system; it is an incident waiting for a timestamp.

### Then Do Good: Single Operator Command

The checked-in deployment reference is [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md). On a fresh VPS, run this as `root` after replacing the domain and email values:

```bash
export CT_DOMAIN="proxy.example.com"
export CT_EMAIL="admin@example.com"
export CT_USER="cool"
export CT_PASSWORD="$(openssl rand -base64 32)"
bash -s <<'EOF'
set -Eeuo pipefail
: "${CT_DOMAIN:?set CT_DOMAIN}"
: "${CT_EMAIL:?set CT_EMAIL}"
: "${CT_USER:?set CT_USER}"
: "${CT_PASSWORD:?set CT_PASSWORD}"

command -v docker >/dev/null 2>&1 || {
  curl -fsSL https://get.docker.com | sh
}

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

For audit-sensitive operators, the stricter path is:

```bash
git clone https://github.com/coo1white/cool-tunnel.git
cd cool-tunnel
less NaiveProxy_Server_Setup.md
```

Then execute the setup block manually with the same values. The deployment is designed to be idempotent: re-running the Docker/Caddy setup converges the host to the declared state, not parallel services.

### Server Verification

| Check | Command | Expected |
|---|---|---|
| HTTPS fallback | `curl -v https://$CT_DOMAIN` | `OK` from the fallback file server. |
| Caddy module | `docker exec cool-tunnel caddy list-modules | grep forward` | `forward_proxy` module present. |
| Proxy path | `curl -v --proxy "https://$CT_USER:$CT_PASSWORD@$CT_DOMAIN:443" https://ipinfo.io` | Public IP resolves through the VPS. |
| Mac client | `curl -x socks5h://127.0.0.1:1080 -vk --max-time 30 https://www.google.com/generate_204` | `HTTP/2 204` after Cool Tunnel is connected. |

---

## macOS Installation

1. Download the latest `Cool-tunnel-vX.Y.Z.dmg` from [Releases](https://github.com/coo1white/cool-tunnel/releases/latest).
2. Drag `Cool Tunnel.app` into `/Applications`.
3. First launch: right-click -> **Open**. macOS requires this because the project does not depend on Apple's paid Developer ID channel.
4. Provide a profile. Either enter the VPS domain, username, password, and local port manually, or paste a `https://…/api/v1/subscription/<token>` URL from a `cool-tunnel-server` panel and import. Keep the local port at `1080` unless there is a conflict.
5. Choose routing mode.

| Mode | Use when | Mechanism |
|---|---|---|
| Smart | Blocked destinations should use the tunnel while ordinary local traffic stays direct. | System proxy points at a generated PAC file. Loopback, RFC 1918 ranges, and the user's direct-domain list resolve `DIRECT`; everything else is sent through the local SOCKS listener. |
| Global | Every TCP connection should route through the configured proxy. | System SOCKS proxy points at `127.0.0.1:<localPort>`. |
| Local | Cool Tunnel should only expose `127.0.0.1:1080` and leave system proxy settings untouched. | No system-wide proxy changes; only the local listener runs. |

---

## Operator Diagnostics

The control panel exposes four wire-adjacent probes for triaging an incident without leaving the app. Each writes a redacted report into the live log and never includes credentials in process arguments.

| Action | What it does | Use when |
|---|---|---|
| Run Diagnostics | Drives a CONNECT through the active tunnel and reports DNS, TCP, TLS, and end-to-end timings. | The tunnel is running but a destination is slow or failing. |
| Debug Handshake | Spawns a temporary reference `naive` client, performs one deterministic CONNECT, sends a TLS `ClientHello` through it, and reports `connect_ok`, `post_connect_recv`, elapsed time, and first-byte hex. | Comparing the bundled client's handshake against hardened-server suppression logs; isolating CONNECT acceptance from post-CONNECT payload drops. |
| Latency | Issues a small batch of probes through the local listener and surfaces per-sample timing. | Quantifying jitter or comparing two VPS hosts. |
| VPS Health overlay | Hydrates the selected profile and runs an out-of-band reachability probe (DNS, TCP, TLS) against the VPS without routing user traffic. Probe failures are labelled `Probe error` rather than masquerading as `Blocked`. | Deciding whether a connection failure is a local profile defect, an upstream uplink defect, or the VPS itself being down or blocked. |

Reports are also visible to the operator via the optional Developer Overlay (`DeveloperOverlayView`), which surfaces tunnel lifecycle, throughput, encryption overhead, and error-layer attribution without external telemetry.

---

## Maintenance

A deployed Cool Tunnel is plumbing. After step 4 of the [First Deployment](#first-deployment) walkthrough, the daily operator surface is small: install updates when they appear, glance at the VPS Health overlay if traffic feels off, and triage the three documented error layers when the banner flips red. This chapter is the operator's manual for that surface.

### Keeping the client up to date

Cool Tunnel ships its own SHA-256-pinned in-app updater. Updates are operator-initiated, never silent:

| Action | What it does |
|---|---|
| Open the Settings window → `Check for Updates` | Issues one HTTPS request to `api.github.com` to read the `latest` release tag. No background polling. |
| Click `Update` when a newer version is offered | Downloads `Cool-tunnel-vX.Y.Z.zip` AND its `.sha256` manifest from `*.githubusercontent.com`. Refuses to install if either asset is missing. Verifies the bytes of the `.zip` against the manifest line before extracting — a mismatch produces a "Refusing to install — checksum failed" banner, not a silent upgrade. |
| App relaunch | Old `Cool Tunnel.app` is replaced atomically. A 5-second watchdog `Darwin.exit(0)` kicks in if the clean shutdown path stalls, so a wedged update can't park the app in "Relaunching…" forever. |

**Verifying integrity without the updater UI.** Every release tag publishes the same `.sha256` manifest as a release asset. After downloading a DMG manually, you can verify it from the terminal:

```bash
shasum -a 256 -c Cool-tunnel-vX.Y.Z.sha256
# Expected: "Cool-tunnel-vX.Y.Z.dmg: OK"
```

A mismatch here means the bytes you downloaded don't match the bytes the release cutter signed. Don't open the DMG; report it as a [SECURITY.md](./SECURITY.md) incident.

**What versions look like.** The header view + `About Cool Tunnel` panel both surface the running version. The release cutter pins the version in three places (`core/Cargo.toml`, both `MARKETING_VERSION` lines in `COOL-TUNNEL.xcodeproj/project.pbxproj`, `CHANGELOG.md`); a mismatch trips `cut_release.sh`'s pre-flight gate, so any version you see in the running app is the version that passed every CI gate.

### Triaging the three error layers

When the banner flips red, the chip names the layer. The right next click is layer-specific:

| Chip | Meaning | Operator next step |
|---|---|---|
| `Local Kernel` | The local Mac stack: `naive` not running, saved credentials malformed, local firewall blocking the loopback bind, profile fields invalid. | Open `Run Diagnostics`. The probe will name DNS, TCP, or TLS at the local layer. If `Debug Handshake` succeeds but `Run Diagnostics` fails, the `naive` child is alive but loopback routing is broken. |
| `ISP` | Between the Mac and the public internet: Wi-Fi association, captive portal, ISP DNS, route to the VPS hostname. | Open the `VPS Health overlay`. If it reports `Probe error · DNS ?`, your local resolver is down or hijacked. If it reports `Blocked · DNS ✓ · TCP ?`, your ISP has TCP-level interference. |
| `VPS` | The configured server itself: hostname doesn't resolve, `:443` refuses connections, `forward_proxy` rejects the handshake, certificate expired. | Run [Server Verification](#one-click-vps-installation) on the VPS side. The fallback `curl https://$CT_DOMAIN` probe in particular reveals whether the Caddy stack is alive at all. |

The classifier is deterministic — same input, same layer attribution — so two operators triaging the same incident reach the same root cause without coordinating.

### Where state lives

Three files in `~/Library/Application Support/space.coolwhite.cooltunnel/`, all `0o600`, atomic-write, excluded from Time Machine:

| File | Purpose | Lifecycle |
|---|---|---|
| `config.json` | Generated `naive` config carrying the operator's `https://user:pass@host:port` URL. | Written fresh on every Start. Deleted on graceful Stop. Never under operator hand-editing. |
| `credentials.json` | Base64-encoded profile passwords. | Survives across launches. Migrates from the macOS Keychain on first run under the file backend. |
| `lifecycle-telemetry.jsonl` | Local-only state-machine transitions (bootstrap, start, stop, anomaly classification, error-layer attribution, sleep/wake). | Append-only. Credential-redacted before write (the redaction surface is regression-tested in `LifecycleTelemetryRedactionTests`). Never sent off-device. |

The full operator-facing privacy model for these files — including the known surfaces where information about traffic CAN leak in error paths — lives in [SECURITY-WEB3.md](./SECURITY-WEB3.md). Read it once before routing sensitive traffic.

### Rotating VPS credentials

Cool Tunnel does not auto-rotate; rotation is an explicit operator action:

1. On the VPS, regenerate the password and update the `Caddyfile`:
   ```bash
   export CT_USER="cool"
   export CT_PASSWORD="$(openssl rand -base64 32)"
   sed -i "s/basic_auth .* .*/basic_auth ${CT_USER} ${CT_PASSWORD}/" /opt/cool-tunnel/Caddyfile
   docker compose -f /opt/cool-tunnel/docker-compose.yml restart
   ```
2. On the Mac, open the connection form, paste the new password, save. The old password lingers in `credentials.json` until the next save; the new save replaces it.
3. Run `Run Diagnostics` to confirm the new credentials forward traffic correctly.

Rotation cadence is operator-defined. The project doesn't enforce one — the threat model is "the operator owns the VPS" — but the credentials are 32 bytes from `/dev/urandom` and are not weakened by age. Rotate if you suspect a leak; otherwise leave them alone.

### Rolling the bundled NaiveProxy pin

The `naive` binary inside the app bundle is pinned by `COOL-TUNNEL/naive.upstream.json`. The pin is **authoritative** — `cut_release.sh` verifies the bundled binary's SHA against the manifest on every release cut and refuses to ship a mismatch. A daily scheduled CI workflow (`naive-pin-audit.yml`) re-downloads the upstream tarballs at the pinned tag and verifies every SHA still reproduces; an upstream tag rewrite or mirror tampering surfaces within 24 hours.

Operators don't normally touch the pin. If you're a maintainer and you need to roll it intentionally:

```bash
git pull origin main
CT_REPIN_CONFIRM=1 bash scripts/fetch_naive.sh --repin v148.0.7778.96-7
# Inspect the printed OLD → NEW diff.
git add COOL-TUNNEL/naive COOL-TUNNEL/naive.upstream.json
git commit -m "chore(naive): repin to v148.0.7778.96-7"
```

The `--repin` flag refuses to write anything without `CT_REPIN_CONFIRM=1` — rolling the pin is an operator decision, not an accident. The change must land as a single commit (binary + manifest) that names the old → new tag transition in the message. See `scripts/fetch_naive.sh --help` for the full mode table.

### Common-failure quick reference

| Symptom | Likely cause | First operator action |
|---|---|---|
| `Unlock the Keychain and try again` banner | Keychain locked, prompt dismissed, or migration write failed. | Unlock the login keychain, click Start again. The credential won't be silently re-prompted-and-lost (regression-tested in `ProfileStoreTests`). |
| `Refusing to install — checksum failed` | Update artifact bytes don't match the published `.sha256`. | Don't retry blindly. Verify the release tag's `.sha256` is intact on GitHub. If it's a CDN cache issue, retry after a few minutes; if not, report as a security incident. |
| Banner flips to `Local Kernel · naive stopped unexpectedly` | The `naive` child died. Self-healing retries automatically (3 attempts, 0.5 s / 2 s / 5 s back-off) unless the failure is permanent (invalid credentials, missing binary). | Watch the log for `self-healing aborted: …` — that names the permanent cause. |
| Wake from sleep, header shows `Active` but no traffic | Sleep/wake checkpoint missed (rare; usually Path A in `handleSystemDidWake` recovers without operator action). | Click the active mode chip to re-enter it. The orchestrator's stop-quiet + restart hot-swap path is the same one used by mode changes. |
| `lifecycle-telemetry.jsonl` growing slowly over time | Normal. Append-only, schema-versioned, credential-redacted. | If you're routing sensitive traffic and the file holds session metadata you'd rather not preserve: `rm "$HOME/Library/Application Support/space.coolwhite.cooltunnel/lifecycle-telemetry.jsonl"` between sessions. |

For anything not in this table, [SUPPORT.md](./SUPPORT.md) names the LTSC contract.

### Uninstalling cleanly

```bash
# Stop the tunnel from the menu bar, then:
osascript -e 'quit app "Cool Tunnel"'

# Remove the app
rm -rf "/Applications/Cool Tunnel.app"

# Remove local state (config, credentials, telemetry, PAC file)
rm -rf "$HOME/Library/Application Support/space.coolwhite.cooltunnel"

# Remove the in-app updater's staging dirs (purely cosmetic; auto-cleaned per pipeline)
rm -rf "$(getconf DARWIN_USER_TEMP_DIR)cool-tunnel-* "
```

If the VPS is going away too: `docker compose -f /opt/cool-tunnel/docker-compose.yml down -v && rm -rf /opt/cool-tunnel` on the server.

System proxy settings are reverted automatically on every clean Stop and on `applicationWillTerminate`. If the app crashed without reverting (rare), `networksetup -setautoproxystate <service> off` and `networksetup -setsocksfirewallproxystate <service> off` for each active service in `Network` preferences restores the default state.

---

## Quality Assurance: Heng

Heng means constancy. A release does not ship because the UI looks calm; it ships only after the same failure classes have been forced through the same gates again.

### 1. Sleep / Wake Recovery

With Cool Tunnel connected:

```bash
pmset sleepnow
```

Wake the Mac after roughly 15 seconds.

| Phase | Required behavior |
|---|---|
| `willSleep` | App receives `NSWorkspace.willSleepNotification` and enters pausing state. |
| Sleep checkpoint | Proxy state is made explicit before the machine suspends. |
| `didWake` | App receives `NSWorkspace.didWakeNotification` and begins recovery. |
| Recovery | Orchestrator restarts or reconciles the supervised process. |
| Return to idle | UI returns to connected/ready state within the healthy-uplink budget. |

Failure to recover is a release blocker. Sleep/wake is not a cosmetic feature; it is the normal operating environment of a Mac.

### 2. Error Classification

The classifier must distinguish local failure, upstream failure, and VPS failure. Operators verify by injecting each fault.

| Injection | Expected class | Meaning |
|---|---|---|
| Wrong saved password | Local | Profile, credential, child process, or local firewall defect. |
| Disable all uplinks | Upstream | Wi-Fi, ISP, DNS, captive portal, or general internet path defect. |
| Block VPS `:443` while internet is healthy | VPS | The configured server, TLS endpoint, or proxy daemon is unavailable. |

Misclassification is a product defect. A diagnostic that points to the wrong layer wastes operator time and hides the incident.

### 3. Release Reproducibility

The release gate is the command, not a checklist in someone's memory:

```bash
bash scripts/preflight.sh
bash scripts/cut_release.sh 2.0.36
```

`cut_release.sh` verifies version sync, refreshes the bundled proxy engine, runs the strict audit suite, rebuilds the Rust core and Swift app, runs `security_check.sh`, and packages `.dmg`, `.pkg`, `.zip`, the universal core binary, and the SHA-256 manifest.

---

## Build From Source

### Prerequisites

| Tool | Required |
|---|---|
| Xcode | Xcode with Swift 6 support and macOS 14 SDK or newer. |
| Rust | Toolchain pinned by [core/rust-toolchain.toml](./core/rust-toolchain.toml). |
| `cargo-deny` | `cargo install cargo-deny --locked` |
| `shellcheck` | `brew install shellcheck` |
| `gh` | Optional, only for release publication. |

### Commands

```bash
git clone https://github.com/coo1white/cool-tunnel.git
cd cool-tunnel
bash scripts/preflight.sh
```

For a release build (substitute the next version — pre-flight rejects any value that doesn't match `core/Cargo.toml` and `MARKETING_VERSION`):

```bash
bash scripts/cut_release.sh 2.0.42
```

---

## Security Posture

| Control | Enforcement |
|---|---|
| Credential minimization | Credentials stay local to the user's Mac and selected VPS. |
| Log redaction | Authorization headers, cookies, JSON passwords, and credential-bearing lines are redacted before UI display. |
| Local bind guard | The supervised proxy is expected to bind to loopback only. Public bind anomalies are stopped. |
| SHA-256 update pinning | Updater refuses artifacts whose bytes do not match the manifest. |
| Trusted-host update guard | Update redirects are constrained to GitHub-controlled hosts. |
| Hardened runtime | macOS runtime hardening limits injection and tampering against the app process. |

Cool Tunnel cannot protect against a malicious macOS user process, an unlocked stolen machine, a hostile VPS operator, or a global observer with visibility at both tunnel ends. The server is a trust boundary. Own it accordingly.

Full model: [SECURITY.md](./SECURITY.md).

---

## License and LTSC-Heng Posture

Cool Tunnel is licensed under **AGPL-3.0-only**. The summary below is operational posture, not a replacement for [LICENSE](./LICENSE).

| Axis | Position |
|---|---|
| Copyleft floor | Network service modifications must remain source-available under AGPL terms. |
| Warranty | None. The software is provided as-is, without implied fitness, merchantability, non-infringement, availability, or circumvention efficacy. |
| Liability | Operators carry their own legal, operational, financial, and jurisdictional risk. |
| Commercial use | Services around the software are tolerated; proprietary capture of the software is not. |
| Relicensing | No proprietary fork grant, no CLA aggregation, no open-core conversion path. |
| LTSC-Heng | Maintenance favors long-term corrective releases over feature velocity. Incident history is ballast. |

Commercial support, audits, packaging, and integration work may exist around the project. They do not purchase the right to close the source, hide network-service modifications, or weaken the license.

---

## Compatibility

| Need | Detail |
|---|---|
| macOS | 14 Sonoma or newer. |
| Mac architecture | Apple Silicon and Intel, via universal release artifacts. |
| Installed size | Approximately 45 MB. |
| Runtime memory | Approximately 30 MB on the Mac client. |
| VPS floor | 1 GB RAM Debian host for Docker + Caddy/FrankenPHP-class deployment. |
| Admin password | Not required for normal macOS client operation. |

---

## Maintenance Files

| File | Purpose |
|---|---|
| [CHANGELOG.md](./CHANGELOG.md) | Incident and release history. |
| [SUPPORT.md](./SUPPORT.md) | LTSC support contract. |
| [CONTRIBUTING.md](./CONTRIBUTING.md) | Contributor workflow and local checks. |
| [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md) | VPS deployment reference. |
| [Disclaimer.md](./Disclaimer.md) | Legal/operator disclaimer. |
| [NOTICE](./NOTICE) | Third-party attribution, including upstream NaiveProxy. |

<sub>Steward: coolwhite LLC. Posture: non-custodial, hard-copyleft, zero analytics.</sub>
