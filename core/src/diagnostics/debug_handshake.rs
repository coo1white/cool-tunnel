// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// Debug handshake: drives one SOCKS5 connect through a temporary
// `sing-box` child to confirm the VLESS+Reality outbound is wiring
// up against the configured server. Replaces the v2.x HTTP-CONNECT
// framing used by NaiveProxy.

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

use crate::config::SingboxConfig;
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
const TARGET_PORT: u16 = 443;
const TARGET_AUTHORITY: &str = "www.google.com:443";
const READ_LIMIT_BYTES: usize = HEX_CAPTURE_BYTES;
const LOG_LINE_LIMIT: usize = 12;
const LOG_LINE_BYTES: usize = 512;

#[derive(Debug, Error)]
enum DebugHandshakeError {
    #[error("failed to choose a temporary listener port: {0}")]
    PickPort(std::io::Error),
    #[error("failed to spawn sing-box for debug handshake: {0}")]
    Spawn(std::io::Error),
    #[error("failed to write temporary debug handshake config: {0}")]
    ConfigWrite(std::io::Error),
    #[error("failed to render temporary debug handshake config: {0}")]
    ConfigRender(serde_json::Error),
    #[error("sing-box did not bind the temporary listener within {0:?}")]
    StartupTimeout(Duration),
    #[error("sing-box exited before binding the temporary listener")]
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
    let config = DebugSingboxConfig::write(profile, port)?;

    let mut child = Command::new(binary_path)
        .arg("run")
        .arg("-c")
        .arg(config.path())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(DebugHandshakeError::Spawn)?;

    if !wait_for_listener(&mut child, port).await? {
        return Err(DebugHandshakeError::StartupTimeout(STARTUP_TIMEOUT));
    }

    let trace = drive_local_socks_connect(
        port,
        TARGET_HOST,
        TARGET_PORT,
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

    let (singbox_stdout, singbox_stderr) = output.map_or_else(
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
        singbox_stdout,
        singbox_stderr,
        error: trace.error,
    })
}

struct DebugSingboxConfig {
    path: PathBuf,
}

