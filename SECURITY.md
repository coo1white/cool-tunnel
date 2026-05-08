# Security

## Reporting a vulnerability

Please report security issues **privately** via a
[GitHub Security Advisory][advisory] rather than as a public
issue. We'll respond within a few days.

[advisory]: https://github.com/coo1white/cool-tunnel/security/advisories/new

## Historical credential leak — must rotate

Pre-v0.1.5.3 of this repository contained a real working
NaiveProxy server password (it begins with `1999…` and ends with
`…Wry` — the security_check pattern guard prevents printing it
in full here) on the development server `naive.example.com`,
inside three files:

- `debug_proxy.sh`
- `debug_step_by_step.sh`
- `NaiveProxy_Server_Setup.md` (as a Caddyfile example)

These files were deleted or scrubbed in v0.1.5.3, and a pinned
check in `scripts/security_check.sh` rejects any future commit
that tries to reintroduce the literal. **However:** git history is
forever. Anyone who clones the repo and runs `git log -p` between
commits dated 2026-05-02 and the v0.1.5.3 commit can still recover
the value.

**If you used that literal (or anything from those files) verbatim
on a real server: rotate it now.** Generate a new strong password
(`openssl rand -base64 24` is fine), update the Caddyfile on your
server, and reload Caddy. Then update your Cool Tunnel profile
with the new password.

The development server itself is no longer reachable, so the
credential is no longer live, but the principle stands: never
copy example credentials from any guide — including this one —
into production.

## Threat model — what Cool Tunnel does and doesn't protect

**Does protect:**

- Profile passwords on disk: stored in
  `~/Library/Application Support/COOL-TUNNEL/credentials.json`
  with mode 0600 (user-only read/write); the parent directory is
  mode 0700.
- Profile passwords in transit: TLS-encrypted by NaiveProxy
  itself (the bundled binary is just upstream `naive`).
- Code-signature integrity: the bundled engine and naive binary
  are both `SecStaticCodeCheckValidity`-verified before each
  spawn. Tampering with either fails fast.
- Anomaly auto-stop: if naive ever binds outside `127.0.0.1`,
  Cool Tunnel auto-stops the proxy within one monitor probe
  (5 seconds).
- Log redaction: every `naive` log line that mentions
  credentials, `Authorization` headers, or `Cookie` headers is
  redacted before reaching the live log or any persisted output.

**Does NOT protect against:**

- A malicious app running as your macOS user. Anything in
  `~/Library/Application Support/COOL-TUNNEL/` is readable by
  every process running as you. macOS app sandboxing is
  intentionally off because the app needs to spawn `naive` and
  call `networksetup`.
- Physical access. If someone has your unlocked Mac, they can
  read your credentials file with `cat`.
- A compromised NaiveProxy server. Cool Tunnel is the *client*;
  if the server is malicious, it can log every request you proxy
  through it.
- macOS Gatekeeper bypass. Cool Tunnel is ad-hoc signed (no
  Apple Developer ID); the right-click → Open flow is the
  intended one-time approval. Anyone who can run code as you can
  also click that prompt.
- **Bit-flips inside GitHub's release-asset CDN during a
  NaiveProxy binary update.** `NaiveUpdater` downloads the
  upstream NaiveProxy tarballs (klzgrad/naiveproxy) without a
  Cool Tunnel-published SHA-256 manifest — we don't control
  upstream's release process, so generating a trusted manifest
  requires manual verification per release. The redirect
  guard + 100 MB size cap close most of the threat surface,
  but a CDN-internal byte tamper between upstream's publish
  and the user's click would not be caught. **Targeted for a
  future v2.x release**: a Cool Tunnel-side manifest of
  "trusted Naive versions and hashes" that the in-app updater
  pins against. (As of v2.0.2, NaiveUpdater compares against
  `lastInstalledTag` to avoid redundant downloads, but doesn't
  yet SHA-pin the binary itself.)

  As of **v0.1.7.18**, the **Rust Core (`cool-tunnel-core`)
  binary IS SHA-pinned**: the in-app updater downloads the
  matching `Cool-tunnel-vX.Y.Z.sha256` manifest alongside
  the binary, parses the line for
  `cool-tunnel-core-vX.Y.Z-universal`, and refuses to install
  on any hash mismatch. A release without the manifest is
  skipped (not adopted unverified). This closes the equivalent
  gap for the engine binary and matches the App self-updater
  posture.

