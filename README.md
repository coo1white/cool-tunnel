# Cool Tunnel

A free, open-source macOS GUI for the [NaiveProxy][naiveproxy] protocol —
a censorship-circumvention proxy disguised as plain HTTPS traffic. Cool
Tunnel wraps the upstream `naive` binary in a native SwiftUI app driven
by a small Rust core, ships as a single universal `.app` for both Apple
Silicon and Intel, and stores everything locally with no telemetry.

[naiveproxy]: https://github.com/klzgrad/naiveproxy

> **Heads-up.** Cool Tunnel is a tool for circumventing online
> censorship. Read the [Disclaimer](./Disclaimer.md) before downloading
> — it covers intended use, user responsibility, and what the bundled
> components are.

---

## Why Cool Tunnel

| | |
| --- | --- |
| **Native macOS** | SwiftUI + AppKit. No Electron, no Tauri WebView, no Qt. |
| **Classic Mac aesthetic** | System 7 / Platinum-era palette + Monaco for every monospaced surface, with Liquid Glass on macOS 26+ as the modern note. |
| **Universal binary** | One `.app` runs natively on Apple Silicon (M1/M2/M3/M4 and beyond) **and** Intel — `arm64` + `x86_64` slices in every Mach-O. |
| **Two replaceable components** | The bundled `naive` binary **and** the `cool-tunnel-core` Rust engine each have a Test (OK / NG verdict) + Update flow in Settings. Update fetches a fresh universal build from GitHub, lipo-merges + ad-hoc signs it, and adopts it without reinstalling the app. |
| **Ready to use out of the box** | Passwords live in `~/Library/Application Support/COOL-TUNNEL/credentials.json` (mode 0600) — no macOS Keychain prompt before the UI appears. Existing v0.1.5.4 Keychain entries migrate transparently the first time you click Start. |
| **No data collection** | Zero telemetry, zero analytics, zero remote configuration. The only network calls go to the SOCKS upstream you configure (and the GitHub API when you press the Update button). |
| **Verified at launch** | The Rust engine is `SecStaticCodeCheckValidity`-verified before spawning. The naive binary is verified before each proxy start. Both are inspected for host-CPU slice presence so a wrong-arch build can never hit "Bad CPU type in executable". |
| **Free, open-source** | Apache 2.0 licensed — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE). |

---

## Compatibility

| Requirement | Detail |
| --- | --- |
| **OS** | macOS 14 (Sonoma) or newer |
| **CPU** | Apple Silicon (`arm64`) or Intel (`x86_64`) — same `.app` works on both |
| **Disk** | ~23 MB installed (universal binary) |
| **Memory** | ~30 MB resident while the proxy is running |
| **Network** | Outbound HTTPS to your NaiveProxy server; loopback SOCKS listener (default `127.0.0.1:1080`); GitHub API + releases CDN if you press Update |
| **Privileges** | Standard user — no admin / no privileged helper / no kernel extension |
| **Sandbox** | Not sandboxed (the app needs to spawn the bundled `naive` binary and call `networksetup`) |
| **Apple Developer ID** | Not required to use — the app is ad-hoc signed (right-click → Open on first launch) |

The macOS 14 floor covers every Apple Silicon Mac and every Intel Mac
that can still run Sonoma — iMac 2019+, MacBook Air / Pro / mini
2018+, Mac Studio, Mac Pro 2019+. Older Macs can't run Sonoma anyway,
so 14.0 is the practical floor.

If you're already running an upstream NaiveProxy server (Caddy + naive,
or any compatible HTTP CONNECT endpoint), Cool Tunnel is the macOS
client side.

---

## How it works

