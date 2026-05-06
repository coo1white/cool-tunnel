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

/// Wire-format protocol version negotiated by [`RequestKind::Hello`] /
/// [`ResponsePayload::HelloReply`].
///
/// Bump on any breaking change to the JSON-over-stdio frame shapes
/// (renamed/removed variants, changed field types, semantic
/// reinterpretations). Additive changes — new request variants, new
/// optional fields — keep the existing version number; the Swift
/// caller and Rust engine each fall back gracefully on the absence of
/// new fields they don't understand.
///
/// The Swift client compares this against its own constant during
/// `CoreClient.start()` and refuses to proceed on a hard mismatch
/// rather than letting the user hit cryptic deserialization errors
/// later in the session. For the legacy case of an older engine that
/// doesn't implement `Hello` at all (returns `invalid_request` for the
/// unknown method), the Swift side treats that as protocol version 0
/// — accept and continue, since the historical behaviour is what the
/// engine still implements.
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
    /// Takes [`RawProfile`] (the wire shape, no validation runs
    /// at deserialize) so the handler can inspect *which field*
    /// failed and produce a per-field reason. Returns a
    /// successful [`Outbound::Response`] in both cases:
    ///
    /// - Valid input → `ValidationReport { ok: true,
    ///   reason: None }`.
    /// - Invalid input → `ValidationReport { ok: false,
    ///   reason: Some("…") }` with the
    ///   [`crate::domain::ValidationError`] display string
    ///   explaining which field failed and why.
    ///
    /// **2026-05-06 design reversal.** Previously carried
    /// validated [`Profile`], so the handler was unconditionally
    /// `ok: true` and invalid profiles were rejected by the
    /// outer deserializer as `invalid_request` error frames.
    /// The reversal aligns stdio with server-mode's HTTP
    /// `/naive/validate` shape (SM-3) and lets `validate_profile`
    /// work as a probe — Swift callers can ask "is this profile
    /// valid?" and parse the structured reason without catching
    /// a transport error. The Swift caller at
    /// `TunnelOrchestrator.swift:834` already had the
    /// `validation.ok == false` branch coded; under the prior
    /// design it was dead code.
    ///
    /// Other request variants ([`RequestKind::StartProxy`],
    /// [`RequestKind::GenerateNaiveConfig`]) continue to carry
    /// validated [`Profile`] — their handlers rely on the
    /// type-system invariants, and their callers are committing
    /// to *use* the profile, so an invalid one there is
    /// genuinely an error condition (an `invalid_request` frame
    /// is right for them).
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
        /// interval in seconds. The monitor periodically probes
        /// `lsof` for the supervised PID's listening socket and the
        /// bound flag (loopback) for the anomaly detector; lowering
        /// the interval cuts the time-to-detect for naive crashes
        /// at the cost of more `lsof` invocations per minute.
        ///
        /// `None` (or the field absent on the wire) keeps the
        /// historical 5-second cadence. The handler clamps the
        /// effective value into `[1, 60]` so a misuse can't burn
        /// CPU by spinning lsof at sub-second intervals or hide a
        /// crash for hours by setting an enormous value. Added in
        /// `PROTOCOL_VERSION` 1 as an optional field — older engines
        /// that ignore it stay on the constant.
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
    /// Liveness probe — returns whether naive is currently
    /// running and, if so, its PID. Added for **UX-F#7**: the
    /// Swift orchestrator's no-restart hot-swap path
    /// (`applyModeWithoutRestart`) leaves naive untouched while
    /// reconfiguring system proxy. If naive happens to die in
    /// that ~50 ms window, the orchestrator's
    /// `transitionInFlight` gate suppresses the
    /// `stateChanged(false)` event (UX-F#5) — so the swap
    /// declares success while the engine is in fact dead.
    /// Calling `ProbeNaiveLive` *after* the swap converts that
    /// silent gap into an explicit yes/no answer the
    /// orchestrator can route on. Cheap: a single in-process
    /// read of `EngineState.supervisor.is_some()`.
    ProbeNaiveLive,
    /// Wire-protocol handshake. Sent by the Swift client right
    /// after spawning the engine subprocess; the engine answers
    /// with [`ResponsePayload::HelloReply`] carrying the
    /// [`PROTOCOL_VERSION`] constant compiled into this binary
    /// plus its `CARGO_PKG_VERSION`. The Swift caller compares
    /// the protocol version to its own and refuses to proceed
    /// on hard mismatch.
    ///
    /// Older engines that predate this variant return an
    /// `invalid_request` error. The Swift side treats that as
    /// protocol version 0 (legacy) and continues — the
    /// historical behaviour is what the engine still
    /// implements.
    Hello,
    /// Pre-flight reachability probe against the upstream
    /// server. Resolves the hostname and opens a TCP connection
    /// to `host:port` (defaulting to `:443` when the profile's
    /// `ServerAddress` carries no explicit port), measuring
    /// each step. Surfaced in the Swift UI as a "Test
    /// Connection" affordance the user can hit before clicking
    /// Start; catches the most common failure modes — wrong
    /// hostname, blocked port, server down, SNI proxy not
    /// responding — without standing up the full naive child.
    ///
    /// Intentionally *not* a TLS handshake or auth probe at
    /// this revision: a real auth probe would require pulling
    /// in a TLS stack (the crate forbids `unsafe_code`, so
    /// rolling our own is off the table) and the most common
    /// reason a connect succeeds today is that the cover-site
    /// is replying — useful signal on its own. Full TLS+auth
    /// validation continues to live in `RunDiagnostics`, which
    /// requires a running proxy.
    ProbeServer {
        /// The validated profile to probe. Only the
        /// [`crate::domain::ServerAddress`] is consulted; the
        /// rest of the profile is accepted for parity with
        /// other variants and so a future revision can layer
        /// in an auth probe without changing the wire shape.
        profile: Profile,
        /// Optional per-step deadline in seconds, clamped into
        /// `[1, 30]`. `None` defaults to 5. Each step (DNS,
        /// TCP) gets its own deadline so the worst-case wall
        /// clock is `2 * timeout_secs`.
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
    /// `probe_naive_live` reply. `running` is the canonical
    /// flag (`EngineState.supervisor.is_some()`); `pid`
    /// surfaces the supervisor's PID when running, `None`
    /// otherwise. The PID is for diagnostics and isn't read
    /// by the orchestrator's hot-swap routing logic — only
    /// `running` matters there.
    NaiveLiveness {
        /// `true` when the engine has a live `ProxySupervisor`.
        running: bool,
        /// PID of the running naive child, when running.
        pid: Option<u32>,
    },
    /// `hello` reply. Carries the engine's compiled-in
    /// [`PROTOCOL_VERSION`] and `CARGO_PKG_VERSION` so the
    /// Swift caller can refuse a hard version mismatch and
    /// surface the engine version in support diagnostics.
    HelloReply {
        /// Wire-format protocol version of this engine build.
        protocol_version: u32,
        /// `cool-tunnel-core` semver (`CARGO_PKG_VERSION`).
        engine_version: String,
    },
    /// `probe_server` reply.
    Probe(ProbeReport),
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

/// Result of [`RequestKind::ProbeServer`].
///
/// Resolution and connect are timed independently so the Swift UI can
/// distinguish "the DNS server is slow" (long `dns_resolve_ms`, short
/// `tcp_connect_ms`, `reachable: true`) from "the firewall ate the
/// SYN" (long or zero `tcp_connect_ms`, `reachable: false`,
/// `error: Some("…connect refused/timed out…")`).
///
/// On any failure the report still resolves with `reachable: false`
/// and a human-readable `error` rather than producing an
/// [`Outbound::Error`] frame — the probe completed, the *server* did
/// not, and the Swift caller wants to render the timing alongside the
/// failure rather than catch a transport-error exception.
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
                Username::parse("nick").unwrap(),
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
