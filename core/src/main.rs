#![forbid(unsafe_code)]
#![warn(missing_docs)]

//! Standalone binary entry point for the `cool-tunnel-core` engine.
//!
//! The binary is a long-lived subprocess spawned by the macOS app. It reads
//! newline-delimited JSON [`Request`]s on stdin, dispatches them to the
//! engine modules, and writes [`Outbound`] frames (responses, errors, and
//! events) back as newline-delimited JSON on stdout. Diagnostic logs are
//! written to stderr via `tracing`.
//!
//! Error handling on the protocol boundary is total: malformed frames
//! produce an [`Outbound::Error`] reply rather than panicking, and a missing
//! `id` triggers a graceful "id-zero error" so the Swift side never sees an
//! incomplete frame.

use std::process::ExitCode;
use std::sync::Arc;

use cool_tunnel_core::config::{generate_pac, NaiveConfig};
use cool_tunnel_core::diagnostics::{run_diagnostics, run_latency};
use cool_tunnel_core::monitor;
use cool_tunnel_core::protocol::{
    AnomalyReason, ErrorPayload, Event, Outbound, Request, RequestKind, ResponsePayload,
    ValidationReport,
};
use cool_tunnel_core::supervisor::ProxySupervisor;
use tokio::io::{AsyncWriteExt as _, BufReader};
use tokio::sync::{mpsc, Mutex, Semaphore};
use tokio::task::JoinHandle;

const OUTBOUND_BUFFER: usize = 256;
const EVENT_BUFFER: usize = 256;
const MONITOR_INTERVAL_SECS: u64 = 5;
/// Per-anomaly-reason suppression window for [`monitor_loop`]. The same
/// reason is forwarded to Swift at most once per window; distinct
/// reasons are not blocked by each other. 100 ms balances responsive
/// surfacing of new conditions against UI-flooding when the proxy is
/// flapping. Tuned together with the stress test in
/// `cool_tunnel_core::util::debounce`.
const ANOMALY_DEBOUNCE: std::time::Duration = std::time::Duration::from_millis(100);
/// Hard cap on a single inbound JSON frame (one stdin line), in bytes.
/// Frames larger than this are dropped with an `Outbound::Error` reply
/// rather than buffered. 1 MiB is two orders of magnitude above any
/// legitimate request the Swift app can produce.
const MAX_FRAME_BYTES: usize = 1024 * 1024;
/// Maximum number of in-flight request handler tasks. A single misbehaving
/// parent cannot fork-bomb the engine past this ceiling; further requests
/// queue on `Semaphore::acquire_owned` until a permit returns.
const MAX_INFLIGHT_REQUESTS: usize = 32;

#[tokio::main(flavor = "multi_thread")]
async fn main() -> ExitCode {
    init_tracing();
    tracing::info!("cool-tunnel-core starting");

    if let Err(err) = run().await {
        tracing::error!(error = %err, "engine exited with error");
        return ExitCode::FAILURE;
    }
    ExitCode::SUCCESS
}

fn init_tracing() {
    // Hard-clamped to `info`. We deliberately do **not** honour `RUST_LOG`
    // because a parent that sets `RUST_LOG=debug` could enable verbose
    // tracing on a future code path that touches credentials, leaking them
    // through stderr. Engine logs are a stable, audited surface; raise the
    // ceiling by editing this line, not by setting an env var.
    let filter = tracing_subscriber::EnvFilter::new("info");
    tracing_subscriber::fmt()
        .with_env_filter(filter)
        .with_writer(std::io::stderr)
        .with_target(false)
        .compact()
        .init();
}

/// Engine-wide mutable state. Wrapped in a [`Mutex`] and shared between the
/// stdin reader and any background tasks.
#[derive(Default)]
struct EngineState {
    supervisor: Option<ProxySupervisor>,
    monitor_handle: Option<JoinHandle<()>>,
    active_port: Option<cool_tunnel_core::domain::Port>,
}