```
                   ┌──────────────────────────────┐
                   │     SwiftUI app  (UI tier)    │
                   │  Header / ControlPanel /      │
                   │  ConnectionForm / LogConsole  │
                   │  Settings (chip detection,    │
                   │   naive picker, domains)      │
                   └──────────────┬───────────────┘
                                  │ @Observable orchestrator
                   ┌──────────────▼───────────────┐
                   │     TunnelOrchestrator         │
                   │  + NaiveBinaryResolver         │
                   │  + SystemProxyController       │
                   │  + KeychainStore / Profiles    │
                   └──────────────┬───────────────┘
                                  │ JSON over stdin/stdout
                                  │ (request / response / event)
                   ┌──────────────▼───────────────┐
                   │   cool-tunnel-core  (Rust)    │
                   │  - profile validation         │
                   │  - naive config + PAC gen     │
                   │  - ProxySupervisor (spawn,    │
                   │     monitor, restart)         │
                   │  - lsof-based anomaly probe   │
                   │  - curl-based diagnostics     │
                   │  - 100 ms anomaly debouncer   │
                   └──────────────┬───────────────┘
                                  │ Process::spawn
                   ┌──────────────▼───────────────┐
                   │  naive (BSD-3 upstream binary) │
                   │  TLS handshake + HTTP CONNECT  │
                   │  to your NaiveProxy server.    │
                   └──────────────────────────────┘
```

### What happens when you click Start

1. **Profile validation** — `core.send(.validateProfile(profile))`
   parses host, port, credentials in the Rust core (constructor-validated
   value types, no inline UI checks).
2. **Config + PAC generation** — Rust serialises `naive`'s
   `config.json` and (for smart mode) a PAC file routing the user's
   `directDomains` straight to the internet. Both written to
   `~/Library/Application Support/COOL-TUNNEL/` with mode `0600`.
3. **Naive binary resolution** — `NaiveBinaryResolver` runs `lipo
   -info`, `naive --version`, and `SecStaticCodeCheckValidity` in
   parallel. Refuses to spawn if the host CPU slice is missing, the
   signature is invalid, or the file isn't a Mach-O.
4. **Spawn** — Rust's `ProxySupervisor` `Process::spawn`s naive with
   piped stdio, streams stdout/stderr (with credential redaction), and
   emits `Event::StateChanged(running: true)` to the Swift UI.
5. **Anomaly monitoring** — every 5 s, Rust runs `lsof -nP -p <pid>
   -iTCP` and parses the output. If naive bound to `0.0.0.0` instead
   of loopback, a `ListeningOutsideLoopback` anomaly fires and Cool
   Tunnel **auto-stops** the proxy (a critical security guarantee).
6. **System proxy** — Cool Tunnel calls `/usr/sbin/networksetup` to
   set the SOCKS proxy (Global mode) or auto-proxy URL (Smart mode)
   on every active network service.

### Why two binaries (naive + cool-tunnel-core)?

The architecture intentionally separates three concerns —
**UI**, **glue**, **proxy** — so each can evolve and
update independently. The same shape is meant to extend across
platforms in the future:

|                                  | **UI**                      | **Glue (cross-platform)** | **Proxy**     |
| -------------------------------- | --------------------------- | ------------------------- | ------------- |
| **Server**                       | Filament (PHP)              | **RUST**                  | Naïve Proxy   |
| **Client (macOS today)**         | SwiftUI                     | **RUST**                  | Naïve Proxy   |
| **Client (future Android/iOS/Win/Linux)** | Kotlin / Swift / C++ / GTK | **RUST**             | Naïve Proxy   |

The middle column is the same Rust crate everywhere — that is the
whole point of the design. Today on macOS it's `cool-tunnel-core`
(in [`core/`](./core)); on the server it'll be a sibling crate
sharing the same `ct-protocol` types; future client platforms reuse
the same protocol with a per-platform binary.

For the macOS app today:

- **`naive`** is the upstream protocol implementation — we don't fork
  or modify it. Updates are one click in **Settings → Naive Binary →
  Update** (downloads from upstream, lipo-merges arm64 + x86_64,
  ad-hoc signs, installs into Application Support).
