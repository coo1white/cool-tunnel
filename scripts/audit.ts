#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/audit.ts — TypeScript+Bun port of audit.sh.
//
// **Synthetic CI Gate, audit subset (v2.0.18-pre).**
//
// Runs every static check the project has wired up. Designed to be
// called both standalone (`bash scripts/audit.sh`) and from
// `cut_release.ts` as a release-cut precondition. Without a paid
// Apple Developer account the project has no cloud CI; this script
// IS our CI and `cut_release.ts` refuses to ship a build that
// didn't pass it.
//
// What runs, in order (fast checks first so a failure aborts before
// a slow check has a chance to run):
//
//   1. cargo fmt --check                — formatter drift
//   2. cargo clippy -D warnings         — lint cleanliness
//   3. cargo test --all-features        — unit + integration tests
//   3b. cargo deny check                — license/ban/duplicate policy
//   4. swift format lint --strict       — Swift formatter drift
//   5. xcodebuild test (Debug)          — Swift XCTest suites
//   6. naive arch guard                 — bundled binary is universal
//   7. schema sync probe                — engine + Swift Codable
//                                          shapes still match a known
//                                          good wire fixture
//   8. try? ratchet                     — M1 robustness-review followup
//
// Anything that fails sets `status = 1` (we keep going so the operator
// sees ALL failures in one pass) and the script exits with that code
// at the end.
//
// Steps that require optional tools (clippy, swift-format,
// xcodebuild) skip with a warning if the tool is missing — useful on
// minimal CI runners or when iterating locally without Xcode open.
// A `--strict` flag turns those skips into hard failures, used by
// `cut_release.ts` so a release cut can never silently ship past a
// missing tool.
//
// Exit codes:
//   0  every check passed (or skipped non-strict)
//   1  one or more checks failed
//   2  --strict and a required tool was missing, or invocation error

import { spawn, Glob, which } from "bun";
import { readFile } from "node:fs/promises";
import { existsSync, statSync } from "node:fs";
import { join } from "node:path";

import { die, step, warn } from "./lib/log.ts";
import { repoRoot } from "./lib/paths.ts";
import { run } from "./lib/spawn.ts";

export interface AuditOptions {
    readonly strict: boolean;
}

export type ArgsParse =
    | { readonly ok: true; readonly options: AuditOptions }
    | { readonly ok: false; readonly reason: string; readonly exitCode: number };

/**
 * Pure argv parser. Accepts `--strict`; `-h` / `--help` exits 0 with
 * usage; anything else exits 2.
 */
export function parseArgs(argv: readonly string[]): ArgsParse {
    let strict = false;
    for (const arg of argv) {
        switch (arg) {
            case "--strict":
                strict = true;
                break;
            case "-h":
            case "--help":
                return {
                    ok: false,
                    reason:
                        "usage: bun scripts/audit.ts [--strict]\n" +
                        "       run every static check the project has wired up.",
                    exitCode: 0,
                };
            default:
                return {
                    ok: false,
                    reason: `unknown arg: ${arg}`,
                    exitCode: 2,
                };
        }
    }
    return { ok: true, options: { strict } };
}

export type XcodebuildVerdict = "no-test-action" | "failed" | "ok";

/**
 * Classify combined stdout+stderr of `xcodebuild test`. The bash
 * version greps for three distinct shapes:
 *   - "is not currently configured for the test action" → scheme has
 *     no XCTest target wired up; treated as a documented SKIP
 *   - "** TEST FAILED **" / "Testing failed" / line starts with
 *     "xcodebuild: error" → real failure
 *   - anything else → success (or warnings we don't gate on)
 * Order matters: the no-test-action probe wins over the failure
 * probe so a scheme without a test action doesn't get mis-classified.
 */
export function classifyXcodebuildOutput(output: string): XcodebuildVerdict {
    if (output.includes("is not currently configured for the test action")) {
        return "no-test-action";
    }
    if (
        output.includes("** TEST FAILED **") ||
        output.includes("Testing failed") ||
        /(^|\n)xcodebuild: error/.test(output)
    ) {
        return "failed";
    }
    return "ok";
}

