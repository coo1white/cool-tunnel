//! Chaos engineering test suite.
//!
//! Where `protocol_roundtrip.rs` exercises the happy path,
//! this file deliberately misbehaves at the engine boundary —
//! oversized frames, garbage input, mid-frame stdin closure,
//! concurrent start-proxy races — and asserts the engine stays
//! correct under those conditions. Each test invariant maps to a
//! real failure mode the v0.1.7.x audits identified or fixed; if
//! the engine ever regresses, these tests fail loudly.
//!
//! Run with `cargo test --test chaos --release`. Release mode is
//! deliberate: it matches what ships, and it exercises the
//! `panic = "abort"` profile so any panic translates to a
//! process exit which the harness can detect.

#![allow(
    clippy::expect_used,
    clippy::unwrap_used,
    clippy::unused_async,
    clippy::panic,
    clippy::cast_possible_truncation,
    clippy::cast_lossless,
    clippy::doc_markdown,
    clippy::items_after_statements,
    clippy::map_unwrap_or
)]

use std::process::Stdio;
use std::time::Duration;

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

const BINARY: &str = env!("CARGO_BIN_EXE_cool-tunnel-core");
const RECV_TIMEOUT: Duration = Duration::from_secs(5);
const ENGINE_MAX_FRAME_BYTES: usize = 1024 * 1024;

// ---------------------------------------------------------------------
// Scenario 1 — Oversized-frame survival
// ---------------------------------------------------------------------
// The engine must reply `frame_too_large` and *continue* processing
// subsequent valid frames. A regression that left the read state
// machine wedged after an oversized frame would silently break every
// session that ever hit one.

