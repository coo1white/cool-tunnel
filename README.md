# Cool Tunnel 🐶

A small, friendly app for your Mac that helps you visit
websites blocked in your country. It runs the
[NaiveProxy][naiveproxy] protocol, which makes the connection
look like normal HTTPS traffic — the kind your browser uses
every day.

[naiveproxy]: https://github.com/klzgrad/naiveproxy

> **Please read first.** Cool Tunnel is a tool for getting around
> internet blocks. The [Disclaimer](./Disclaimer.md) covers what it
> is for, what it is not for, and the rules you should know before
> you use it.

---

## What you get

- **One app for every Mac.** Same `.app` works on Apple Silicon
  Macs (M1, M2, M3, M4) **and** older Intel Macs from 2018.
- **Easy to use.** Type your server, click a mode, you're online.
- **Soft, friendly look.** Cute Maltese-pup colour palette with
  the classic Mac feel from the 90s.
- **Nothing leaves your computer.** No tracking, no analytics, no
  cloud sync. Your password lives in a file on your Mac that only
  you can read.
- **Open source.** [Apache 2.0 licensed](./LICENSE) — read it,
  change it, build it yourself.

---

## Words you might not know

| Word | What it means |
| --- | --- |
| **Proxy** | A middle-man server. Your computer talks to the proxy, the proxy talks to the website. The website thinks the request came from the proxy, not you. |
| **NaiveProxy** | A specific kind of proxy that hides itself inside normal HTTPS traffic. Hard to detect or block. |
| **Server** | A computer somewhere on the internet that you (or someone you trust) set up to run NaiveProxy. Cool Tunnel is the **client** — the part that lives on your Mac. |
| **Profile** | One server's settings: address, username, password, port. You can save more than one. |
| **Smart / Global / Local** | Three ways Cool Tunnel can route your traffic. See below. |
| **Universal binary** | One file that works on both Apple Silicon and Intel chips. |
| **Ad-hoc signed** | The Mac knows the app hasn't been changed since I built it, but doesn't know who I am. macOS will warn you on the first launch — see Install below. |

---

## Three modes

Pick whichever fits what you're doing:

| Mode | What it does | When to use |
| --- | --- | --- |
| **Smart** | Routes most websites through the proxy, but lets a list of "direct" domains (like Chinese sites) skip the proxy. | Most of the time — fast and friendly. |
| **Global** | Sends *every* TCP connection through the proxy. | When even Smart mode is letting something through it shouldn't. |
| **Local** | Runs the proxy on your Mac at `127.0.0.1:1080` but doesn't change your system network settings. | When you want to point one specific app (a browser, say) at the proxy without affecting the rest of your computer. |

You can switch between them while the proxy is running — just
click a different mode chip.

---

## Install

1. Download the latest release from
   **[github.com/coo1white/cool-tunnel/releases][releases]**.
   Pick **`Cool-tunnel-v0.1.7.5.dmg`** if you're not sure.
2. Open the `.dmg`. A Finder window opens.
3. Drag **Cool tunnel.app** onto the **Applications** folder
   shortcut.
4. Open Applications, find **Cool tunnel**, and **right-click →
   Open** the *first* time. Click **Open** again in the dialog.

[releases]: https://github.com/coo1white/cool-tunnel/releases

That's it. From now on you can open it normally.

> **Why right-click → Open?** macOS asks before running an app
> that doesn't have a paid Apple developer signature. I don't pay
> for one, so the right-click trick tells macOS "I trust this".
> If the regular double-click doesn't work, do right-click →
> Open instead — the difference is just a one-time approval.

---

## First time setup

1. Open Cool Tunnel.
2. You'll see a blue hint banner that says "First time?
   Replace the template values below."
3. Fill in your **Server** (the address of your NaiveProxy
   server), **Username**, and **Password**.
4. Leave **Local Port** at `1080` unless you have a reason to
   change it.
5. Click **Smart**, **Global**, or **Local** to start the proxy.

The status pill at the top of the window will turn pink and
start pulsing — that means it's working.

> **Don't have a server yet?** See
> [NaiveProxy_Server_Setup.md](./NaiveProxy_Server_Setup.md). It
> walks through setting one up on a Debian server with Caddy.

---

## How it works (one picture)