/**
 * Parse `lipo -info <path>` output for the architectures it lists.
 * The line looks like `Architectures in the fat file: <path> are: arm64 x86_64`
 * or, for a thin binary, `Non-fat file: <path> is architecture: arm64`.
 * Either shape is matched by tokenising on whitespace and returning
 * the known-arch words. The bash version's universal check (`*x86_64*
 * && *arm64*`) is preserved as `.universal`.
 */
export function parseLipoInfo(output: string): {
    readonly archs: readonly string[];
    readonly universal: boolean;
} {
    const known = new Set([
        "arm64",
        "arm64e",
        "x86_64",
        "x86_64h",
        "i386",
        "ppc",
        "ppc64",
    ]);
    const archs = output
        .split(/\s+/)
        .map((tok) => tok.trim())
        .filter((tok) => known.has(tok));
    const set = new Set(archs);
    return {
        archs,
        universal: set.has("arm64") && set.has("x86_64"),
    };
}

/**
 * Check that every named field appears in both the JSON fixture
 * (as `"field"`) and at least one Swift source under the decoder dir
 * (as `let field`). Returns the list of mismatch messages — empty
 * means "all fields present". Pure over its inputs so tests can pass
 * synthetic file contents.
 */
export function checkSchemaFields(
    fixtureJson: string,
    swiftSources: ReadonlyMap<string, string>,
    fields: readonly string[],
): readonly string[] {
    const missing: string[] = [];
    for (const field of fields) {
        if (!fixtureJson.includes(`"${field}"`)) {
            missing.push(`fixture missing field: ${field}`);
        }
        const declRe = new RegExp(`\\blet\\s+${field}\\b`);
        let foundInSwift = false;
        for (const src of swiftSources.values()) {
            if (declRe.test(src)) {
                foundInSwift = true;
                break;
            }
        }
        if (!foundInSwift) {
            missing.push(`Swift decoder missing field: ${field}`);
        }
    }
    return missing;
}

// ---------------------------------------------------------------------------
// Runtime helpers (not exported)
// ---------------------------------------------------------------------------

/**
 * Spawn a child and return its combined stdout+stderr as a string,
 * plus exit code. Used for `xcodebuild test` (we tail the last 50
 * lines and grep the full text for verdict classification).
 */
async function captureCombined(
    argv: readonly string[],
    opts: { cwd?: string } = {},
): Promise<{ readonly output: string; readonly code: number }> {
    const proc = spawn({
        cmd: argv as string[],
        cwd: opts.cwd,
        stdout: "pipe",
        stderr: "pipe",
        stdin: "ignore",
    });
    const [stdoutText, stderrText, code] = await Promise.all([
        new Response(proc.stdout).text(),
        new Response(proc.stderr).text(),
        proc.exited,
    ]);
    return { output: `${stdoutText}${stderrText}`, code };
}

interface AuditState {
    status: number;
    readonly skipped: string[];
}

function failMsg(state: AuditState, message: string): void {
    process.stderr.write(`\x1b[1;31m!!!\x1b[0m ${message}\n`);
    state.status = 1;
}

/**
 * Probe for a tool on PATH. On miss, either warn-skip + record the
 * skipped name, or hard-fail with exit 2 under `--strict`. Returns
 * `true` if the tool is present.
 */
function requireOrSkip(
    cmd: string,
    label: string,
    state: AuditState,
    strict: boolean,
): boolean {
    if (which(cmd)) return true;
    if (strict) {
        process.stderr.write(
            `\x1b[1;31m!!!\x1b[0m ${label} required (--strict) but not on PATH\n`,
        );
        process.exit(2);
    }
    warn(`${label} not on PATH — skipping (re-run without --strict to allow)`);
    state.skipped.push(label);
    return false;
}

/**
 * Resolve which Swift-format invocation to use. Returns the argv
 * prefix (a string array) or null if neither variant is on PATH.
 * Tries the standalone `swift-format` first, then `swift format`
 * (Xcode 16+ subcommand of `swift`).
 */