- **`cool-tunnel-core`** is the Rust surface the Swift UI talks to:
  strict types, structured errors, JSON-over-stdio, domain validation,
  100 ms anomaly debouncer. Updates are one click in **Settings →
  Rust Core → Update** (downloads the standalone universal asset
  from the latest Cool Tunnel GitHub release, ad-hoc signs, installs
  into Application Support; takes effect on next launch).

Both have a **Test** button right next to Update that runs the same
checks (lipo arch slices, `--version` liveness, `SecStaticCodeCheckValidity`
signature) and shows a single green **OK** or red **NG** verdict
above the per-row breakdown.

### Modes

| Mode | What it does |
| --- | --- |
| **Smart** | System auto-proxy URL points at a generated PAC file. Domains in your `directDomains` list bypass the proxy; everything else goes through SOCKS. |
| **Global** | All TCP traffic on every active network service routed through the SOCKS listener. |
| **Local only** | naive runs on `127.0.0.1:1080` but the system proxy is disabled — connect to it manually from a browser / app that supports SOCKS. |

---

## Install

Download the latest release from
**[github.com/coo1white/cool-tunnel/releases][releases]** and pick one:

| Format | When to use it |
| --- | --- |
| `.dmg` | Standard macOS install: open, drag to *Applications* |
| `.pkg` | Apple Installer: double-click, follow prompts |
| `.zip` | Run in place: extract, drag to *Applications* (or run from anywhere) |

[releases]: https://github.com/coo1white/cool-tunnel/releases

### First launch (Gatekeeper)

Cool Tunnel is **ad-hoc signed** — there's no Apple Developer ID
behind it, so macOS shows the *"can't be opened because Apple cannot
check it for malicious software"* dialog the first time you run it.
Two ways past it:

1. **Right-click** *Cool tunnel.app* in *Applications* → **Open**, then
   confirm in the dialog. *Or:*
2. **System Settings → Privacy & Security**, scroll to the bottom,
   click **Open Anyway**.

You only need to do this once.

If you used the `.zip` and the right-click flow misbehaves, clear the
quarantine attribute manually:

```sh
xattr -dr com.apple.quarantine "/Applications/Cool tunnel.app"
```

### Configure your first profile

You need a NaiveProxy server. If you don't have one yet,
[`NaiveProxy_Server_Setup.md`](./NaiveProxy_Server_Setup.md) in this
repo walks through a Caddy + naive setup on Debian.

In Cool Tunnel:
1. Click *+* in the connection panel to add a profile.
2. Enter `naive+https://user:pass@your-server:443` in the *Server*
   field, your username, password, and a local SOCKS port (default
   `1080`).
3. Pick a mode (Smart / Global / Local only) and click **Start**.

Profile passwords are written to your macOS Keychain on save and
re-loaded transparently on launch.

---

## Build from source

Prerequisites:

- Xcode 16 or newer (project uses synchronized folders, requires the
  modern build system)
- Rust toolchain — `rustup` plus the `aarch64-apple-darwin` and
  `x86_64-apple-darwin` targets:
  ```sh
  rustup target add aarch64-apple-darwin x86_64-apple-darwin
  ```
- `shellcheck` (for script linting; `brew install shellcheck`)
- `swift format` (ships with the Xcode toolchain)

Clone, then:

```sh
# Pull the upstream naive binary (universal arm64 + x86_64) into
# COOL-TUNNEL/naive. Pins to a specific upstream tag and writes a
# sidecar manifest with SHA-256 hashes for audit.
scripts/fetch_naive.sh

# Optional sanity check: build cool-tunnel-core for both targets
# and confirm the lipo merge produces a fat binary.
CONFIGURATION=Release scripts/build_rust_core.sh

# Universal Release build with ad-hoc signing.
xcodebuild -scheme COOL-TUNNEL \
    -configuration Release \
    -derivedDataPath build/DerivedData \
    -destination "generic/platform=macOS" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM="" \
    clean build

# Pre-package security audit (codesign, universal slices, no embedded
# secrets, license + NOTICE present, entitlements review).
EXPECTED_VERSION=0.1.5.1 scripts/security_check.sh

# One-shot DMG + PKG + ZIP build with SHA-256 manifest.
scripts/package_release.sh 0.1.5.1
```

