// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Wire protocol shared between the engine and the Swift app.
//!
//! Newline-delimited JSON: each frame is one JSON object
//! terminated by `\n`.
//!
//! - **Swift → engine** on stdin as [`Request`] envelopes.
//! - **Engine → Swift** on stdout as [`Outbound`] envelopes
//!   (responses, errors, events interleaved on one stream).
//!
//! Mirrored Swift-side in `Core/Protocol.swift`; a
//! `protocol_roundtrip` integration test pins the wire format.
//!
//! # Frame examples
//!
//! ```json
//! {"id":1,"method":"validate_profile","params":{"profile":{...}}}
//! {"kind":"response","id":1,"result":{"type":"ack"}}
//! {"kind":"error","id":1,"error":{"code":"invalid_profile","message":"..."}}
//! {"kind":"event","event":"log_line","data":{"source":"stdout","line":"..."}}
//! ```

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::domain::{Port, Profile, ProxyTestMode, RawProfile};

/// Wire-format protocol version negotiated by [`RequestKind::Hello`].
///
/// Bump on any breaking frame-shape change. Additive changes (new
/// optional fields, new variants) keep the version number — the
/// Swift caller and Rust engine each fall back gracefully on
/// fields they don't understand.
///
/// The Swift client refuses to proceed on a hard mismatch. A
/// legacy engine that doesn't implement `Hello` is treated as
/// version 0 (Swift accepts and continues).
pub const PROTOCOL_VERSION: u32 = 1;

/// One request frame from the Swift app.
///
/// `id` is a client-chosen monotonically increasing integer. The engine
/// echoes it on the matching [`Outbound::Response`] or [`Outbound::Error`]
/// so the Swift side can correlate a reply to its waiter.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Request {
    /// Client-chosen correlation identifier.
    pub id: u64,
    /// The method being invoked, with its parameters.
    #[serde(flatten)]
    pub kind: RequestKind,
}

/// Discriminated union of every method the engine accepts.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "method", content = "params", rename_all = "snake_case")]
#[non_exhaustive]
pub enum RequestKind {
    /// Validate a profile and return a structured report.
    ///
    /// Takes [`RawProfile`] (no validation at deserialize) so the
    /// handler can produce a per-field reason. Always returns
    /// [`Outbound::Response`]:
    ///
    /// - Valid → `ValidationReport { ok: true, reason: None }`.
    /// - Invalid → `ValidationReport { ok: false, reason: Some("…") }`
    ///   with the [`crate::domain::ValidationError`] display.
    ///
    /// `validate_profile` works as a probe — callers can ask "is
    /// this profile valid?" without catching a transport error.
    /// Other variants ([`StartProxy`](RequestKind::StartProxy),
    /// [`GenerateNaiveConfig`](RequestKind::GenerateNaiveConfig))
    /// carry validated [`Profile`] because their callers commit
    /// to *using* it.
    ValidateProfile {
        /// The raw profile to validate. The handler attempts
        /// `Profile::try_from(this)` and reports the outcome.
        profile: RawProfile,
    },
    /// Generate the `naive` `config.json` text for `profile`.
    GenerateNaiveConfig {
        /// The validated profile.
        profile: Profile,
    },
    /// Generate the smart-routing PAC file body.
    GeneratePac {
        /// Direct-route domains.
        direct_domains: Vec<String>,
        /// Listener port.
        port: Port,
    },
    /// Spawn the bundled `naive` binary and start streaming its output.
    StartProxy {
        /// Filesystem path to the `naive` executable.
        binary_path: PathBuf,
        /// Filesystem path to the `config.json`.
        config_path: PathBuf,
        /// The local SOCKS listener port (must match what's in the config).
        port: Port,
        /// Optional override for the connection-monitor poll
        /// interval in seconds. `None` keeps the 5 s default. The
        /// handler clamps to `[1, 60]` so misuse can't spin lsof
        /// at sub-second cadence or hide a crash for hours.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        monitor_interval_secs: Option<u64>,
    },
    /// Stop the running `naive` process.
    StopProxy,
    /// Run a one-shot connectivity diagnostic against the active proxy.
    RunDiagnostics,
    /// Run a latency probe in the requested mode.
    RunLatencyTest {
        /// Whether to test smart-routing or global proxying.
        mode: ProxyTestMode,
    },
    /// Politely shut the engine down.
    Shutdown,
    /// Liveness probe — returns whether naive is running and its
    /// PID. Used by the orchestrator's no-restart hot-swap path
    /// to detect a naive death during the swap window (the
    /// `transitionInFlight` gate suppresses the implicit
    /// `stateChanged(false)` event). Cheap: a single in-process
    /// read of `EngineState.supervisor.is_some()`.
    ProbeNaiveLive,
    /// Wire-protocol handshake. Engine replies with
    /// [`ResponsePayload::HelloReply`] carrying
    /// [`PROTOCOL_VERSION`] and `CARGO_PKG_VERSION`. Older
    /// engines that predate this variant return `invalid_request`;
    /// the Swift side treats that as version 0 and continues.
    Hello,
    /// Pre-flight reachability probe against the upstream server.
    /// Resolves the hostname and opens a TCP connection to
    /// `host:port` (defaulting `:443`), timing each step.
    ///
    /// Intentionally not a TLS or auth probe: a real auth probe
    /// would require a TLS stack (the crate forbids `unsafe_code`)
    /// and the cover-site reply is itself useful signal. Full
    /// TLS+auth validation lives in `RunDiagnostics`.
    ProbeServer {
        /// The profile to probe. Only [`crate::domain::ServerAddress`]
        /// is consulted; the rest is accepted for parity so a
        /// future auth probe doesn't change the wire shape.
        profile: Profile,
        /// Optional per-step deadline in seconds, clamped to
        /// `[1, 30]`. `None` defaults to 5. Worst-case wall
        /// clock is `2 * timeout_secs` (DNS + TCP).
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_secs: Option<u64>,
    },
    /// Spawn a temporary reference `naive` client and drive one
    /// HTTP CONNECT through it for handshake diagnostics.
    DebugHandshake {
        /// Filesystem path to the `naive` executable.
        binary_path: PathBuf,
        /// The validated profile to test.
        profile: Profile,
        /// Optional end-to-end deadline in seconds.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        timeout_secs: Option<u64>,
    },
}

