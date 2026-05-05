//! Client mode: long-lived JSON-over-stdio engine driven by the
//! macOS app (or any other client UI).
//!
//! This is the original — and historically only — `cool-tunnel-core`
//! mode. Reads `Request` frames on stdin, writes `Outbound` frames
//! (response / error / event) on stdout. Spawns the bundled
//! `naive` binary as a child process; supervises it; emits log
//! lines, anomaly events, and diagnostic progress to the client.
//!
//! Lives next to `server_mode.rs` so the same binary can be
//! launched in either flavour from the same `--mode` flag in
//! `main.rs`.

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
// `ANOMALY_DEBOUNCE` and the previous "Per-anomaly-reason
// suppression window" doc-comment have been removed: the
// `Debouncer::default()` impl in `util::debounce` is now the
// single source of truth (50 ms — tightened from 100 ms in
// v0.1.7.4 to halve auto-stop latency). Two declarations would
// risk drift across the LTSC window.

/// Hard cap on a single inbound JSON frame (one stdin line), in
/// bytes. Frames larger than this are dropped with an
/// `Outbound::Error` reply rather than buffered. 1 MiB is two
/// orders of magnitude above any legitimate request the Swift app
/// can produce.
pub const MAX_FRAME_BYTES: usize = 1024 * 1024;

/// Maximum number of concurrent request handler tasks.
///
/// The Swift app issues requests serially today (each `await` on
/// the response before sending the next), so the hard cap exists
/// only to bound memory if a future caller pipelines: 32 ×
/// `MAX_FRAME_BYTES` ≈ 32 MiB worst-case in-flight buffer plus 32
/// `JoinHandle` allocations. Acquired via `acquire_owned().await`
/// — bursts beyond 32 *queue* rather than fail-fast; the eventual
/// throughput is bounded by the slowest dispatcher arm. (An
/// earlier doc-comment claimed "drop new requests" — that
/// behaviour would require `try_acquire_owned` and an explicit
/// `Outbound::Error` reply on rejection, which we don't do today.)
const MAX_INFLIGHT_REQUESTS: usize = 32;

/// Engine-wide mutable state. Wrapped in a [`Mutex`] and shared
/// between the stdin reader and any background tasks.
///
/// **v0.1.7.10 additions** (Ru-A1 / Ru-A3):
/// - `stopping`: dispatcher sets `true` while holding the lock to
///   block concurrent `start_proxy` from spawning a second naive
///   while a stop is in flight (Ru-A3 TOCTOU fix). Cleared after
///   `supervisor.stop().await` returns.
/// - `emitted_stopped`: at-most-once gate so the natural-death
///   path in `monitor_loop` and the user-stop path in the
///   dispatcher don't both emit `StateChanged{false}` for the
///   same transition (Ru-A1 single-emitter discipline). Reset
///   to `false` on every successful `start_proxy`.
#[derive(Default)]
struct EngineState {
    supervisor: Option<ProxySupervisor>,
    monitor_handle: Option<JoinHandle<()>>,
    active_port: Option<cool_tunnel_core::domain::Port>,
    anomaly_debouncer: cool_tunnel_core::util::debounce::Debouncer<AnomalyReason>,
    stopping: bool,
    emitted_stopped: bool,
}