### Tests

```sh
cd core
cargo fmt --all -- --check
cargo clippy --release --all-targets -- -D warnings
cargo test --release             # 89 tests, ~2 s
```

The Rust core enforces `clippy::pedantic` and denies `unwrap_used`,
`expect_used`, `panic`, `todo`, `unimplemented` — so production code
paths can't trap.

### Linting the whole tree

```sh
cargo fmt --all -- --check                                              # Rust
swift format lint --recursive --strict --configuration .swift-format COOL-TUNNEL   # Swift
shellcheck debug_*.sh scripts/*.sh                                       # Bash
```

---

## Repository layout

```
COOL-TUNNEL/                  Swift app (synchronized folder, auto-included)
├── App/                      @main, AppDelegate (window lifecycle)
├── Core/                     CoreClient (subprocess IPC), TunnelOrchestrator (UI façade), Protocol (codable types)
├── Persistence/              KeychainStore, ProfileStore, SettingsStore
├── SystemIntegration/        AppSupportPaths, CodeSignVerifier, FirewallProbe,
│                             HostArchitecture, NaiveBinaryResolver, SystemProxyController
├── Views/                    HeaderView, ControlPanelView, ConnectionFormView,
│                             LogConsoleView, SettingsView, ContentView
├── naive                     Bundled NaiveProxy binary (universal, ad-hoc signed)
└── naive.upstream.json       SHA-256 manifest pinning the upstream NaiveProxy release
core/                         Rust engine crate (cool-tunnel-core)
├── src/
│   ├── domain/               Validated value types (Port, Server, Credentials, Profile)
│   ├── config/               naive config.json + PAC generation
│   ├── supervisor/           Process spawning, stdout/stderr piping, credential redaction
│   ├── monitor/              lsof-based anomaly probe
│   ├── diagnostics/          curl-based latency + connectivity probes
│   ├── util/debounce.rs      100 ms per-key anomaly debouncer (with stress test)
│   ├── protocol.rs           Wire format (Request / Response / Event)
│   ├── lib.rs / main.rs      JSON-over-stdio dispatch loop, semaphore-capped concurrency
│   └── redaction.rs          Credential masking for log lines
└── tests/                    Integration tests (round-trip, frame size, malformed input)
scripts/
├── fetch_naive.sh            Download upstream + lipo arm64+x64 → universal naive
├── build_rust_core.sh        Build cool-tunnel-core (universal Release / single-arch Debug)
├── security_check.sh         Pre-package audit
└── package_release.sh        DMG + PKG + ZIP one-shot
docs/
└── v0.1.5-roadmap.md         Layout / feature ideas for v0.1.5+ (clash-verge-rev research)
```

---

## Trade-offs and known limitations

- **Ad-hoc signing means Gatekeeper friction.** Users see the
  unidentified-developer dialog on first launch. Subscribing to the
  Apple Developer Program ($99/yr) and adding notarisation would
  remove this — at the cost of an annual fee and an Apple account.
- **Not sandboxed.** The app needs to spawn the bundled `naive`
  binary, call `/usr/sbin/networksetup`, and run `lsof`. Sandboxing
  is technically possible but would require a privileged helper for
  the system-proxy calls, which we deliberately avoid.
- **Single upstream binary.** Cool Tunnel wraps NaiveProxy
  specifically; it is not a clash / sing-box / V2Ray client. Pick the
  right tool for your protocol.
- **macOS only today.** Other platforms are on the roadmap below.

---

## Roadmap

