// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/log.ts — coloured output matching the bash conventions.
//
// The bin/ct wrapper and the legacy bash scripts both use the same
// visual idiom: `==>` blue for major steps, `Error:` red, `Warning:`
// yellow, `ok:` green, `!!!` red for hard exits with a status code.
// Mirror it exactly here so a mixed run (some Bun, some bash) reads
// as one program from the operator's terminal.
//
// Colour codes are emitted only when stdout/stderr is a TTY — when
// piped or run under CI, the output is plain bytes. Matches the
// `bin/ct` and `cut_release.sh` behaviour so the in-CI logs and the
// operator's terminal output diverge only in colour, not in shape.

const isTTY = (stream: NodeJS.WriteStream): boolean => Boolean(stream?.isTTY);

const colour = (
    stream: NodeJS.WriteStream,
    open: string,
    close: string,
    text: string,
): string => (isTTY(stream) ? `${open}${text}${close}` : text);

const BLUE_OPEN = "\x1b[1;34m";
const GREEN_OPEN = "\x1b[1;32m";
const YELLOW_OPEN = "\x1b[1;33m";
const RED_OPEN = "\x1b[1;31m";
const RESET = "\x1b[0m";

/**
 * Major-step marker. Matches `printf '\033[1;34m==>\033[0m %s\n'`
 * from the legacy bash scripts.
 */
export function step(message: string): void {
    process.stdout.write(
        `${colour(process.stdout, BLUE_OPEN, RESET, "==>")} ${message}\n`,
    );
}

/**
 * Success marker — green `ok:` prefix. Matches `bin/ct`'s ok().
 */
export function ok(message: string): void {
    process.stdout.write(
        `${colour(process.stdout, GREEN_OPEN, RESET, "ok:")} ${message}\n`,
    );
}

/**
 * Plain info line — no prefix, no colour. Matches the bash
 * `echo "info: …"` shape that fetch_naive emits.
 */
export function info(message: string): void {
    process.stdout.write(`info: ${message}\n`);
}

/**
 * Non-fatal warning. Matches `printf '\033[1;33m!!\033[0m  %s\n'`.
 * Goes to stderr so it shows in red/yellow on TTY but doesn't
 * contaminate stdout pipelines.
 */
export function warn(message: string): void {
    process.stderr.write(
        `${colour(process.stderr, YELLOW_OPEN, RESET, "Warning:")} ${message}\n`,
    );
}

/**
 * Fatal error. Matches `printf '\033[1;31m!!!\033[0m %s\n'` from
 * the legacy bash `die()` helper. Exits with the supplied code
 * (default 1, matching `die` in cut_release.sh / fetch_naive.sh).
 */
export function die(message: string, exitCode = 1): never {
    process.stderr.write(
        `${colour(process.stderr, RED_OPEN, RESET, "!!!")} ${message}\n`,
    );
    process.exit(exitCode);
}

/**
 * Print an error line WITHOUT exiting. For multi-line failures
 * where the caller wants to surface several lines before calling
 * `die`.
 */
export function err(message: string): void {
    process.stderr.write(
        `${colour(process.stderr, RED_OPEN, RESET, "error:")} ${message}\n`,
    );
}

/**
 * Non-terminal failure marker — red `!!!` prefix on stderr,
 * matching `die`'s visual idiom but WITHOUT the `process.exit`.
 * Use when the script tracks its own failure state and exits
 * separately at the end (e.g. audit.ts accumulates fail counts
 * across N checks and exits once at the summary).
 */
export function fail(message: string): void {
    process.stderr.write(
        `${colour(process.stderr, RED_OPEN, RESET, "!!!")} ${message}\n`,
    );
}
