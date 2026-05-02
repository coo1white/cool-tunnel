//! Connection monitoring for the running `naive` child.
//!
//! Periodically (driven by the dispatcher) the monitor runs
//! `lsof -nP -a -p <pid> -iTCP`, parses the output, and decides whether the
//! observed traffic pattern looks abnormal. An abnormality maps to one of
//! the [`crate::protocol::AnomalyReason`] variants.

mod heuristics;
mod lsof;

use std::ffi::OsStr;

use thiserror::Error;
use tokio::process::Command;

use crate::domain::Port;
use crate::protocol::AnomalyReason;

pub use heuristics::{DetectedAnomaly, TrafficSnapshot};
pub use lsof::parse;

/// Error raised by [`run`].
#[derive(Debug, Error)]
#[non_exhaustive]
pub enum MonitorError {
    /// Spawning `lsof` failed.
    #[error("failed to run lsof: {0}")]
    Io(#[from] std::io::Error),
    /// `lsof` exited with a non-zero status.
    #[error("lsof exited with status {0}")]
    NonZeroExit(i32),
}

/// Runs `lsof` against `pid` and parses the output into a [`TrafficSnapshot`].
///
/// `port` is the SOCKS listener port; the parser uses it to distinguish
/// inbound local-client connections from outbound remote connections.
///
/// # Errors
///
/// Returns [`MonitorError::Io`] if the `lsof` command cannot be spawned, and
/// [`MonitorError::NonZeroExit`] if `lsof` reports a non-zero exit code with
/// no captured output.
pub async fn run(pid: u32, port: Port) -> Result<TrafficSnapshot, MonitorError> {
    let output = Command::new("/usr/sbin/lsof")
        .args([
            OsStr::new("-nP"),
            OsStr::new("-a"),
            OsStr::new("-p"),
            OsStr::new(&pid.to_string()),
            OsStr::new("-iTCP"),
        ])
        .output()
        .await?;

    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() && stdout.trim().is_empty() {
        return Err(MonitorError::NonZeroExit(output.status.code().unwrap_or(-1)));
    }
    Ok(parse(&stdout, port))
}

impl From<&DetectedAnomaly> for AnomalyReason {
    fn from(value: &DetectedAnomaly) -> Self {
        value.reason
    }
}
