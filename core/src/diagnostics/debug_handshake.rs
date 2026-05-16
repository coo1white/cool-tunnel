// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.

use std::fs::{self, OpenOptions};
use std::io::Write as _;
#[cfg(unix)]
use std::os::unix::fs::OpenOptionsExt as _;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use thiserror::Error;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};
use tokio::net::{TcpListener, TcpStream};
use tokio::process::Command;
use tokio::time::{sleep, timeout};

use crate::config::NaiveConfig;
use crate::domain::Profile;
use crate::protocol::DebugHandshakeReport;
use crate::redaction;

const DEFAULT_TIMEOUT_SECS: u64 = 12;
const MIN_TIMEOUT_SECS: u64 = 3;
const MAX_TIMEOUT_SECS: u64 = 30;
const STARTUP_TIMEOUT: Duration = Duration::from_secs(3);
const STARTUP_POLL: Duration = Duration::from_millis(50);
const HEX_CAPTURE_BYTES: usize = 1024;
const TARGET_HOST: &str = "www.google.com";
const TARGET_AUTHORITY: &str = "www.google.com:443";
const READ_LIMIT_BYTES: usize = HEX_CAPTURE_BYTES;
const LOG_LINE_LIMIT: usize = 12;
const LOG_LINE_BYTES: usize = 512;

#[derive(Debug, Error)]
enum DebugHandshakeError {
    #[error("failed to choose a temporary listener port: {0}")]
    PickPort(std::io::Error),
    #[error("failed to spawn naive for debug handshake: {0}")]
    Spawn(std::io::Error),
    #[error("failed to write temporary debug handshake config: {0}")]
    ConfigWrite(std::io::Error),
    #[error("naive did not bind the temporary listener within {0:?}")]
    StartupTimeout(Duration),
    #[error("naive exited before binding the temporary listener")]
    ExitedEarly,
}

#[allow(clippy::missing_errors_doc, missing_docs)]
pub async fn run_debug_handshake(
    binary_path: &Path,
    profile: &Profile,
    timeout_secs: Option<u64>,
) -> Result<DebugHandshakeReport, String> {
    run_debug_handshake_inner(binary_path, profile, timeout_secs)
        .await
        .map_err(|err| err.to_string())
}

async fn run_debug_handshake_inner(
    binary_path: &Path,
    profile: &Profile,
    timeout_secs: Option<u64>,
) -> Result<DebugHandshakeReport, DebugHandshakeError> {
    let started = Instant::now();
    let deadline = Duration::from_secs(
        timeout_secs
            .unwrap_or(DEFAULT_TIMEOUT_SECS)
            .clamp(MIN_TIMEOUT_SECS, MAX_TIMEOUT_SECS),
    );
    let port = pick_free_port()
        .await
        .map_err(DebugHandshakeError::PickPort)?;
    let config =
        DebugNaiveConfig::write(profile, port).map_err(DebugHandshakeError::ConfigWrite)?;

    let mut child = Command::new(binary_path)
        .arg(config.path())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(DebugHandshakeError::Spawn)?;

    if !wait_for_listener(&mut child, port).await? {
        return Err(DebugHandshakeError::StartupTimeout(STARTUP_TIMEOUT));
    }

    let target = TARGET_AUTHORITY;
    let connect_request = format!(
        "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nUser-Agent: cool-tunnel-debug-handshake\r\nProxy-Connection: keep-alive\r\n\r\n"
    );
    let trace = drive_local_connect(
        port,
        connect_request.as_bytes(),
        &tls_client_hello(TARGET_HOST),
        deadline,
    )
    .await;

    let _ = child.start_kill();
    let output = match timeout(Duration::from_secs(2), child.wait_with_output()).await {
        Ok(Ok(output)) => Some(output),
        Ok(Err(_)) | Err(_) => None,
    };

    let ok = trace.error.is_none() && trace.connect_ok && trace.post_connect_received_bytes > 0;

    let (naive_stdout, naive_stderr) = output.map_or_else(
        || (Vec::new(), Vec::new()),
        |out| (sanitize_lines(&out.stdout), sanitize_lines(&out.stderr)),
    );

    Ok(DebugHandshakeReport {
        server: profile.server().to_string(),
        target: TARGET_AUTHORITY.to_owned(),
        ok,
        connect_ok: trace.connect_ok,
        post_connect_received_bytes: trace.post_connect_received_bytes as u64,
        elapsed_ms: ms_to_u64(started.elapsed()),
        local_sent_hex: first_hex(&trace.sent),
        local_received_hex: first_hex(&trace.received),
        naive_stdout,
        naive_stderr,
        error: trace.error,
    })
}