async fn run() -> std::io::Result<()> {
    let state = Arc::new(Mutex::new(EngineState::default()));
    let inflight = Arc::new(Semaphore::new(MAX_INFLIGHT_REQUESTS));
    let (outbound_tx, outbound_rx) = mpsc::channel::<Outbound>(OUTBOUND_BUFFER);
    let (event_tx, event_rx) = mpsc::channel::<Event>(EVENT_BUFFER);

    let writer_task = tokio::spawn(stdout_writer(outbound_rx));
    let bridge_task = tokio::spawn(event_bridge(event_rx, outbound_tx.clone()));

    let mut reader = BufReader::new(tokio::io::stdin());
    let mut frame = Vec::with_capacity(8 * 1024);

    loop {
        frame.clear();
        match read_capped_line(&mut reader, &mut frame, MAX_FRAME_BYTES).await? {
            FrameOutcome::Eof => break,
            FrameOutcome::TooLarge => {
                let _ = outbound_tx
                    .send(Outbound::Error {
                        id: 0,
                        error: ErrorPayload::new(
                            "frame_too_large",
                            format!("request frame exceeded {MAX_FRAME_BYTES} bytes"),
                        ),
                    })
                    .await;
                continue;
            }
            FrameOutcome::Frame => {}
        }

        let frame_str = match std::str::from_utf8(&frame) {
            Ok(s) => s.trim(),
            Err(err) => {
                let _ = outbound_tx
                    .send(Outbound::Error {
                        id: 0,
                        error: ErrorPayload::new("malformed_request", err.to_string()),
                    })
                    .await;
                continue;
            }
        };
        if frame_str.is_empty() {
            continue;
        }

        // Two-phase parse: extract `id` first as a raw `Value`, then attempt
        // typed deserialization. If only the typed parse fails (e.g. invalid
        // profile fields), we still have the original `id` to correlate the
        // error reply with the caller's waiter.
        let value: serde_json::Value = match serde_json::from_str(frame_str) {
            Ok(v) => v,
            Err(err) => {
                let _ = outbound_tx
                    .send(Outbound::Error {
                        id: 0,
                        error: ErrorPayload::new("malformed_request", err.to_string()),
                    })
                    .await;
                continue;
            }
        };
        let id = value
            .get("id")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);

        match serde_json::from_value::<Request>(value) {
            Ok(request) => {
                if matches!(request.kind, RequestKind::Shutdown) {
                    let _ = outbound_tx
                        .send(Outbound::Response {
                            id,
                            result: ResponsePayload::Ack,
                        })
                        .await;
                    break;
                }

                // Cap concurrent in-flight handlers so a flood of requests
                // cannot exhaust task / memory budgets. Acquire **before**
                // spawning so backpressure surfaces on the stdin loop.
                let Ok(permit) = Arc::clone(&inflight).acquire_owned().await else {
                    break; // semaphore closed -> shutdown
                };
                let state = Arc::clone(&state);
                let outbound_tx = outbound_tx.clone();
                let event_tx = event_tx.clone();
                tokio::spawn(async move {
                    let _permit = permit; // released on drop
                    handle_request(state, request, outbound_tx, event_tx).await;
                });
            }
            Err(err) => {
                let _ = outbound_tx
                    .send(Outbound::Error {
                        id,
                        error: ErrorPayload::new("invalid_request", err.to_string()),
                    })
                    .await;
            }
        }
    }

    drain(state).await;
    drop(event_tx);
    drop(outbound_tx);
    let _ = bridge_task.await;
    let _ = writer_task.await;
    Ok(())
}

/// Per-frame outcome from [`read_capped_line`].
enum FrameOutcome {
    /// Stdin reached EOF with no pending bytes.
    Eof,
    /// A complete line within the size cap; bytes are in the supplied buffer.
    Frame,
    /// The line exceeded the cap; the offending bytes have been discarded
    /// from the underlying reader, but the buffer is empty so the caller
    /// can emit a structured error and resume.
    TooLarge,
}

