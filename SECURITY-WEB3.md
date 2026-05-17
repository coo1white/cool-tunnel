# SECURITY-WEB3.md

Privacy posture for operators routing Web3 / JSON-RPC / wallet traffic through Cool Tunnel. Sibling to [SECURITY.md](./SECURITY.md). Answers: if I route my wallet, RPC, and signing traffic through Cool Tunnel, what can Cool Tunnel see, log, or persist?

This distinguishes **architectural guarantees** (verified by code review, pinned by regression tests) from **known surfaces** (places where information CAN leak if an error fires or an operator triggers a diagnostic).

## Threat model

Traffic where any of the following would be a privacy or security harm:

- Destination hostname (RPC provider, indexer, bridge, validator endpoint, custodial wallet API).
- Request path / query string (often carries API keys embedded as path segments: `/v2/<API-KEY>/method`).
- Request / response body (JSON-RPC payloads carrying wallet addresses, transaction hashes, signed transactions, balances, approval messages, message hashes).
- User's home IP (tied to identity via geolocation + on-chain activity correlation).
- The fact that the user is using Cool Tunnel at all.

Actor model:

- Networked observer at user's ISP / Wi-Fi / captive portal — sees TLS metadata but not payload.
- Future operator-mistake scenario: shared support transcript, screenshot of the live log, Time Machine snapshot containing the Cool Tunnel Application Support directory.
- App-level bug that accidentally logs or persists data the operator never intended to capture.

## What Cool Tunnel does NOT see, ever

**Architectural guarantees**, not best-effort:

- **HTTPS CONNECT payloads.** Cool Tunnel hands inbound traffic to the bundled `naive` binary via a SOCKS5 listener on `127.0.0.1`. `naive` forwards through an HTTPS CONNECT tunnel to the operator-controlled VPS. The Cool Tunnel app (Swift UI + Rust core) **never decrypts, parses, or stores** anything inside that tunnel. JSON-RPC bodies, signed transactions, wallet addresses, and method names exist only inside the HTTPS payload between user's browser/wallet and destination.
- **Destination URL of routed traffic.** Data plane delivers TLS bytes; the app does not log per-request destinations. System proxy routes to `127.0.0.1:<port>`; from `naive`'s view the destination is visible (CONNECT target), but `naive`'s default verbosity is quiet — logs errors, not per-request URLs.
- **Telemetry endpoints, identity services, analytics.** None exist. Code search verified. No `POST` to any third-party service in normal operation. Diagnostic probes that DO reach external endpoints (`https://ipinfo.io/ip`, `https://www.google.com/generate_204`, `https://www.baidu.com`) are hard-coded canaries, only run when operator clicks "Run Diagnostics" or "Latency".
- **Process arguments that expose credentials.** `naive` is spawned with argv `[<binary>, <config-path>]` only. Basic-auth username/password live inside the 0o600 config file; they never appear in `ps`, in stdout/stderr, in OS process listings, or in audit-trail tools that read argv.
- **Wallet-specific behavior.** No seed-phrase handling, no transaction parsing, no signing flows, no wallet permissions. Cool Tunnel is transport-neutral.

## What Cool Tunnel DOES persist, and where

Three pieces of state under `~/Library/Application Support/space.coolwhite.cooltunnel/`:

1. **`config.json`** (mode 0600). Carries operator's `https://user:pass@host:port` proxy URL. Generated fresh per Start, atomically written via `RestrictedFile.write` with `O_CREAT|O_EXCL` (no umask race). Deleted on graceful Stop. Time Machine excluded via `setResourceValues(.isExcludedFromBackup)` on parent directory (since v2.0.38, with logging if exclusion fails).
2. **`credentials.json`** (mode 0600). Base64-encoded profile passwords. Same atomic-write discipline. Same Time Machine exclusion. Migrated from macOS Keychain on first run under the file-credential backend (migration path regression-tested per H2/H3 in v2.0.38 audit).
3. **`lifecycle-telemetry.jsonl`** (mode 0600, append-only). Local state-machine transitions: bootstrap, start, stop, anomaly classification, error-layer attribution, sleep/wake. **Every `message` and `details` value is run through credential redaction** (regression-tested in `LifecycleTelemetryRedactionTests`) before append. Schema-versioned.

