// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! End-to-end test: spawns the `cool-tunnel-core` binary, exchanges JSON
//! frames over stdin/stdout, and asserts each response shape.
//!
//! Tests live behind `cargo test --test protocol_roundtrip`. The binary
//! under test is the one Cargo just built (resolved via `env!("CARGO_BIN_EXE_*")`).
//!
//! v3.0.0 — the profile fixtures carry the VLESS UUID + Reality block
//! shape (uuid + reality.{public_key, dest_host, short_id}). The old
//! `generate_naive_config` + `generate_pac` methods are gone; the
//! single replacement is `generate_singbox_config`.

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::unused_async)]

use std::process::Stdio;
use std::time::Duration;

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

const BINARY: &str = env!("CARGO_BIN_EXE_cool-tunnel-core");
const READ_TIMEOUT: Duration = Duration::from_secs(5);

/// One canonical profile fixture for every test that needs a
/// well-formed v3.0.0 client profile. The wire fields are
/// snake_case (the Rust core's serde default for the `Reality`
/// struct; `localPort` keeps its explicit camelCase rename for
/// Swift compatibility).
fn well_formed_profile() -> serde_json::Value {
    json!({
        "id": "default",
        "server": "vless.example.com",
        "username": "alice",
        "uuid": "11111111-2222-3333-4444-555555555555",
        "reality": {
            "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "dest_host": "www.microsoft.com",
            "short_id": ""
        },
        "localPort": "1080"
    })
}

#[tokio::test]
async fn validate_profile_responds_with_validation_payload() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 1,
        "method": "validate_profile",
        "params": {"profile": well_formed_profile()}
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 1);
    assert_eq!(frame["result"]["type"], "validation");
    assert_eq!(frame["result"]["ok"], true);

    harness.shutdown().await;
}

#[tokio::test]
async fn malformed_input_returns_error_with_id_zero() {
    let mut harness = spawn().await;

    harness.send_raw("not-json\n").await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "error");
    assert_eq!(frame["id"], 0);
    assert_eq!(frame["error"]["code"], "malformed_request");

    harness.shutdown().await;
}

#[tokio::test]
async fn generate_singbox_config_returns_pretty_json() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 7,
        "method": "generate_singbox_config",
        "params": {"profile": well_formed_profile()}
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 7);
    assert_eq!(frame["result"]["type"], "singbox_config");
    let body = frame["result"]["json"].as_str().expect("json field");
    let parsed: serde_json::Value = serde_json::from_str(body).expect("body is valid JSON");

    // Smoke-check the sing-box client config shape — VLESS+Reality
    // outbound, SOCKS5 inbound at 127.0.0.1:1080, route block
    // sending DNS through the dns-out outbound.
    assert_eq!(parsed["inbounds"][0]["type"], "socks");
    assert_eq!(parsed["inbounds"][0]["listen"], "127.0.0.1");
    assert_eq!(parsed["inbounds"][0]["listen_port"], 1080);
    assert_eq!(parsed["outbounds"][0]["type"], "vless");
    assert_eq!(parsed["outbounds"][0]["server"], "vless.example.com");
    assert_eq!(parsed["outbounds"][0]["server_port"], 443);
    assert_eq!(parsed["outbounds"][0]["flow"], "xtls-rprx-vision");
    assert_eq!(parsed["outbounds"][0]["tls"]["reality"]["enabled"], true);
    assert_eq!(parsed["route"]["final"], "vless-out");

    harness.shutdown().await;
}

// v3.0.0 — `generate_pac` is gone. sing-box's `route.rules` handle
// per-domain decisions inside the engine; no PAC file is emitted.
// The `generate_pac_returns_javascript_with_listener_port` test from
// v2.x is removed; the PAC code path it covered no longer exists.

#[tokio::test]
async fn frame_exceeding_one_mib_returns_frame_too_large_error() {
    let mut harness = spawn().await;

    // 1 MiB + 16 bytes of garbage, no newline yet, then a newline. The
    // engine should drop the entire oversized frame and return an error
    // with id == 0.
    let oversize = "x".repeat(1024 * 1024 + 16);
    let payload = format!("{oversize}\n");
    harness.send_raw(&payload).await;

    let frame = harness.recv().await;
    assert_eq!(frame["kind"], "error");
    assert_eq!(frame["id"], 0);
    assert_eq!(frame["error"]["code"], "frame_too_large");

    // The engine should still be alive and able to handle a normal request
    // immediately after — confirms stream resync.
    let request = json!({
        "id": 42,
        "method": "validate_profile",
        "params": {"profile": well_formed_profile()}
    });
    harness.send(&request).await;
    let next = harness.recv().await;
    assert_eq!(next["kind"], "response");
    assert_eq!(next["id"], 42);

    harness.shutdown().await;
}

/// **2026-05-06 (`validate_profile` design reversal):**
/// invalid profiles now return a successful `Outbound::Response`
/// with `ValidationReport { ok: false, reason: ... }`, NOT an
/// `Outbound::Error` frame. The reason field carries the
/// `ValidationError::Display` string from the first failing
/// field — the exact reason string is an implementation detail
/// of `Profile::try_from`, so this test only pins that some non-
/// empty reason is present.
#[tokio::test]
async fn validate_profile_returns_structured_failure_for_invalid_profile() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 4,
        "method": "validate_profile",
        "params": {
            "profile": {
                "id": "bad",
                "server": "https://x",
                "username": "",
                "uuid": "not-a-uuid",
                "reality": {
                    "public_key": "",
                    "dest_host": "",
                    "short_id": ""
                },
                "localPort": "0"
            }
        }
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 4);
    assert_eq!(frame["result"]["type"], "validation");
    assert_eq!(frame["result"]["ok"], false);
    let reason = frame["result"]["reason"]
        .as_str()
        .expect("reason string present on ok=false");
    assert!(
        !reason.is_empty(),
        "reason must be non-empty when ok=false; got {reason:?}"
    );

    harness.shutdown().await;
}

/// v3.0.0 — the empty-uuid case is the v=3 equivalent of v2.x's
/// empty-password regression. Operators on a misconfigured panel
/// (where the regenerate-UUID flow hasn't run) would otherwise see
/// a working-looking validate pass with empty credential, then the
/// engine spawn fails with no diagnostic surface. The structured
/// reason here names the offending field so the UI can render a
/// pointed error.
#[tokio::test]
async fn validate_profile_flags_empty_uuid_with_reason() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 5,
        "method": "validate_profile",
        "params": {
            "profile": {
                "id": "default",
                "server": "vless.example.com",
                "username": "alice",
                "uuid": "",
                "reality": {
                    "public_key": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
                    "dest_host": "www.microsoft.com",
                    "short_id": ""
                },
                "localPort": "1080"
            }
        }
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 5);
    assert_eq!(frame["result"]["type"], "validation");
    assert_eq!(frame["result"]["ok"], false);
    let reason = frame["result"]["reason"]
        .as_str()
        .expect("reason string present on ok=false");
    assert!(
        reason.to_lowercase().contains("uuid"),
        "reason should name the uuid field; got {reason:?}"
    );

    harness.shutdown().await;
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
        self.stdin
            .write_all(text.as_bytes())
            .await
            .expect("write stdin");
        self.stdin.flush().await.expect("flush stdin");
    }

    async fn recv(&mut self) -> serde_json::Value {
        let mut line = String::new();
        timeout(READ_TIMEOUT, self.stdout.read_line(&mut line))
            .await
            .expect("read response within timeout")
            .expect("read response line");
        serde_json::from_str(&line).expect("parse response as JSON")
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
