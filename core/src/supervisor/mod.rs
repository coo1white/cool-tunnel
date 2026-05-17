// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//! Lifecycle management of the `sing-box` child process.
//!
//! [`ProxySupervisor`] owns one running `sing-box` instance. Spawning
//! installs a background task that streams the child's stdout and
//! stderr lines as [`crate::protocol::Event::LogLine`] events. Natural-
//! death detection runs in `client_mode::monitor_loop` so it can gate
//! the at-most-once `StateChanged { running: false }` emission.

use std::path::Path;
use std::process::Stdio;

use tokio::io::{AsyncBufReadExt as _, AsyncRead, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use crate::error::CoreError;
use crate::protocol::{Event, LogSource};
use crate::redaction::redact;

/// Maximum bytes retained for one child-process log line before
/// forwarding it to Swift. A hostile or broken `sing-box` build can
/// otherwise write a newline-free blob and make `BufReadExt::lines`
/// allocate until EOF. 16 KiB is far above legitimate diagnostic
/// lines and keeps the UI/export buffer bounded.
const MAX_CHILD_LOG_LINE_BYTES: usize = 16 * 1024;

/// Handle to a running `sing-box` child.
///
/// Drop the handle (or call [`Self::stop`]) to terminate the child.
#[derive(Debug)]
pub struct ProxySupervisor {
    pid: u32,
    kill_tx: Option<oneshot::Sender<()>>,
    monitor: Option<JoinHandle<()>>,
}

impl ProxySupervisor {
    /// Spawns `sing-box run -c <config>` and starts streaming its output.
    ///
    /// `events` is the engine-wide outbound event channel. The supervisor
    /// keeps a clone for each background task; closing every clone allows
    /// the engine to drain at shutdown.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Spawn`] when the child process cannot be created
    /// or its stdio handles cannot be captured.
    #[allow(clippy::unused_async)]
    pub async fn spawn(
        binary_path: &Path,
        config_path: &Path,
        events: mpsc::Sender<Event>,
    ) -> Result<Self, CoreError> {
        let mut command = Command::new(binary_path);
        // sing-box uses subcommand-based CLI: `sing-box run -c
        // <config>`. The Swift caller passes only the config path
        // and binary path; assembling the argv lives here so the
        // protocol stays agnostic.
        command
            .arg("run")
            .arg("-c")
            .arg(config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command.spawn().map_err(CoreError::Spawn)?;

        let pid = child.id().ok_or_else(|| {
            CoreError::Spawn(std::io::Error::other(
                "sing-box child exited before reporting a PID",
            ))
        })?;

        let stdout = child.stdout.take().ok_or_else(|| {
            CoreError::Spawn(std::io::Error::other("sing-box stdout was not piped"))
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            CoreError::Spawn(std::io::Error::other("sing-box stderr was not piped"))
        })?;

        tokio::spawn(read_lines(stdout, LogSource::Stdout, events.clone()));
        tokio::spawn(read_lines(stderr, LogSource::Stderr, events.clone()));

        // `StateChanged { running: true }` is emitted by the
        // dispatcher AFTER the `Started { pid }` response writes,
        // so the wire ordering is `response → event` (Ru#C4).
        // See `client_mode::handle_request`.

        let (kill_tx, kill_rx) = oneshot::channel();
        let monitor = tokio::spawn(monitor_lifecycle(child, kill_rx, events));

        Ok(Self {
            pid,
            kill_tx: Some(kill_tx),
            monitor: Some(monitor),
        })
    }

    /// Returns the PID of the running child.
    #[must_use]
    pub const fn pid(&self) -> u32 {
        self.pid
    }

    /// Stops the child and waits for the monitor task to drain.
    ///
    /// Idempotent — calling `stop` after the child has already exited on its
    /// own is a no-op.
    ///
    /// # Errors
    ///
    /// Returns the underlying I/O error if joining the monitor task fails.
    /// In practice this never happens for a healthy task.
    pub async fn stop(mut self) -> Result<(), CoreError> {
        if let Some(tx) = self.kill_tx.take() {
            let _ = tx.send(());
        }
        // Bound the monitor-drain wait. The happy path is that
        // `monitor_lifecycle` returns within a few ms (kill_rx
        // → child.kill → child.wait → StateChanged emit). If
        // anything has gone sideways — child stuck in an
        // uninterruptible state, kernel pause, etc. — we
        // abort the task rather than leak the wait indefinitely.
        // `kill_on_drop(true)` on the original spawn means the
        // child still gets reaped when `Child` drops with the
        // task; the only thing we lose is the trailing
        // `StateChanged { running: false }` event, which the
        // engine can also synthesize from supervisor disposal.
        if let Some(mut handle) = self.monitor.take() {
            // Pass `&mut handle` to `timeout` so ownership stays
            // local — on the timeout branch we still hold the
            // handle and can `abort()` it explicitly. The previous
            // implementation moved the handle into `timeout`, so
            // on expiry it leaked: the task kept awaiting
            // `child.wait()` indefinitely and the `Child`
            // (with `kill_on_drop`) was never dropped because
            // the task that owned it never returned. A subsequent
            // `start_proxy` could spawn a *second* `naive` against
            // the still-alive previous PID.
            if tokio::time::timeout(std::time::Duration::from_secs(2), &mut handle)
                .await
                .is_err()
            {
                tracing::warn!(
                    pid = self.pid,
                    "monitor_lifecycle did not drain within 2s; aborting"
                );
                handle.abort();
                // Drain the abort so the inner `Child` drops and
                // `kill_on_drop(true)` actually reaps the naive
                // subprocess.
                let _ = handle.await;
            }
        }
        Ok(())
    }
}

impl Drop for ProxySupervisor {
    fn drop(&mut self) {
        // Signal the monitor to terminate the child.
        if let Some(tx) = self.kill_tx.take() {
            let _ = tx.send(());
        }
        // Abort the monitor task too, so the JoinHandle isn't
        // leaked on the runtime if the supervisor is dropped
        // without `stop()` being called (e.g. a future code
        // path where `start_proxy` succeeds but a subsequent
        // `?` propagates and the supervisor goes out of scope
        // before being stored in `EngineState`). `kill_on_drop`
        // on the underlying `Child` handles reap.
        if let Some(handle) = self.monitor.take() {
            handle.abort();
        }
    }
}

async fn read_lines<R>(reader: R, source: LogSource, events: mpsc::Sender<Event>)
where
    R: AsyncRead + Unpin + Send + 'static,
{
    let mut reader = BufReader::new(reader);
    let mut buffer = Vec::with_capacity(1024);
    loop {
        buffer.clear();
        match reader.read_until(b'\n', &mut buffer).await {
            Ok(0) => return,
            Ok(_) => {
                let truncated = buffer.len() > MAX_CHILD_LOG_LINE_BYTES;
                if truncated {
                    buffer.truncate(MAX_CHILD_LOG_LINE_BYTES);
                }
                while matches!(buffer.last(), Some(b'\n' | b'\r')) {
                    buffer.pop();
                }
                let mut line = String::from_utf8_lossy(&buffer).into_owned();
                if truncated {
                    line.push_str("... [truncated]");
                }
                // Redact userinfo + bare-UUID + Reality public_key /
                // short_id patterns before any forwarding. sing-box
                // prints the resolved outbound block (with UUID and
                // Reality keys) at startup; without this filter those
                // secrets reach the UI log buffer.
                let redacted = redact(&line).into_owned();
                if events
                    .send(Event::LogLine {
                        source,
                        line: redacted,
                    })
                    .await
                    .is_err()
                {
                    return;
                }
            }
            Err(err) => {
                // Log the IO error before dropping it. Loss of a
                // log stream is the most likely cause of mid-
                // session log silence; without the warn the
                // operator has no signal to debug from.
                tracing::warn!(?source, error = %err, "log stream ended with error");
                return;
            }
        }
    }
}

async fn monitor_lifecycle(
    mut child: Child,
    kill_rx: oneshot::Receiver<()>,
    _events: mpsc::Sender<Event>,
) {
    // **v0.1.7.10 (Ru-A1):** monitor_lifecycle no longer emits
    // `StateChanged { running: false }`. The single emitter
    // for natural-death is now `client_mode::monitor_loop`,
    // gated by an at-most-once flag in `EngineState` so it
    // never duplicates with the dispatcher's user-stop emit.
    // monitor_lifecycle's job is now pure cleanup: drain on
    // either `kill_rx` or natural exit, kill_on_drop reaps the
    // child if we were aborted mid-flight.
    tokio::select! {
        _ = kill_rx => {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        _ = child.wait() => {}
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tokio::time::{timeout, Duration};

    fn shell_path() -> PathBuf {
        PathBuf::from("/bin/sh")
    }

    #[tokio::test]
    async fn supervisor_streams_stdout_and_signals_state_changes() {
        let (tx, mut rx) = mpsc::channel::<Event>(32);

        // Use /bin/sh -c "echo hello; sleep 0.05" to emulate a short-lived child.
        // We bend the API: pass /bin/sh as the binary and "-c ..." as the config.
        // The supervisor spawns Command::new(binary).arg(config), so
        // /bin/sh -c "echo hello; sleep 0.05" works as a stand-in.
        let mut cmd = Command::new(shell_path());
        cmd.arg("-c")
            .arg("echo hello-from-test; sleep 0.05")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = cmd.spawn().unwrap();
        let stdout = child.stdout.take().unwrap();
        let stderr = child.stderr.take().unwrap();

        tokio::spawn(read_lines(stdout, LogSource::Stdout, tx.clone()));
        tokio::spawn(read_lines(stderr, LogSource::Stderr, tx.clone()));
        let (kx_tx, kx_rx) = oneshot::channel();
        let _h = tokio::spawn(monitor_lifecycle(child, kx_rx, tx.clone()));
        drop(tx); // close the original sender so receivers see end-of-stream when tasks finish

        // **v0.1.7.10:** monitor_lifecycle no longer emits
        // `StateChanged { running: false }` (Ru-A1 single-emitter
        // discipline). The natural-death emission moved to
        // `client_mode::monitor_loop` which gates on the engine
        // state's at-most-once flag. So this test now just
        // asserts the log line was streamed and the lifecycle
        // task drained — no state-change event is expected from
        // the supervisor itself.
        let mut saw_log_line = false;
        while let Some(evt) = timeout(Duration::from_secs(2), rx.recv()).await.unwrap() {
            if let Event::LogLine { line, .. } = evt {
                if line.contains("hello-from-test") {
                    saw_log_line = true;
                }
            }
        }
        assert!(saw_log_line, "expected to receive the echoed log line");
        // suppress unused-variable warning for kx_tx; we deliberately let the child exit on its own.
        drop(kx_tx);
    }
}
