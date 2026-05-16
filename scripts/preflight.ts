#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/preflight.ts — TypeScript+Bun port of preflight.sh.
//
// Runs the same lint / test floor that CI enforces — locally, and as
// fast as the local machine permits. Mirrors `.github/workflows/ci.yml`:
// every check below has a CI counterpart and the flags match
// (`--locked`, `--strict`, `xcrun swift-format`). If everything passes
// here, the corresponding CI step should pass — modulo runner-
// environment differences (e.g. swift-format version drift between
// the local Xcode and the macos-14 runner image).
//
// Invoked by:
//   - bin/ct preflight (and bin/ct doctor) — the brew-style maintenance
//     wrapper that contributors hit before opening a PR.
//   - contributors directly — same effect as the test sweep block in
//     CONTRIBUTING.md, fewer commands to type.
//
// Usage:
//   bun scripts/preflight.ts                 # full floor
//   bun scripts/preflight.ts --skip-tests    # skip cargo test (faster; CI still runs it)
//   bun scripts/preflight.ts --skip-deny     # skip cargo deny (when cargo-deny isn't installed locally)
//
// Exit codes (preserved from the legacy shell script for muscle memory):
//   0  every check passed
//   1  at least one check failed
//   2  required tooling missing (cargo / shellcheck / xcrun) or invocation error

import { Glob, which } from "bun";
import { join } from "node:path";

import { die, ok, step } from "./lib/log.ts";
import { repoRoot } from "./lib/paths.ts";
import { run } from "./lib/spawn.ts";

export interface PreflightOptions {
    readonly skipTests: boolean;
    readonly skipDeny: boolean;
}

export type ArgsParse =
    | { readonly ok: true; readonly options: PreflightOptions }
    | { readonly ok: false; readonly reason: string; readonly exitCode: number };

/**
 * Pure argv parser. `--skip-tests` and `--skip-deny` are accepted in
 * any order; `-h` / `--help` exits 0 with usage; anything else exits 2.
 * Exported so the tests can pin the flag-shape without spawning
 * cargo.
 */
export function parseArgs(argv: readonly string[]): ArgsParse {
    let skipTests = false;
    let skipDeny = false;
    for (const arg of argv) {
        switch (arg) {
            case "--skip-tests":
                skipTests = true;
                break;
            case "--skip-deny":
                skipDeny = true;
                break;
            case "-h":
            case "--help":
                return {
                    ok: false,
                    reason:
                        "usage: bun scripts/preflight.ts [--skip-tests] [--skip-deny]\n" +
                        "       run the local synthetic CI gate suite.",
                    exitCode: 0,
                };
            default:
                return {
                    ok: false,
                    reason: `preflight: unknown argument: ${arg}`,
                    exitCode: 2,
                };
        }
    }
    return { ok: true, options: { skipTests, skipDeny } };
}

interface RunCheck {
    readonly label: string;
    readonly argv: readonly string[];
    readonly cwd: string;
}

async function runCheck(check: RunCheck): Promise<boolean> {
    step(check.label);
    const code = await run(check.argv, { cwd: check.cwd });
    if (code === 0) {
        ok(check.label);
        return true;
    }
    process.stderr.write(`\x1b[1;31mfail\x1b[0m ${check.label}\n`);
    return false;
}

