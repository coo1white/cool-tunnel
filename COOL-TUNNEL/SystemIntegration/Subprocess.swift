// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
// SystemIntegration/Subprocess.swift
//
// Robust subprocess runner with concurrent pipe drain + hard
// timeout. Replaces several near-identical `runProcess` helpers
// scattered across SystemIntegration that all suffered from two
// real-world failures:
//
//   1. `process.waitUntilExit()` followed by
//      `pipe.fileHandleForReading.readDataToEndOfFile()` — if the
//      child writes more than the pipe buffer (~64 KB on macOS)
//      the child blocks on its next write, `waitUntilExit` blocks
//      on the still-running child, and the helper deadlocks.
//      Fix: drain both stdout and stderr concurrently *while*
//      the child runs.
//
//   2. No timeout. A wedged subprocess (`sing-box version`
//      hanging in a stuck DNS resolver, `lipo` blocked on a
//      slow disk, `codesign` paused on a kernel-level signal
//      block) parks the calling Task forever. Fix: race
//      `waitUntilExit` against a `Task.sleep`; on expiry,
//      escalate `terminate()` → `interrupt()` → SIGKILL.
//
// Used by FirewallProbe, SingboxBinaryResolver, RustCoreResolver.
// Updater-side helpers retain their bespoke flows for now since
// they're user-initiated and easier to recover from.

import Darwin
import Foundation

/// Result of a subprocess run.
public struct SubprocessResult: Sendable {
    /// `true` if the process exited cleanly with status 0.
    public let success: Bool
    /// Exit status (0 on success). `-1` if the process was killed
    /// after the timeout escalation.
    public let exitCode: Int32
    /// Captured stdout, decoded as UTF-8 (lossy on invalid bytes).
    public let stdout: String
    /// Captured stderr, decoded as UTF-8 (lossy on invalid bytes).
    public let stderr: String
    /// `true` if the process was killed by the timeout escalation.
    public let timedOut: Bool
}

/// Errors raised by [`Subprocess.run`] before the process can be
/// observed (launch failure). Post-launch failures are folded into
/// the result with `success == false`.
public enum SubprocessError: Error, Sendable {
    /// `process.run()` failed (binary missing, not executable,
    /// permission denied).
    case launchFailed(String)
}

/// Caseless namespace for the robust subprocess helpers.
public enum Subprocess {

    /// Runs `executable` with `arguments`, draining both pipes
    /// concurrently and enforcing `timeout`. Always returns within
    /// `timeout + ~1 s` (the kill-escalation grace).
    ///
    /// - Parameters:
    ///   - executable: absolute URL to the binary to invoke.
    ///   - arguments: argv tail (no shell expansion).
    ///   - timeout: wall-clock deadline. After expiry the child
    ///     is sent SIGTERM, then SIGINT 250 ms later, then SIGKILL
    ///     250 ms after that. The returned result has
    ///     `timedOut: true`.
    public static func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval = 30
    ) async throws -> SubprocessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // **Subproc-F#3 (v0.1.7.19):** sanitize the env passed
        // to children. Without this, the child inherits the
        // app's full env — including `DYLD_INSERT_LIBRARIES`,
        // `OBJC_DEBUG_*`, `MallocStackLogging`, etc. — which can
        // bias trust-boundary tools like `codesign` and
        // `networksetup`. The PATH is also reset to a
        // system-only allowlist so a barewords command in a
        // child shell (the relaunch helper invokes `ditto`,
        // `kill`, `mv`, `seq`, `date`, `open`) can't be
        // shadowed by something in `~/bin`. `LANG=C` /
        // `LC_ALL=C` keep output parsing locale-stable.
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "C",
            "LC_ALL": "C",
        ]

        do {
            try process.run()
        } catch {
            throw SubprocessError.launchFailed(error.localizedDescription)
        }

        // Spawn detached drains so the kernel pipe buffers never
        // fill while the child is still writing. Without this, a
        // chatty `--version` (or a verbose `codesign` failure) can
        // produce a classic pipe-deadlock.
        async let stdoutData: Data = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData: Data = readAll(stderrPipe.fileHandleForReading)

        // Race the wait against the timeout. Whichever wins, the
        // pipe drains complete by virtue of EOF on child exit.
        let timedOut = await waitWithTimeout(process: process, seconds: timeout)
        let stdoutBytes = await stdoutData
        let stderrBytes = await stderrData

        return SubprocessResult(
            success: !timedOut && process.terminationStatus == 0,
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: String(data: stdoutBytes, encoding: .utf8) ?? "",
            stderr: String(data: stderrBytes, encoding: .utf8) ?? "",
            timedOut: timedOut
        )
    }

    /// Waits for the process to exit, returning `true` if the
    /// timeout fired first (and we had to kill it).
    private static func waitWithTimeout(process: Process, seconds: TimeInterval) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                // Spin in a background thread because Process has
                // no async wait API; the alternative is
                // terminationHandler + a continuation, which has
                // its own resume-once gotcha. Detached + sleep-poll
                // is honest about the cost.
                await withCheckedContinuation { continuation in
                    process.terminationHandler = { _ in
                        continuation.resume(returning: ())
                    }
                    if !process.isRunning {
                        // Race: process may have exited before we
                        // installed the handler.
                        process.terminationHandler = nil
                        continuation.resume(returning: ())
                    }
                }
                return false  // did not time out
            }
            group.addTask {
                // try-ok: sleep cancellation
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                if process.isRunning {
                    // **Subproc-F#1 (v0.1.7.19):** simplified
                    // escalation. Previously
                    // SIGTERM → 250ms → SIGINT → 250ms → SIGKILL.
                    // SIGINT is not an escalation past SIGTERM —
                    // any child that traps SIGTERM almost always
                    // also traps SIGINT (`sing-box` does both for
                    // graceful shutdown). The middle step wasted
                    // time on no escalation; now SIGTERM gets a
                    // longer 1s grace before SIGKILL takes over.
                    process.terminate()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)  // try-ok: sleep cancellation
                    if process.isRunning {
                        kill(process.processIdentifier, SIGKILL)
                    }
                    return true  // timed out
                }
                return false
            }
            // First-finished wins; cancel the other.
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
    }

    /// Reads `handle` to EOF on a detached task so the kernel
    /// pipe buffer drains as the child writes. Returns the
    /// accumulated bytes when the child closes its end.
    private static func readAll(_ handle: FileHandle) async -> Data {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let data = handle.readDataToEndOfFile()
                continuation.resume(returning: data)
            }
        }
    }
}