impl DebugSingboxConfig {
    fn write(profile: &Profile, listen_port: u16) -> Result<Self, DebugHandshakeError> {
        // Re-render the canonical client config but force the
        // local SOCKS listener onto `listen_port`. We can't go
        // through `Profile::local_port` (the type rejects 0 and
        // we want to honour whatever ephemeral port we picked) so
        // we serialize the SingboxConfig produced from `profile`
        // and then post-process the JSON Value to swap the port.
        let canonical = SingboxConfig::from_profile(profile);
        let canonical_json = canonical
            .to_pretty_json()
            .map_err(DebugHandshakeError::ConfigRender)?;
        let mut value: serde_json::Value =
            serde_json::from_str(&canonical_json).map_err(DebugHandshakeError::ConfigRender)?;
        // Swap inbounds[0].listen_port to the ephemeral port.
        if let Some(port_field) = value
            .get_mut("inbounds")
            .and_then(|inbounds| inbounds.get_mut(0))
            .and_then(|first| first.get_mut("listen_port"))
        {
            *port_field = serde_json::Value::from(listen_port);
        }
        let body =
            serde_json::to_string_pretty(&value).map_err(DebugHandshakeError::ConfigRender)?;

        for attempt in 0_u8..16 {
            let path = debug_config_path(attempt);
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            options.mode(0o600);

            match options.open(&path) {
                Ok(mut file) => {
                    file.write_all(body.as_bytes())
                        .map_err(DebugHandshakeError::ConfigWrite)?;
                    file.sync_all().map_err(DebugHandshakeError::ConfigWrite)?;
                    return Ok(Self { path });
                }
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(err) => return Err(DebugHandshakeError::ConfigWrite(err)),
            }
        }

        Err(DebugHandshakeError::ConfigWrite(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            "could not allocate a unique temporary debug handshake config path",
        )))
    }

    fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for DebugSingboxConfig {
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

/// Drives a SOCKS5 CONNECT through the temporary sing-box listener
/// and pushes a TLS ClientHello through it, capturing the first
/// reply bytes. Bounded by `deadline` end-to-end.
async fn drive_local_socks_connect(
    port: u16,
    target_host: &str,
    target_port: u16,
    post_connect_payload: &[u8],
    deadline: Duration,
) -> LocalConnectTrace {
    match timeout(
        deadline,
        drive_local_socks_connect_inner(port, target_host, target_port, post_connect_payload),
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

async fn drive_local_socks_connect_inner(
    port: u16,
    target_host: &str,
    target_port: u16,
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

    // ---- SOCKS5 greeting: VER=5, NMETHODS=1, METHODS=[NoAuth(0)].
    let greeting = [0x05_u8, 0x01, 0x00];
    if let Err(err) = stream.write_all(&greeting).await {
        trace.error = Some(format!("failed to write SOCKS5 greeting: {err}"));
        return trace;
    }
    append_capture(&mut trace.sent, &greeting);
    if let Err(err) = stream.flush().await {
        trace.error = Some(format!("failed to flush SOCKS5 greeting: {err}"));
        return trace;
    }

    // Greeting reply: VER, METHOD. NoAuth ⇒ 0x00.
    let mut greeting_reply = [0_u8; 2];
    if let Err(err) = stream.read_exact(&mut greeting_reply).await {
        trace.error = Some(format!("failed to read SOCKS5 greeting reply: {err}"));
        return trace;
    }
    append_capture(&mut trace.received, &greeting_reply);
    if greeting_reply[0] != 0x05 || greeting_reply[1] != 0x00 {
        trace.error = Some(format!(
            "SOCKS5 greeting rejected (ver={:#04x}, method={:#04x})",
            greeting_reply[0], greeting_reply[1]
        ));
        return trace;
    }

    // ---- SOCKS5 CONNECT request: VER=5, CMD=1 (CONNECT), RSV=0,
    //      ATYP=3 (domain), DST.LEN, DST.HOST, DST.PORT (BE u16).
    let host_bytes = target_host.as_bytes();
    // SOCKS5 ATYP=3 (domain) limits the host length to a single byte;
    // u8::try_from rejects > 255 (clippy::cast_possible_truncation).
    let Ok(host_len) = u8::try_from(host_bytes.len()) else {
        trace.error = Some("SOCKS5 target host exceeds 255 bytes".to_owned());
        return trace;
    };
    let mut request = Vec::with_capacity(7 + host_bytes.len());
    request.extend_from_slice(&[0x05, 0x01, 0x00, 0x03]);
    request.push(host_len);
    request.extend_from_slice(host_bytes);
    request.extend_from_slice(&target_port.to_be_bytes());
    if let Err(err) = stream.write_all(&request).await {
        trace.error = Some(format!("failed to write SOCKS5 CONNECT: {err}"));
        return trace;
    }
    append_capture(&mut trace.sent, &request);
    if let Err(err) = stream.flush().await {
        trace.error = Some(format!("failed to flush SOCKS5 CONNECT: {err}"));
        return trace;
    }

    // CONNECT reply: VER, REP, RSV, ATYP, BND.ADDR…, BND.PORT.
    // Read the fixed prefix, then the variable-length BND.ADDR
    // based on ATYP.
    let mut reply_head = [0_u8; 4];
    if let Err(err) = stream.read_exact(&mut reply_head).await {
        trace.error = Some(format!("failed to read SOCKS5 CONNECT reply head: {err}"));
        return trace;
    }
    append_capture(&mut trace.received, &reply_head);
    if reply_head[0] != 0x05 {
        trace.error = Some(format!(
            "SOCKS5 reply carried unexpected version {:#04x}",
            reply_head[0]
        ));
        return trace;
    }
    if reply_head[1] != 0x00 {
        trace.error = Some(format!(
            "SOCKS5 CONNECT failed with REP={:#04x}",
            reply_head[1]
        ));
        return trace;
    }
    // ATYP-driven address byte count.
    let addr_len = match reply_head[3] {
        0x01 => 4,  // IPv4
        0x04 => 16, // IPv6
        0x03 => {
            let mut len_byte = [0_u8; 1];
            if let Err(err) = stream.read_exact(&mut len_byte).await {
                trace.error = Some(format!(
                    "failed to read SOCKS5 reply ATYP=domain len: {err}"
                ));
                return trace;
            }
            append_capture(&mut trace.received, &len_byte);
            usize::from(len_byte[0])
        }
        other => {
            trace.error = Some(format!("SOCKS5 reply carried unknown ATYP {other:#04x}"));
            return trace;
        }
    };
    let mut tail = vec![0_u8; addr_len + 2];
    if let Err(err) = stream.read_exact(&mut tail).await {
        trace.error = Some(format!("failed to read SOCKS5 CONNECT reply tail: {err}"));
        return trace;
    }
    append_capture(&mut trace.received, &tail);
    trace.connect_ok = true;

    // ---- Push TLS ClientHello through the established tunnel.
    if let Err(err) = stream.write_all(post_connect_payload).await {
        trace.error = Some(format!("failed to write post-CONNECT TLS probe: {err}"));
        return trace;
    }
    append_capture(&mut trace.sent, post_connect_payload);
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

fn append_capture(out: &mut Vec<u8>, bytes: &[u8]) {
    let remaining = READ_LIMIT_BYTES.saturating_sub(out.len());
    out.extend_from_slice(&bytes[..bytes.len().min(remaining)]);
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
        // SOCKS5 greeting payload, hexed.
        assert_eq!(first_hex(&[0x05, 0x01, 0x00]), "05 01 00");
    }

    #[test]
    fn sanitize_lines_redacts_uuid() {
        let lines = sanitize_lines(b"vless-out using uuid 11111111-2222-3333-4444-555555555555\n");
        assert_eq!(lines.len(), 1);
        assert!(!lines[0].contains("11111111-2222-3333-4444-555555555555"));
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
}
