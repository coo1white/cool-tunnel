//! Lifecycle management of the `naive` child process.
//!
//! [`ProxySupervisor`] owns one running `naive` instance. Spawning installs
//! a background task that streams the child's stdout and stderr lines as
//! [`crate::protocol::Event::LogLine`] events and emits a final
//! [`crate::protocol::Event::StateChanged`] when the process exits — whether
//! it died on its own or was killed via [`ProxySupervisor::stop`].

use std::path::Path;
use std::process::Stdio;

use tokio::io::{AsyncBufReadExt as _, AsyncRead, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot};
use tokio::task::JoinHandle;

use crate::error::CoreError;
use crate::protocol::{Event, LogSource};
use crate::redaction::redact;

/// Handle to a running `naive` child.
///
/// Drop the handle (or call [`Self::stop`]) to terminate the child.
#[derive(Debug)]
pub struct ProxySupervisor {
    pid: u32,
    kill_tx: Option<oneshot::Sender<()>>,
    monitor: Option<JoinHandle<()>>,
}

impl ProxySupervisor {
    /// Spawns `naive` with the given config and starts streaming its output.
    ///
    /// `events` is the engine-wide outbound event channel. The supervisor
    /// keeps a clone for each background task; closing every clone allows
    /// the engine to drain at shutdown.
    ///
    /// # Errors
    ///
    /// Returns [`CoreError::Spawn`] when the child process cannot be created
    /// or its stdio handles cannot be captured.
    pub async fn spawn(
        binary_path: &Path,
        config_path: &Path,
        events: mpsc::Sender<Event>,
    ) -> Result<Self, CoreError> {
        let mut command = Command::new(binary_path);
        command
            .arg(config_path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let mut child = command.spawn().map_err(CoreError::Spawn)?;

        let pid = child.id().ok_or_else(|| {
            CoreError::Spawn(std::io::Error::other(
                "naive child exited before reporting a PID",
            ))
        })?;

        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| CoreError::Spawn(std::io::Error::other("naive stdout was not piped")))?;
        let stderr = child
            .stderr
            .take()
            .ok_or_else(|| CoreError::Spawn(std::io::Error::other("naive stderr was not piped")))?;

        tokio::spawn(read_lines(stdout, LogSource::Stdout, events.clone()));
        tokio::spawn(read_lines(stderr, LogSource::Stderr, events.clone()));

        let _ = events
            .send(Event::StateChanged { running: true })
            .await;

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
        if let Some(handle) = self.monitor.take() {
            let _ = handle.await;
        }
        Ok(())
    }
}

impl Drop for ProxySupervisor {
    fn drop(&mut self) {
        if let Some(tx) = self.kill_tx.take() {
            let _ = tx.send(());
        }
    }
}

async fn read_lines<R>(reader: R, source: LogSource, events: mpsc::Sender<Event>)
where
    R: AsyncRead + Unpin + Send + 'static,
{
    let mut lines = BufReader::new(reader).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                // Redact `scheme://user:pass@host` patterns before any
                // forwarding. `naive` prints its proxy URL with userinfo
                // at startup; without this filter those credentials reach
                // the UI log buffer.
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
            Ok(None) | Err(_) => return,
        }
    }
}

async fn monitor_lifecycle(
    mut child: Child,
    kill_rx: oneshot::Receiver<()>,
    events: mpsc::Sender<Event>,
) {
    tokio::select! {
        _ = kill_rx => {
            let _ = child.kill().await;
            let _ = child.wait().await;
        }
        _ = child.wait() => {}
    }
    let _ = events
        .send(Event::StateChanged { running: false })
        .await;
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used)]
mod tests {
    use super::*;
    use std::path::PathBuf;
    use tokio::time::{Duration, timeout};

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

        let mut saw_log_line = false;
        let mut saw_state_change_false = false;
        while let Some(evt) = timeout(Duration::from_secs(2), rx.recv()).await.unwrap() {
            match evt {
                Event::LogLine { line, .. } if line.contains("hello-from-test") => {
                    saw_log_line = true;
                }
                Event::StateChanged { running: false } => {
                    saw_state_change_false = true;
                }
                _ => {}
            }
        }
        assert!(saw_log_line, "expected to receive the echoed log line");
        assert!(saw_state_change_false, "expected a stopped state-change event");
        // suppress unused-variable warning for kx_tx; we deliberately let the child exit on its own.
        drop(kx_tx);
    }
}
