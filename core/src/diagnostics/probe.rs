//! Single-shot `curl` invocation that returns a [`LatencySample`].

use tokio::process::Command;

use crate::domain::Port;
use crate::protocol::LatencySample;

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

    cmd.arg("-w").arg(WRITE_OUT_FORMAT).arg(&opts.url);

    let started = tokio::time::Instant::now();
    let output = cmd.output().await?;
    let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    let metrics = parse_write_out(&stdout);

    let http_code = metrics.get("http_code").map_or("000", String::as_str);

    let ok = output.status.success() && http_code != "000";

    let notes = if ok {
        format!("HTTP {http_code} via curl exit {}", output.status)
    } else {
        let trimmed = stderr.trim();
        if trimmed.is_empty() {
            format!("HTTP {http_code} via curl exit {}", output.status)
        } else {
            format!("curl exit {}: {trimmed}", output.status)
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
