// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Anomaly detection thresholds applied to a parsed lsof snapshot.
//!
//! The thresholds and detection order match the Swift implementation:
//!
//! 1. Any LISTEN line outside loopback → [`AnomalyReason::ListeningOutsideLoopback`].
//! 2. Total established connections > 160 → [`AnomalyReason::TooManyEstablished`].
//! 3. Local-client connections > 120 → [`AnomalyReason::TooManyLocalClients`].
//! 4. Remote connections > 32 → [`AnomalyReason::TooManyRemote`].

use crate::protocol::AnomalyReason;

/// Maximum tolerated total established connections.
pub const MAX_ESTABLISHED: u32 = 160;
/// Maximum tolerated inbound local-client connections.
pub const MAX_LOCAL_CLIENTS: u32 = 120;
/// Maximum tolerated outbound remote connections.
pub const MAX_REMOTE: u32 = 32;

/// Connection-count summary plus optional anomaly verdict.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrafficSnapshot {
    /// Lines from `lsof` that matched LISTEN or ESTABLISHED.
    pub raw_lines: Vec<String>,
    /// Total established connections.
    pub established: u32,
    /// Established connections with both endpoints on `127.0.0.1`.
    pub local_clients: u32,
    /// Established connections with at least one non-loopback endpoint.
    pub remote: u32,
    /// Set when at least one threshold was tripped.
    pub anomaly: Option<DetectedAnomaly>,
}

/// Categorised detection result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DetectedAnomaly {
    /// Cause of the detection.
    pub reason: AnomalyReason,
    /// Human-readable explanation suitable for surfacing in logs.
    pub detail: String,
}

/// Applies the threshold rules to raw counts plus an optional exposed-listen
/// line, producing the final [`TrafficSnapshot`].
#[must_use]
pub fn classify(
    raw_lines: Vec<String>,
    established: u32,
    local_clients: u32,
    remote: u32,
    exposed_listen: Option<String>,
) -> TrafficSnapshot {
    let anomaly = if let Some(line) = exposed_listen {
        Some(DetectedAnomaly {
            reason: AnomalyReason::ListeningOutsideLoopback,
            detail: format!("sing-box is listening outside loopback: {line}"),
        })
    } else if established > MAX_ESTABLISHED {
        Some(DetectedAnomaly {
            reason: AnomalyReason::TooManyEstablished,
            detail: format!(
                "established connections {established} exceeded threshold {MAX_ESTABLISHED}"
            ),
        })
    } else if local_clients > MAX_LOCAL_CLIENTS {
        Some(DetectedAnomaly {
            reason: AnomalyReason::TooManyLocalClients,
            detail: format!(
                "local-client connections {local_clients} exceeded threshold {MAX_LOCAL_CLIENTS}"
            ),
        })
    } else if remote > MAX_REMOTE {
        Some(DetectedAnomaly {
            reason: AnomalyReason::TooManyRemote,
            detail: format!("remote connections {remote} exceeded threshold {MAX_REMOTE}"),
        })
    } else {
        None
    };

    TrafficSnapshot {
        raw_lines,
        established,
        local_clients,
        remote,
        anomaly,
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn no_anomaly_under_thresholds() {
        let snap = classify(Vec::new(), 50, 30, 5, None);
        assert!(snap.anomaly.is_none());
    }

    #[test]
    fn exposed_listen_dominates_other_thresholds() {
        let snap = classify(
            Vec::new(),
            999,
            999,
            999,
            Some("0.0.0.0:1080 (LISTEN)".to_owned()),
        );
        let anomaly = snap.anomaly.expect("expected exposed-listen anomaly");
        assert_eq!(anomaly.reason, AnomalyReason::ListeningOutsideLoopback);
    }

    #[test]
    fn established_threshold() {
        let snap = classify(Vec::new(), MAX_ESTABLISHED + 1, 0, 0, None);
        assert_eq!(
            snap.anomaly.unwrap().reason,
            AnomalyReason::TooManyEstablished
        );
    }

    #[test]
    fn local_clients_threshold() {
        let snap = classify(Vec::new(), 0, MAX_LOCAL_CLIENTS + 1, 0, None);
        assert_eq!(
            snap.anomaly.unwrap().reason,
            AnomalyReason::TooManyLocalClients
        );
    }

    #[test]
    fn remote_threshold() {
        let snap = classify(Vec::new(), 0, 0, MAX_REMOTE + 1, None);
        assert_eq!(snap.anomaly.unwrap().reason, AnomalyReason::TooManyRemote);
    }

    #[test]
    fn boundary_values_not_anomalous() {
        let snap = classify(
            Vec::new(),
            MAX_ESTABLISHED,
            MAX_LOCAL_CLIENTS,
            MAX_REMOTE,
            None,
        );
        assert!(snap.anomaly.is_none());
    }
}