async function main(): Promise<void> {
    const parsed = parseArgs(process.argv.slice(2));
    if (!parsed.ok) {
        process.stderr.write(`${parsed.reason}\n`);
        process.exit(parsed.exitCode);
    }
    const { skipTests, skipDeny } = parsed.options;

    const root = repoRoot(import.meta.url);
    const coreDir = join(root, "core");

    // Preconditions — same as the bash version. If a developer
    // doesn't have cargo plus shellcheck and xcrun on PATH, they're
    // not in a position to ship a release of this product.
    if (!which("cargo")) {
        die("cargo not found in PATH (install via https://rustup.rs/)", 2);
    }
    if (!which("shellcheck")) {
        die("shellcheck not found in PATH (brew install shellcheck)", 2);
    }
    if (!which("xcrun")) {
        die("xcrun not found in PATH (install Xcode + Command Line Tools)", 2);
    }

    let failed = 0;

    // --- Rust floor -------------------------------------------------------

    if (
        !(await runCheck({
            label: "cargo fmt --all -- --check",
            argv: ["cargo", "fmt", "--all", "--", "--check"],
            cwd: coreDir,
        }))
    ) {
        failed += 1;
    }

    if (
        !(await runCheck({
            label: "cargo clippy --locked --all-targets --all-features -- -D warnings",
            argv: [
                "cargo",
                "clippy",
                "--locked",
                "--all-targets",
                "--all-features",
                "--",
                "-D",
                "warnings",
            ],
            cwd: coreDir,
        }))
    ) {
        failed += 1;
    }

    if (!skipTests) {
        if (
            !(await runCheck({
                label: "cargo test --locked --all-features",
                argv: ["cargo", "test", "--locked", "--all-features"],
                cwd: coreDir,
            }))
        ) {
            failed += 1;
        }
    } else {
        step("cargo test --locked --all-features  (skipped: --skip-tests)");
    }

    if (!skipDeny) {
        if (which("cargo-deny")) {
            if (
                !(await runCheck({
                    label: "cargo deny check",
                    argv: ["cargo", "deny", "check"],
                    cwd: coreDir,
                }))
            ) {
                failed += 1;
            }
        } else {
            process.stderr.write(
                "\x1b[1;31mfail\x1b[0m cargo deny check — cargo-deny not installed; install via 'cargo install cargo-deny' or pass --skip-deny\n",
            );
            failed += 1;
        }
    } else {
        step("cargo deny check  (skipped: --skip-deny)");
    }

    // --- Swift floor ------------------------------------------------------

    // Always invoke via `xcrun`. Bare `swift-format` exits 127 on
    // macos-14 CI runners because the toolchain bin isn't on the
    // default $PATH — gave us a silent no-op lint job for months
    // until F8a fixed it (ADR 0001).
    if (
        !(await runCheck({
            label: "xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL",
            argv: [
                "xcrun",
                "swift-format",
                "lint",
                "-r",
                "--strict",
                "--configuration",
                ".swift-format",
                "COOL-TUNNEL",
            ],
            cwd: root,
        }))
    ) {
        failed += 1;
    }

    // --- Shell floor ------------------------------------------------------

    // Expand the glob in this process so shellcheck receives explicit
    // file args. **post-v2.0.51:** `bin/ct` (brew-style maintenance
    // CLI) is also linted so a future edit can't silently regress.
    const shellFiles: string[] = [];
    const scriptsGlob = new Glob("*.sh");
    for await (const match of scriptsGlob.scan({
        cwd: join(root, "scripts"),
    })) {
        shellFiles.push(join(root, "scripts", match));
    }
    shellFiles.sort();
    shellFiles.push(join(root, "bin", "ct"));

    if (
        !(await runCheck({
            label: "shellcheck scripts/*.sh bin/ct",
            argv: ["shellcheck", ...shellFiles],
            cwd: root,
        }))
    ) {
        failed += 1;
    }

    // --- summary ----------------------------------------------------------

    process.stdout.write("\n");
    if (failed === 0) {
        step("preflight: ALL GREEN — local lint floor matches CI.");
        process.exit(0);
    }
    process.stderr.write(
        `\x1b[1;31mfail\x1b[0m preflight: ${failed} check(s) failed — CI will reject. Fix locally and re-run.\n`,
    );
    process.exit(1);
}

if (import.meta.main) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`preflight: ${caught.message}`);
        } else {
            die(`preflight: unknown failure: ${String(caught)}`);
        }
    });
}