async function resolveSwiftFormat(): Promise<readonly string[] | null> {
    if (which("swift-format")) {
        return ["swift-format"];
    }
    if (which("swift")) {
        // Probe `swift format --help`; the subcommand is silent-success
        // when present and emits "no such subcommand" on older toolchains.
        const probe = spawn({
            cmd: ["swift", "format", "--help"],
            stdout: "ignore",
            stderr: "ignore",
            stdin: "ignore",
        });
        const code = await probe.exited;
        if (code === 0) {
            return ["swift", "format"];
        }
    }
    return null;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
    const parsed = parseArgs(process.argv.slice(2));
    if (!parsed.ok) {
        process.stderr.write(`${parsed.reason}\n`);
        process.exit(parsed.exitCode);
    }
    const { strict } = parsed.options;

    const root = repoRoot(import.meta.url);
    const coreDir = join(root, "core");
    const state: AuditState = { status: 0, skipped: [] };

    // --- 1. cargo fmt -----------------------------------------------------
    step("cargo fmt --check");
    if ((await run(["cargo", "fmt", "--check"], { cwd: coreDir })) !== 0) {
        failMsg(state, "cargo fmt found drift — run 'cargo fmt' inside core/");
    }

    // --- 2. cargo clippy --------------------------------------------------
    step("cargo clippy --all-targets -- -D warnings");
    if (
        (await run(
            [
                "cargo",
                "clippy",
                "--all-targets",
                "--all-features",
                "--",
                "-D",
                "warnings",
            ],
            { cwd: coreDir },
        )) !== 0
    ) {
        failMsg(state, "cargo clippy reported issues");
    }

    // --- 3. cargo test ----------------------------------------------------
    step("cargo test --all-features");
    if (
        (await run(
            ["cargo", "test", "--all-features", "--quiet"],
            { cwd: coreDir },
        )) !== 0
    ) {
        failMsg(state, "cargo test failed");
    }

    // --- 3b. cargo deny check ---------------------------------------------
    if (requireOrSkip("cargo-deny", "cargo-deny", state, strict)) {
        step("cargo deny check");
        if (
            (await run(
                ["cargo", "deny", "check", "--hide-inclusion-graph"],
                { cwd: coreDir },
            )) !== 0
        ) {
            failMsg(
                state,
                "cargo deny check failed — license/ban/duplicate policy violation in core/Cargo.lock",
            );
        }
    }

    // --- 4. swift format lint ---------------------------------------------
    const swiftFormat = await resolveSwiftFormat();
    if (swiftFormat) {
        const label = swiftFormat.join(" ");
        step(`${label} lint --strict (recursive on COOL-TUNNEL/)`);
        const swiftFiles: string[] = [];
        const glob = new Glob("**/*.swift");
        for await (const match of glob.scan({
            cwd: join(root, "COOL-TUNNEL"),
        })) {
            swiftFiles.push(join(root, "COOL-TUNNEL", match));
        }
        swiftFiles.sort();
        if (swiftFiles.length > 0) {
            if (
                (await run(
                    [...swiftFormat, "lint", "--strict", ...swiftFiles],
                    { cwd: root },
                )) !== 0
            ) {
                failMsg(state, "swift format lint reported issues");
            }
        } else {
            warn("no .swift files found under COOL-TUNNEL/ — nothing to lint");
        }
    } else if (strict) {
        process.stderr.write(
            "\x1b[1;31m!!!\x1b[0m swift-format / swift format required (--strict) but neither is on PATH\n",
        );
        process.exit(2);
    } else {
        warn(
            "swift-format not available — skipping (install via 'brew install swift-format' or use Xcode 16+)",
        );
        state.skipped.push("swift format lint");
    }

    // --- 5. xcodebuild test -----------------------------------------------
    if (requireOrSkip("xcodebuild", "xcodebuild", state, strict)) {
        step("xcodebuild test (Debug)");
        const { output } = await captureCombined(
            [
                "xcodebuild",
                "test",
                "-project",
                join(root, "COOL-TUNNEL.xcodeproj"),
                "-scheme",
                "COOL-TUNNEL",
                "-configuration",
                "Debug",
                "-destination",
                "platform=macOS",
                "CODE_SIGNING_ALLOWED=NO",
                "-quiet",
            ],
            { cwd: root },
        );
        // Mirror bash: `echo "$XCB_OUT" | tail -50` for operator visibility.
        const lines = output.split("\n");
        const tail = lines.slice(-50).join("\n");
        process.stdout.write(`${tail}\n`);
        const verdict = classifyXcodebuildOutput(output);
        if (verdict === "no-test-action") {
            warn(
                "scheme COOL-TUNNEL has no test action (no XCTest target) — skipping",
            );
            state.skipped.push("xcodebuild test (no test target)");
        } else if (verdict === "failed") {
            failMsg(state, "xcodebuild test failed");
        }
    }

    // --- 6. naive arch guard ---------------------------------------------
    const naivePath = join(root, "COOL-TUNNEL", "naive");
    if (existsSync(naivePath) && statSync(naivePath).isFile()) {
        step(`naive arch guard: lipo on ${naivePath}`);
        const { output: lipoOut, code: lipoCode } = await captureCombined([
            "lipo",
            "-info",
            naivePath,
        ]);
        if (lipoCode !== 0) {
            failMsg(state, `lipo failed: ${lipoOut.trim()}`);
        } else {
            const parsed = parseLipoInfo(lipoOut);
            if (parsed.universal) {
                step("naive: universal (arm64 + x86_64) ✓");
            } else {
                failMsg(state, `naive is not universal: ${lipoOut.trim()}`);
            }
        }
    } else {
        warn(
            `no naive at ${naivePath} — bootstrap the pin with CT_REPIN_CONFIRM=1 scripts/fetch_naive.sh --repin`,
        );
        if (strict) {
            failMsg(state, "naive missing (--strict)");
        }
    }

    // --- 7. schema sync probe --------------------------------------------
    step("schema sync probe (subscription manifest)");
    const schemaFixture = join(
        root,
        "tests",
        "fixtures",
        "subscription_manifest_v1.json",
    );
    const decoderDir = join(root, "COOL-TUNNEL", "Core");
    if (
        existsSync(schemaFixture) &&
        existsSync(decoderDir) &&
        statSync(decoderDir).isDirectory()
    ) {
        const fixtureJson = await readFile(schemaFixture, "utf8");
        const swiftSources = new Map<string, string>();
        const glob = new Glob("**/*.swift");
        for await (const match of glob.scan({ cwd: decoderDir })) {
            const abs = join(decoderDir, match);
            swiftSources.set(match, await readFile(abs, "utf8"));
        }
        const missing = checkSchemaFields(fixtureJson, swiftSources, [
            "profiles",
            "host",
            "username",
            "password",
        ]);
        if (missing.length > 0) {
            for (const m of missing) failMsg(state, m);
        } else {
            step("schema sync probe ✓");
        }
    } else {
        warn("schema fixture or decoder dir missing — schema probe skipped");
        if (strict) {
            failMsg(state, "schema fixture / decoder dir not found (--strict)");
        }
    }

    // --- 8. try? ratchet --------------------------------------------------
    step("try? ratchet");
    if (
        (await run(["bash", join(root, "scripts", "try_question_ratchet.sh")], {
            cwd: root,
        })) !== 0
    ) {
        failMsg(state, "try? ratchet failed — see message above");
    }

    // --- Summary ----------------------------------------------------------
    process.stdout.write("\n");
    if (state.status === 0) {
        step("audit: PASS");
        if (state.skipped.length > 0) {
            warn(`non-strict skips: ${state.skipped.join(" ")}`);
        }
    } else {
        process.stderr.write(
            `\x1b[1;31m!!!\x1b[0m audit: FAIL — fix issues above and re-run\n`,
        );
    }
    process.exit(state.status);
}

if (import.meta.main) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`audit: ${caught.message}`);
        } else {
            die(`audit: unknown failure: ${String(caught)}`);
        }
    });
}
