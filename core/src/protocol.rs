//! Wire protocol shared between the engine and the Swift app.
//!
//! The protocol is **newline-delimited JSON**: each frame is one JSON object
//! terminated by `\n`. Frames flow:
//!
//! - **Swift → engine** on stdin as [`Request`] envelopes.
//! - **Engine → Swift** on stdout as [`Outbound`] envelopes (responses,
//!   errors, and events interleaved on a single stream).
//!
//! The Swift side mirrors these types in `Core/Protocol.swift`. A
//! `protocol_roundtrip` integration test verifies that the wire format stays
//! in lock-step.
//!
//! # Frame examples
//!
//! Request:
//!
//! ```json
//! {"id":1,"method":"validate_profile","params":{"profile":{...}}}
//! ```
//!
//! Successful response:
//!
//! ```json
//! {"kind":"response","id":1,"result":{"type":"ack"}}
//! ```
//!
//! Error response:
//!
//! ```json
//! {"kind":"error","id":1,"error":{"code":"invalid_profile","message":"..."}}
//! ```
//!
//! Event (no `id` because events are unsolicited):
//!
//! ```json
//! {"kind":"event","event":"log_line","data":{"source":"stdout","line":"..."}}
//! ```

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::domain::{Port, Profile, ProxyTestMode, RawProfile};

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
    /// Validate a profile and return whether it is well-formed.
    ///
    /// **v0.1.7.16 (Rust-F#1):** the variant now carries a
    /// `RawProfile` rather than a fully-validated `Profile`.
    /// Previously the `serde` deserializer did the validation
    /// before this arm could run — making the `ok:false`
    /// branch of `ValidationReport` structurally unreachable.
    /// The dispatcher now runs `Profile::try_from(raw)` itself,
    /// surfacing both branches of the contract in line with the
    /// SM-3 hardening on the HTTP server side.
    ValidateProfile {
        /// The profile to validate (un-validated wire shape).
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
    /// Diagnostic progress for long-running operations. Emitted live as
    /// each probe inside `run_diagnostics` / `run_latency` finishes so
    /// the UI log can render `✓ probe_name (47ms)` in real time instead
    /// of waiting for the whole report to come back as a single
    /// `Response::Diagnostic` / `Response::Latency` payload.
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
                profile: RawProfile::from(sample_profile()),
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
}