/// One frame written by the engine on stdout.
///
/// Responses and errors carry the `id` of their originating [`Request`];
/// events do not.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Outbound {
    /// A successful reply to a [`Request`].
    Response {
        /// Request correlation identifier.
        id: u64,
        /// Reply payload.
        result: ResponsePayload,
    },
    /// A failed reply to a [`Request`].
    Error {
        /// Request correlation identifier.
        id: u64,
        /// Failure detail.
        error: ErrorPayload,
    },
    /// An unsolicited event from the engine.
    Event(Event),
}

/// Reply payloads matched to specific requests.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
#[non_exhaustive]
pub enum ResponsePayload {
    /// Generic acknowledgement carrying no payload.
    Ack,
    /// `validate_profile` reply.
    Validation(ValidationReport),
    /// `generate_naive_config` reply.
    NaiveConfig {
        /// Pretty-printed JSON body.
        json: String,
    },
    /// `generate_pac` reply.
    Pac {
        /// PAC file body.
        js: String,
    },
    /// `start_proxy` reply.
    Started {
        /// Process ID of the spawned `naive` child.
        pid: u32,
    },
    /// `stop_proxy` reply.
    Stopped,
    /// `run_diagnostics` reply.
    Diagnostic(DiagnosticReport),
    /// `run_latency_test` reply.
    Latency(LatencyReport),
    /// `probe_naive_live` reply. `running` is the canonical flag;
    /// `pid` is for diagnostics only.
    NaiveLiveness {
        /// `true` when the engine has a live `ProxySupervisor`.
        running: bool,
        /// PID of the running naive child, when running.
        pid: Option<u32>,
    },
    /// `hello` reply.
    HelloReply {
        /// Wire-format protocol version of this engine build.
        protocol_version: u32,
        /// `cool-tunnel-core` semver (`CARGO_PKG_VERSION`).
        engine_version: String,
    },
    /// `probe_server` reply.
    Probe(ProbeReport),
    /// `debug_handshake` reply.
    DebugHandshake(DebugHandshakeReport),
}

/// Structured failure detail accompanying an [`Outbound::Error`] frame.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ErrorPayload {
    /// Stable machine-readable code (e.g. `"invalid_profile"`).
    pub code: String,
    /// Human-readable description suitable for surfacing in the UI.
    pub message: String,
}

impl ErrorPayload {
    /// Constructs an error payload.
    #[must_use]
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            code: code.into(),
            message: message.into(),
        }
    }
}

/// Result of `validate_profile`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ValidationReport {
    /// `true` when the profile passes every validation rule.
    pub ok: bool,
    /// When `ok` is `false`, a human-readable reason. `None` when `ok`.
    pub reason: Option<String>,
}

