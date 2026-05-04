<div align="center">

# Cool Tunnel 🐶

### *Open the web. Quietly.*

**A friendly Mac app that gives you private, uncensored internet — using
traffic that looks indistinguishable from a normal browser visit.**

[![Latest release](https://img.shields.io/github/v/release/coo1white/cool-tunnel?label=latest&color=ff6b8b)](https://github.com/coo1white/cool-tunnel/releases/latest)
[![License: Apache-2.0](https://img.shields.io/badge/license-Apache--2.0-1c5cdc)](./LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%20Sonoma%2B-blue)](#compatibility)
[![CI](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml/badge.svg)](https://github.com/coo1white/cool-tunnel/actions/workflows/ci.yml)
[![Engine: Rust](https://img.shields.io/badge/engine-Rust-orange)](./core)
[![Universal binary](https://img.shields.io/badge/Mac-Apple%20Silicon%20%2B%20Intel-success)](#compatibility)

<!-- VISUAL ANCHOR -->
<!--
  Replace with a clean screenshot of the running app
  (Header pill in pink-active, mode chips, log scrolling).
  Recommended: 1200×750 PNG, 2x retina,
  saved to docs/screenshots/hero-v0.1.7.x.png
-->

<img src="docs/screenshots/hero.png" alt="Cool Tunnel running in Smart mode — pink status pill, log streaming a successful connection" width="780" />

</div>

---

> **Read this first.** Cool Tunnel is a tool for getting around
> internet blocks. The [Disclaimer](./Disclaimer.md) covers what
> it is for, what it is *not* for, and the rules you should know
> before you use it. By installing, you agree you've read it.

---

## Why Cool Tunnel?

There are dozens of tools that promise "private internet." Most ask you
to trust a logo, a server somewhere, or a subscription page. Cool Tunnel
is different on three things that matter:

**1. The connection actually looks normal.**
Most circumvention tools leave a fingerprint — a TLS shape, a packet
size pattern, a port number — that a moderately funded censor can spot.
Cool Tunnel uses [NaiveProxy](https://github.com/klzgrad/naiveproxy),
which makes your traffic look identical to Chrome talking to a regular
HTTPS website. There's nothing to spot.

**2. The code is on your computer, not a service.**
Cool Tunnel is a `.app` you install. Your password lives in a file
*on your disk* (mode 0600 — only your user can read it). Nothing is
sent to a third party. There is no account, no telemetry, no cloud
sync. If you delete the app, the only thing left is what you put in
your own NaiveProxy server.

**3. You can audit every line.**
The whole project — the Swift app, the Rust engine, the build
scripts — is on GitHub under [Apache-2.0](./LICENSE). You don't have
to take anyone's word for what it does. You can read it. So can a
journalist, a security researcher, or anyone else who wants to verify.

> **The philosophy:**
> *Security as the foundation. Performance as the ballast.*
> Both are written into the code; neither was added later.

---

## What you actually get (no jargon)

| What it says under the hood | What that means for you |
| --- | --- |
| **Built in [Rust](https://www.rust-lang.org/)** (the engine) | Memory-safe by design. Won't crash your Mac. Won't leak your password into the wrong place because some pointer was misused. The whole class of bugs that takes down other privacy tools is structurally impossible here. |
| **[NaiveProxy](https://github.com/klzgrad/naiveproxy) protocol** | Your encrypted traffic *literally* looks like a normal Chrome browser visiting a normal HTTPS website. Censorship systems that block "VPN-shaped" packets cannot identify it as anything to block. |
| **[Axum](https://github.com/tokio-rs/axum) + [Tokio](https://tokio.rs/) async runtime** | The engine handles thousands of small connections at once without slowing your Mac down. The whole proxy uses about 30 MB of memory while it's running — less than a single browser tab. |
| **Universal binary** | One `.app` file that works on every Mac since 2018 — Apple Silicon (M1/M2/M3/M4) AND older Intel models. No "wrong build for your chip" mistake possible. |
| **Hardened runtime + ad-hoc signed** | macOS knows the app hasn't been tampered with since I built it. Library injection by other software is blocked at runtime. |
| **No accounts, no telemetry, no cloud** | Cool Tunnel never phones home. The only outbound traffic from the app itself is to GitHub when *you* click "Check for Updates." |

---

## ⚡ 5-Minute Quick Start

Designed so a non-technical user can finish in one sitting.

> **Recommended path** for most people: download the prebuilt `.dmg`
> below. No terminal. No `cargo build`. No "open Xcode and pray."

### Step 1 — Download the latest `.dmg` 📥

Go to **[github.com/coo1white/cool-tunnel/releases/latest][releases]**.
Pick **`Cool-tunnel-v0.1.7.20.dmg`** if you're not sure which one.

### Step 2 — Drag it into Applications 📂

Double-click the `.dmg`. A Finder window opens with a Cool Tunnel
icon and an **Applications** folder shortcut. Drag the icon onto
the shortcut.

### Step 3 — First launch (one-time approval) 🔑

Open `/Applications`, find **Cool tunnel**, and **right-click → Open**.
Click **Open** again in the dialog macOS shows you. After that, you
can open it normally — every time.

> **Why right-click?** Cool Tunnel is signed with my own key, not
> Apple's $99/year Developer ID. macOS shows a warning the first
> time it sees that. Right-click → Open is the user-side "I trust
> this" approval. One-time only.

### Step 4 — Fill in your server ✏️

You need a NaiveProxy server somewhere on the internet. If you have
one, type its address, your username, and your password into the
form. Leave **Local Port** at `1080` unless you have a reason.

> **Don't have a server yet?** Spin one up in 15 minutes following
> [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md). It walks
> through a Debian server with Caddy.

### Step 5 — Click a mode 🚀

| Click... | When |
| --- | --- |
| **Smart** | Most of the time. Routes blocked sites through your server, lets local sites (Chinese, Korean, etc.) skip the proxy for speed. |
| **Global** | Maximum privacy — every TCP connection routes through your server. |
| **Local** | The proxy listens on `127.0.0.1:1080` but doesn't change your system network settings. Useful for pointing one specific app at it. |

The status pill at the top of the window will turn pink and start
pulsing — that means it's working. Open your browser and try a
blocked site.

[releases]: https://github.com/coo1white/cool-tunnel/releases/latest

---

## How it works (one picture)

```
┌─────────────────────┐
│   You + your Mac    │
│   (Cool Tunnel app) │
└─────────┬───────────┘
          │  encrypted HTTPS — looks like a normal Chrome visit
          ▼
┌─────────────────────┐
│  Your NaiveProxy    │
│  server somewhere   │  ← you set this up
└─────────┬───────────┘
          │  the actual website request
          ▼
┌─────────────────────┐
│  google.com /       │
│  any-website.com    │
└─────────────────────┘
```

A network observer between you and your server only sees the **top
arrow** — encrypted traffic indistinguishable from every other HTTPS
request on the internet. Your server (which you control) does the
routing on your behalf.

---

## Security & Ethics — the *ballast*

This is what makes the project boring to attack and reliable in practice.

### What protects you

| Defence | What it does |
| --- | --- |
| **Hardened runtime** | macOS blocks library-injection and runtime tampering against the app process. Enabled in v0.1.7.17. |
| **Mode-0600 credentials** | Your NaiveProxy password lives in `~/Library/Application Support/COOL-TUNNEL/credentials.json`, readable only by your user account. Not Keychain (intentional — see [SECURITY.md](./SECURITY.md)). Not UserDefaults. |
| **SHA-256 update pinning** | When you click "Update Cool Tunnel", the app downloads a SHA-256 manifest separately and refuses to install if the bytes don't match. CDN tampering can't slip a substituted binary past it. |
| **Trusted-host redirect guard** | All three update flows (app, NaiveProxy, engine) refuse any HTTP redirect that leaves `*.github.com` / `*.githubusercontent.com`. |
| **Hard-link + symlink-escape rejection** | A malicious .zip can't plant `Resources/foo` as a hard link to `/etc/passwd`. The extraction walker rejects it. |
| **Anomaly auto-stop** | If `naive` ever binds outside `127.0.0.1`, the engine auto-stops the proxy within one monitor probe (≤5 seconds). |
| **Log redaction** | Every log line that touches credentials, `Authorization` / `Cookie` headers, or JSON `password` fields is redacted before reaching the live log. |

### What it deliberately does NOT do

- **No sandbox** — the app needs to spawn `naive` and call
  `networksetup`. App Sandbox would block both. Hardened runtime
  + ad-hoc-signed binary + audited surfaces are the substitute.
- **No notarization** — there's no Apple Developer ID behind this
  project. The right-click → Open dance is the user-side trust gesture.
- **No cloud, ever** — the only outbound traffic from the app is to
  GitHub when you click an Update button. Profile changes, log
  entries, diagnostics — all of it stays local.

### What it cannot defend against

Honesty matters here:
- A malicious app running as your macOS user (anything in
  `~/Library/Application Support/COOL-TUNNEL/` is readable to every
  process running as you).
- Physical access to an unlocked Mac.
- A compromised NaiveProxy server you point Cool Tunnel at — it can
  log every request you proxy through it.
- Bit-flips inside GitHub's CDN during an update of the bundled
  NaiveProxy or Rust engine — SHA pinning for these is targeted for
  v0.1.8.

The full threat model is in [SECURITY.md](./SECURITY.md).

---

## FAQ for Newbies

> **Is this safe?**
> The app's threat model is published in [SECURITY.md](./SECURITY.md)
> — read it. The short answer: against a network-level censor between
> you and your server, yes — the connection is encrypted and shaped
> like normal HTTPS. Against a malicious server *you* picked, no app
> can save you. Pick a server you trust (or run your own).

> **Is it free?**
> Yes. Apache-2.0 licensed, no paid tier, no premium server, no
> donation pop-up. The app itself is free; you'll need to pay for a
> server you control (any Linux VPS at $3–5/month is enough).

> **Do I need a server?**
> Yes. Cool Tunnel is the *client* part. You set up a NaiveProxy
> server (or get access to a friend's). The
> [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md) walks
> through it on Debian + Caddy in about 15 minutes.

> **Will my employer / school / ISP see what I'm doing?**
> They'll see encrypted HTTPS-looking traffic to your server's IP
> address. They'll *not* see which sites you're visiting through it.
> Whether they can correlate the connection with you depends on
> your local situation; Cool Tunnel doesn't claim anonymity, only
> traffic-shape indistinguishability.

> **Will it slow my internet down?**
> About 5–10 ms of added latency for the encryption round-trip,
> usually invisible. Throughput is bottlenecked by your server's
> egress bandwidth, not by Cool Tunnel itself. The Rust engine
> handles many simultaneous connections at <30 MB memory.

> **Can I use this for [BitTorrent / banking / online games]?**
> Banking — yes, totally fine, end-to-end encryption stays end-to-end.
> Games — works for most; some games have their own latency-sensitive
> protocols that don't love proxies. BitTorrent — technically works
> but is hard on a single-user server; check whether your server's
> provider allows it before you start seeding.

> **What if my Mac is older than 2018?**
> macOS 14 Sonoma is the floor. If your Mac runs macOS 14, Cool
> Tunnel runs. If your Mac stops at macOS 13 or earlier, this isn't
> the tool for you (and Apple has dropped security support for those
> macOSes anyway).

> **What happens if I uninstall?**
> Drag the app to the Trash, then delete
> `~/Library/Application Support/COOL-TUNNEL/`. That's it. No
> launch agents, no kernel extensions, no leftover registry. The
> system proxy settings revert when you click Stop or quit the app.

> **What's the bundled "naive" binary?**
> The actual NaiveProxy client. We bundle a universal-binary build of
> [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy) (BSD-3
> licensed) as `Contents/Resources/naive`. The Settings → Naive Binary
> → Update button refreshes it from upstream.

---

## Updating without reinstalling

Open Settings (⚙️ button) and you'll see three **Update** buttons:

| Update | What it does |
| --- | --- |
| **Cool Tunnel → Update** | Downloads the latest version of the app itself, verifies it against a published SHA-256 manifest, and relaunches when ready. |
| **Naive Binary → Update** | Pulls the latest NaiveProxy from upstream, makes one universal file from the arm64 + x86_64 versions, ad-hoc signs it. |
| **Rust Core → Update** | Pulls the latest engine binary from the Cool Tunnel release. Takes effect on the next app launch. |

All three are one click. No terminal, no recompiling. Each
validates the URL is on a trusted GitHub-served host and caps the
download size before adopting the new file.

---

## Where things live on your Mac

| What | Where |
| --- | --- |
| The app itself | `/Applications/Cool tunnel.app` |
| Your saved password | `~/Library/Application Support/COOL-TUNNEL/credentials.json` (mode 0600) |
| The proxy config | `~/Library/Application Support/COOL-TUNNEL/config.json` |
| Smart-mode routing rules | `~/Library/Application Support/COOL-TUNNEL/smart-proxy.pac` |
| Updated `naive` (if you clicked Update) | `~/Library/Application Support/COOL-TUNNEL/naive-managed` |
| Updated engine (if you clicked Update) | `~/Library/Application Support/COOL-TUNNEL/cool-tunnel-core-managed` |
| Relaunch helper log | `~/Library/Logs/cool-tunnel/relaunch.log` |

To completely uninstall: drag the app to Trash, then delete the
`~/Library/Application Support/COOL-TUNNEL` folder.

---

## Compatibility

| Need | Detail |
| --- | --- |
| **Mac model** | Any Mac that runs macOS 14 (Apple Silicon, or 2018-or-newer Intel + 2017 iMac Pro) |
| **macOS** | 14 (Sonoma) or newer |
| **Disk** | About 45 MB installed |
| **Memory** | About 30 MB while running |
| **Admin password** | Never needed |

---

## Need help?

When something doesn't work, in this order:

1. **Check the live log** at the bottom of the window. Most
   problems explain themselves there.
2. **Click Diag** while the proxy is running — it sends a test
   request and prints the timing.
3. **Click Latency** to measure DNS, connect, TLS, and first-byte
   timings to a couple of test URLs.
4. **Open Settings** → **Naive Binary** or **Rust Core** → **Test**
   to check whichever component you think might be off. Green **OK**
   = good; red **NG** = the message tells you what to fix.
5. **Open an [issue](https://github.com/coo1white/cool-tunnel/issues)**
   — paste the relevant log lines. Credentials are auto-redacted
   before they reach the log, so it's safe to share.

For security-sensitive issues, please report privately via the
process in [SECURITY.md](./SECURITY.md).

---

## For developers

Architecture, build steps, and contribution guide:
[CONTRIBUTING.md](./CONTRIBUTING.md). Release-by-release changelog:
[CHANGELOG.md](./CHANGELOG.md). Security threat model:
[SECURITY.md](./SECURITY.md). Long-term support contract:
[SUPPORT.md](./SUPPORT.md).

A quick taste — running the engine binary as a server:

```sh
./cool-tunnel-core --mode server --listen 127.0.0.1:8787
curl http://127.0.0.1:8787/health
# → {"status":"ok"}
```

---

## License — and why that matters to you

Cool Tunnel is licensed under
**[Apache-2.0](./LICENSE)**, deliberately:

- **Open** — every line of source code is on GitHub. You can read
  it. So can a journalist, a security researcher, anyone else who
  wants to verify what the app does.
- **Transparent** — every release is reproducible from the public
  source via `cargo build --locked` + `xcodebuild`.
- **Legally vetted** — Apache-2.0 includes an explicit *patent
  grant* that other permissive licenses (MIT, BSD) lack. If a future
  patent claim ever surfaces against the underlying technology, the
  grant protects you, the user, by name.
- **Forkable** — anyone is free to fork, modify, and redistribute
  Cool Tunnel under the same license. The community can keep the
  project alive even if I don't.

> **For users, this means:** the code is open, transparent, and
> legally vetted for your protection. You're not depending on me
> staying interested or staying alive. You're depending on the
> source, which is published and stays published.

Bundled-component attribution lives in [NOTICE](./NOTICE). Read
the [Disclaimer](./Disclaimer.md) before you install. Report
security issues privately via the process in
[SECURITY.md](./SECURITY.md).

---

## Thank you

Cool Tunnel wraps the upstream
[NaiveProxy](https://github.com/klzgrad/naiveproxy) (BSD-3 licensed);
without that project there'd be nothing to wrap. Apple ships
Monaco, Helvetica, and SF Pro Rounded with macOS — those three
fonts do most of the visual work. The rest is careful packaging
and a small Rust crate.

If Cool Tunnel helps you, that's the whole point.