struct DebugNaiveConfig {
    path: PathBuf,
}

impl DebugNaiveConfig {
    fn write(profile: &Profile, port: u16) -> Result<Self, std::io::Error> {
        let proxy = NaiveConfig::from_profile(profile).proxy;
        let proxy_json = serde_json::to_string(&proxy).map_err(std::io::Error::other)?;
        let body = format!(
            "{{\n  \"listen\": \"http://127.0.0.1:{port}\",\n  \"proxy\": {proxy_json}\n}}\n"
        );

        for attempt in 0_u8..16 {
            let path = debug_config_path(attempt);
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            options.mode(0o600);

            match options.open(&path) {
                Ok(mut file) => {
                    file.write_all(body.as_bytes())?;
                    file.sync_all()?;
                    return Ok(Self { path });
                }
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(err) => return Err(err),
            }
        }

        Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "could not allocate a unique temporary debug handshake config path",
        ))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for DebugNaiveConfig {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

fn debug_config_path(attempt: u8) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |duration| duration.as_nanos());
    std::env::temp_dir().join(format!(
        "cool-tunnel-debug-handshake-{}-{nanos}-{attempt}.json",
        std::process::id()
    ))
}

async fn pick_free_port() -> Result<u16, std::io::Error> {
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    listener.local_addr().map(|addr| addr.port())
}

async fn wait_for_listener(
    child: &mut tokio::process::Child,
    port: u16,
) -> Result<bool, DebugHandshakeError> {
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    while Instant::now() < deadline {
        if let Ok(Some(_status)) = child.try_wait() {
            return Err(DebugHandshakeError::ExitedEarly);
        }
        if TcpStream::connect(("127.0.0.1", port)).await.is_ok() {
            return Ok(true);
        }
        sleep(STARTUP_POLL).await;
    }
    Ok(false)
}

#[derive(Debug, Default)]
struct LocalConnectTrace {
    sent: Vec<u8>,
    received: Vec<u8>,
    connect_ok: bool,
    post_connect_received_bytes: usize,
    error: Option<String>,
}

async fn drive_local_connect(
    port: u16,
    connect_request: &[u8],
    post_connect_payload: &[u8],
    deadline: Duration,
) -> LocalConnectTrace {
    match timeout(
        deadline,
        drive_local_connect_inner(port, connect_request, post_connect_payload),
    )
    .await
    {
        Ok(trace) => trace,
        Err(_) => LocalConnectTrace {
            error: Some(format!(
                "debug handshake timed out after {}s",
                deadline.as_secs()
            )),
            ..LocalConnectTrace::default()
        },
    }
}