/// Result of [`RequestKind::ProbeServer`]. DNS and connect are
/// timed independently so the UI can distinguish "slow DNS" from
/// "firewall ate the SYN". Failure resolves with `reachable: false`
/// rather than an [`Outbound::Error`] frame so the timing renders
/// alongside the failure.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProbeReport {
    /// The probed `host:port` after default-port substitution.
    /// `port` defaults to 443 when the profile's
    /// [`crate::domain::ServerAddress`] carried no explicit port.
    pub server: String,
    /// `true` when DNS resolved and the TCP connect completed.
    pub reachable: bool,
    /// DNS resolution wall-clock in milliseconds. `0.0` when the
    /// resolver step did not run (should not happen — we always
    /// resolve first).
    pub dns_resolve_ms: f64,
    /// TCP connect wall-clock in milliseconds. `0.0` when the
    /// connect step did not run (DNS failed first).
    pub tcp_connect_ms: f64,
    /// Free-form failure detail when `reachable` is `false`. `None`
    /// when the probe succeeded.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Result of [`RequestKind::DebugHandshake`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DebugHandshakeReport {
    /// Upstream proxy server under test.
    pub server: String,
    /// CONNECT target used to force one proxied stream.
    pub target: String,
    /// `true` when CONNECT returned 200 and post-CONNECT bytes came back.
    pub ok: bool,
    /// `true` when the temporary local HTTP proxy returned CONNECT 200.
    pub connect_ok: bool,
    /// Number of bytes read from the target after the diagnostic sent a
    /// TLS `ClientHello` through the established CONNECT tunnel.
    pub post_connect_received_bytes: u64,
    /// Wall-clock diagnostic duration in milliseconds.
    pub elapsed_ms: u64,
    /// First 1024 bytes written to the temporary local naive listener.
    pub local_sent_hex: String,
    /// First 1024 bytes read back from the temporary local naive listener.
    pub local_received_hex: String,
    /// Redacted stdout lines captured from the temporary naive child.
    pub naive_stdout: Vec<String>,
    /// Redacted stderr lines captured from the temporary naive child.
    pub naive_stderr: Vec<String>,
    /// Failure detail when the diagnostic did not complete cleanly.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

/// Aggregate result of [`RequestKind::RunDiagnostics`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct DiagnosticReport {
    /// Individual probe outcomes, in execution order.
    pub probes: Vec<ProbeResult>,
}

/// Outcome of one probe inside a [`DiagnosticReport`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ProbeResult {
    /// Probe name (e.g. `"upstream_https"`).
    pub name: String,
    /// `true` when the probe completed successfully.
    pub ok: bool,
    /// Free-form detail, e.g. command output or error text.
    pub detail: String,
    /// Wall-clock duration of the probe in milliseconds.
    pub duration_ms: u64,
}

/// Aggregate result of [`RequestKind::RunLatencyTest`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LatencyReport {
    /// Per-target measurements.
    pub samples: Vec<LatencySample>,
}

/// One latency probe inside a [`LatencyReport`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct LatencySample {
    /// URL probed (e.g. `"https://www.google.com/generate_204"`).
    pub url: String,
    /// `true` when the probe returned the expected status.
    pub ok: bool,
    /// Elapsed milliseconds, parsed from `curl --write-out`.
    pub elapsed_ms: f64,
    /// DNS resolution time (ms).
    pub dns_ms: f64,
    /// TCP connect time (ms).
    pub connect_ms: f64,
    /// TLS handshake time (ms).
    pub tls_ms: f64,
    /// Time to first byte (ms).
    pub first_byte_ms: f64,
    /// Free-form notes (curl error, status code, etc.).
    pub notes: String,
}

/// Unsolicited engine events.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "event", content = "data", rename_all = "snake_case")]
#[non_exhaustive]
pub enum Event {
    /// One line of `naive` stdout or stderr.
    LogLine {
        /// Originating stream.
        source: LogSource,
        /// Line content (no trailing newline).
        line: String,
    },
    /// Proxy lifecycle transition.
    StateChanged {
        /// `true` when the listener is up.
        running: bool,
    },
    /// Anomaly detected by the connection monitor.
    Anomaly {
        /// Machine-readable cause.
        reason: AnomalyReason,
        /// Human-readable detail.
        detail: String,
    },
    /// Diagnostic progress for long-running operations. Emitted live
    /// as each probe finishes so the UI log can render in real time
    /// rather than waiting for the full report.
    DiagnosticProgress {
        /// Step name (probe URL or symbolic identifier).
        step: String,
        /// `true` when the step finished without error.
        ok: bool,
        /// Wall-clock duration of just this step, in milliseconds.
        /// Defaults to 0 in older clients that did not include timing.
        #[serde(default)]
        elapsed_ms: u64,
    },
    /// Lightweight monitor snapshot for the developer overlay.
    /// Counts come from the same `lsof` parse that powers anomaly
    /// detection.
    TrafficSnapshot {
        /// Supervised naive process ID.
        pid: u32,
        /// Total established TCP connections in the lsof snapshot.
        established: u32,
        /// Established connections whose endpoints are loopback.
        local_clients: u32,
        /// Established connections with at least one non-loopback endpoint.
        remote: u32,
    },
}