/// Reads a single newline-terminated frame, dropping the line entirely if
/// it would exceed `max` bytes. Unlike `BufReader::lines()`, this never
/// allocates beyond `max` bytes regardless of attacker behaviour.
async fn read_capped_line<R>(
    reader: &mut R,
    buffer: &mut Vec<u8>,
    max: usize,
) -> std::io::Result<FrameOutcome>
where
    R: tokio::io::AsyncBufRead + Unpin,
{
    use tokio::io::AsyncBufReadExt as _;
    buffer.clear();
    let mut over = false;

    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return Ok(if over {
                FrameOutcome::TooLarge
            } else if buffer.is_empty() {
                FrameOutcome::Eof
            } else {
                // Final partial line at EOF — treat as a frame.
                FrameOutcome::Frame
            });
        }

        if let Some(pos) = chunk.iter().position(|&b| b == b'\n') {
            let take = pos + 1;
            if !over && buffer.len() + take <= max {
                buffer.extend_from_slice(&chunk[..take]);
                reader.consume(take);
                return Ok(FrameOutcome::Frame);
            }
            // Either already over, or this terminator pushes us over.
            buffer.clear();
            reader.consume(take);
            return Ok(FrameOutcome::TooLarge);
        }

        let len = chunk.len();
        if !over && buffer.len() + len > max {
            // First chunk that pushes us past the cap. Drop accumulated
            // data, keep scanning for the terminator so we resync the
            // stream on the next iteration.
            over = true;
            buffer.clear();
        }
        if !over {
            buffer.extend_from_slice(chunk);
        }
        reader.consume(len);
    }
}

async fn handle_request(
    state: Arc<Mutex<EngineState>>,
    request: Request,
    outbound: mpsc::Sender<Outbound>,
    events: mpsc::Sender<Event>,
) {
    let id = request.id;
    let result = dispatch(state, request.kind, events).await;
    let frame = match result {
        Ok(payload) => Outbound::Response {
            id,
            result: payload,
        },
        Err(error) => Outbound::Error { id, error },
    };
    let _ = outbound.send(frame).await;
}

async fn dispatch(
    state: Arc<Mutex<EngineState>>,
    kind: RequestKind,
    events: mpsc::Sender<Event>,
) -> Result<ResponsePayload, ErrorPayload> {
    match kind {
        RequestKind::ValidateProfile { profile: _ } => {
            Ok(ResponsePayload::Validation(ValidationReport {
                ok: true,
                reason: None,
            }))
        }
        RequestKind::GenerateNaiveConfig { profile } => {
            let config = NaiveConfig::from_profile(&profile);
            let json = config
                .to_pretty_json()
                .map_err(|err| ErrorPayload::new("serialization", err.to_string()))?;
            Ok(ResponsePayload::NaiveConfig { json })
        }
        RequestKind::GeneratePac {
            direct_domains,
            port,
        } => {
            let js = generate_pac(&direct_domains, port);
            Ok(ResponsePayload::Pac { js })
        }
        RequestKind::StartProxy {
            binary_path,
            config_path,
            port,
        } => {
            let mut guard = state.lock().await;
            if guard.supervisor.is_some() {
                return Err(ErrorPayload::new(
                    "already_running",
                    "proxy is already running",
                ));
            }
            let supervisor = ProxySupervisor::spawn(&binary_path, &config_path, events.clone())
                .await
                .map_err(|err| ErrorPayload::new("spawn_failed", err.to_string()))?;
            let pid = supervisor.pid();
            let monitor_handle = tokio::spawn(monitor_loop(pid, port, events));
            guard.supervisor = Some(supervisor);
            guard.monitor_handle = Some(monitor_handle);
            guard.active_port = Some(port);
            Ok(ResponsePayload::Started { pid })
        }
        RequestKind::StopProxy => {
            let (supervisor, monitor_handle) = {
                let mut guard = state.lock().await;
                guard.active_port = None;
                (guard.supervisor.take(), guard.monitor_handle.take())
            };
            let Some(supervisor) = supervisor else {
                return Err(ErrorPayload::new("not_running", "proxy is not running"));
            };
            if let Some(handle) = monitor_handle {
                handle.abort();
                let _ = handle.await;
            }
            supervisor
                .stop()
                .await
                .map_err(|err| ErrorPayload::new("stop_failed", err.to_string()))?;
            Ok(ResponsePayload::Stopped)
        }
        RequestKind::RunDiagnostics => {
            let port = current_port(&state).await.ok_or_else(|| {
                ErrorPayload::new("not_running", "diagnostics require a running proxy")
            })?;
            // Pass the engine-wide events channel so each probe can
            // emit a `DiagnosticProgress` with timing as it completes.
            // The Swift orchestrator turns those into live log lines.
            let report = run_diagnostics(port, &events)
                .await
                .map_err(|err| ErrorPayload::new("diagnostic_failed", err.to_string()))?;
            Ok(ResponsePayload::Diagnostic(report))
        }
        RequestKind::RunLatencyTest { mode } => {
            let port = current_port(&state).await.ok_or_else(|| {
                ErrorPayload::new("not_running", "latency test requires a running proxy")
            })?;
            let report = run_latency(mode, port, &events)
                .await
                .map_err(|err| ErrorPayload::new("diagnostic_failed", err.to_string()))?;
            Ok(ResponsePayload::Latency(report))
        }
        RequestKind::Shutdown => Ok(ResponsePayload::Ack),
        // The protocol is `#[non_exhaustive]`; add a defensive arm so adding a
        // future variant is a forward-compat error message rather than a panic.
        _ => Err(ErrorPayload::new(
            "unimplemented_method",
            "this engine version does not implement the requested method",
        )),
    }
}

