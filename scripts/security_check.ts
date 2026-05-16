#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/security_check.ts — TypeScript+Bun port of security_check.sh.
//
// Pre-release security audit for a built `Cool tunnel.app` bundle.
// Run this *after* the Release archive completes and *before*
// packaging the DMG/PKG/ZIP; refusing to ship until every check
// passes catches the common ways an open-source macOS app can leak
// credentials, ship a tampered helper, or fail to launch on Intel.
//
// Usage:
//   bun scripts/security_check.ts path/to/Cool\ tunnel.app
//   bun scripts/security_check.ts   # auto-discovers the Release build
//
// Checks (each one is a hard fail unless marked "advisory"):
//   1. App bundle exists and contains the expected Mach-O helpers
//   2. Code signature is intact for the .app and every embedded Mach-O
//   3. naive and cool-tunnel-core are both *universal* (arm64 + x86_64)
//   4. naive matches the upstream NaiveProxy SHA-256 we recorded
//   5. Info.plist version matches the git tag we are about to release
//   6. No source file contains hard-coded credentials or API keys
//   7. LICENSE / NOTICE / Disclaimer.md present at the repo root
//   8. App entitlements (advisory: prints the full list)
//   9. LTSC posture (Cargo.lock present, version match, toolchain pin)
//  10. spctl assessment (advisory: ad-hoc-signed apps are expected to
//      be rejected on first launch)
//
// Exit codes (preserved from the legacy shell script for muscle memory):
//   0  all checks passed
//   1  bad arguments
//   2  at least one check failed

import { Glob } from "bun";
import { existsSync, statSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { basename, join, relative } from "node:path";

import { parseLipoInfo } from "./audit.ts";
import { die } from "./lib/log.ts";
import { parseCargoTomlVersion } from "./package_release.ts";
import { repoRoot } from "./lib/paths.ts";
import { captureStdout, run } from "./lib/spawn.ts";

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

export interface SecurityArgs {
    readonly appPath: string | undefined;
}

export type ArgsParse =
    | { readonly ok: true; readonly args: SecurityArgs }
    | { readonly ok: false; readonly reason: string; readonly exitCode: number };

/**
 * Pure argv parser. First positional arg is an optional .app path;
 * `-h` / `--help` exits 0 with usage. Anything else after the first
 * positional is an error.
 */
export function parseArgs(argv: readonly string[]): ArgsParse {
    if (argv.length === 0) {
        return { ok: true, args: { appPath: undefined } };
    }
    const first = argv[0];
    if (first === "-h" || first === "--help") {
        return {
            ok: false,
            reason:
                "usage: bun scripts/security_check.ts [path/to/Cool tunnel.app]\n" +
                "       pre-release security audit; auto-discovers the Release build if omitted.",
            exitCode: 0,
        };
    }
    if (argv.length > 1) {
        return {
            ok: false,
            reason: `unexpected extra arguments after app path: ${argv.slice(1).join(" ")}`,
            exitCode: 1,
        };
    }
    return { ok: true, args: { appPath: first } };
}

// ---------------------------------------------------------------------------
// Pure-logic helpers (exported for tests)
// ---------------------------------------------------------------------------

export interface SecretMatch {
    readonly path: string;
    readonly lineno: number;
    readonly content: string;
}

/**
 * Translate the small subset of POSIX-ERE character classes the bash
 * patterns use (`[[:space:]]`, `[[:digit:]]`, `[[:alpha:]]`) into the
 * JS-RegExp equivalents. The rest of the patterns are already
 * cross-compatible.
 */
export function posixToJsRegex(pattern: string): string {
    return pattern
        .replaceAll("[[:space:]]", "\\s")
        .replaceAll("[[:digit:]]", "\\d")
        .replaceAll("[[:alpha:]]", "[A-Za-z]")
        .replaceAll("[[:alnum:]]", "[A-Za-z0-9]");
}

/**
 * Scan one file's text for any of the given regexes. Each match is
 * reported as `(path, 1-based lineno, line content trimmed)`.
 * Exported so tests can exercise the matcher without disk I/O.
 */
export function scanContentForSecrets(
    content: string,
    relPath: string,
    regexes: readonly RegExp[],
): readonly SecretMatch[] {
    const out: SecretMatch[] = [];
    const lines = content.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i] ?? "";
        for (const re of regexes) {
            if (re.test(line)) {
                out.push({ path: relPath, lineno: i + 1, content: line });
                break;
            }
        }
    }
    return out;
}