#[tokio::test]
async fn chaos_oversized_frame_survives_and_engine_continues() {
    let mut harness = spawn().await;

    // 1.5 MiB of `x` followed by a newline — well above MAX_FRAME_BYTES.
    let blob = vec![b'x'; ENGINE_MAX_FRAME_BYTES + (ENGINE_MAX_FRAME_BYTES / 2)];
    harness.send_bytes(&blob).await;
    harness.send_raw("\n").await;

    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "error", "expected error frame, got {frame}");
    assert_eq!(frame["error"]["code"], "frame_too_large");

    // Engine still alive — send a normal request and verify it works.
    harness
        .send(&json!({
            "id": 99,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;
    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 99);

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 2 — No-newline flood discard cap (Ru#H4 fix verification)
// ---------------------------------------------------------------------
// `read_capped_line` enters discard mode once `MAX_FRAME_BYTES` is
// exceeded and previously would loop forever consuming bytes until
// it found a `\n`. v0.1.7.3 added a 16× cap; over that, the engine
// must fail-fast with InvalidData rather than burn CPU.

#[tokio::test]
async fn chaos_no_newline_flood_does_not_loop_forever() {
    let mut harness = spawn().await;

    // Send 20 MiB of `x` with no newline. That's above the discard
    // cap (16 × 1 MiB = 16 MiB). The engine should fail-fast and
    // exit; the harness should observe the child exit cleanly within
    // a few seconds — *not* hang for minutes.
    let blob = vec![b'x'; 20 * 1024 * 1024];
    let _ = harness.stdin.write_all(&blob).await;
    let _ = harness.stdin.flush().await;
    drop(harness.stdin);

    // Engine should exit promptly via the InvalidData propagation.
    let exit = timeout(Duration::from_secs(10), harness.child.wait()).await;
    assert!(
        exit.is_ok(),
        "engine did not exit within 10s after no-newline flood — discard cap regressed?"
    );
}

// ---------------------------------------------------------------------
// Scenario 3 — Malformed-frame burst stability
// ---------------------------------------------------------------------
// 1000 invalid frames in a row should not crash the engine, OOM it,
// or wedge its event loop. Each must produce an `error` frame; the
// engine must remain responsive to a valid request after the storm.

#[tokio::test]
async fn chaos_malformed_burst_does_not_crash_engine() {
    let mut harness = spawn().await;

    let salvos: usize = 1000;
    for i in 0..salvos {
        // Mix of JSON-ish garbage to exercise different parser arms.
        let line = match i % 4 {
            0 => "not-json\n".to_owned(),
            1 => "{\"id\": \"not-a-number\", \"method\": \"validate_profile\"}\n".to_owned(),
            2 => "{}\n".to_owned(), // missing required fields
            _ => format!("{{\"id\": {i}, \"method\": \"unknown_method_{i}\"}}\n"),
        };
        harness.send_raw(&line).await;
    }

    // Send a sentinel valid request and drain the engine's reply
    // stream until we see it. This avoids a race where slow
    // malformed-burst replies are still in flight; we don't need
    // to drain *every* error individually, just to demonstrate
    // the engine processes a valid request after the storm.
    let sentinel_id = 0xDEAD_BEEF_u64;
    harness
        .send(&json!({
            "id": sentinel_id,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;

    let mut burst_replies = 0_usize;
    let mut sentinel_seen = false;
    let drain_deadline = std::time::Instant::now() + Duration::from_secs(15);
    while std::time::Instant::now() < drain_deadline {
        let Ok(Some(line)) = timeout(Duration::from_secs(2), harness.recv_raw()).await else { break };
        let frame: serde_json::Value = serde_json::from_str(&line).unwrap();
        let id = frame["id"].as_u64().unwrap_or(0);
        if id == sentinel_id {
            assert_eq!(
                frame["kind"], "response",
                "sentinel reply was not a response: {frame}"
            );
            sentinel_seen = true;
            break;
        }
        burst_replies += 1;
    }
    assert!(burst_replies > 0, "expected error replies from malformed burst");
    assert!(sentinel_seen, "engine wedged after malformed burst — sentinel reply never arrived");

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 4 — Concurrent start_proxy races (Ru#C2 fix verification)
// ---------------------------------------------------------------------
// Two start_proxy requests sent back-to-back must produce exactly one
// `started` reply and one `already_running` error. Anything else means
// the v0.1.7.3 TOCTOU fix regressed and we may have spawned two
// `naive` PIDs.

#[tokio::test]
async fn chaos_concurrent_start_proxy_does_not_double_spawn() {
    let mut harness = spawn().await;

    // Use /bin/sh as a stand-in "naive" binary — it accepts a
    // config-file path arg (we point at /dev/null), opens no
    // sockets, and `kill_on_drop(true)` reaps it on engine teardown.
    let fake_binary = "/bin/sleep";

    // Field names match the Rust schema's `rename_all = "snake_case"`.
    let req = |id: u64| {
        json!({
            "id": id,
            "method": "start_proxy",
            "params": {
                "binary_path": fake_binary,
                "config_path": "60",  // sleep 60 seconds (sleep's "config")
                "port": 1080
            }
        })
    };

    // Send two requests as fast as possible (no await between).
    harness.send(&req(101)).await;
    harness.send(&req(102)).await;

    // Collect exactly two response/error frames, skipping the
    // unsolicited `state_changed` events the supervisor emits
    // when `naive` (here: /bin/sleep) launches. The multi-set of
    // (kind, code) values must be exactly:
    //   {response/started, error/already_running}
    // v0.1.7.5 wire-ordering contract: every response is emitted
    // BEFORE its associated state_changed event. Track that any
    // state_changed:true event arrives AFTER the started
    // response (not before). The previous behaviour (audit
    // Ru#C4, fixed in v0.1.7.5) emitted state_changed from the
    // supervisor on a different channel, racing the response.
    let mut seen: Vec<(String, String)> = Vec::new();
    let mut state_changed_before_response = false;
    let mut started_response_seen = false;
    let deadline = std::time::Instant::now() + Duration::from_secs(10);
    while seen.len() < 2 && std::time::Instant::now() < deadline {
        let Ok(Some(line)) = timeout(Duration::from_secs(5), harness.recv_raw()).await else { break };
        let frame: serde_json::Value = serde_json::from_str(&line).unwrap();
        let kind = frame["kind"].as_str().unwrap_or("?").to_owned();
        if kind == "event" {
            // If a state_changed:true event arrives BEFORE the
            // started response, that's the Ru#C4 regression.
            if frame["data"]["running"].as_bool() == Some(true) && !started_response_seen {
                state_changed_before_response = true;
            }
            continue;
        }
        let code = if kind == "error" {
            frame["error"]["code"].as_str().unwrap_or("?").to_owned()
        } else {
            frame["result"]["type"].as_str().unwrap_or("?").to_owned()
        };
        if kind == "response" && code == "started" {
            started_response_seen = true;
        }
        seen.push((kind, code));
    }
    assert!(
        !state_changed_before_response,
        "Ru#C4 regression: state_changed:true event arrived before started response"
    );

    // Send stop_proxy so we don't leak the sleep.
    harness
        .send(&json!({"id": 199, "method": "stop_proxy", "params": null}))
        .await;
    let _ = timeout(Duration::from_secs(3), harness.recv_raw()).await;

    let started = seen
        .iter()
        .filter(|(k, c)| k == "response" && c == "started")
        .count();
    let already = seen
        .iter()
        .filter(|(k, c)| k == "error" && c == "already_running")
        .count();
    assert_eq!(
        started, 1,
        "expected exactly one started response, got {seen:?}"
    );
    assert_eq!(
        already, 1,
        "expected exactly one already_running error, got {seen:?}"
    );

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 5 — Stdin EOF mid-frame
// ---------------------------------------------------------------------
// Half a frame followed by stdin close should not crash the engine
// or emit a phantom error response. The engine should drain and
// exit cleanly.

#[tokio::test]
async fn chaos_stdin_closed_mid_frame_exits_cleanly() {
    let mut harness = spawn().await;

    // Send a partial JSON frame with no newline.
    harness.send_raw(r#"{"id": 1, "method": "validate_pro"#).await;
    drop(harness.stdin);

    let exit = timeout(Duration::from_secs(5), harness.child.wait()).await;
    assert!(exit.is_ok(), "engine did not exit within 5s of stdin EOF");
    let status = exit.unwrap().expect("wait succeeds");
    assert!(
        status.success(),
        "engine exited with non-zero on clean EOF: {status}"
    );
}

// ---------------------------------------------------------------------
// Scenario 6 — Empty + whitespace-only lines are skipped
// ---------------------------------------------------------------------
// The engine treats empty/whitespace lines as no-ops. Verify that
// no error frames are emitted and that valid frames after them
// still work.

#[tokio::test]
async fn chaos_empty_and_whitespace_lines_are_skipped() {
    let mut harness = spawn().await;

    // Three blank lines, then a valid request.
    harness.send_raw("\n").await;
    harness.send_raw("   \n").await;
    harness.send_raw("\t\t\n").await;
    harness
        .send(&json!({
            "id": 5,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;

    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "response", "blank lines triggered an error: {frame}");
    assert_eq!(frame["id"], 5);

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 7 — UTF-8 invalid bytes
// ---------------------------------------------------------------------
// Bytes that aren't valid UTF-8 must produce a `malformed_request`
// error frame, not a panic.

#[tokio::test]
async fn chaos_invalid_utf8_returns_malformed_request_error() {
    let mut harness = spawn().await;

    // Lone continuation byte (invalid UTF-8 start) plus newline.
    harness.send_bytes(&[0x80, 0xff, b'\n']).await;

    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "error");
    assert_eq!(frame["error"]["code"], "malformed_request");

    // Engine still alive.
    harness
        .send(&json!({
            "id": 11,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;
    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 11);

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 8 — Id correlation under interleaved valid/invalid
// ---------------------------------------------------------------------
// Each error frame must carry the id it was associated with. The
// two-phase parse exists exactly so the Swift waiter can correlate
// errors with their pending callsite.

#[tokio::test]
async fn chaos_id_correlation_holds_under_interleaved_traffic() {
    let mut harness = spawn().await;

    let valid = |id: u64| {
        json!({
            "id": id,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        })
    };
    // Invalid (port out of range) but well-formed JSON with an id.
    let invalid = |id: u64| {
        json!({
            "id": id,
            "method": "validate_profile",
            "params": {"profile": {
                "id": "x",
                "server": "naive.example.com",
                "username": "nick",
                "password": "p",
                "localPort": "999999"
            }},
        })
    };

    let ids = [101_u64, 102, 103, 104, 105];
    for (i, id) in ids.iter().enumerate() {
        if i % 2 == 0 {
            harness.send(&valid(*id)).await;
        } else {
            harness.send(&invalid(*id)).await;
        }
    }

    // Collect five frames; each must carry the matching id.
    let mut returned_ids = std::collections::HashSet::new();
    for _ in 0..ids.len() {
        let frame = harness.recv().await;
        let id = frame["id"].as_u64().expect("id present");
        returned_ids.insert(id);
    }
    let expected: std::collections::HashSet<u64> = ids.iter().copied().collect();
    assert_eq!(
        returned_ids, expected,
        "id correlation broken: returned ids {returned_ids:?}, expected {expected:?}"
    );

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 9 — Stop-proxy when nothing is running
// ---------------------------------------------------------------------
// Idempotent stop: must return `not_running` rather than crash or
// hang.

#[tokio::test]
async fn chaos_stop_proxy_when_idle_returns_not_running() {
    let mut harness = spawn().await;

    harness
        .send(&json!({"id": 1, "method": "stop_proxy", "params": null}))
        .await;
    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "error");
    assert_eq!(frame["error"]["code"], "not_running");

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 10 — Stop-proxy spam (rapid duplicate stops)
// ---------------------------------------------------------------------
// User spam-clicking Stop must produce stable error replies, not
// crash or wedge.

#[tokio::test]
async fn chaos_stop_proxy_spam_stays_stable() {
    let mut harness = spawn().await;

    for i in 0..20 {
        harness
            .send(&json!({"id": i + 1, "method": "stop_proxy", "params": null}))
            .await;
    }
    for _ in 0..20 {
        let frame = harness.recv().await;
        assert_eq!(frame["kind"], "error");
        assert_eq!(frame["error"]["code"], "not_running");
    }

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 11 — Newline flood
// ---------------------------------------------------------------------
// 100,000 empty lines must be skipped without producing 100k error
// frames or exhausting memory. Tests the empty-line short-circuit
// in the read loop.

#[tokio::test]
async fn chaos_newline_flood_does_not_emit_per_line_errors() {
    let mut harness = spawn().await;

    // Fire-and-forget: we don't care about stdin backpressure here
    // since each newline is one byte and the engine drains them.
    let mut blob = String::with_capacity(100_000);
    for _ in 0..100_000 {
        blob.push('\n');
    }
    harness.send_raw(&blob).await;

    // Sentinel: one valid request id we recv until we see.
    let sentinel_id = 0xCAFE_BABE_u64;
    harness
        .send(&json!({
            "id": sentinel_id,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;

    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    let mut error_frames_seen = 0_usize;
    let mut sentinel_seen = false;
    while std::time::Instant::now() < deadline {
        let Ok(Some(line)) = timeout(Duration::from_secs(2), harness.recv_raw()).await else { break };
        let frame: serde_json::Value = serde_json::from_str(&line).unwrap();
        if frame["kind"] == "error" {
            error_frames_seen += 1;
            // Hard cap: if the engine emitted more than 100 errors,
            // it's emitting per-line which is the regression we're
            // guarding against.
            assert!(
                error_frames_seen <= 100,
                "newline flood produced {error_frames_seen} error frames — empty-line short-circuit regressed?"
            );
        }
        if frame["id"].as_u64() == Some(sentinel_id) {
            sentinel_seen = true;
            break;
        }
    }
    assert!(sentinel_seen, "engine wedged after newline flood");
    assert_eq!(
        error_frames_seen, 0,
        "expected zero error frames from pure-newline flood, got {error_frames_seen}"
    );

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Scenario 12 — Shutdown while requests in flight
// ---------------------------------------------------------------------
// Send several requests followed immediately by `shutdown`. The
// engine must reply to the requests OR exit cleanly; it must not
// crash or hang.

#[tokio::test]
async fn chaos_shutdown_during_inflight_requests_exits_cleanly() {
    let mut harness = spawn().await;

    for id in 1..=5 {
        harness
            .send(&json!({
                "id": id,
                "method": "validate_profile",
                "params": {"profile": sample_profile()},
            }))
            .await;
    }
    harness
        .send(&json!({"id": 999, "method": "shutdown", "params": null}))
        .await;
    drop(harness.stdin);

    let exit = timeout(Duration::from_secs(5), harness.child.wait()).await;
    assert!(exit.is_ok(), "engine did not exit within 5s of shutdown-after-burst");
    let status = exit.unwrap().expect("wait succeeds");
    assert!(status.success(), "engine exited non-zero on shutdown: {status}");
}

// ---------------------------------------------------------------------
// SIEGE — Scenario 13: Randomized rapid concurrent request burst
// ---------------------------------------------------------------------
// 50 validate_profile requests fired with no await between, then
// drained with random 1–100 ms inter-recv delays to simulate a
// slow Swift consumer. The engine must reply to all 50 and remain
// responsive to a sentinel afterward.

#[tokio::test]
async fn siege_concurrent_request_burst_with_random_delays() {
    let mut harness = spawn().await;
    let mut rng = XorShift::seeded();

    const SALVO_SIZE: u64 = 50;
    for id in 1..=SALVO_SIZE {
        harness
            .send(&json!({
                "id": id,
                "method": "validate_profile",
                "params": {"profile": sample_profile()},
            }))
            .await;
    }

    let mut received_ids: std::collections::HashSet<u64> = std::collections::HashSet::new();
    while received_ids.len() < SALVO_SIZE as usize {
        // Random 1–100 ms delay to simulate consumer back-pressure.
        let delay_ms = rng.next_in_range(1, 100);
        tokio::time::sleep(Duration::from_millis(delay_ms)).await;
        let frame = harness.recv().await;
        let id = frame["id"].as_u64().expect("id present");
        assert_eq!(frame["kind"], "response", "burst response was not a response: {frame}");
        received_ids.insert(id);
    }
    assert_eq!(received_ids.len(), SALVO_SIZE as usize, "missing replies under siege");

    // Engine still responsive.
    harness
        .send(&json!({
            "id": 9_991,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;
    let frame = harness.recv().await;
    assert_eq!(frame["id"], 9_991);

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// SIEGE — Scenario 14: Start/stop cycle storm (FD-leak detector)
// ---------------------------------------------------------------------
// 100 start_proxy→stop_proxy cycles in series with random 1–30 ms
// jitter between calls. /bin/sleep is the fake naive (kill_on_drop
// reaps it on supervisor stop). Any FD leak from `Pipe`s, `lsof`
// invocations, or tokio internals would surface as a spawn failure
// somewhere past cycle 50 (default macOS ulimit -n is ~256 for
// shell-spawned processes, lower under test runners). Survival
// through 100 cycles plus a final responsive sentinel = no leak.

#[tokio::test]
async fn siege_start_stop_cycle_storm_no_fd_leak() {
    let mut harness = spawn().await;
    let mut rng = XorShift::seeded();
    const CYCLES: u32 = 100;

    for cycle in 0..CYCLES {
        let start_id = (cycle as u64) * 2 + 1;
        let stop_id = start_id + 1;

        harness
            .send(&json!({
                "id": start_id,
                "method": "start_proxy",
                "params": {
                    "binary_path": "/bin/sleep",
                    "config_path": "60",
                    "port": 1080
                },
            }))
            .await;
        // Drain frames until we see the start response (skipping
        // any state_changed event the dispatcher emits after).
        drain_until_response(&mut harness, start_id).await;

        // Random 1–30 ms jitter to surface race conditions in the
        // lock-held start_proxy → stop_proxy transition window.
        tokio::time::sleep(Duration::from_millis(rng.next_in_range(1, 30))).await;

        harness
            .send(&json!({"id": stop_id, "method": "stop_proxy", "params": null}))
            .await;
        drain_until_response(&mut harness, stop_id).await;
    }

    // Engine still responsive after 100 cycles.
    harness
        .send(&json!({
            "id": 99_999,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;
    let frame = drain_until_response(&mut harness, 99_999).await;
    assert_eq!(frame["kind"], "response");

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// SIEGE — Scenario 15: Race the start/stop with random delays
// ---------------------------------------------------------------------
// Fire start, sleep a random 1–50 ms, fire stop. Repeat 30 cycles.
// The lock-across-spawn fix (Ru#C2) plus the stop-handle-abort
// fix (Ru#C1) must hold under randomized timing.

#[tokio::test]
async fn siege_random_delay_race_start_stop() {
    let mut harness = spawn().await;
    let mut rng = XorShift::seeded();
    const CYCLES: u32 = 30;

    for cycle in 0..CYCLES {
        let start_id = 10_000 + (cycle as u64) * 2;
        let stop_id = start_id + 1;

        harness
            .send(&json!({
                "id": start_id,
                "method": "start_proxy",
                "params": {
                    "binary_path": "/bin/sleep",
                    "config_path": "60",
                    "port": 1080
                },
            }))
            .await;

        // Vary the inter-call delay across the full critical
        // window. 1–50 ms covers the period when supervisor
        // spawn + monitor task setup are interleaving with stop.
        tokio::time::sleep(Duration::from_millis(rng.next_in_range(1, 50))).await;

        harness
            .send(&json!({"id": stop_id, "method": "stop_proxy", "params": null}))
            .await;

        // Drain both responses (and any events).
        let _start_frame = drain_until_response(&mut harness, start_id).await;
        let _stop_frame = drain_until_response(&mut harness, stop_id).await;
    }

    // Sentinel.
    harness
        .send(&json!({
            "id": 88_888,
            "method": "validate_profile",
            "params": {"profile": sample_profile()},
        }))
        .await;
    let frame = drain_until_response(&mut harness, 88_888).await;
    assert_eq!(frame["kind"], "response");

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// SIEGE — Scenario 16: Wire ordering under burst (Ru#C4 stress)
// ---------------------------------------------------------------------
// Fire 10 back-to-back start/stop cycles and verify EVERY
// state_changed event arrives AFTER its associated response on
// the wire. This is the stress version of scenario 4's ordering
// check.

#[tokio::test]
async fn siege_wire_ordering_holds_under_burst() {
    let mut harness = spawn().await;
    const CYCLES: u32 = 10;

    for cycle in 0..CYCLES {
        let start_id = 20_000 + (cycle as u64) * 2;
        let stop_id = start_id + 1;
        harness
            .send(&json!({
                "id": start_id,
                "method": "start_proxy",
                "params": {
                    "binary_path": "/bin/sleep",
                    "config_path": "60",
                    "port": 1080
                },
            }))
            .await;
        // Walk frames in arrival order, asserting the wire
        // sequence: started response → state_changed:true event.
        let mut saw_response = false;
        loop {
            let frame = harness.recv().await;
            if frame["kind"] == "response" && frame["id"].as_u64() == Some(start_id) {
                saw_response = true;
                continue;
            }
            if frame["kind"] == "event" && frame["data"]["running"].as_bool() == Some(true) {
                assert!(
                    saw_response,
                    "Ru#C4 regression in cycle {cycle}: state_changed:true arrived before started response"
                );
                break;
            }
        }

        harness
            .send(&json!({"id": stop_id, "method": "stop_proxy", "params": null}))
            .await;
        // Mirror invariant for the stop side.
        let mut saw_stop_response = false;
        loop {
            let frame = harness.recv().await;
            if frame["kind"] == "response" && frame["id"].as_u64() == Some(stop_id) {
                saw_stop_response = true;
                continue;
            }
            if frame["kind"] == "event" && frame["data"]["running"].as_bool() == Some(false) {
                assert!(
                    saw_stop_response,
                    "Ru#C4 regression in cycle {cycle}: state_changed:false arrived before stopped response"
                );
                break;
            }
        }
    }

    harness.shutdown().await;
}

// ---------------------------------------------------------------------
// Helpers — siege-specific
// ---------------------------------------------------------------------

/// Receive frames until one matches `expected_id` and return it.
/// Skips intervening events (state_changed, etc.).
async fn drain_until_response(harness: &mut Harness, expected_id: u64) -> serde_json::Value {
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while std::time::Instant::now() < deadline {
        let frame = harness.recv().await;
        if frame["id"].as_u64() == Some(expected_id) {
            return frame;
        }
        // Otherwise it's an event or an out-of-order reply — keep draining.
    }
    panic!("did not receive frame with id={expected_id} within 15s");
}

/// Tiny xorshift64 PRNG seeded from the system clock. Deterministic
/// within a test run, varies across runs. Avoids pulling `rand` as
/// a dev-dependency for the LTSC patch.
struct XorShift {
    state: u64,
}

impl XorShift {
    fn seeded() -> Self {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.subsec_nanos() as u64)
            .unwrap_or(1);
        // Avoid a zero seed — xorshift's fixed point.
        Self { state: nanos.max(1) }
    }

    fn next(&mut self) -> u64 {
        let mut x = self.state;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        self.state = x;
        x
    }

    /// Returns a value in `[lo, hi]` inclusive.
    fn next_in_range(&mut self, lo: u64, hi: u64) -> u64 {
        let span = hi - lo + 1;
        lo + (self.next() % span)
    }
}

// ---------------------------------------------------------------------
// Test harness — adapted from protocol_roundtrip with chaos extras
// ---------------------------------------------------------------------

fn sample_profile() -> serde_json::Value {
    json!({
        "id": "default",
        "server": "naive.example.com",
        "username": "nick",
        "password": "secret",
        "localPort": "1080",
    })
}

struct Harness {
    child: tokio::process::Child,
    stdin: tokio::process::ChildStdin,
    stdout: BufReader<tokio::process::ChildStdout>,
}

async fn spawn() -> Harness {
    let mut child = Command::new(BINARY)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .expect("spawn cool-tunnel-core");
    let stdin = child.stdin.take().expect("piped stdin");
    let stdout = BufReader::new(child.stdout.take().expect("piped stdout"));
    Harness {
        child,
        stdin,
        stdout,
    }
}

impl Harness {
    async fn send(&mut self, value: &serde_json::Value) {
        let mut bytes = serde_json::to_vec(value).expect("serialize request");
        bytes.push(b'\n');
        self.stdin.write_all(&bytes).await.expect("write stdin");
        self.stdin.flush().await.expect("flush stdin");
    }

    async fn send_raw(&mut self, text: &str) {
        let _ = self.stdin.write_all(text.as_bytes()).await;
        let _ = self.stdin.flush().await;
    }

    async fn send_bytes(&mut self, bytes: &[u8]) {
        let _ = self.stdin.write_all(bytes).await;
        let _ = self.stdin.flush().await;
    }

    async fn recv(&mut self) -> serde_json::Value {
        let mut line = String::new();
        timeout(RECV_TIMEOUT, self.stdout.read_line(&mut line))
            .await
            .expect("read response within timeout")
            .expect("read response line");
        serde_json::from_str(&line).expect("parse response as JSON")
    }

    /// Recv a raw line, returning `None` on EOF rather than
    /// asserting. Used by the malformed-burst scenario which
    /// drains best-effort.
    async fn recv_raw(&mut self) -> Option<String> {
        let mut line = String::new();
        let read = self.stdout.read_line(&mut line).await.ok()?;
        if read == 0 {
            return None;
        }
        Some(line)
    }

    async fn shutdown(mut self) {
        let request = json!({"id": 9999, "method": "shutdown", "params": null});
        let mut bytes = serde_json::to_vec(&request).expect("serialize");
        bytes.push(b'\n');
        let _ = self.stdin.write_all(&bytes).await;
        let _ = self.stdin.flush().await;
        drop(self.stdin);
        let _ = timeout(Duration::from_secs(2), self.child.wait()).await;
    }
}

// `tokio::io::AsyncReadExt` is imported for completeness; a future
// chaos test that reads stderr will need it.
#[allow(dead_code)]
fn _ensure_async_read_ext_used() {
    fn _f<R: AsyncReadExt>(_: R) {}
}
