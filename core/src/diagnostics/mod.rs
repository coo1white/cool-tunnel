// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Diagnostic probes that exercise the proxy and the upstream server.
//!
//! Each probe is a thin wrapper around `curl` invoked with `--write-out`. The
//! captured timing metrics are parsed into a [`LatencySample`] and bundled
//! into a [`LatencyReport`] or [`DiagnosticReport`] for the wire protocol.

mod metrics;
mod probe;

use std::time::Instant;

use thiserror::Error;
use tokio::sync::mpsc;

use crate::domain::{Port, ProxyTestMode};
use crate::protocol::{DiagnosticReport, Event, LatencyReport, Outbound, ProbeResult};

pub use metrics::{parse_write_out, secs_to_ms};
pub use probe::{run_probe, ProbeOptions};

/// Targets used for both the global-mode and smart-mode latency
/// tests. Matches the Swift `runTimeoutTest` argument list.
///
/// The two modes used to ship as separate `GLOBAL_TARGETS` and
/// `SMART_TARGETS` constants with byte-identical contents — a
/// future-divergence footgun. If the two need to differ later
/// (e.g. smart mode also pings a CDN region), reintroduce the
/// split with `LATENCY_TARGETS_GLOBAL` / `LATENCY_TARGETS_SMART`
/// names so the divergence is intentional.
pub const LATENCY_TARGETS: &[&str] = &[
    "https://www.baidu.com",
    "https://www.google.com/generate_204",
];

/// Backwards-compatible aliases — `pub` items in the engine
/// surface, kept under the LTSC contract until the next minor.
/// Both point at the same underlying slice.
pub const GLOBAL_TARGETS: &[&str] = LATENCY_TARGETS;
/// Smart-mode latency targets. Identical to [`GLOBAL_TARGETS`]
/// today; both are aliases for [`LATENCY_TARGETS`].
pub const SMART_TARGETS: &[&str] = LATENCY_TARGETS;

/// Error raised by a diagnostics run.
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum DiagnosticError {
    /// Failed to spawn `curl`.
    #[error("failed to invoke curl: {0}")]
    Io(#[from] std::io::Error),
}

/// Runs the standard upstream connectivity diagnostic.
///
/// Currently a single probe through the local SOCKS proxy to `ipinfo.io/ip`.
/// The result list is intentionally small; richer diagnostics are run via
/// [`run_latency`].
///
/// Emits an [`Event::DiagnosticProgress`] for the probe so the live log
/// window can render `✓ upstream_via_socks (47ms)` in real time. The
/// progress event is sent on the **same channel as the response** to
/// guarantee the user sees per-probe lines before the closing summary
/// — emitting on the separate `events` channel races against the
/// response and can land out of order on stdout.
///
/// # Errors
///
/// Returns [`DiagnosticError::Io`] if `curl` cannot be spawned.
pub async fn run_diagnostics(
    port: Port,
    outbound: &mpsc::Sender<Outbound>,
) -> Result<DiagnosticReport, DiagnosticError> {
    let probes = vec![probe_through_proxy(port, outbound).await?];
    Ok(DiagnosticReport { probes })
}

/// Runs a latency report for the requested mode.
///
/// The first target is probed **without** a proxy (a direct hit on the
/// upstream) to give a baseline DNS/TCP timing the user can compare
/// against the via-proxy probes. Remaining targets are probed via the
/// local SOCKS listener.
///
/// Per-probe progress events are emitted on `outbound` (not `events`)
/// so they cannot race ahead of or behind the response payload — see
/// [`run_diagnostics`] for the rationale.
///
/// # Errors
///
/// Returns [`DiagnosticError::Io`] if `curl` cannot be spawned for any probe.
pub async fn run_latency(
    mode: ProxyTestMode,
    port: Port,
    outbound: &mpsc::Sender<Outbound>,
) -> Result<LatencyReport, DiagnosticError> {
    // Both modes target the same upstream list today; if they
    // need to diverge later, replace this with a per-mode pick
    // and rename the underlying constants.
    let _ = mode; // mode kept in the API for future per-mode targets
    let targets: &[&str] = LATENCY_TARGETS;

    let mut samples = Vec::with_capacity(targets.len());
    for (idx, url) in targets.iter().enumerate() {
        let proxy_port = if idx == 0 { None } else { Some(port) };
        let opts = ProbeOptions {
            url: (*url).to_owned(),
            proxy_port,
            connect_timeout_secs: 5,
            max_time_secs: 12,
        };
        // Wall-clock the whole probe so the live log shows total time
        // including proxy handshake, not just the curl-reported segments.
        let started = Instant::now();
        let sample = run_probe(&opts).await?;
        let elapsed_ms = ms_to_u64(started.elapsed().as_secs_f64() * 1000.0);
        let step_label = if idx == 0 {
            // The first probe is the direct/no-proxy baseline. Make
            // that explicit in the label — "baseline" alone would let
            // a user think both runs of the same URL go through the
            // proxy. The label is the only place the UI surfaces the
            // distinction.
            format!("baseline (direct, no proxy) {url}")
        } else {
            format!("via proxy {url}")
        };
        emit_progress(outbound, step_label, sample.ok, elapsed_ms).await;
        samples.push(sample);
    }
    Ok(LatencyReport { samples })
}

async fn probe_through_proxy(
    port: Port,
    outbound: &mpsc::Sender<Outbound>,
) -> Result<ProbeResult, DiagnosticError> {
    let opts = ProbeOptions {
        url: "https://ipinfo.io/ip".to_owned(),
        proxy_port: Some(port),
        connect_timeout_secs: 5,
        max_time_secs: 12,
    };
    let started = Instant::now();
    let sample = run_probe(&opts).await?;
    let elapsed_ms = ms_to_u64(started.elapsed().as_secs_f64() * 1000.0);
    emit_progress(
        outbound,
        "upstream_via_socks".to_owned(),
        sample.ok,
        elapsed_ms,
    )
    .await;
    Ok(ProbeResult {
        name: "upstream_via_socks".to_owned(),
        ok: sample.ok,
        detail: sample.notes.clone(),
        duration_ms: ms_to_u64(sample.elapsed_ms),
    })
}

/// Wraps a `DiagnosticProgress` event in `Outbound::Event` and pushes
/// it down the response channel. We deliberately use the awaited
/// `send` (not `try_send`) so the log line is never silently dropped
/// under back-pressure; failure means stdout has closed and the
/// engine is shutting down anyway.
async fn emit_progress(outbound: &mpsc::Sender<Outbound>, step: String, ok: bool, elapsed_ms: u64) {
    let _ = outbound
        .send(Outbound::Event(Event::DiagnosticProgress {
            step,
            ok,
            elapsed_ms,
        }))
        .await;
}

/// Rounds a non-negative milliseconds value to `u64`, saturating on overflow
/// and clamping negative values to zero. Used because the wire format uses
/// `u64` for durations while curl reports `f64` seconds.
#[allow(
    clippy::cast_possible_truncation,
    clippy::cast_sign_loss,
    clippy::cast_precision_loss
)]
fn ms_to_u64(ms: f64) -> u64 {
    if !ms.is_finite() || ms <= 0.0 {
        return 0;
    }
    let rounded = ms.round();
    // f64 can represent every u64 below 2^53 exactly; above that the cast
    // saturates harmlessly because we have already clamped to u64::MAX.
    if rounded >= u64::MAX as f64 {
        u64::MAX
    } else {
        rounded as u64
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn smart_and_global_target_lists_are_non_empty() {
        assert!(!SMART_TARGETS.is_empty());
        assert!(!GLOBAL_TARGETS.is_empty());
    }
}