async fn drive_local_connect_inner(
    port: u16,
    connect_request: &[u8],
    post_connect_payload: &[u8],
) -> LocalConnectTrace {
    let mut trace = LocalConnectTrace::default();
    let mut stream = match TcpStream::connect(("127.0.0.1", port)).await {
        Ok(stream) => stream,
        Err(err) => {
            trace.error = Some(format!("failed to connect to temporary listener: {err}"));
            return trace;
        }
    };

    if let Err(err) = stream.write_all(connect_request).await {
        trace.error = Some(format!("failed to write CONNECT request: {err}"));
        return trace;
    }
    trace.sent.extend_from_slice(connect_request);
    if let Err(err) = stream.flush().await {
        trace.error = Some(format!("failed to flush CONNECT request: {err}"));
        return trace;
    }

    if let Err(err) = read_until_connect_response(&mut stream, &mut trace.received).await {
        trace.error = Some(format!("failed to read CONNECT response: {err}"));
        return trace;
    }
    let received_text = String::from_utf8_lossy(&trace.received).to_ascii_lowercase();
    trace.connect_ok =
        received_text.starts_with("http/1.1 200") || received_text.starts_with("http/1.0 200");
    if !trace.connect_ok {
        trace.error = Some("CONNECT did not return HTTP 200".to_owned());
        return trace;
    }

    if let Err(err) = stream.write_all(post_connect_payload).await {
        trace.error = Some(format!("failed to write post-CONNECT TLS probe: {err}"));
        return trace;
    }
    trace.sent.extend_from_slice(post_connect_payload);
    if let Err(err) = stream.flush().await {
        trace.error = Some(format!("failed to flush post-CONNECT TLS probe: {err}"));
        return trace;
    }

    let mut buffer = [0_u8; 512];
    match stream.read(&mut buffer).await {
        Ok(0) => {
            trace.error = Some("post-CONNECT tunnel closed before target replied".to_owned());
        }
        Ok(n) => {
            trace.post_connect_received_bytes = n;
            append_capture(&mut trace.received, &buffer[..n]);
        }
        Err(err) => {
            trace.error = Some(format!("post-CONNECT read failed: {err}"));
        }
    }

    trace
}

async fn read_until_connect_response(
    stream: &mut TcpStream,
    received: &mut Vec<u8>,
) -> Result<(), std::io::Error> {
    let mut buffer = [0_u8; 512];
    while !has_header_terminator(received) && received.len() < READ_LIMIT_BYTES {
        let n = stream.read(&mut buffer).await?;
        if n == 0 {
            break;
        }
        append_capture(received, &buffer[..n]);
    }
    Ok(())
}

fn append_capture(out: &mut Vec<u8>, bytes: &[u8]) {
    let remaining = READ_LIMIT_BYTES.saturating_sub(out.len());
    out.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
}

fn has_header_terminator(bytes: &[u8]) -> bool {
    bytes.windows(4).any(|window| window == b"\r\n\r\n")
}

fn tls_client_hello(host: &str) -> Vec<u8> {
    let host = host.as_bytes();
    let mut extensions = Vec::new();

    let mut sni_data = Vec::new();
    push_u16(&mut sni_data, u16_saturating(1 + 2 + host.len()));
    sni_data.push(0);
    push_u16(&mut sni_data, u16_saturating(host.len()));
    sni_data.extend_from_slice(host);
    push_extension(&mut extensions, 0x0000, &sni_data);

    let mut supported_groups = Vec::new();
    push_u16(&mut supported_groups, 6);
    supported_groups.extend_from_slice(&[0x00, 0x1d, 0x00, 0x17, 0x00, 0x18]);
    push_extension(&mut extensions, 0x000a, &supported_groups);

    push_extension(&mut extensions, 0x000b, &[0x01, 0x00]);

    let mut signature_algorithms = Vec::new();
    push_u16(&mut signature_algorithms, 10);
    signature_algorithms
        .extend_from_slice(&[0x04, 0x03, 0x08, 0x04, 0x04, 0x01, 0x05, 0x03, 0x05, 0x01]);
    push_extension(&mut extensions, 0x000d, &signature_algorithms);

    let mut alpn = Vec::new();
    push_u16(&mut alpn, 9);
    alpn.push(8);
    alpn.extend_from_slice(b"http/1.1");
    push_extension(&mut extensions, 0x0010, &alpn);

    push_extension(&mut extensions, 0x002b, &[0x02, 0x03, 0x03]);

    let mut body = Vec::new();
    body.extend_from_slice(&[0x03, 0x03]);
    body.extend_from_slice(&[
        0x43, 0x4f, 0x4f, 0x4c, 0x2d, 0x54, 0x55, 0x4e, 0x4e, 0x45, 0x4c, 0x2d, 0x44, 0x45, 0x42,
        0x55, 0x47, 0x2d, 0x48, 0x41, 0x4e, 0x44, 0x53, 0x48, 0x41, 0x4b, 0x45, 0x2d, 0x30, 0x30,
        0x30, 0x31,
    ]);
    body.push(0);

    let cipher_suites = [
        0xc0, 0x2f, 0xc0, 0x2b, 0xcc, 0xa9, 0xcc, 0xa8, 0xc0, 0x30, 0xc0, 0x2c, 0x00, 0x9e, 0x00,
        0x9c, 0x00, 0x2f, 0x00, 0x35,
    ];
    push_u16(&mut body, u16_saturating(cipher_suites.len()));
    body.extend_from_slice(&cipher_suites);
    body.extend_from_slice(&[0x01, 0x00]);
    push_u16(&mut body, u16_saturating(extensions.len()));
    body.extend_from_slice(&extensions);

    let mut handshake = Vec::new();
    handshake.push(0x01);
    push_u24(&mut handshake, u32_saturating(body.len()));
    handshake.extend_from_slice(&body);

    let mut record = Vec::new();
    record.extend_from_slice(&[0x16, 0x03, 0x01]);
    push_u16(&mut record, u16_saturating(handshake.len()));
    record.extend_from_slice(&handshake);
    record
}

