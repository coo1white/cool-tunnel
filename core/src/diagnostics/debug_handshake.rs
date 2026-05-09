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

#[allow(missing_docs)]
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

    let connect_request = format!(
        "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\nUser-Agent: cool-tunnel-debug-handshake\r\nProxy-Connection: keep-alive\r\n\r\n",
        target = TARGET_AUTHORITY,
    );
    let sent = connect_request.into_bytes();
    let (received, error) = drive_local_connect(port, &sent, deadline).await;

    let _ = child.start_kill();
    let output = match timeout(Duration::from_secs(2), child.wait_with_output()).await {
        Ok(Ok(output)) => Some(output),
        Ok(Err(_)) | Err(_) => None,
    };

    let received_text = String::from_utf8_lossy(&received).to_ascii_lowercase();
    let ok = error.is_none()
        && (received_text.starts_with("http/1.1 200") || received_text.starts_with("http/1.0 200"));

    let (naive_stdout, naive_stderr) = output.map_or_else(
        || (Vec::new(), Vec::new()),
        |out| (sanitize_lines(&out.stdout), sanitize_lines(&out.stderr)),
    );

    Ok(DebugHandshakeReport {
        server: profile.server().to_string(),
        target: TARGET_AUTHORITY.to_owned(),
        ok,
        elapsed_ms: ms_to_u64(started.elapsed()),
        local_sent_hex: first_hex(&sent),
        local_received_hex: first_hex(&received),
        naive_stdout,
        naive_stderr,
        error,
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
                Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
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
        .map(|duration| duration.as_nanos())
        .unwrap_or(0);
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

async fn drive_local_connect(
    port: u16,
    sent: &[u8],
    deadline: Duration,
) -> (Vec<u8>, Option<String>) {
    match timeout(deadline, drive_local_connect_inner(port, sent)).await {
        Ok(Ok(received)) => (received, None),
        Ok(Err(err)) => (Vec::new(), Some(err.to_string())),
        Err(_) => (
            Vec::new(),
            Some(format!(
                "debug handshake timed out after {}s",
                deadline.as_secs()
            )),
        ),
    }
}

async fn drive_local_connect_inner(port: u16, sent: &[u8]) -> Result<Vec<u8>, std::io::Error> {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).await?;
    stream.write_all(sent).await?;
    stream.flush().await?;
    let mut received = vec![0_u8; READ_LIMIT_BYTES];
    let n = stream.read(&mut received).await?;
    received.truncate(n);
    Ok(received)
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
}
