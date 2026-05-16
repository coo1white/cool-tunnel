// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Connection monitoring for the running `sing-box` child.
//!
//! Periodically (driven by the dispatcher) the monitor runs
//! `lsof -nP -a -p <pid> -iTCP`, parses the output, and decides whether the
//! observed traffic pattern looks abnormal. An abnormality maps to one of
//! the [`crate::protocol::AnomalyReason`] variants. The flow is binary-
//! agnostic — only the supervised PID matters — so the rename from
//! NaiveProxy to sing-box is a comment-only change here.

mod heuristics;
mod lsof;

use std::ffi::OsStr;
use std::time::Duration;

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
    // Bound the lsof call. `lsof` can wedge in pathological
    // situations (network filesystem stuck in an EINTR storm,
    // managed Macs with kernel extensions intercepting `proc_*`
    // syscalls). Without this timeout the monitor loop's
    // `MissedTickBehavior::Skip` only protects scheduling, not
    // the in-flight call itself — a stuck lsof would block the
    // whole monitor task forever, silencing the security-anomaly
    // signal channel. 4 s is comfortably under the 5 s
    // monitor interval so successive ticks don't pile up.
    let mut command = Command::new("/usr/sbin/lsof");
    command
        .args([
            OsStr::new("-nP"),
            OsStr::new("-a"),
            OsStr::new("-p"),
            OsStr::new(&pid.to_string()),
            OsStr::new("-iTCP"),
        ])
        .kill_on_drop(true);
    let output = match tokio::time::timeout(Duration::from_secs(4), command.output()).await {
        Ok(result) => result?,
        Err(_) => {
            return Err(MonitorError::Io(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "lsof did not return within 4s",
            )));
        }
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    // `lsof -p <pid>` exits 1 when the PID has no matching open
    // files — a perfectly normal state for a `sing-box` that hasn't
    // yet accepted a connection. Treating that as an error
    // produced spurious `tracing::warn!` lines on every probe of
    // an idle proxy. Only treat non-zero exit as an error when
    // stderr also reported something.
    if !output.status.success() && stdout.trim().is_empty() && !output.stderr.is_empty() {
        return Err(MonitorError::NonZeroExit(
            output.status.code().unwrap_or(-1),
        ));
    }
    Ok(parse(&stdout, port))
}

impl From<&DetectedAnomaly> for AnomalyReason {
    fn from(value: &DetectedAnomaly) -> Self {
        value.reason
    }
}
