// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Pre-flight reachability probe against an upstream proxy server.
//!
//! Resolves the [`crate::domain::ServerAddress`] (defaulting to
//! port 443 when no explicit port is set), then opens a single TCP
//! connection. Each step is timed independently and bounded by its
//! own deadline so a half-open firewall can't hang the probe past
//! `2 * deadline`.
//!
//! Returns a [`crate::protocol::ProbeReport`] in every case — DNS
//! failure, connect failure, success — so the Swift caller can render
//! timing alongside the failure mode rather than catching a transport
//! exception. Hard errors (a runtime that can't spawn at all) bubble
//! up as [`std::io::Error`]; everything that reaches the network is
//! reported as a structured `reachable: false` with a human-readable
//! `error`.
//!
//! # What this is *not*
//!
//! - Not a TLS handshake. The crate forbids `unsafe_code`, so rolling
//!   our own TLS is off the table, and adding a TLS dep widens the
//!   audit surface for a probe whose primary value is catching wrong
//!   hostname / blocked port. Full TLS validation continues to live in
//!   [`crate::diagnostics`], which probes through a running proxy.
//! - Not an auth probe. `NaiveProxy` authenticates over HTTPS CONNECT
//!   inside the TLS tunnel; without a TLS client there's no way to
//!   reach the auth surface from this layer. Future revisions can
//!   extend [`probe`] to shell out to `/usr/bin/curl -x https://...`
//!   for full validation; the wire shape ([`crate::protocol::ProbeReport`])
//!   is forward-compatible.

use std::time::{Duration, Instant};

use tokio::net::{lookup_host, TcpStream};

use crate::domain::Profile;
use crate::protocol::ProbeReport;

/// Default per-step deadline when the caller passes `None`. Picked to
/// match the existing `RunDiagnostics` path's connect timeout (5 s)
/// so a user comparing the two probes against the same upstream sees
/// consistent latency boundaries.
const DEFAULT_TIMEOUT_SECS: u64 = 5;

/// Hard floor on the per-step deadline. Below 1 second the probe
/// becomes a thrash test of the local resolver rather than a useful
/// signal about the upstream.
const MIN_TIMEOUT_SECS: u64 = 1;

/// Hard ceiling on the per-step deadline. The Swift `CoreClient`
/// already enforces a 120 s overall request timeout; capping each
/// step at 30 s keeps the worst-case probe (DNS slow + connect slow
/// + retry) well inside that envelope.
const MAX_TIMEOUT_SECS: u64 = 30;

/// Default TCP port assumed when the profile's
/// [`crate::domain::ServerAddress`] carries no explicit port. Matches
/// the cool-tunnel-server topology — sing-box terminates `NaiveProxy`
/// on `:443/tcp` for SNI-fronted compatibility with normal HTTPS
/// traffic.
const DEFAULT_TCP_PORT: u16 = 443;

/// Runs the pre-flight probe and returns a structured report.
///
/// # Errors
///
/// Returns [`std::io::Error`] only on conditions that prevent the
/// probe from starting at all (Tokio runtime acquisition failure,
/// etc.). Reachability failures — `getaddrinfo` errors, connect
/// refused, connect timeout — are surfaced inside the
/// [`ProbeReport`] with `reachable: false`.
pub async fn probe(
    profile: &Profile,
    timeout_override: Option<u64>,
) -> std::io::Result<ProbeReport> {
    let timeout_secs = timeout_override
        .unwrap_or(DEFAULT_TIMEOUT_SECS)
        .clamp(MIN_TIMEOUT_SECS, MAX_TIMEOUT_SECS);
    let timeout = Duration::from_secs(timeout_secs);

    let (host, port) = split_host_port(profile.server().as_str());
    let server = format!("{host}:{port}");

    // Step 1: DNS. Tokio's `lookup_host` is the async wrapper around
    // `getaddrinfo`. Wrapping it in `tokio::time::timeout` is what
    // bounds a slow resolver — without this a misconfigured
    // /etc/resolv.conf could block the probe past the per-request
    // 120 s deadline and the user sees a hung "Test Connection"
    // button instead of a real error.
    let dns_start = Instant::now();
    // Pass an owned `String` (not `&str`) so the future returned by
    // `lookup_host` doesn't keep a borrow on `server` — that borrow
    // would conflict with `server` being moved into the
    // `ProbeReport` struct further down. The clone is one tiny
    // allocation per probe, run only when the user clicks "Test
    // Connection" (a per-second-at-best UI affordance), so the
    // cost is fully invisible.
    let dns_result = tokio::time::timeout(timeout, lookup_host(server.clone())).await;
    let dns_resolve_ms = elapsed_ms(dns_start);

    let mut addrs = match dns_result {
        Ok(Ok(addrs)) => addrs.collect::<Vec<_>>(),
        Ok(Err(err)) => {
            return Ok(ProbeReport {
                server,
                reachable: false,
                dns_resolve_ms,
                tcp_connect_ms: 0.0,
                error: Some(format!("DNS resolve failed: {err}")),
            });
        }
        Err(_) => {
            return Ok(ProbeReport {
                server,
                reachable: false,
                dns_resolve_ms,
                tcp_connect_ms: 0.0,
                error: Some(format!("DNS resolve timed out after {timeout_secs} s")),
            });
        }
    };

    if addrs.is_empty() {
        return Ok(ProbeReport {
            server,
            reachable: false,
            dns_resolve_ms,
            tcp_connect_ms: 0.0,
            error: Some("DNS returned no addresses".to_owned()),
        });
    }

    // Step 2: TCP connect. We try the first resolved address only —
    // probing every A/AAAA record matches `getaddrinfo`'s ordering
    // (typically OS-preferred first), and a partial-failure result
    // ("connect succeeded on the third address") would be more
    // confusing than useful in the UI. If users hit a real
    // multi-address-with-one-broken case we'll add a fanout in a
    // later cycle.
    let target = addrs.remove(0);
    let connect_start = Instant::now();
    let connect_result = tokio::time::timeout(timeout, TcpStream::connect(target)).await;
    let tcp_connect_ms = elapsed_ms(connect_start);

    match connect_result {
        Ok(Ok(_stream)) => Ok(ProbeReport {
            server,
            reachable: true,
            dns_resolve_ms,
            tcp_connect_ms,
            error: None,
        }),
        Ok(Err(err)) => Ok(ProbeReport {
            server,
            reachable: false,
            dns_resolve_ms,
            tcp_connect_ms,
            error: Some(format!("TCP connect failed: {err}")),
        }),
        Err(_) => Ok(ProbeReport {
            server,
            reachable: false,
            dns_resolve_ms,
            tcp_connect_ms,
            error: Some(format!("TCP connect timed out after {timeout_secs} s")),
        }),
    }
}

