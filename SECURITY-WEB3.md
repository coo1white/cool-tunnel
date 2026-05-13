# SECURITY-WEB3.md

Privacy posture for operators routing Web3 / JSON-RPC / wallet
traffic through Cool Tunnel. Sibling to [SECURITY.md](./SECURITY.md);
that file covers the project's overall security model, this one
narrows to the question:

> If I route my wallet, RPC, and signing traffic through Cool
> Tunnel, what can Cool Tunnel see, log, or persist?

The honest answer below distinguishes **architectural
guarantees** (verified by code review and pinned by regression
tests) from **known surfaces** (places where information about
traffic CAN leak if an error fires or an operator triggers a
diagnostic).

## Threat model

The user is routing transport-layer traffic through Cool Tunnel
where any of the following would be a privacy or security harm:

- The destination hostname (RPC provider, indexer, bridge,
  validator endpoint, custodial wallet API).
- The request path or query string (often carries API keys
  embedded as path segments: `/v2/<API-KEY>/method`).
- The request or response body (JSON-RPC payloads carry wallet
  addresses, transaction hashes, signed transactions, balances,
  approval messages, message hashes).
- The user's home IP address (tied to identity via geolocation +
  on-chain activity correlation).
- The fact that the user is using Cool Tunnel at all (the proxy
  client itself is local-only; the data plane sees only TLS
  to the operator's VPS).

The actor model we defend against is roughly:

- A networked observer at the user's ISP / Wi-Fi / captive
  portal that can see TLS metadata but not payload.
- A future operator-mistake scenario where the user shares
  a support transcript, a screenshot of the live log, or a
  Time Machine snapshot containing the Cool Tunnel
  Application Support directory.
- An app-level bug that accidentally logs or persists data
  the operator never intended to capture.

## What Cool Tunnel does NOT see, ever

These are **architectural guarantees**, not "best-effort"
behavior. The code physically cannot do these things without a
breaking-change PR that anyone reviewing would catch:

- **HTTPS CONNECT payloads.** Cool Tunnel hands inbound traffic
  to the bundled `naive` binary via a SOCKS5 listener on
  `127.0.0.1`. `naive` forwards through an HTTPS CONNECT tunnel
  to the operator-controlled VPS, which forwards to the
  destination. The Cool Tunnel app (Swift UI + Rust core)
  **never decrypts, parses, or stores** anything inside that
  tunnel. JSON-RPC bodies, signed transactions, wallet
  addresses, and method names exist only inside the HTTPS
  payload between the user's browser/wallet and the destination
  endpoint.

- **The destination URL of routed traffic.** The data plane
  delivers TLS bytes; the Cool Tunnel app does not log per-
  request destinations. The system proxy routes traffic to
  `127.0.0.1:<port>`; from `naive`'s point of view the
  destination is visible (it's the CONNECT target), but
  `naive`'s default verbosity is quiet — it logs errors, not
  per-request URLs.

- **Telemetry endpoints, identity services, analytics.** None
  exist. Code search verified. There is no `POST` to any
  third-party service from the Cool Tunnel app or the Rust
  core in normal operation. The diagnostic probes that DO
  reach external endpoints (`https://ipinfo.io/ip`,
  `https://www.google.com/generate_204`, `https://www.baidu.com`)
  are hard-coded canaries used only when the operator clicks
  "Run Diagnostics" or "Latency" — never auto-run.

- **Process arguments that expose credentials.** `naive` is
  spawned with argv `[<binary>, <config-path>]` only. The
  basic-auth username/password live inside the 0o600 config
  file at `~/Library/Application Support/.../config.json`;
  they never appear in `ps`, in the engine's stdout/stderr,
  in OS-wide process listings, or in audit-trail tools that
  read argv.

- **Wallet-specific behavior.** No seed-phrase handling, no
  transaction parsing, no signing flows, no wallet permissions.
  Cool Tunnel is transport-neutral. A wallet running through
  it is opaque to it.

## What Cool Tunnel DOES persist, and where

Three pieces of state live on disk, all under
`~/Library/Application Support/space.coolwhite.cooltunnel/`:

1. **`config.json`** (mode 0600). Carries the operator's
   `https://user:pass@host:port` proxy URL — generated fresh
   per Start, atomically written via `RestrictedFile.write`
   with `O_CREAT|O_EXCL` (no umask race). Deleted on graceful
   Stop. Time Machine excluded via
   `setResourceValues(.isExcludedFromBackup)` on the
   parent directory (since v2.0.38 with logging if exclusion
   fails).

2. **`credentials.json`** (mode 0600). Base64-encoded profile
   passwords. Same atomic-write discipline. Same Time Machine
   exclusion. Migrated from the macOS Keychain on first run
   under the file-credential backend (the migration path is
   regression-tested per H2/H3 in the v2.0.38 audit).

3. **`lifecycle-telemetry.jsonl`** (mode 0600, append-only).
   Local state-machine transitions: bootstrap, start, stop,
   anomaly classification, error-layer attribution, sleep/wake.
   **Every `message` and `details` value is run through
   credential redaction** (regression-tested in
   `LifecycleTelemetryRedactionTests`) before append.
   Schema-versioned for future evolution.

The telemetry file is what an operator might share in a support
transcript. Treat it as sensitive: it contains the *shape* of
your session (when you started, what mode you used, what error
layer fired) but no destination URLs, no body content, no
credentials.

A PAC file (mode 0600) is also written when Smart mode is
active. It contains the user's direct-domain list (defaults to a
small set of high-traffic domestic Chinese hosts; configurable
in Settings) plus the SOCKS listener address (`127.0.0.1:<port>`).
No user destinations, no operator credentials.

## Known surfaces — places where information CAN leak

These are real surfaces, documented honestly so an operator can
make informed decisions:

### Live log view (Log Console in the UI)

The live log surfaces `naive` stdout/stderr in real time.
Credential-shaped strings are filtered through
`cool_tunnel_core::redaction::redact` (regression-tested for
quoted JSON values, bare-token forms, multi-`@` userinfo,
`Authorization:` and `Cookie:` headers) before the line crosses
the supervisor boundary. **However:**

- **Destination hostnames in `naive` error messages CAN reach
  the log.** If `naive` encounters a connection-layer error
  surfacing a host (e.g., an upstream CONNECT failure), the
  hostname can appear verbatim. The redaction layer strips
  credentials, NOT destination identifiers. For an operator
  routing wallet/RPC traffic, this means an error log line
  might say `"connect to alchemyapi.io:443 failed"` or
  similar — leaking the fact that the operator was tunneling
  Alchemy traffic, even though no payload bytes are exposed.

  **Operator guidance:** treat the live log as sensitive. Don't
  screenshot it during an RPC-tunneling session. Clear it
  before sharing a support transcript.

### Lifecycle telemetry file

Same redaction discipline as the live log (W1 alignment in
v2.0.42). Same caveat: destination hostnames in an error
message embedded in `error.localizedDescription` could pass
through. The file is 0o600, in the user's home Application
Support, excluded from Time Machine — but anyone with read
access to the user account can read it.

**Operator guidance:** know it exists, know what it contains,
delete it if a support session ends or if it accumulated content
from an RPC-tunneling session you don't want preserved:

```sh
rm "$HOME/Library/Application Support/space.coolwhite.cooltunnel/lifecycle-telemetry.jsonl"
```

### Diagnostic probes (operator-initiated)

`Run Diagnostics`, `Debug Handshake`, `Latency` actions in the
control panel issue HTTPS requests through the proxy to
hard-coded canary endpoints (`www.google.com`, `ipinfo.io/ip`,
`www.baidu.com`). The user's wallet/RPC destinations are
**not** probed. The fact that the operator clicked a diagnostic
button is local-only; nothing is reported off-device.

The probe `notes` field carries `curl` stderr on failure,
which is credential-redacted before persistence. It can name
the hard-coded canary host on failure — never a user
destination.

### Updater traffic

`AppUpdater` / `NaiveUpdater` / `RustCoreUpdater` issue HTTPS
requests to `api.github.com` and `*.githubusercontent.com` to
check for new releases and fetch artifacts. The host suffix
list is enforced by `GitHubTrust` (regression-tested in
`GitHubTrustTests`); redirects to non-trusted hosts are
rejected before the download starts. Update checks happen on
explicit user click; the app does not poll for updates in the
background.

GitHub learns: that an instance of Cool Tunnel checked for
updates at a given time, from a given IP. This is the same
metadata Homebrew, `npm`, `pip`, `cargo`, and `gh` itself emit
for any update check. The operator's user identity is not sent;
the User-Agent is `URLSession`'s default.

## What this means in practice

If your threat model includes "Alchemy / Infura / Ankr cannot
correlate my home IP with my on-chain activity," Cool Tunnel
delivers that — the destination sees only the VPS's exit IP.
The bundled `naive` is the data plane; the Cool Tunnel app
never sees inside the tunnel.

If your threat model includes "a future review of the
Application Support directory (Time Machine, support
transcript, multi-user macOS account) cannot reveal which RPC
providers I was using," check the live log and the lifecycle
telemetry file. Both are 0o600 + Time Machine-excluded, but
both can contain destination hostnames in `naive` error paths.
Clear them between sessions if that matters to you.

If your threat model includes "Cool Tunnel itself cannot have
been compromised to silently exfiltrate my activity," the
project's hard answers are:

- AGPL-3.0-only source, reviewable end-to-end.
- Daily upstream `naive` SHA pin audit
  (`.github/workflows/naive-pin-audit.yml`) detects upstream
  tag rewrites within 24 h.
- The bundled `cool-tunnel-core` Rust binary forbids `unsafe`
  code (`#![forbid(unsafe_code)]`).
- No analytics, no telemetry endpoint, no identity service —
  verified by code search and pinned by the absence of any
  outbound URLs to non-canary, non-GitHub hosts in production
  code paths.
- The Rust core's protocol surface is JSON-over-stdio with a
  strict message-version handshake; protocol drift fails at
  startup, not silently.

## Reporting a privacy regression

If a future change to Cool Tunnel introduces a leak of
destination URLs, credentials, payload content, or wallet-
specific state, file an issue tagged `privacy-regression`.

For coordinated disclosure of a security-relevant leak, follow
the [SECURITY.md](./SECURITY.md) process.
