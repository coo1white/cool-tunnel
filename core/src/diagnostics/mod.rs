//! Diagnostic probes that exercise the proxy and the upstream server.
//!
//! Each probe is a thin wrapper around `curl` invoked with `--write-out`. The
//! captured timing metrics are parsed into a [`LatencySample`] and bundled
//! into a [`LatencyReport`] or [`DiagnosticReport`] for the wire protocol.

mod metrics;
mod probe;

use thiserror::Error;

use crate::domain::{Port, ProxyTestMode};
use crate::protocol::{DiagnosticReport, LatencyReport, ProbeResult};

pub use metrics::{parse_write_out, secs_to_ms};
pub use probe::{run_probe, ProbeOptions};

/// Targets used for the global-mode latency test. Matches the Swift
/// `runTimeoutTest` argument list.
pub const GLOBAL_TARGETS: &[&str] = &[
    "https://www.baidu.com",
    "https://www.google.com/generate_204",
];

/// Targets used for the smart-mode latency test. Matches the Swift
/// `runTimeoutTest` argument list.
pub const SMART_TARGETS: &[&str] = &[
    "https://www.baidu.com",
    "https://www.google.com/generate_204",
];

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
/// # Errors
///
/// Returns [`DiagnosticError::Io`] if `curl` cannot be spawned.
pub async fn run_diagnostics(port: Port) -> Result<DiagnosticReport, DiagnosticError> {
    let probes = vec![probe_through_proxy(port).await?];
    Ok(DiagnosticReport { probes })
}

/// Runs a latency report for the requested mode.
///
/// The first target is probed without a proxy (to compare baseline DNS/TCP
/// timings). Remaining targets are probed via the local SOCKS listener.
///
/// # Errors
///
/// Returns [`DiagnosticError::Io`] if `curl` cannot be spawned for any probe.
pub async fn run_latency(
    mode: ProxyTestMode,
    port: Port,
) -> Result<LatencyReport, DiagnosticError> {
    let targets: &[&str] = match mode {
        ProxyTestMode::Smart => SMART_TARGETS,
        ProxyTestMode::Global => GLOBAL_TARGETS,
    };

    let mut samples = Vec::with_capacity(targets.len());
    for (idx, url) in targets.iter().enumerate() {
        let proxy_port = if idx == 0 { None } else { Some(port) };
        let opts = ProbeOptions {
            url: (*url).to_owned(),
            proxy_port,
            connect_timeout_secs: 5,
            max_time_secs: 12,
        };
        samples.push(run_probe(&opts).await?);
    }
    Ok(LatencyReport { samples })
}

async fn probe_through_proxy(port: Port) -> Result<ProbeResult, DiagnosticError> {
    let opts = ProbeOptions {
        url: "https://ipinfo.io/ip".to_owned(),
        proxy_port: Some(port),
        connect_timeout_secs: 5,
        max_time_secs: 12,
    };
    let sample = run_probe(&opts).await?;
    Ok(ProbeResult {
        name: "upstream_via_socks".to_owned(),
        ok: sample.ok,
        detail: sample.notes.clone(),
        duration_ms: ms_to_u64(sample.elapsed_ms),
    })
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