/// Source of a log line.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum LogSource {
    /// Standard output of the `naive` child.
    Stdout,
    /// Standard error of the `naive` child.
    Stderr,
}

/// Categorised reason an anomaly was raised.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[non_exhaustive]
pub enum AnomalyReason {
    /// The listener is bound to a non-loopback address.
    ListeningOutsideLoopback,
    /// Total established connections exceeded the threshold.
    TooManyEstablished,
    /// Inbound local-client connections exceeded the threshold.
    TooManyLocalClients,
    /// Outbound remote connections exceeded the threshold.
    TooManyRemote,
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use crate::domain::{Credentials, Password, ProfileId, ServerAddress, Username};
    use serde_json::json;

    fn sample_profile() -> Profile {
        Profile::new(
            ProfileId::new("default"),
            ServerAddress::parse("naive.example.com").unwrap(),
            Credentials::new(
                Username::parse("alice").unwrap(),
                Password::parse("secret").unwrap(),
            ),
            Port::new(1080).unwrap(),
        )
    }

    #[test]
    fn request_validate_profile_serializes_correctly() {
        let req = Request {
            id: 7,
            kind: RequestKind::ValidateProfile {
                profile: sample_profile().into(),
            },
        };
        let value = serde_json::to_value(&req).unwrap();
        assert_eq!(value["id"], 7);
        assert_eq!(value["method"], "validate_profile");
        assert_eq!(value["params"]["profile"]["server"], "naive.example.com");
    }

    #[test]
    fn request_stop_has_empty_params() {
        let req = Request {
            id: 11,
            kind: RequestKind::StopProxy,
        };
        let value = serde_json::to_value(&req).unwrap();
        assert_eq!(value["method"], "stop_proxy");
        assert_eq!(value["params"], serde_json::Value::Null);
    }

    #[test]
    fn request_round_trips_through_json() {
        let req = Request {
            id: 1,
            kind: RequestKind::GeneratePac {
                direct_domains: vec!["baidu.com".to_owned()],
                port: Port::new(1080).unwrap(),
            },
        };
        let json = serde_json::to_string(&req).unwrap();
        let back: Request = serde_json::from_str(&json).unwrap();
        assert_eq!(req, back);
    }

    #[test]
    fn outbound_response_shape() {
        let out = Outbound::Response {
            id: 3,
            result: ResponsePayload::Started { pid: 42_000 },
        };
        let value = serde_json::to_value(&out).unwrap();
        assert_eq!(value["kind"], "response");
        assert_eq!(value["id"], 3);
        assert_eq!(value["result"]["type"], "started");
        assert_eq!(value["result"]["pid"], 42_000);
    }

    #[test]
    fn outbound_error_shape() {
        let out = Outbound::Error {
            id: 5,
            error: ErrorPayload::new("invalid_profile", "port must be 1..=65535"),
        };
        let value = serde_json::to_value(&out).unwrap();
        assert_eq!(value["kind"], "error");
        assert_eq!(value["error"]["code"], "invalid_profile");
        assert_eq!(value["error"]["message"], "port must be 1..=65535");
    }

    #[test]
    fn outbound_event_shape() {
        let out = Outbound::Event(Event::LogLine {
            source: LogSource::Stderr,
            line: "ready".to_owned(),
        });
        let value = serde_json::to_value(&out).unwrap();
        assert_eq!(value["kind"], "event");
        assert_eq!(value["event"], "log_line");
        assert_eq!(value["data"]["source"], "stderr");
        assert_eq!(value["data"]["line"], "ready");
    }