/// Entry point for client mode. Returns when stdin reaches EOF or
/// the client sends `Shutdown`.
pub async fn run() -> std::io::Result<()> {
    let state = Arc::new(Mutex::new(EngineState::default()));
    let inflight = Arc::new(Semaphore::new(MAX_INFLIGHT_REQUESTS));
    let (outbound_tx, outbound_rx) = mpsc::channel::<Outbound>(OUTBOUND_BUFFER);
    let (event_tx, event_rx) = mpsc::channel::<Event>(EVENT_BUFFER);

    let writer_task = tokio::spawn(stdout_writer(outbound_rx));
    let bridge_task = tokio::spawn(event_bridge(event_rx, outbound_tx.clone()));

    let mut reader = BufReader::new(tokio::io::stdin());
    let mut frame = Vec::with_capacity(8 * 1024);

    // `outbound_tx.send` returning Err means the receiver
    // (`stdout_writer`) is gone — Swift dropped the pipe, the
    // process is shutting down. Propagate as `break` rather than
    // silently `let _ = …`-ing the error: the previous code would
    // keep reading frames forever after the writer died, allocating
    // and discarding work, masking real shutdown.
    macro_rules! emit_or_break {
        ($frame:expr) => {
            if outbound_tx.send($frame).await.is_err() {
                break;
            }
        };
    }

    loop {
        frame.clear();
        match read_capped_line(&mut reader, &mut frame, MAX_FRAME_BYTES).await? {
            FrameOutcome::Eof => break,
            FrameOutcome::TooLarge => {
                emit_or_break!(Outbound::Error {
                    id: 0,
                    error: ErrorPayload::new(
                        "frame_too_large",
                        format!("request frame exceeded {MAX_FRAME_BYTES} bytes"),
                    ),
                });
                continue;
            }
            FrameOutcome::Frame => {}
        }

        let frame_str = match std::str::from_utf8(&frame) {
            Ok(s) => s.trim(),
            Err(err) => {
                emit_or_break!(Outbound::Error {
                    id: 0,
                    error: ErrorPayload::new("malformed_request", err.to_string()),
                });
                continue;
            }
        };
        if frame_str.is_empty() {
            continue;
        }

        // Two-phase parse: extract `id` first as a raw `Value`, then
        // attempt typed deserialization. If only the typed parse
        // fails (e.g. invalid profile fields), we still have the
        // original `id` to correlate the error reply with the
        // caller's waiter.
        let value: serde_json::Value = match serde_json::from_str(frame_str) {
            Ok(v) => v,
            Err(err) => {
                emit_or_break!(Outbound::Error {
                    id: 0,
                    error: ErrorPayload::new("malformed_request", err.to_string()),
                });
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
                    emit_or_break!(Outbound::Response {
                        id,
                        result: ResponsePayload::Ack,
                    });
                    break;
                }

                let Ok(permit) = Arc::clone(&inflight).acquire_owned().await else {
                    break;
                };
                let state = Arc::clone(&state);
                let outbound_tx = outbound_tx.clone();
                let event_tx = event_tx.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    handle_request(state, request, outbound_tx, event_tx).await;
                });
            }
            Err(err) => {
                emit_or_break!(Outbound::Error {
                    id,
                    error: ErrorPayload::new("invalid_request", err.to_string()),
                });
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

enum FrameOutcome {
    Eof,
    Frame,
    TooLarge,
}

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
    // Hard cap on bytes discarded while in oversized-frame
    // resync mode. Without this, a misbehaving (or hostile)
    // parent feeding a multi-GB blob with no newline would burn
    // CPU forever in the consume loop. 16× MAX_FRAME_BYTES is
    // generous enough to swallow any legitimate overshoot
    // (truncated multi-MB curl-stderr blob, etc.) while still
    // bounding the worst case.
    let discard_cap = max.saturating_mul(16);
    let mut discarded: usize = 0;

    loop {
        let chunk = reader.fill_buf().await?;
        if chunk.is_empty() {
            return Ok(if over {
                FrameOutcome::TooLarge
            } else if buffer.is_empty() {
                FrameOutcome::Eof
            } else {
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
            buffer.clear();
            reader.consume(take);
            return Ok(FrameOutcome::TooLarge);
        }

        let len = chunk.len();
        if !over && buffer.len() + len > max {
            over = true;
            buffer.clear();
        }
        if over {
            discarded = discarded.saturating_add(len);
            if discarded > discard_cap {
                // Treat protocol-level desync as I/O failure so
                // the outer `client_mode::run` exits the read
                // loop and drains. Better to fail-fast than to
                // spin forever on a stream that will never
                // produce a `\n`.
                return Err(std::io::Error::new(
                    std::io::ErrorKind::InvalidData,
                    "stdin protocol desync: oversized-frame discard exceeded cap",
                ));
            }
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
    let was_start = matches!(request.kind, RequestKind::StartProxy { .. });
    let was_stop = matches!(request.kind, RequestKind::StopProxy);
    let result = dispatch(state, request.kind, outbound.clone(), events).await;
    let frame = match result {
        Ok(payload) => Outbound::Response {
            id,
            result: payload,
        },
        Err(error) => Outbound::Error { id, error },
    };
    let response_succeeded = matches!(&frame, Outbound::Response { .. });
    let _ = outbound.send(frame).await;
    // Ru#C4 fix: emit `state_changed` AFTER the response on the
    // same outbound channel so FIFO ordering guarantees the wire
    // sequence is `response → event`. Previously the event was
    // emitted from `ProxySupervisor::spawn` (for start) or
    // `monitor_lifecycle` (for stop), traveled through a
    // separate event channel + bridge task, and could overtake
    // the response. The supervisor now emits *only* the
    // natural-death event (naive crashes on its own); user-
    // initiated start/stop transitions are emitted here.
    if response_succeeded {
        if was_start {
            let _ = outbound
                .send(Outbound::Event(Event::StateChanged { running: true }))
                .await;
        } else if was_stop {
            let _ = outbound
                .send(Outbound::Event(Event::StateChanged { running: false }))
                .await;
        }
    }
}

async fn dispatch(
    state: Arc<Mutex<EngineState>>,
    kind: RequestKind,
    outbound: mpsc::Sender<Outbound>,
    events: mpsc::Sender<Event>,
) -> Result<ResponsePayload, ErrorPayload> {
    match kind {
        // The wire variant carries a fully-validated `Profile`
        // (see `protocol.rs` doc comment on `ValidateProfile`).
        // Validation runs at serde deserialization via Profile's
        // `try_from = "RawProfile"` attribute, so by the time we
        // reach this arm the input has already cleared every
        // domain-type check. An invalid profile would have
        // failed the outer `from_value::<Request>(value)` call
        // and been emitted as an `invalid_request` error frame
        // by the read loop above (see the `Err(err) =>
        // emit_or_break!(... "invalid_request" ...)` arm).
        //
        // The `_` bind is intentional: `validate_profile`'s
        // contract is "did this profile pass validation?", not
        // "do something with the profile." Now that the answer
        // is unconditionally "yes" (no by definition can't reach
        // here), we don't need to use the value.
        //
        // **Divergence from server_mode (SM-3):** HTTP
        // `/naive/validate` returns 200 with `ok:false` for
        // invalid profiles so HTTP clients see a uniform
        // 200-with-payload shape. Stdio mode talks to the
        // trusted Swift app and uses `Outbound::Error` for any
        // "you sent me bad data" — see the `RequestKind::
        // ValidateProfile` doc comment for the full rationale.
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
        } => start_proxy(state, binary_path, config_path, port, events).await,
        RequestKind::StopProxy => {
            // Take supervisor + monitor under the lock AND set
            // `stopping = true` so a concurrent `start_proxy` can't
            // spawn a second naive in the window between us
            // releasing the lock and `supervisor.stop()` returning
            // (Ru-A3 fix). Also pre-claim the at-most-once
            // emission flag so `monitor_loop`'s natural-death
            // detection skips emitting (Ru-A1: single emitter
            // per transition).
            let (supervisor, monitor_handle) = {
                let mut guard = state.lock().await;
                let Some(sup) = guard.supervisor.take() else {
                    return Err(ErrorPayload::new("not_running", "proxy is not running"));
                };
                let mh = guard.monitor_handle.take();
                guard.active_port = None;
                guard.stopping = true;
                guard.emitted_stopped = true;
                (sup, mh)
            };
            if let Some(handle) = monitor_handle {
                handle.abort();
                let _ = handle.await;
            }
            let stop_result = supervisor
                .stop()
                .await
                .map_err(|err| ErrorPayload::new("stop_failed", err.to_string()));
            // Release the stopping flag so a future `start_proxy`
            // can proceed. emitted_stopped stays true until the
            // next `start_proxy` resets it.
            {
                let mut guard = state.lock().await;
                guard.stopping = false;
            }
            stop_result?;
            Ok(ResponsePayload::Stopped)
        }
        RequestKind::RunDiagnostics => {
            let port = current_port(&state).await.ok_or_else(|| {
                ErrorPayload::new("not_running", "diagnostics require a running proxy")
            })?;
            let report = run_diagnostics(port, &outbound)
                .await
                .map_err(|err| ErrorPayload::new("diagnostic_failed", err.to_string()))?;
            Ok(ResponsePayload::Diagnostic(report))
        }
        RequestKind::RunLatencyTest { mode } => {
            let port = current_port(&state).await.ok_or_else(|| {
                ErrorPayload::new("not_running", "latency test requires a running proxy")
            })?;
            let report = run_latency(mode, port, &outbound)
                .await
                .map_err(|err| ErrorPayload::new("diagnostic_failed", err.to_string()))?;
            Ok(ResponsePayload::Latency(report))
        }
        RequestKind::Shutdown => Ok(ResponsePayload::Ack),
        // **UX-F#7 (v2.0.15):** liveness probe used by the Swift
        // orchestrator's no-restart hot-swap path. Reads
        // `EngineState.supervisor` under the lock — `Some(_)`
        // means naive is currently being supervised (alive);
        // `None` means it died, was stopped, or was never
        // started. `supervisor.pid()` is surfaced for diagnostic
        // logging on the Swift side; the routing decision uses
        // only `running`.
        RequestKind::ProbeNaiveLive => {
            let guard = state.lock().await;
            let pid = guard.supervisor.as_ref().map(ProxySupervisor::pid);
            Ok(ResponsePayload::NaiveLiveness {
                running: guard.supervisor.is_some(),
                pid,
            })
        }
        // The lib crate defines `RequestKind` with
        // `#[non_exhaustive]`; the binary crate (this file is a
        // submodule of `main.rs`) imports it through the public
        // surface, so the wildcard arm is structurally required
        // even though every documented variant is matched above.
        // Future variants land here as a forced compile failure
        // *only* if added to `protocol.rs` without bumping the lib
        // version — anyone adding a `RequestKind` variant should
        // add a real arm above and let this fall through unused.
        // **Rust-F#4 (v0.1.7.16):** the wildcard previously
        // returned `format!("...{kind:?}")`, embedding the
        // entire (unknown future) `RequestKind` Debug
        // representation in the wire payload. Today's variants
        // carry redacted types (Profile, paths, ports), but
        // the wildcard exists for forward-compat — the case
        // where Debug content is unknown. Now the wire body is
        // a stable, payload-free string; the unknown variant
        // goes to logs only.
        kind => {
            tracing::warn!(?kind, "unimplemented_method requested by client");
            Err(ErrorPayload::new(
                "unimplemented_method",
                "this engine version does not implement the requested method".to_owned(),
            ))
        }
    }
}

async fn start_proxy(
    state: Arc<Mutex<EngineState>>,
    binary_path: std::path::PathBuf,
    config_path: std::path::PathBuf,
    port: cool_tunnel_core::domain::Port,
    events: mpsc::Sender<Event>,
) -> Result<ResponsePayload, ErrorPayload> {
    // Hold the engine mutex across the entire spawn. The previous
    // implementation released the lock between the "is already
    // running?" check and the spawn, then re-acquired and tried
    // to `stop()` the loser if the check now disagreed. Two
    // concurrent `start_proxy` requests would both pass the first
    // check, both spawn `naive` (two real PIDs!), and the loser's
    // log lines and state-changed events would still ship to the
    // Swift side because they're emitted via the event channel
    // from `ProxySupervisor::spawn` *before* `stop()` is called
    // on the loser.
    //
    // Holding the mutex across `.await` is exactly what
    // `tokio::sync::Mutex` is designed for; the lock is single
    // point of contention only for the proxy lifecycle, and
    // double-spawn is a real correctness bug.
    let mut guard = state.lock().await;
    if guard.supervisor.is_some() {
        return Err(ErrorPayload::new(
            "already_running",
            "proxy is already running",
        ));
    }
    if guard.stopping {
        // A concurrent stop is in flight; the supervisor is
        // taken but the previous naive may still be draining.
        // Refuse rather than racing to spawn a second one.
        // (Ru-A3 — pair to the lock-across-spawn fix on the
        // start side.)
        return Err(ErrorPayload::new(
            "already_running",
            "proxy is currently stopping; try Start again in a moment",
        ));
    }
    let supervisor = ProxySupervisor::spawn(&binary_path, &config_path, events.clone())
        .await
        .map_err(|err| {
            tracing::error!(error = %err, "ProxySupervisor::spawn failed");
            ErrorPayload::new(
                "spawn_failed",
                "failed to spawn the naive proxy binary; check the engine log for details",
            )
        })?;
    let pid = supervisor.pid();
    guard.anomaly_debouncer.reset();
    // Reset the at-most-once gate for the new session. Without
    // this, any session after the first would skip the
    // natural-death emit (because the gate was claimed by the
    // PRIOR session's stop).
    guard.emitted_stopped = false;
    let monitor_handle = tokio::spawn(monitor_loop(pid, port, events, Arc::clone(&state)));
    guard.supervisor = Some(supervisor);
    guard.monitor_handle = Some(monitor_handle);
    guard.active_port = Some(port);
    Ok(ResponsePayload::Started { pid })
}

async fn monitor_loop(
    pid: u32,
    port: cool_tunnel_core::domain::Port,
    events: mpsc::Sender<Event>,
    state: Arc<Mutex<EngineState>>,
) {
    let mut ticker = tokio::time::interval(std::time::Duration::from_secs(MONITOR_INTERVAL_SECS));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    ticker.tick().await;

    loop {
        ticker.tick().await;
        // Exit the monitor as soon as the supervised PID is gone.
        // Without this check, a `naive` that dies on its own
        // (network stack collapse, panic, OOM) leaves the monitor
        // probing the stale PID forever — until next StopProxy. On
        // macOS PIDs roll over (max 99,998), so within a long
        // session another process can take the same PID and the
        // engine starts emitting anomalies derived from someone
        // else's lsof output. That's a confused-deputy signal and
        // a real CVE-class hazard for a security monitor.
        if !pid_alive(pid).await {
            tracing::info!(pid, "supervised process gone; monitor_loop exiting");
            // Natural-death path. Claim the at-most-once
            // emission gate; if the dispatcher's user-stop got
            // there first (already set `emitted_stopped =
            // true`), skip our emit so Swift doesn't see two
            // events for one transition (Ru-A1). If we win the
            // claim, also clean up the EngineState so a
            // subsequent StopProxy returns `not_running` rather
            // than trying to stop an already-dead supervisor.
            let should_emit = {
                let mut guard = state.lock().await;
                if guard.stopping || guard.emitted_stopped {
                    false
                } else {
                    guard.emitted_stopped = true;
                    let _ = guard.supervisor.take();
                    let _ = guard.monitor_handle.take();
                    guard.active_port = None;
                    true
                }
            };
            if should_emit {
                let _ = events.send(Event::StateChanged { running: false }).await;
            }
            return;
        }
        match monitor::run(pid, port).await {
            Ok(snapshot) => {
                if let Some(anomaly) = snapshot.anomaly {
                    let reason: AnomalyReason = (&anomaly).into();
                    let admitted = {
                        let mut guard = state.lock().await;
                        guard
                            .anomaly_debouncer
                            .admit(reason, std::time::Instant::now())
                    };
                    if admitted {
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

/// Returns `true` if a process with `pid` exists.
///
/// Implemented as `/bin/kill -0 <pid>` because the crate forbids
/// `unsafe_code` and the stdlib has no safe equivalent. The
/// monitor only ticks every 5 s, so the per-tick spawn cost is
/// negligible. Any non-zero exit (no such process, EPERM, etc.)
/// is treated as "gone" — the monitor's job is to stop probing
/// for an unowned PID, and EPERM means the PID was reused by
/// another user, which is also a valid "stop probing" signal.
async fn pid_alive(pid: u32) -> bool {
    let status = tokio::process::Command::new("/bin/kill")
        .args(["-0", &pid.to_string()])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .await;
    matches!(status, Ok(s) if s.success())
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
                // **v0.1.7.10 (Ru-A4):** the previous behaviour
                // was to log and continue, which silently dropped
                // the frame and left the Swift waiter map for
                // that `id` pending forever (UI hangs the
                // operation until the per-call timeout fires).
                // `Outbound` only contains primitives that
                // serialize infallibly today — but if a future
                // field ever fails (NaN float, non-UTF-8 byte),
                // a hand-built fallback gives the waiter a real
                // error to resolve against.
                tracing::error!(error = %err, "failed to serialize outbound frame");
                let id = match &frame {
                    Outbound::Response { id, .. } | Outbound::Error { id, .. } => *id,
                    Outbound::Event(_) => 0,
                };
                let fallback = format!(
                    r#"{{"kind":"error","id":{id},"error":{{"code":"engine_serialization_panic","message":"engine could not serialize this response; please report this build's --version output"}}}}{}"#,
                    "\n"
                );
                if stdout.write_all(fallback.as_bytes()).await.is_err() {
                    break;
                }
                if stdout.flush().await.is_err() {
                    break;
                }
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
