//! End-to-end test: spawns the `cool-tunnel-core` binary, exchanges JSON
//! frames over stdin/stdout, and asserts each response shape.
//!
//! Tests live behind `cargo test --test protocol_roundtrip`. The binary
//! under test is the one Cargo just built (resolved via `env!("CARGO_BIN_EXE_*")`).

#![allow(clippy::expect_used, clippy::unwrap_used, clippy::unused_async)]

use std::process::Stdio;
use std::time::Duration;

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use tokio::time::timeout;

const BINARY: &str = env!("CARGO_BIN_EXE_cool-tunnel-core");
const READ_TIMEOUT: Duration = Duration::from_secs(5);

#[tokio::test]
async fn validate_profile_responds_with_validation_payload() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 1,
        "method": "validate_profile",
        "params": {
            "profile": {
                "id": "default",
                "server": "naive.example.com",
                "username": "alice",
                "password": "secret",
                "localPort": "1080"
            }
        }
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
async fn generate_naive_config_returns_pretty_json() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 7,
        "method": "generate_naive_config",
        "params": {
            "profile": {
                "id": "default",
                "server": "naive.example.com",
                "username": "alice",
                "password": "secret",
                "localPort": "1080"
            }
        }
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["id"], 7);
    assert_eq!(frame["result"]["type"], "naive_config");
    let body = frame["result"]["json"].as_str().expect("json field");
    let parsed: serde_json::Value = serde_json::from_str(body).expect("body is valid JSON");
    assert_eq!(parsed["listen"], "socks://127.0.0.1:1080");
    assert_eq!(parsed["proxy"], "https://alice:secret@naive.example.com");

    harness.shutdown().await;
}

#[tokio::test]
async fn generate_pac_returns_javascript_with_listener_port() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 9,
        "method": "generate_pac",
        "params": {
            "direct_domains": ["baidu.com"],
            "port": 1080
        }
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "response");
    assert_eq!(frame["result"]["type"], "pac");
    let js = frame["result"]["js"].as_str().expect("js field");
    assert!(js.contains("function FindProxyForURL"));
    assert!(js.contains("SOCKS5 127.0.0.1:1080"));
    assert!(js.contains("\"baidu.com\""));

    harness.shutdown().await;
}

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
        "params": {
            "profile": {
                "id": "default",
                "server": "naive.example.com",
                "username": "alice",
                "password": "secret",
                "localPort": "1080"
            }
        }
    });
    harness.send(&request).await;
    let next = harness.recv().await;
    assert_eq!(next["kind"], "response");
    assert_eq!(next["id"], 42);

    harness.shutdown().await;
}

#[tokio::test]
async fn rejects_invalid_profile_during_deserialization() {
    let mut harness = spawn().await;

    let request = json!({
        "id": 4,
        "method": "validate_profile",
        "params": {
            "profile": {
                "id": "bad",
                "server": "https://x",
                "username": "",
                "password": "",
                "localPort": "0"
            }
        }
    });
    harness.send(&request).await;
    let frame = harness.recv().await;

    assert_eq!(frame["kind"], "error");
    assert_eq!(frame["id"], 4);
    assert_eq!(frame["error"]["code"], "invalid_request");

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