    #[test]
    fn traffic_snapshot_event_shape() {
        let out = Outbound::Event(Event::TrafficSnapshot {
            pid: 42,
            established: 7,
            local_clients: 5,
            remote: 2,
        });
        let value = serde_json::to_value(&out).unwrap();
        assert_eq!(value["kind"], "event");
        assert_eq!(value["event"], "traffic_snapshot");
        assert_eq!(value["data"]["pid"], 42);
        assert_eq!(value["data"]["established"], 7);
        assert_eq!(value["data"]["local_clients"], 5);
        assert_eq!(value["data"]["remote"], 2);
    }

    #[test]
    fn outbound_round_trips_through_json() {
        let out = Outbound::Event(Event::Anomaly {
            reason: AnomalyReason::TooManyEstablished,
            detail: "established=200".to_owned(),
        });
        let s = serde_json::to_string(&out).unwrap();
        let back: Outbound = serde_json::from_str(&s).unwrap();
        assert_eq!(out, back);
    }

    #[test]
    fn rejects_unknown_method() {
        let bad = json!({"id": 1, "method": "bogus", "params": {}});
        assert!(serde_json::from_value::<Request>(bad).is_err());
    }

    #[test]
    fn hello_request_serializes_with_null_params() {
        // Pin the wire shape: serde unit variant under
        // `tag = "method", content = "params"` must emit
        // `params: null`.
        let req = Request {
            id: 99,
            kind: RequestKind::Hello,
        };
        let value = serde_json::to_value(&req).unwrap();
        assert_eq!(value["id"], 99);
        assert_eq!(value["method"], "hello");
        assert_eq!(value["params"], serde_json::Value::Null);
        let back: Request = serde_json::from_value(value).unwrap();
        assert_eq!(req, back);
    }

    #[test]
    fn hello_reply_round_trips_with_protocol_version() {
        let out = Outbound::Response {
            id: 99,
            result: ResponsePayload::HelloReply {
                protocol_version: PROTOCOL_VERSION,
                engine_version: env!("CARGO_PKG_VERSION").to_owned(),
            },
        };
        let s = serde_json::to_string(&out).unwrap();
        let value: serde_json::Value = serde_json::from_str(&s).unwrap();
        assert_eq!(value["kind"], "response");
        assert_eq!(value["result"]["type"], "hello_reply");
        assert_eq!(value["result"]["protocol_version"], PROTOCOL_VERSION);
        let back: Outbound = serde_json::from_str(&s).unwrap();
        assert_eq!(out, back);
    }

    #[test]
    fn probe_server_request_round_trips() {
        let req = Request {
            id: 17,
            kind: RequestKind::ProbeServer {
                profile: sample_profile(),
                timeout_secs: Some(7),
            },
        };
        let value = serde_json::to_value(&req).unwrap();
        assert_eq!(value["method"], "probe_server");
        assert_eq!(value["params"]["timeout_secs"], 7);
        assert_eq!(value["params"]["profile"]["server"], "naive.example.com");
        let back: Request = serde_json::from_value(value).unwrap();
        assert_eq!(req, back);
    }

    #[test]
    fn probe_server_request_omits_timeout_when_none() {
        let req = Request {
            id: 18,
            kind: RequestKind::ProbeServer {
                profile: sample_profile(),
                timeout_secs: None,
            },
        };
        let value = serde_json::to_value(&req).unwrap();
        // `skip_serializing_if = "Option::is_none"`: the field
        // must be absent (not explicit null) so the Swift side's
        // "use engine default" semantics has no ambiguity.
        assert!(value["params"].get("timeout_secs").is_none());
    }

    #[test]
    fn probe_report_response_has_flat_shape_with_type_tag() {
        let out = Outbound::Response {
            id: 19,
            result: ResponsePayload::Probe(ProbeReport {
                server: "naive.example.com:443".to_owned(),
                reachable: true,
                dns_resolve_ms: 12.5,
                tcp_connect_ms: 33.0,
                error: None,
            }),
        };
        let value = serde_json::to_value(&out).unwrap();
        assert_eq!(value["kind"], "response");
        // Newtype tuple variant under `serde(tag = "type")` —
        // fields hoist alongside the tag, no `probe` nesting.
        assert_eq!(value["result"]["type"], "probe");
        assert_eq!(value["result"]["server"], "naive.example.com:443");
        assert_eq!(value["result"]["reachable"], true);
        assert_eq!(value["result"]["dns_resolve_ms"], 12.5);
        assert_eq!(value["result"]["tcp_connect_ms"], 33.0);
        // `None` + `skip_serializing_if`: field must be absent on
        // the wire, not explicit null.
        assert!(value["result"].get("error").is_none());
        let back: Outbound = serde_json::from_value(value).unwrap();
        assert_eq!(out, back);
    }