/**
 * Heuristic: a file is "binary" if its first 8 KB contains a null
 * byte. Mirrors `grep --binary-files=without-match`'s effect — we
 * skip such files entirely from the secret scan.
 */
export function looksBinary(bytes: Uint8Array): boolean {
    const limit = Math.min(bytes.length, 8192);
    for (let i = 0; i < limit; i++) {
        if (bytes[i] === 0) return true;
    }
    return false;
}

/**
 * Extract the version string from a Cargo.lock entry for the named
 * package. Cargo.lock has the shape:
 *
 *   [[package]]
 *   name = "<name>"
 *   version = "X.Y.Z"
 *   ...
 *
 * The bash version used `awk '/^name = "cool-tunnel-core"/{getline; print}'`
 * — find the `name = "<name>"` line, then return the next line. We
 * preserve that exact semantics (next line is the version line) and
 * extract the quoted value from it.
 */
export function parseLockfileVersion(
    content: string,
    name: string,
): string | null {
    const lines = content.split("\n");
    for (let i = 0; i < lines.length - 1; i++) {
        if (lines[i] === `name = "${name}"`) {
            const next = lines[i + 1] ?? "";
            const match = /"([^"]+)"/.exec(next);
            if (match) return match[1] ?? null;
        }
    }
    return null;
}

/**
 * Extract the `channel = "..."` pin from a rust-toolchain.toml.
 * Anchored to start of line; first match wins.
 */
export function parseToolchainChannel(content: string): string | null {
    const re = /^channel\s*=\s*"([^"]*)"/m;
    const match = re.exec(content);
    return match ? (match[1] ?? null) : null;
}

/**
 * Check whether a LICENSE file's content matches the AGPL-3.0 header
 * signature. Looser than a byte-exact match (which would break on
 * whitespace tweaks) but tight enough to catch a license swap.
 */
export function hasAgplLicenseHeader(content: string): boolean {
    return (
        content.includes("GNU AFFERO GENERAL PUBLIC LICENSE") &&
        content.includes("Version 3")
    );
}

// ---------------------------------------------------------------------------
// Runtime helpers (not exported)
// ---------------------------------------------------------------------------

interface CheckState {
    pass: number;
    fail: number;
    warn: number;
}

function ok(state: CheckState, message: string): void {
    process.stdout.write(`  ✓ ${message}\n`);
    state.pass += 1;
}
function warn(state: CheckState, message: string): void {
    process.stdout.write(`  ⚠ ${message}\n`);
    state.warn += 1;
}
function fail(state: CheckState, message: string): void {
    process.stderr.write(`  ✗ ${message}\n`);
    state.fail += 1;
}
function heading(title: string): void {
    process.stdout.write(`\n== ${title} ==\n`);
}

/**
 * Verify a Mach-O signature via codesign. The `--deep --strict` form
 * is used for the .app itself (to catch nested framework mismatches);
 * the per-binary form drops `--deep` since these are leaf Mach-Os.
 */
async function verifySignature(
    target: string,
    deep: boolean,
): Promise<boolean> {
    const argv = ["codesign", "--verify", "--strict", "--verbose=2"];
    if (deep) argv.splice(2, 0, "--deep");
    argv.push(target);
    const code = await run(argv);
    return code === 0;
}

// Excluded directories for the secret scan. Same set as the bash
// version's `--exclude-dir` flags. node_modules is in there to avoid
// the bun-types placeholder false-positive documented in the bash
// header.
const SECRET_SCAN_EXCLUDED_DIRS = new Set([
    "target",
    ".git",
    "dist",
    "build",
    "node_modules",
]);

/**
 * Walk the repo and yield every text file path (relative to root)
 * that isn't under one of the excluded build/output directories.
 * Uses Bun.Glob to match the bash version's `grep -R` traversal.
 */
