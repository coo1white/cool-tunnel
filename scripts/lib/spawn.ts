// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/spawn.ts — typed wrapper around `Bun.spawn` for the
// subprocess patterns the maintenance scripts use:
//
//   - run a command, inherit stdio (operator sees it in real time)
//   - run a command, capture stdout (for parsing version strings, etc.)
//   - run a command, capture stdout AND stderr to a file (for the
//     xcodebuild log redirect in cut_release.ts)
//
// Replaces the bash patterns:
//
//   if ! cmd; then die "msg"; fi             → await runOrDie(...)
//   $(cmd | head -1 | awk ...)               → await captureStdout(...)
//   cmd > "$logfile" 2>&1                    → await runWithCombinedLog(...)

import { spawn, type Subprocess } from "bun";

/**
 * Options shared by every run helper.
 */
export interface SpawnOpts {
    /** Working directory for the child. Defaults to the parent's cwd. */
    cwd?: string;
    /** Environment overrides; merged on top of the parent's env. */
    env?: Record<string, string>;
}

/**
 * Run a command and stream its stdout / stderr to the parent. Returns
 * the exit code; non-zero is the caller's problem to interpret. Use
 * `runOrDie` when any non-zero should abort.
 */
export async function run(
    argv: readonly string[],
    opts: SpawnOpts = {},
): Promise<number> {
    if (argv.length === 0) {
        throw new Error("run() requires at least the executable");
    }
    const proc: Subprocess = spawn({
        cmd: argv as string[],
        cwd: opts.cwd,
        env: opts.env ? { ...process.env, ...opts.env } : undefined,
        stdout: "inherit",
        stderr: "inherit",
        stdin: "ignore",
    });
    return await proc.exited;
}

/**
 * Run a command and abort the process on a non-zero exit. The error
 * message names the command and exit code; the child's own stderr
 * has already gone straight to the operator's terminal.
 */
export async function runOrDie(
    argv: readonly string[],
    opts: SpawnOpts & { failMessage?: string; exitCode?: number } = {},
): Promise<void> {
    const code = await run(argv, opts);
    if (code !== 0) {
        const { die } = await import("./log.ts");
        const message =
            opts.failMessage ??
            `command failed (exit ${code}): ${argv.join(" ")}`;
        die(message, opts.exitCode ?? 1);
    }
}

/**
 * Run a command and capture its stdout as a string. Stderr is still
 * streamed to the parent so the operator sees diagnostics. Throws on
 * non-zero exit so the caller doesn't accidentally parse an error
 * page.
 */
export async function captureStdout(
    argv: readonly string[],
    opts: SpawnOpts = {},
): Promise<string> {
    if (argv.length === 0) {
        throw new Error("captureStdout() requires at least the executable");
    }
    const proc = spawn({
        cmd: argv as string[],
        cwd: opts.cwd,
        env: opts.env ? { ...process.env, ...opts.env } : undefined,
        stdout: "pipe",
        stderr: "inherit",
        stdin: "ignore",
    });
    const [stdoutText, code] = await Promise.all([
        new Response(proc.stdout).text(),
        proc.exited,
    ]);
    if (code !== 0) {
        throw new Error(
            `command failed (exit ${code}): ${argv.join(" ")}`,
        );
    }
    return stdoutText;
}

/**
 * Run a command, redirecting both stdout AND stderr to the given
 * file path (truncates first). Matches the bash idiom
 * `cmd > "$logfile" 2>&1` that the long-running xcodebuild step
 * uses to keep the operator's terminal clean while still
 * preserving the full build log.
 */
export async function runWithCombinedLog(
    argv: readonly string[],
    logPath: string,
    opts: SpawnOpts = {},
): Promise<number> {
    if (argv.length === 0) {
        throw new Error("runWithCombinedLog() requires at least the executable");
    }
    const proc = spawn({
        cmd: argv as string[],
        cwd: opts.cwd,
        env: opts.env ? { ...process.env, ...opts.env } : undefined,
        stdout: "pipe",
        stderr: "pipe",
        stdin: "ignore",
    });
    // Bun's `file().writer()` is the streaming-write surface — we
    // pipe both streams into the same file so the order roughly
    // matches what tail -f would show.
    const logFile = Bun.file(logPath).writer();
    const drain = async (stream: ReadableStream<Uint8Array>): Promise<void> => {
        for await (const chunk of stream) {
            logFile.write(chunk);
        }
    };
    await Promise.all([drain(proc.stdout), drain(proc.stderr)]);
    const code = await proc.exited;
    await logFile.end();
    return code;
}