    #[test]
    fn probe_report_response_round_trips_with_error() {
        let out = Outbound::Response {
            id: 20,
            result: ResponsePayload::Probe(ProbeReport {
                server: "naive.example.com:443".to_owned(),
                reachable: false,
                dns_resolve_ms: 0.0,
                tcp_connect_ms: 0.0,
                error: Some("DNS resolve failed: nodename nor servname provided".to_owned()),
            }),
        };
        let s = serde_json::to_string(&out).unwrap();
        let back: Outbound = serde_json::from_str(&s).unwrap();
        assert_eq!(out, back);
    }

    #[test]
    fn debug_handshake_request_round_trips() {
        let req = Request {
            id: 23,
            kind: RequestKind::DebugHandshake {
                binary_path: "/usr/local/bin/naive".into(),
                profile: sample_profile(),
                timeout_secs: Some(12),
            },
        };
        let value = serde_json::to_value(&req).unwrap();
        assert_eq!(value["method"], "debug_handshake");
        assert_eq!(value["params"]["binary_path"], "/usr/local/bin/naive");
        assert_eq!(value["params"]["profile"]["server"], "naive.example.com");
        assert_eq!(value["params"]["timeout_secs"], 12);
        let back: Request = serde_json::from_value(value).unwrap();
        assert_eq!(req, back);
    }

    #[test]
    fn debug_handshake_response_has_flat_shape_with_optional_error() {
        let out = Outbound::Response {
            id: 24,
            result: ResponsePayload::DebugHandshake(DebugHandshakeReport {
                server: "naive.example.com:443".to_owned(),
                target: "www.google.com:443".to_owned(),
                ok: false,
                connect_ok: true,
                post_connect_received_bytes: 0,
                elapsed_ms: 1200,
                local_sent_hex: "43 4f 4e 4e 45 43 54".to_owned(),
                local_received_hex: String::new(),
                naive_stdout: Vec::new(),
                naive_stderr: vec!["Preamble error: ERR_PROXY_CONNECTION_FAILED".to_owned()],
                error: Some("debug handshake timed out after 12s".to_owned()),
            }),
        };
        let value = serde_json::to_value(&out).unwrap();
        assert_eq!(value["kind"], "response");
        assert_eq!(value["result"]["type"], "debug_handshake");
        assert_eq!(value["result"]["server"], "naive.example.com:443");
        assert_eq!(value["result"]["target"], "www.google.com:443");
        assert_eq!(value["result"]["ok"], false);
        assert_eq!(value["result"]["connect_ok"], true);
        assert_eq!(value["result"]["post_connect_received_bytes"], 0);
        assert_eq!(value["result"]["elapsed_ms"], 1200);
        assert_eq!(value["result"]["local_sent_hex"], "43 4f 4e 4e 45 43 54");
        assert_eq!(value["result"]["local_received_hex"], "");
        assert_eq!(
            value["result"]["naive_stderr"][0],
            "Preamble error: ERR_PROXY_CONNECTION_FAILED"
        );
        assert_eq!(
            value["result"]["error"],
            "debug handshake timed out after 12s"
        );
        let back: Outbound = serde_json::from_value(value).unwrap();
        assert_eq!(out, back);
    }

    #[test]
    fn start_proxy_omits_monitor_interval_when_none() {
        let req = Request {
            id: 21,
            kind: RequestKind::StartProxy {
                binary_path: "/usr/local/bin/naive".into(),
                config_path: "/tmp/config.json".into(),
                port: Port::new(1080).unwrap(),
                monitor_interval_secs: None,
            },
        };
        let value = serde_json::to_value(&req).unwrap();
        // Field must be absent (not explicit null) so the
        // legacy-engine fallback path stays intact.
        assert!(
            value["params"].get("monitor_interval_secs").is_none(),
            "monitor_interval_secs must be absent on the wire when None: {value}"
        );
    }

    #[test]
    fn start_proxy_round_trips_with_explicit_monitor_interval() {
        let req = Request {
            id: 22,
            kind: RequestKind::StartProxy {
                binary_path: "/usr/local/bin/naive".into(),
                config_path: "/tmp/config.json".into(),
                port: Port::new(1080).unwrap(),
                monitor_interval_secs: Some(10),
            },
        };
        let s = serde_json::to_string(&req).unwrap();
        let back: Request = serde_json::from_str(&s).unwrap();
        assert_eq!(req, back);
    }
}