fn push_extension(out: &mut Vec<u8>, ty: u16, data: &[u8]) {
    push_u16(out, ty);
    push_u16(out, u16_saturating(data.len()));
    out.extend_from_slice(data);
}

fn push_u16(out: &mut Vec<u8>, value: u16) {
    out.extend_from_slice(&value.to_be_bytes());
}

fn push_u24(out: &mut Vec<u8>, value: u32) {
    let bytes = value.to_be_bytes();
    out.extend_from_slice(&bytes[1..]);
}

fn u16_saturating(value: usize) -> u16 {
    u16::try_from(value).unwrap_or(u16::MAX)
}

fn u32_saturating(value: usize) -> u32 {
    u32::try_from(value).unwrap_or(u32::MAX)
}

fn first_hex(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len().min(HEX_CAPTURE_BYTES) * 3);
    for (idx, byte) in bytes.iter().take(HEX_CAPTURE_BYTES).enumerate() {
        if idx > 0 {
            out.push(' ');
        }
        push_hex_byte(&mut out, *byte);
    }
    out
}

fn push_hex_byte(out: &mut String, byte: u8) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    out.push(char::from(HEX[usize::from(byte >> 4)]));
    out.push(char::from(HEX[usize::from(byte & 0x0f)]));
}

fn sanitize_lines(bytes: &[u8]) -> Vec<String> {
    String::from_utf8_lossy(bytes)
        .lines()
        .take(LOG_LINE_LIMIT)
        .map(|line| {
            let redacted = redaction::redact(line);
            let mut line = redacted.into_owned();
            if line.len() > LOG_LINE_BYTES {
                line.truncate(LOG_LINE_BYTES);
                line.push_str("... [truncated]");
            }
            line
        })
        .filter(|line| !line.trim().is_empty())
        .collect()
}

#[allow(clippy::cast_possible_truncation)]
fn ms_to_u64(duration: Duration) -> u64 {
    let ms = duration.as_millis();
    if ms > u128::from(u64::MAX) {
        u64::MAX
    } else {
        ms as u64
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn first_hex_caps_and_formats_bytes() {
        assert_eq!(first_hex(b"CONNECT"), "43 4f 4e 4e 45 43 54");
    }

    #[test]
    fn sanitize_lines_redacts_userinfo() {
        let lines = sanitize_lines(b"proxy https://user:secret@example.com\n");
        assert_eq!(lines.len(), 1);
        assert!(!lines[0].contains("secret"));
    }

    #[test]
    fn tls_client_hello_contains_sni_and_alpn() {
        let hello = tls_client_hello("www.google.com");
        assert_eq!(&hello[0..3], &[0x16, 0x03, 0x01]);
        assert!(hello
            .windows(b"www.google.com".len())
            .any(|w| w == b"www.google.com"));
        assert!(hello.windows(b"http/1.1".len()).any(|w| w == b"http/1.1"));
    }

    #[test]
    fn header_terminator_detects_complete_response() {
        assert!(!has_header_terminator(b"HTTP/1.1 200 OK\r\n"));
        assert!(has_header_terminator(b"HTTP/1.1 200 OK\r\n\r\n"));
    }
}
