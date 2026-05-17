// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Single-shot `curl` invocation that returns a [`LatencySample`].

use tokio::process::Command;

use crate::domain::Port;
use crate::protocol::LatencySample;
use crate::redaction;

use super::metrics::{parse_write_out, secs_to_ms};

const WRITE_OUT_FORMAT: &str = concat!(
    "http_code=%{http_code}\\n",
    "remote_ip=%{remote_ip}\\n",
    "time_namelookup=%{time_namelookup}\\n",
    "time_connect=%{time_connect}\\n",
    "time_appconnect=%{time_appconnect}\\n",
    "time_starttransfer=%{time_starttransfer}\\n",
    "time_total=%{time_total}\\n",
);

/// Inputs to a single curl probe.
#[derive(Debug, Clone)]
pub struct ProbeOptions {
    /// URL to probe.
    pub url: String,
    /// When `Some`, route the probe through `socks5h://127.0.0.1:<port>`.
    pub proxy_port: Option<Port>,
    /// `--connect-timeout` value in seconds.
    pub connect_timeout_secs: u32,
    /// `--max-time` value in seconds.
    pub max_time_secs: u32,
}

/// Runs `curl` with the given options and returns a [`LatencySample`].
///
/// # Errors
///
/// Returns the underlying [`std::io::Error`] if the `curl` executable cannot
/// be spawned. Network failures are surfaced inside the [`LatencySample`]
/// (`ok: false`, with `notes` containing the captured stderr).
pub async fn run_probe(opts: &ProbeOptions) -> std::io::Result<LatencySample> {
    let mut cmd = Command::new("/usr/bin/curl");
    cmd.arg("-L")
        .arg("-o")
        .arg("/dev/null")
        .arg("-sS")
        .arg("--connect-timeout")
        .arg(opts.connect_timeout_secs.to_string())
        .arg("--max-time")
        .arg(opts.max_time_secs.to_string());

    if let Some(port) = opts.proxy_port {
        cmd.arg("-x").arg(format!("socks5h://127.0.0.1:{port}"));
    }

    // `--` separates flags from positional args so a URL beginning
    // with `-` (no caller passes one today, but a future caller
    // surfacing user-set probe targets would) cannot be interpreted
    // by curl as an additional flag.
    cmd.arg("-w").arg(WRITE_OUT_FORMAT).arg("--").arg(&opts.url);
    // Reap the curl child if the diagnostic Task is cancelled
    // — without this, every cancelled probe leaks a curl process
    // until the kernel finally closes its sockets.
    cmd.kill_on_drop(true);

    let started = tokio::time::Instant::now();
    // Outer Tokio-side timeout in case curl itself wedges in
    // libc's getaddrinfo or similar — `--max-time` only governs
    // the request itself once curl is in its event loop.
    // Add 5 seconds of slack so curl's normal slow-path finishes
    // first; only truly-stuck processes hit our outer ceiling.
    let outer_deadline =
        std::time::Duration::from_secs(u64::from(opts.max_time_secs).saturating_add(5));
    let output = match tokio::time::timeout(outer_deadline, cmd.output()).await {
        Ok(result) => result?,
        Err(_) => {
            return Err(std::io::Error::new(
                std::io::ErrorKind::TimedOut,
                "curl did not return within the outer deadline",
            ));
        }
    };
    let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let metrics = parse_write_out(&stdout);

    let http_code = metrics.get("http_code").map_or("000", String::as_str);

    let ok = output.status.success() && http_code != "000";

    // curl's stderr can include the full proxy URL (with embedded
    // userinfo) and any auth/cookie headers from the failure path.
    // Redact before stringifying so the note we ship over the wire,
    // log to stderr, or surface to the UI never carries secrets even
    // when a future code change starts passing credentials to curl.
    let notes = if ok {
        format!("HTTP {http_code} via curl exit {}", output.status)
    } else {
        let trimmed = stderr.trim();
        if trimmed.is_empty() {
            format!("HTTP {http_code} via curl exit {}", output.status)
        } else {
            let redacted = redaction::redact(trimmed);
            format!("curl exit {}: {redacted}", output.status)
        }
    };

    Ok(LatencySample {
        url: opts.url.clone(),
        ok,
        elapsed_ms,
        dns_ms: secs_to_ms(metrics.get("time_namelookup")).unwrap_or(-1.0),
        connect_ms: secs_to_ms(metrics.get("time_connect")).unwrap_or(-1.0),
        tls_ms: secs_to_ms(metrics.get("time_appconnect")).unwrap_or(-1.0),
        first_byte_ms: secs_to_ms(metrics.get("time_starttransfer")).unwrap_or(-1.0),
        notes,
    })
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;

    #[test]
    fn probe_options_round_trip() {
        let opts = ProbeOptions {
            url: "https://example.com".to_owned(),
            proxy_port: Some(Port::new(1080).unwrap()),
            connect_timeout_secs: 5,
            max_time_secs: 12,
        };
        let cloned = opts.clone();
        assert_eq!(cloned.url, opts.url);
        assert_eq!(cloned.proxy_port, opts.proxy_port);
    }
}