The full design notes live in [`docs/v0.1.5-roadmap.md`](./docs/v0.1.5-roadmap.md);
this is the short version with status tags.

### Shipped in the v0.1.5.x line

- ✅ **Universal arm64 + x86_64 binary** — same `.app` for every Mac.
- ✅ **macOS 14 (Sonoma) floor** — every Mac since 2018.
- ✅ **One-tap mode switching** — Smart / Global / Local Only chips
  hot-swap modes without stopping.
- ✅ **Per-probe ms timing** in the live log for diagnostics +
  latency tests.
- ✅ **OK / NG verdict** on `Test` for both naive and Rust core.
- ✅ **Replaceable naive binary** with one-click Update from
  upstream NaiveProxy releases.
- ✅ **Replaceable Rust core** with one-click Update from Cool
  Tunnel GitHub releases (new in v0.1.5.8).
- ✅ **File-backed credentials** — no Keychain prompt before the UI
  appears, ready to use out of the box.
- ✅ **Inline Settings panel** — no modal sheet, Cmd+W returns to
  main view (new in v0.1.5.8).
- ✅ **Classic Macintosh theme + Monaco** for monospaced surfaces.
- ✅ **`PerformanceProfile`** auto-tunes animation density on
  older Intel hardware.
- ✅ **100 ms anomaly debouncer** with lazy pruning.
- ✅ **Whole-project secret scan** in `security_check.sh`.
- ✅ **Apache 2.0** licensed.

### Planned for v0.1.6 / v0.1.7

- ⏭️ **Menu-bar (NSStatusItem)** with quick toggles — start / stop,
  profile picker, current state.
- ⏭️ **Latency / IP-Geo card** in the header — see actual upstream
  IP and ping while running.
- ⏭️ **Settings → sidebar reorganisation** — once sections grow
  past five.

### Planned for v0.1.8 / v0.2.0

- ⏭️ **Live Connections pane** — host, bytes ↑↓, duration,
  originating process. Requires a Rust-side flow accountant via
  `lsof` / `nettop`.
- ⏭️ **Profile cards + subscription URL import** — auto-refresh
  intervals, drag-to-reorder.
- ⏭️ **Lightweight mode** — close GUI, keep proxy + menu bar
  alive.

### v0.2.0 — cross-platform

The big architectural beat. The whole project is structured so the
Rust crate (the **Glue** column above) is the same on every
platform; UI changes per platform; engine stays naive everywhere.

- 🛣️ **Server tier** — Filament (PHP) admin UI driving
  `ct-server-core` (Rust) on the same `ct-protocol` we already use,
  with `forwardproxy@naive` as the Caddy plugin.
- 🛣️ **Cross-platform clients** — Kotlin (Android), Swift (iOS),
  C++ (Windows), GTK (Linux). All share `ct-protocol` and a
  per-platform Rust core; each platform supplies its own naive
  build (or its OS's NaiveProxy port).
- 🛣️ **Component-style updates everywhere** — every platform's
  Settings exposes the same Test (OK / NG) + Update flow for both
  the Rust core and the engine, so updates are a single button
  click on every device.

### Honourable mentions (anytime)

- URL scheme handler (`cooltunnel://import?url=...`).
- WebDAV backup of profiles + settings.
- Custom CSS / accent colour theming.
- Per-mode tray icons.

If any of these matters most to you, file an issue with `[roadmap]`
in the title and I'll prioritise.

---

## Reporting security issues

Please report vulnerabilities **privately** via a
[GitHub Security Advisory](https://github.com/coo1white/cool-tunnel/security/advisories/new)
rather than as a public issue.

---

## License

Apache License 2.0 — see [LICENSE](./LICENSE) and [NOTICE](./NOTICE).

The bundled `naive` binary is BSD-3-Clause (see
[NOTICE](./NOTICE) for full attribution).

Read the [Disclaimer](./Disclaimer.md) before use.