async fn monitor_loop(pid: u32, port: cool_tunnel_core::domain::Port, events: mpsc::Sender<Event>) {
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(MONITOR_INTERVAL_SECS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    // Skip the first immediate tick — give naive a moment to bind before we probe.
    ticker.tick().await;

    // Anomalies are emitted at most once per `ANOMALY_DEBOUNCE` per
    // reason. The probe interval is currently 5 s so this only kicks
    // in on tighter probe schedules or when several consecutive probes
    // happen to fall inside the window after a missed tick. Keeping
    // the debouncer here (rather than at the channel boundary) makes
    // the suppression policy local and easy to reason about.
    let mut anomaly_debouncer = cool_tunnel_core::util::debounce::Debouncer::new(ANOMALY_DEBOUNCE);

    loop {
        ticker.tick().await;
        match monitor::run(pid, port).await {
            Ok(snapshot) => {
                if let Some(anomaly) = snapshot.anomaly {
                    let reason: AnomalyReason = (&anomaly).into();
                    if anomaly_debouncer.admit(reason, std::time::Instant::now()) {
                        let _ = events
                            .send(Event::Anomaly {
                                reason,
                                detail: anomaly.detail,
                            })
                            .await;
                    }
                }
            }
            Err(err) => {
                tracing::warn!(error = %err, "lsof probe failed");
            }
        }
    }
}

async fn stdout_writer(mut rx: mpsc::Receiver<Outbound>) {
    let mut stdout = tokio::io::stdout();
    while let Some(frame) = rx.recv().await {
        match serde_json::to_vec(&frame) {
            Ok(mut bytes) => {
                bytes.push(b'\n');
                if stdout.write_all(&bytes).await.is_err() {
                    break;
                }
                if stdout.flush().await.is_err() {
                    break;
                }
            }
            Err(err) => {
                tracing::error!(error = %err, "failed to serialize outbound frame");
            }
        }
    }
    let _ = stdout.flush().await;
}

async fn event_bridge(mut rx: mpsc::Receiver<Event>, outbound: mpsc::Sender<Outbound>) {
    while let Some(event) = rx.recv().await {
        if outbound.send(Outbound::Event(event)).await.is_err() {
            break;
        }
    }
}

async fn current_port(state: &Arc<Mutex<EngineState>>) -> Option<cool_tunnel_core::domain::Port> {
    let guard = state.lock().await;
    guard.active_port
}

async fn drain(state: Arc<Mutex<EngineState>>) {
    let (supervisor, monitor_handle) = {
        let mut guard = state.lock().await;
        (guard.supervisor.take(), guard.monitor_handle.take())
    };
    if let Some(handle) = monitor_handle {
        handle.abort();
        let _ = handle.await;
    }
    if let Some(supervisor) = supervisor {
        let _ = supervisor.stop().await;
    }
}
