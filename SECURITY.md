# Security

## Reporting a vulnerability

Report security issues **privately** via a [GitHub Security Advisory][advisory] rather than as a public issue. We respond within a few days.

[advisory]: https://github.com/coo1white/cool-tunnel/security/advisories/new

## Historical credential leak — v2.x only

Pre-v0.1.5.3 of this repository contained a real working NaiveProxy server password on a development server, in three files since deleted or scrubbed. `scripts/security_check.sh` rejects any future commit that tries to reintroduce the literal, but git history is forever — anyone who clones the repo can still recover the value. The v3.0.0 sing-box pivot replaced password auth with VLESS UUIDs, so the literal is not relevant to current installs, but if you ever copied it verbatim onto a v2.x Caddy + NaiveProxy server: rotate it.

## Threat model — what Cool Tunnel does and doesn't protect

**Does protect:**

- Profile credentials on disk: `~/Library/Application Support/COOL-TUNNEL/credentials.json` is mode 0600; the parent directory is mode 0700.
- Profile credentials in transit: VLESS + Reality wraps the credential exchange in TLS to the operator-controlled VPS, with Reality providing SNI cover.
- Code-signature integrity: the bundled engine and `sing-box` binary are `SecStaticCodeCheckValidity`-verified before each spawn.
- Anomaly auto-stop: if `sing-box` ever binds outside `127.0.0.1`, Cool Tunnel auto-stops the proxy within one monitor probe (5 seconds).
- Log redaction: every `sing-box` log line that mentions credentials, UUIDs, or Reality keys is redacted before reaching the live log or any persisted output.
- Binary SHA-pinning: the in-app updater downloads the matching `Cool-tunnel-vX.Y.Z.sha256` manifest alongside the binary and refuses to install on any hash mismatch. The bundled `sing-box` binary itself is pinned in `COOL-TUNNEL/singbox-core.upstream.json` and verified by `scripts/fetch_singbox-core.sh`.

**Does NOT protect against:**

- A malicious app running as your macOS user. Anything under `~/Library/Application Support/COOL-TUNNEL/` is readable by every process running as you. macOS app sandboxing is intentionally off because the app needs to spawn `sing-box` and call `networksetup`.
- Physical access. If someone has your unlocked Mac, they can read your credentials file with `cat`.
- A compromised server. Cool Tunnel is the *client*; if your sing-box server is malicious, it can log every request you proxy through it.
- macOS Gatekeeper bypass. Cool Tunnel is ad-hoc signed (no Apple Developer ID); the right-click → Open flow is the intended one-time approval.

## Anonymity is NOT promised

Cool Tunnel is a **proxy client**, not an **anonymity tool**. Forwarding traffic through a server you control hides the destination from the network in front of you, but it does NOT make you anonymous. It does not defend against:

- **Server-side logging.** The sing-box server you connect to sees every destination URL, every IP you connect from, every byte volume. Pick the operator like you'd pick a doctor.
- **Traffic correlation.** A passive observer with visibility on both sides of the tunnel can correlate timing and packet sizes to deanonymise the flow. Reality's SNI mimicry mitigates passive DPI; a state-level adversary with bandwidth taps on both endpoints is not in scope.
- **TLS-fingerprint analysis.** Reality presents a TLS Client Hello that mimics a chosen `dest_host`. Sufficient against passive DPI but not against active probing of the masked dest. Read the upstream [SagerNet/sing-box](https://github.com/SagerNet/sing-box) and [Reality](https://github.com/XTLS/REALITY) threat models — Cool Tunnel inherits them verbatim.
- **Endpoint compromise.** A malicious browser extension, shared user account, or kernel-level rootkit sees cleartext traffic *before* it reaches Cool Tunnel.
- **Bandwidth correlation against video / streaming.** Even with TLS, the bandwidth signature of streaming a specific video at a specific resolution is recognisable to a sufficiently-resourced observer.

If your threat model is "passive ISP-level censorship that blocks specific domains" — Cool Tunnel does what it says. If your threat model is "state-level adversary actively trying to identify and prosecute me" — Cool Tunnel is not enough on its own.

## Maintainer key fingerprint

Releases are not yet signed by a maintainer key (ad-hoc binary signing only). A future revision will publish a Sigstore / minisign / GPG fingerprint here. Until then, the trust anchor is TLS to GitHub + SHA-256 manifest pin on `cool-tunnel-core` and on the bundled `sing-box` binary.

## Apple Developer ID

Cool Tunnel is **not** notarised by Apple. The .app is ad-hoc signed (`codesign --sign -`). On first launch macOS will ask you to right-click → Open, or to approve under **System Settings → Privacy & Security → Open Anyway**. SHA-256 hashes for every release artefact are listed in the GitHub release notes and inside `dist/Cool-tunnel-vX.Y.Z.sha256`.

## What runs over the network

Cool Tunnel makes outbound HTTPS calls to:

- Your sing-box server (the one you configure in the profile)
- `https://api.github.com/repos/SagerNet/sing-box/releases` — only when you click **Settings → sing-box Binary → Update**
- `https://api.github.com/repos/coo1white/cool-tunnel/releases` — only when you click **Settings → Rust Core → Update** or **Check for Updates**
- `https://github.com/.../releases/download/...` — only during an Update, to fetch the actual binary
- `https://ipinfo.io/ip` — only when you click **Diag**
- `https://www.baidu.com` and `https://www.google.com/generate_204` — only when you click **Latency Test**

Nothing else. No telemetry, no analytics, no remote configuration.
