//! Pure parser for `lsof -iTCP` output.
//!
//! Splits the output into TCP connection lines and counts them by category:
//! established connections, established connections with both endpoints on
//! `127.0.0.1` (local clients), and established connections that leave
//! loopback (remote). It also flags any LISTEN line whose address is not
//! `127.0.0.1:port` or `[::1]:port` — that would mean `naive` is exposing
//! itself outside loopback, which the activity monitor treats as critical.

use crate::domain::Port;

use super::heuristics::{TrafficSnapshot, classify};

/// Parses `lsof -iTCP` stdout, scoped to a known listener port.
///
/// `port` is the local SOCKS listener port (the one in [`crate::config::NaiveConfig::listen`]);
/// the parser uses it to detect the listener line and to recognise inbound
/// local-client connections.
#[must_use]
pub fn parse(output: &str, port: Port) -> TrafficSnapshot {
    let local_listen_marker = format!("127.0.0.1:{port}");
    let local_listen_marker_v6 = format!("[::1]:{port}");
    let port_marker = format!(":{port}");
    let local_client_marker = format!("127.0.0.1:{port}->127.0.0.1:");

    let mut raw_lines: Vec<String> = Vec::new();
    let mut established: u32 = 0;
    let mut local_clients: u32 = 0;
    let mut remote: u32 = 0;
    let mut exposed_listen: Option<String> = None;

    for line in output.split('\n') {
        let is_established = line.contains("ESTABLISHED");
        let is_listening = line.contains("LISTEN");
        if !is_established && !is_listening {
            continue;
        }

        raw_lines.push(line.to_owned());

        if is_established {
            established = established.saturating_add(1);
            if line.contains(local_client_marker.as_str()) {
                local_clients = local_clients.saturating_add(1);
            }
            if line.contains("->") && !line.contains("127.0.0.1") {
                remote = remote.saturating_add(1);
            }
        } else if exposed_listen.is_none()
            && line.contains(port_marker.as_str())
            && !line.contains(local_listen_marker.as_str())
            && !line.contains(local_listen_marker_v6.as_str())
        {
            exposed_listen = Some(line.to_owned());
        }
    }

    classify(raw_lines, established, local_clients, remote, exposed_listen)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::protocol::AnomalyReason;

    fn port() -> Port {
        Port::new(1080).unwrap()
    }

    #[test]
    fn empty_output_yields_zero_counts_and_no_anomaly() {
        let snap = parse("", port());
        assert_eq!(snap.established, 0);
        assert_eq!(snap.local_clients, 0);
        assert_eq!(snap.remote, 0);
        assert!(snap.anomaly.is_none());
        assert!(snap.raw_lines.is_empty());
    }

    #[test]
    fn loopback_listener_only_is_clean() {
        let output = "naive 1234 user 7u IPv4 0x... 0t0 TCP 127.0.0.1:1080 (LISTEN)\n";
        let snap = parse(output, port());
        assert!(snap.anomaly.is_none());
        assert_eq!(snap.raw_lines.len(), 1);
    }

    #[test]
    fn ipv6_loopback_listener_is_also_clean() {
        let output = "naive 1234 user 8u IPv6 0x... 0t0 TCP [::1]:1080 (LISTEN)\n";
        let snap = parse(output, port());
        assert!(snap.anomaly.is_none());
    }

    #[test]
    fn non_loopback_listener_triggers_anomaly() {
        let output = "naive 1234 user 7u IPv4 0x... 0t0 TCP 0.0.0.0:1080 (LISTEN)\n";
        let snap = parse(output, port());
        let anomaly = snap.anomaly.expect("expected anomaly");
        assert_eq!(anomaly.reason, AnomalyReason::ListeningOutsideLoopback);
        assert!(anomaly.detail.contains("0.0.0.0:1080"));
    }

    #[test]
    fn local_client_connection_counts_correctly() {
        let output = concat!(
            "naive 1234 user 7u IPv4 a 0t0 TCP 127.0.0.1:1080 (LISTEN)\n",
            "naive 1234 user 8u IPv4 b 0t0 TCP 127.0.0.1:1080->127.0.0.1:54321 (ESTABLISHED)\n",
            "naive 1234 user 9u IPv4 c 0t0 TCP 127.0.0.1:1080->127.0.0.1:54322 (ESTABLISHED)\n",
        );
        let snap = parse(output, port());
        assert_eq!(snap.established, 2);
        assert_eq!(snap.local_clients, 2);
        assert_eq!(snap.remote, 0);
        assert!(snap.anomaly.is_none());
    }

    #[test]
    fn remote_connection_counts_correctly() {
        let output = "naive 1234 user 9u IPv4 c 0t0 TCP 192.168.1.5:54322->8.8.8.8:443 (ESTABLISHED)\n";
        let snap = parse(output, port());
        assert_eq!(snap.established, 1);
        assert_eq!(snap.local_clients, 0);
        assert_eq!(snap.remote, 1);
    }

    #[test]
    fn lines_without_listen_or_established_are_ignored() {
        let output = "naive 1234 user 5u IPv4 d 0t0 TCP 1.2.3.4:443 (CLOSE_WAIT)\n";
        let snap = parse(output, port());
        assert_eq!(snap.established, 0);
        assert!(snap.raw_lines.is_empty());
    }

    #[test]
    fn established_threshold_triggers_anomaly() {
        use std::fmt::Write as _;
        let mut output = String::new();
        for i in 0..170 {
            let _ = writeln!(
                output,
                "naive 1234 user {i}u IPv4 x 0t0 TCP 127.0.0.1:1080->127.0.0.1:5{i:04} (ESTABLISHED)"
            );
        }
        let snap = parse(&output, port());
        assert_eq!(snap.established, 170);
        let anomaly = snap.anomaly.expect("expected anomaly");
        // Established is checked before local_clients, so it dominates here.
        assert_eq!(anomaly.reason, AnomalyReason::TooManyEstablished);
    }
}