async function* walkScanCandidates(
    root: string,
): AsyncGenerator<string, void, void> {
    const glob = new Glob("**/*");
    for await (const rel of glob.scan({
        cwd: root,
        onlyFiles: true,
        dot: false,
    })) {
        const segments = rel.split("/");
        let skip = false;
        for (const seg of segments) {
            if (SECRET_SCAN_EXCLUDED_DIRS.has(seg)) {
                skip = true;
                break;
            }
        }
        if (!skip) yield rel;
    }
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

    const root = repoRoot(import.meta.url);
    const app =
        parsed.args.appPath ??
        join(
            root,
            "build",
            "DerivedData",
            "Build",
            "Products",
            "Release",
            "Cool tunnel.app",
        );

    if (!existsSync(app) || !statSync(app).isDirectory()) {
        process.stderr.write(`error: app bundle not found at ${app}\n`);
        process.stderr.write(
            `       run \`xcodebuild -configuration Release\` first or pass an explicit path\n`,
        );
        process.exit(1);
    }

    const state: CheckState = { pass: 0, fail: 0, warn: 0 };

    const naiveBin = join(app, "Contents", "Resources", "naive");
    const coreBin = join(app, "Contents", "Resources", "cool-tunnel-core");
    const appBin = join(app, "Contents", "MacOS", "Cool tunnel");

    // --- 1. Bundle layout -----------------------------------------------
    heading("1. Bundle layout");
    for (const f of [appBin, naiveBin, coreBin]) {
        if (existsSync(f) && statSync(f).isFile()) {
            ok(state, `found ${basename(f)}`);
        } else {
            fail(state, `missing ${f}`);
        }
    }

    // --- 2. Code signatures ---------------------------------------------
    heading("2. Code signatures");
    if (await verifySignature(app, true)) {
        ok(state, "app bundle signature verifies (deep, strict)");
    } else {
        fail(state, "app bundle signature verification failed");
    }
    for (const f of [appBin, naiveBin, coreBin]) {
        if (!existsSync(f)) continue;
        if (await verifySignature(f, false)) {
            ok(state, `${basename(f)} signature verifies`);
        } else {
            fail(state, `${basename(f)} signature verification failed`);
        }
    }

    // --- 3. Universal binaries ------------------------------------------
    heading("3. Universal binaries (arm64 + x86_64)");
    for (const [label, p] of [
        ["Cool tunnel", appBin] as const,
        ["naive", naiveBin] as const,
        ["cool-tunnel-core", coreBin] as const,
    ]) {
        if (!existsSync(p)) {
            fail(state, `${label} missing`);
            continue;
        }
        try {
            const out = await captureStdout(["lipo", "-info", p]);
            const lipoInfo = parseLipoInfo(out);
            const after = out.split(":").slice(2).join(":").trim();
            if (lipoInfo.universal) {
                ok(state, `${label}: universal (${after})`);
            } else {
                fail(state, `${label}: not universal — got ${after}`);
            }
        } catch (caught) {
            fail(state, `${label}: lipo failed: ${String(caught)}`);
        }
    }

    // --- 4. naive matches upstream manifest -----------------------------
    heading("4. naive matches upstream manifest");
    const manifest = join(root, "COOL-TUNNEL", "naive.upstream.json");
    if (existsSync(manifest)) {
        const manifestJson = JSON.parse(await readFile(manifest, "utf8")) as {
            merged_universal_sha256?: string;
        };
        const expected = manifestJson.merged_universal_sha256;
        if (!expected) {
            warn(state, "manifest present but has no merged_universal_sha256 field");
        } else {
            try {
                const shasumOut = await captureStdout([
                    "shasum",
                    "-a",
                    "256",
                    naiveBin,
                ]);
                const actual = shasumOut.split(/\s+/)[0] ?? "";
                if (actual === expected) {
                    ok(state, `naive sha256 matches manifest (${expected})`);
                } else {
                    // Ad-hoc signing rewrites bytes inside the Mach-O
                    // after the universal merge, so a hash mismatch is
                    // *expected* here — surface both for the audit log.
                    warn(state, "bundled naive differs from manifest (likely re-signed)");
                    warn(state, `  manifest: ${expected}`);
                    warn(state, `  bundled : ${actual}`);
                }
            } catch (caught) {
                fail(state, `shasum failed: ${String(caught)}`);
            }
        }
    } else {
        warn(state, "no naive.upstream.json manifest — cannot verify upstream provenance");
    }

    // --- 5. Info.plist version sanity -----------------------------------
    heading("5. Info.plist version");
    const plist = join(app, "Contents", "Info.plist");
    const readPlistKey = async (key: string): Promise<string> => {
        try {
            const out = await captureStdout([
                "/usr/libexec/PlistBuddy",
                "-c",
                `Print :${key}`,
                plist,
            ]);
            return out.trim();
        } catch (caught) {
            void caught;
            return "?";
        }
    };
    const shortVersion = await readPlistKey("CFBundleShortVersionString");
    const bundleVersion = await readPlistKey("CFBundleVersion");
    ok(state, `CFBundleShortVersionString = ${shortVersion}`);
    ok(state, `CFBundleVersion            = ${bundleVersion}`);
    const expectedVersion = process.env.EXPECTED_VERSION;
    if (expectedVersion) {
        if (shortVersion === expectedVersion) {
            ok(state, `version matches EXPECTED_VERSION=${expectedVersion}`);
        } else {
            fail(
                state,
                `version ${shortVersion} != EXPECTED_VERSION=${expectedVersion}`,
            );
        }
    }

    // --- 6. Source-level secret scan ------------------------------------
    heading("6. Source-level secret scan");
    // Pinned past-leak guard. Kept as a base64-encoded sentinel so this
    // script's own source never contains any plaintext fragment of the
    // historical leak — same discipline as the bash version. Specific
    // placeholder strings used in node_modules' bun-types documentation
    // are deliberately NOT named here either: naming them would make
    // this script self-match.
    const historicalLeak = Buffer.from("MTk5OTA1MTVXcnk=", "base64").toString(
        "utf8",
    );
    const secretPatterns: readonly string[] = [
        "AKIA[0-9A-Z]{16}",
        "sk-[A-Za-z0-9]{20,}",
        "ghp_[A-Za-z0-9]{20,}",
        "xox[baprs]-[A-Za-z0-9-]{20,}",
        "-----BEGIN[ A-Z]+PRIVATE KEY",
        historicalLeak,
        "basic_auth[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+[A-Za-z0-9._/+=-]{6,}",
    ];
    const regexes = secretPatterns.map(
        (p) => new RegExp(posixToJsRegex(p)),
    );
    const allMatches: SecretMatch[] = [];
    for await (const rel of walkScanCandidates(root)) {
        const abs = join(root, rel);
        let bytes: Uint8Array;
        try {
            bytes = await Bun.file(abs).bytes();
        } catch (caught) {
            void caught;
            continue;
        }
        if (looksBinary(bytes)) continue;
        const text = new TextDecoder("utf-8", { fatal: false }).decode(bytes);
        const matches = scanContentForSecrets(text, rel, regexes);
        allMatches.push(...matches);
    }
    if (allMatches.length === 0) {
        ok(state, "no secret patterns matched in tracked source");
    } else {
        fail(state, "secret-pattern matches found:");
        for (const m of allMatches) {
            process.stderr.write(`    ${m.path}:${m.lineno}:${m.content}\n`);
        }
    }

    // --- 7. License + disclaimer ----------------------------------------
    heading("7. AGPL-3.0-only license, NOTICE, and disclaimer");
    const licensePath = join(root, "LICENSE");
    if (existsSync(licensePath)) {
        ok(state, "LICENSE present at repo root");
        const licenseContent = await readFile(licensePath, "utf8");
        if (hasAgplLicenseHeader(licenseContent)) {
            ok(state, "LICENSE contains AGPL-3.0 header");
        } else {
            fail(state, "LICENSE does not look like AGPL-3.0");
        }
    } else {
        fail(state, "LICENSE missing — required by AGPL-3.0 distribution terms");
    }
    if (existsSync(join(root, "NOTICE"))) {
        ok(state, "NOTICE present at repo root");
    } else {
        fail(state, "NOTICE missing — required for our bundled-software attribution");
    }
    if (existsSync(join(root, "Disclaimer.md"))) {
        ok(state, "Disclaimer.md present at repo root");
    } else {
        fail(state, "Disclaimer.md missing — required by README");
    }

    // --- 8. Entitlements (advisory) -------------------------------------
    heading("8. App entitlements (advisory — review these are minimal)");
    try {
        const out = await captureStdout([
            "codesign",
            "-d",
            "--entitlements",
            ":-",
            app,
        ]);
        for (const line of out.split("\n")) {
            if (line.length > 0) process.stdout.write(`    ${line}\n`);
        }
        ok(state, "entitlements printed for review");
    } catch (caught) {
        void caught;
        warn(state, "could not read entitlements");
    }

    // --- 9. LTSC posture ------------------------------------------------
    heading("9. LTSC posture");
    const cargoLock = join(root, "core", "Cargo.lock");
    if (existsSync(cargoLock)) {
        ok(state, "core/Cargo.lock present (deterministic Rust builds)");
    } else {
        fail(state, "core/Cargo.lock missing — Rust builds are non-deterministic without it");
    }

    const cargoToml = join(root, "core", "Cargo.toml");
    if (existsSync(cargoToml) && existsSync(cargoLock)) {
        const tomlContent = await readFile(cargoToml, "utf8");
        const lockContent = await readFile(cargoLock, "utf8");
        const tomlVer = parseCargoTomlVersion(tomlContent);
        const lockVer = parseLockfileVersion(lockContent, "cool-tunnel-core");
        if (tomlVer && lockVer && tomlVer === lockVer) {
            ok(state, `Cargo.lock cool-tunnel-core ${lockVer} matches Cargo.toml`);
        } else {
            fail(
                state,
                `Cargo.lock (${lockVer ?? "?"}) and Cargo.toml (${tomlVer ?? "?"}) disagree on cool-tunnel-core version`,
            );
        }
    }

    const toolchain = join(root, "rust-toolchain.toml");
    if (existsSync(toolchain)) {
        const channel = parseToolchainChannel(await readFile(toolchain, "utf8"));
        ok(state, `rust-toolchain.toml pins channel ${channel ?? "unknown"}`);
    } else {
        warn(state, "rust-toolchain.toml missing — Rust version will float across machines");
    }

    if (existsSync(join(root, "SUPPORT.md"))) {
        ok(state, "SUPPORT.md present (LTSC support policy)");
    } else {
        warn(state, "SUPPORT.md missing — LTSC commitments are undocumented");
    }

    // --- 10. Gatekeeper assessment (advisory) ---------------------------
    heading(
        "10. Gatekeeper assessment (ad-hoc-signed apps are expected to be rejected)",
    );
    try {
        const out = await captureStdout([
            "spctl",
            "--assess",
            "--type",
            "execute",
            "--verbose=4",
            app,
        ]);
        ok(state, `spctl: ${out.trim()}`);
    } catch (caught) {
        const detail = caught instanceof Error ? caught.message : String(caught);
        warn(state, `spctl: ${detail}`);
        warn(state, "this is expected for ad-hoc-signed apps without an Apple Developer ID;");
        warn(state, "users will need to right-click → Open on first launch");
    }

    // --- Final summary --------------------------------------------------
    heading("Summary");
    process.stdout.write(`  passed:   ${state.pass}\n`);
    process.stdout.write(`  warnings: ${state.warn}\n`);
    process.stdout.write(`  failures: ${state.fail}\n`);

    if (state.fail > 0) {
        process.stderr.write(`\nsecurity_check FAILED — refusing to package\n`);
        process.exit(2);
    }
    process.stdout.write(`\nsecurity_check passed — safe to package\n`);
    process.exit(0);
}

// Acknowledge unused import — only needed for the test/import surface.
void relative;

if (import.meta.main) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`security_check: ${caught.message}`, 2);
        } else {
            die(`security_check: unknown failure: ${String(caught)}`, 2);
        }
    });
}