```
┌─────────────────────┐
│   You + your Mac    │
│   (Cool Tunnel app) │
└─────────┬───────────┘
          │  encrypted HTTPS, looks like a normal browser
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

The censor sitting between you and your server only sees the
top arrow — encrypted traffic that looks identical to every
other HTTPS request on the internet.

---

## What's inside the app

If you peek at the code, the project is split into three parts.
The same shape applies to a future server-tier admin panel and
to future apps on Windows / Linux / iOS / Android — that's the
point of the design.

|                                   | UI                          | Glue (Rust) | Proxy        |
| --------------------------------- | --------------------------- | ----------- | ------------ |
| **Server (planned)**              | Filament (PHP)              | RUST        | Naïve Proxy  |
| **Mac (today)**                   | SwiftUI                     | RUST        | Naïve Proxy  |
| **Other clients (planned)**       | Kotlin / Swift / C++ / GTK  | RUST        | Naïve Proxy  |

The middle column — the "Glue" — is the same Rust crate
everywhere. On your Mac it's called `cool-tunnel-core` and lives
inside the app. On the server it'll be the same binary launched
with `--mode server`.

---

## Where things live on your Mac

| What | Where |
| --- | --- |
| The app itself | `/Applications/Cool tunnel.app` |
| Your saved password | `~/Library/Application Support/COOL-TUNNEL/credentials.json` (mode 0600 — only your account can read it) |
| The proxy config | `~/Library/Application Support/COOL-TUNNEL/config.json` |
| The smart-mode routing rules | `~/Library/Application Support/COOL-TUNNEL/smart-proxy.pac` |
| Updated naive (if you clicked Update) | `~/Library/Application Support/COOL-TUNNEL/naive-managed` |
| Updated engine (if you clicked Update) | `~/Library/Application Support/COOL-TUNNEL/cool-tunnel-core-managed` |

To completely uninstall, drag the app to the Trash and delete
the `~/Library/Application Support/COOL-TUNNEL` folder.

---

## Help

- **Check the live log** at the bottom of the window. Most
  problems explain themselves there.
- **Click Diag** while the proxy is running — it sends a test
  request and prints the timing.
- **Click Latency** to measure DNS, connect, TLS, and
  first-byte timings to a couple of test URLs.
- **Open Settings** (the gear button) → **Naive Binary** or
  **Rust Core** → **Test** to check whichever component you
  think might be off. Green **OK** = good; red **NG** = the
  message tells you what to fix.

---

## Updating without reinstalling the app

Open Settings (gear button) and you'll see two **Update**
buttons:

- **Naive Binary → Update** downloads the latest NaiveProxy from
  upstream, makes one universal file from the arm64 + x86_64
  versions, and adopts it as your engine.
- **Rust Core → Update** downloads the latest engine binary from
  the Cool Tunnel GitHub release. Takes effect on your next app
  launch.

Both are one click. No terminal, no recompiling.

---

## Compatibility

| Need | Detail |
| --- | --- |
| **Mac model** | Apple Silicon (any) or Intel from 2018 |
| **macOS** | 14 (Sonoma) or newer |
| **Disk** | About 23 MB |
| **Memory** | About 30 MB while running |
| **Admin password** | Never needed |

---

## For developers

The full technical README, including build steps and
architecture, lives in [CONTRIBUTING.md](./CONTRIBUTING.md).
The release-by-release changelog is in
[CHANGELOG.md](./CHANGELOG.md). The roadmap of features tracked
but not yet shipped is in
[docs/v0.1.5-roadmap.md](./docs/v0.1.5-roadmap.md). Security
reporting + threat model are in [SECURITY.md](./SECURITY.md).

A quick taste — running the engine binary as a server:

```sh
./cool-tunnel-core --mode server --listen 127.0.0.1:8787
curl http://127.0.0.1:8787/health
# → {"status":"ok"}
```

---

## Thank you

Cool Tunnel wraps the upstream
[NaiveProxy](https://github.com/klzgrad/naiveproxy) (BSD-3
licensed); without that project there'd be nothing to wrap.
Apple ships Monaco, Helvetica, and SF Pro Rounded with macOS —
those three fonts do most of the visual work. The rest is
careful packaging and a small Rust crate.

If Cool Tunnel helps you, that's the whole point.

---

## License

[Apache License 2.0](./LICENSE). Copyright + bundled-component
attribution in [NOTICE](./NOTICE). Read the
[Disclaimer](./Disclaimer.md) before you install. Report
security issues privately via [SECURITY.md](./SECURITY.md).