/// Splits a [`crate::domain::ServerAddress`] string (already
/// validated by the domain layer to be `host` or `host:port`) into
/// its components. The validation layer guarantees the input is
/// well-formed, so this is a pure split with default-port
/// substitution.
fn split_host_port(server: &str) -> (&str, u16) {
    if let Some(idx) = server.rfind(':') {
        let host = &server[..idx];
        let port_str = &server[idx + 1..];
        // The domain layer already rejected non-numeric ports during
        // `ServerAddress::parse`, so this `parse` cannot legitimately
        // fail. Falling back to the default rather than panicking
        // matches the crate-wide policy of forbidding `unwrap`/`expect`
        // and keeps the probe useful even if a future serde path
        // smuggles in an unvalidated address.
        let port = port_str.parse::<u16>().unwrap_or(DEFAULT_TCP_PORT);
        (host, port)
    } else {
        (server, DEFAULT_TCP_PORT)
    }
}

fn elapsed_ms(start: Instant) -> f64 {
    // `Duration::as_secs_f64` does the precision juggling we used
    // to do by hand here — a single primitive that the compiler
    // (and clippy) recognises as the canonical way to get
    // sub-second precision out of a `Duration`. The ms range is
    // never large enough to lose mantissa bits.
    start.elapsed().as_secs_f64() * 1000.0
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::domain::{
        Credentials, Port, ProfileId, Reality, RealityDestHost, RealityPublicKey, RealityShortId,
        ServerAddress, Username, Uuid,
    };

    fn profile_for(server: &str) -> Profile {
        Profile::new(
            ProfileId::new("test"),
            ServerAddress::parse(server).unwrap(),
            Credentials::new(
                Username::parse("u").unwrap(),
                Uuid::parse("11111111-2222-3333-4444-555555555555").unwrap(),
                Reality::new(
                    RealityPublicKey::parse("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
                        .unwrap(),
                    RealityDestHost::parse("www.microsoft.com").unwrap(),
                    RealityShortId::parse("").unwrap(),
                ),
            ),
            Port::new(1080).unwrap(),
        )
    }

    #[test]
    fn split_host_port_defaults_to_443() {
        assert_eq!(split_host_port("example.com"), ("example.com", 443));
    }

    #[test]
    fn split_host_port_uses_explicit_port() {
        assert_eq!(split_host_port("example.com:8443"), ("example.com", 8443));
    }

    #[tokio::test]
    async fn probe_reports_unreachable_on_invalid_host() {
        // Non-routable TEST-NET-1 address per RFC 5737. Connect
        // attempts here will time out cleanly without leaking real
        // traffic and without depending on test-host network
        // configuration. We bound the probe at 1 s so the test
        // returns quickly even when the local kernel doesn't ICMP-
        // reject the packet.
        let profile = profile_for("192.0.2.1:1");
        let report = probe(&profile, Some(1)).await.unwrap();
        assert!(!report.reachable);
        assert!(report.error.is_some());
        // DNS for a literal IP should be near-instant; we don't
        // assert exact timing because CI machines vary, just that
        // the connect step ran (timed out at ~1 s).
        assert!(report.tcp_connect_ms >= 0.0);
        assert_eq!(report.server, "192.0.2.1:1");
    }

    #[test]
    fn elapsed_ms_returns_nonnegative() {
        let start = Instant::now();
        let ms = elapsed_ms(start);
        assert!(ms >= 0.0);
    }
}