The telemetry file is what an operator might share in a support transcript. Treat as sensitive: contains the *shape* of your session (when started, what mode, what error layer fired) but no destination URLs, no body content, no credentials.

A PAC file (mode 0600) is also written when Smart mode is active. Contains user's direct-domain list (defaults to a small set of high-traffic domestic Chinese hosts; configurable in Settings) plus SOCKS listener address (`127.0.0.1:<port>`). No user destinations, no operator credentials.

## Known surfaces — places where information CAN leak

**Live log view (Log Console in the UI).** Surfaces `naive` stdout/stderr in real time. Credential-shaped strings are filtered through `cool_tunnel_core::redaction::redact` (regression-tested for quoted JSON values, bare-token forms, multi-`@` userinfo, `Authorization:` and `Cookie:` headers) before the line crosses the supervisor boundary. **However: destination hostnames in `naive` error messages CAN reach the log.** If `naive` encounters a connection-layer error surfacing a host (e.g., upstream CONNECT failure), the hostname can appear verbatim. Redaction strips credentials, NOT destination identifiers. An error line might say `"connect to alchemyapi.io:443 failed"` — leaking that the operator was tunneling Alchemy traffic, even though no payload bytes are exposed. Operator guidance: treat the live log as sensitive; don't screenshot it during an RPC-tunneling session; clear before sharing a support transcript.

**Lifecycle telemetry file.** Same redaction discipline as live log (W1 alignment in v2.0.42). Same caveat: destination hostnames in an error message embedded in `error.localizedDescription` could pass through. File is 0o600, in user's home Application Support, Time Machine excluded — but anyone with read access to the user account can read it. Delete it if a support session ends or it accumulated content from an RPC-tunneling session you don't want preserved:

```sh
rm "$HOME/Library/Application Support/space.coolwhite.cooltunnel/lifecycle-telemetry.jsonl"
```

**Diagnostic probes (operator-initiated).** `Run Diagnostics`, `Debug Handshake`, `Latency` issue HTTPS through the proxy to hard-coded canaries (`www.google.com`, `ipinfo.io/ip`, `www.baidu.com`). User wallet/RPC destinations are **not** probed. The probe `notes` field carries `curl` stderr on failure, credential-redacted before persistence. Can name the hard-coded canary host on failure — never a user destination.

**Updater traffic.** `AppUpdater` / `NaiveUpdater` / `RustCoreUpdater` issue HTTPS to `api.github.com` and `*.githubusercontent.com`. Host suffix list enforced by `GitHubTrust` (regression-tested in `GitHubTrustTests`); redirects to non-trusted hosts rejected before download. Checks happen on explicit user click; no background polling. GitHub learns: that an instance of Cool Tunnel checked for updates at a given time, from a given IP. Same metadata Homebrew, `npm`, `pip`, `cargo`, `gh` emit. User identity not sent; User-Agent is `URLSession`'s default.

## What this means in practice

If your threat model includes "Alchemy / Infura / Ankr cannot correlate my home IP with my on-chain activity" — Cool Tunnel delivers; destination sees only the VPS exit IP.

If your threat model includes "future review of the Application Support directory (Time Machine, support transcript, multi-user macOS) cannot reveal which RPC providers I was using" — check the live log and lifecycle telemetry file. Both are 0o600 + Time Machine-excluded, but both can contain destination hostnames in `naive` error paths. Clear them between sessions.

If your threat model includes "Cool Tunnel itself cannot have been compromised to silently exfiltrate my activity":

- AGPL-3.0-only source, reviewable end-to-end.
- Daily upstream `sing-box` SHA pin audit (`.github/workflows/singbox-core-pin-audit.yml`) detects upstream tag rewrites within 24 h.
- Bundled `cool-tunnel-core` Rust binary forbids `unsafe` code (`#![forbid(unsafe_code)]`).
- No analytics, no telemetry endpoint, no identity service — verified by code search, pinned by absence of any outbound URLs to non-canary, non-GitHub hosts in production code paths.
- Rust core's protocol surface is JSON-over-stdio with a strict message-version handshake; protocol drift fails at startup, not silently.

## Reporting a privacy regression

If a future change introduces a leak of destination URLs, credentials, payload content, or wallet-specific state, file an issue tagged `privacy-regression`. For coordinated disclosure of a security-relevant leak, follow the [SECURITY.md](./SECURITY.md) process.