## Anonymity is NOT promised

Cool Tunnel is a **proxy client**, not an **anonymity tool**.
Forwarding traffic through a server you control hides the
*destination* from the network in front of you, but it does
NOT make you anonymous. Specifically, Cool Tunnel does not
defend against:

- **Server-side logging.** The NaiveProxy server you connect to
  sees every destination URL, every IP you connect from, every
  byte volume. If the operator (or anyone with access to the
  server) is hostile, they have a complete log of your usage.
  The server is the trust boundary; pick the operator like
  you'd pick a doctor.
- **Traffic correlation.** A passive observer with visibility
  on both sides of the tunnel — your network and the server's
  network, or two points along the path — can correlate
  request/response timing and packet sizes to deanonymise the
  flow. NaiveProxy's HTTP/2 cover-traffic mitigates this against
  unsophisticated observers; a state-level adversary with
  bandwidth taps on both endpoints is not in scope.
- **TLS-fingerprint analysis.** NaiveProxy sends a Chrome-style
  TLS Client Hello to blend in. This is sufficient against
  passive DPI but not against active probing or a vendor-specific
  fingerprint database. Read the upstream
  [klzgrad/naiveproxy](https://github.com/klzgrad/naiveproxy)
  threat model — Cool Tunnel inherits it verbatim.
- **Endpoint compromise.** A malicious browser extension, a
  shared user account, or a kernel-level rootkit on your Mac
  sees the cleartext traffic *before* it reaches Cool Tunnel.
  Encryption-in-transit doesn't help if the endpoint is
  compromised.
- **Bandwidth correlation against video / streaming.** Even
  with TLS, the bandwidth signature of streaming a specific
  video at a specific resolution is recognisable to a
  sufficiently-resourced observer.

If your threat model is "**passive ISP-level censorship that
blocks specific domains**" — Cool Tunnel does what it says.
If your threat model is "**state-level adversary actively trying
to identify and prosecute me**" — Cool Tunnel is not enough on
its own. Pair with Tor, run on a separate device, vary your
network path, and be careful about endpoint metadata. Plenty of
people use it for the first threat model; don't treat the second
as covered by this software.

## Maintainer key fingerprint

Releases are not yet signed by a maintainer key (deferred —
ad-hoc binary signing only, see "Apple Developer ID" below).
A future revision will publish a Sigstore / minisign / GPG
fingerprint here so users can verify a release artefact was
authored by the maintainer rather than substituted via a CDN
takeover. Until then, the trust anchor is "TLS to GitHub +
SHA-256 manifest pin on `cool-tunnel-core` (per-release)" — see
the "What runs over the network" section.

## Apple Developer ID

Cool Tunnel is **not** notarised by Apple — there's no Apple
Developer Program subscription behind this project. The .app is
ad-hoc signed (`codesign --sign -`). On first launch macOS will
ask you to right-click → Open, or to approve the app under
**System Settings → Privacy & Security → Open Anyway**. You only
need to do this once.

If you want to verify the binaries match what we built, the SHA-256
hashes for every release artefact are listed in the GitHub release
notes and inside the `dist/Cool-tunnel-vX.Y.Z.sha256` manifest
that ships in each release.

## What runs over the network

Cool Tunnel makes outbound HTTPS calls to:

- Your NaiveProxy server (the one you configure in the profile)
- `https://api.github.com/repos/klzgrad/naiveproxy/releases` —
  only when you click **Settings → Naive Binary → Update**
- `https://api.github.com/repos/coo1white/cool-tunnel/releases`
  — only when you click **Settings → Rust Core → Update**
- `https://github.com/.../releases/download/...` — only during
  an Update, to fetch the actual binary
- `https://ipinfo.io/ip` — only when you click **Diag**
- `https://www.baidu.com` and
  `https://www.google.com/generate_204` — only when you click
  **Latency Test**

Nothing else. No telemetry, no analytics, no remote configuration.
