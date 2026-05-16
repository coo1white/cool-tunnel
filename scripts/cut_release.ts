#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/cut_release.ts — TypeScript+Bun port of cut_release.sh.
//
// **Synthetic CI Gate** (originally v2.0.18-pre). Cool Tunnel ships
// without a paid Apple Developer account, which means no Xcode Cloud,
// no notarisation, no automated CI. This script substitutes for all
// three: every check the project would otherwise gate behind a cloud
// build runs here, locally, before a release artefact is allowed to
// leave the working tree.
//
// Stages, in order (fast pre-flight first so a wrong MARKETING_VERSION
// aborts before a 60-second cargo test does):
//
//   PRE-FLIGHT
//     1. core/Cargo.toml `version = "<X>"` matches argv[1].
//     2. COOL-TUNNEL.xcodeproj's MARKETING_VERSION matches argv[1].
//        Both Debug and Release configurations must agree.
//     3. Bundled `naive` matches the committed pin (fetch_naive.ts).
//        Drift here is a release blocker — re-pinning is an explicit,
//        audited operation.
//     4. scripts/audit.sh --strict — cargo fmt / clippy / test, swift
//        format lint, xcodebuild test, naive arch guard, schema sync.
//
//   BUILD
//     5. cargo clean inside core/.
//     6. cargo update -p cool-tunnel-core (refreshes Cargo.lock).
//     7. xcodebuild Release. Output captured to dist/build-${V}.log.
//     8. Smoke checks: bundled cool-tunnel-core --version matches V;
//        bundled naive sha256 matches naive.upstream.json.
//
//   PRE-PACKAGE
//     8b. scripts/security_check.sh against the built .app — secret
//         scan, code-sign on every embedded Mach-O, NaiveProxy SHA
//         pin cross-check, Info.plist version assertion.
//
//   PACKAGE
//     9. scripts/package_release.sh emits .dmg / .pkg / .zip /
//        .sha256 manifest into dist/.
//
// Usage:
//   bun scripts/cut_release.ts 2.0.53
//
// Exit codes (preserved from the legacy shell script for muscle memory):
//   0  success
//   1  bad arguments / version mismatch (pre-flight 1, 2)
//   2  fetch_naive failed (pre-flight 3)
//   3  cargo clean failed (build 5)
//   4  Release build / smoke check failed (build 7, 8)
//   5  package_release failed (package 9)
//   6  audit suite failed (pre-flight 4)
//   7  security_check failed (pre-package 8b)

import { readdir, mkdir, stat } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";

import { die, info, step, warn } from "./lib/log.ts";
import { captureStdout, run, runWithCombinedLog } from "./lib/spawn.ts";
import { repoRoot } from "./lib/paths.ts";

const REPO_ROOT = repoRoot(import.meta.url);

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

/**
 * Parse the single positional `<version>` argument. Pure: returns
 * a discriminated result instead of exiting, so the dispatch and
 * error path live at the call site (and the test suite can exercise
 * the parser without spawning a subprocess).
 */
export function parseVersionArg(
    argv: readonly string[],
): { ok: true; version: string } | { ok: false; reason: string } {
    const version = argv[0];
    if (version === undefined || version === "" || version.startsWith("--")) {
        return {
            ok: false,
            reason:
                "usage: cut_release.ts <version>\n  e.g. cut_release.ts 2.0.53",
        };
    }
    return { ok: true, version };
}

function parsedVersionOrExit(argv: readonly string[]): string {
    const result = parseVersionArg(argv);
    if (!result.ok) {
        process.stderr.write(`${result.reason}\n`);
        process.exit(1);
    }
    return result.version;
}

// **Test-friendly main-guard:** the dispatch runs only when this
// file is the process entry point, not when it's imported by a
// test or another script. Without the guard, `bun test` would
// invoke `parsedVersionOrExit(process.argv.slice(2))` at module-
// import time, find Bun's test-runner argv, and `process.exit(1)`
// before any test could run.
const IS_ENTRY = import.meta.main;
const VERSION = IS_ENTRY ? parsedVersionOrExit(process.argv.slice(2)) : "";

// ---------------------------------------------------------------------------
// PRE-FLIGHT 1: core/Cargo.toml version sync
// ---------------------------------------------------------------------------

async function preflightCargoVersion(): Promise<void> {
    const cargoToml = join(REPO_ROOT, "core", "Cargo.toml");
    const text = await Bun.file(cargoToml).text();
    // Match `version = "X.Y.Z"` at line start (the package version,
    // not a dependency's version field deeper in the file).
    const match = text.match(/^version\s*=\s*"([^"]+)"/m);
    if (!match) {
        die(`could not parse version field from ${cargoToml}`, 1);
    }
    const cargoVersion = match[1];
    if (cargoVersion !== VERSION) {
        die(
            `core/Cargo.toml is '${cargoVersion}' but you requested '${VERSION}'. Bump core/Cargo.toml first.`,
            1,
        );
    }
    step(`Cargo.toml version: ${cargoVersion} ✓`);
}

// ---------------------------------------------------------------------------
// PRE-FLIGHT 2: Xcode MARKETING_VERSION sync (Debug + Release)
// ---------------------------------------------------------------------------

async function preflightMarketingVersion(): Promise<void> {
    const pbxproj = join(REPO_ROOT, "COOL-TUNNEL.xcodeproj", "project.pbxproj");
    const text = await Bun.file(pbxproj).text();
    // Match every `MARKETING_VERSION = X.Y.Z;` occurrence.
    const versions = [...text.matchAll(/MARKETING_VERSION\s*=\s*([^;\s]+)/g)].map(
        (m) => m[1],
    );
    if (versions.length === 0) {
        die(`could not find any MARKETING_VERSION lines in ${pbxproj}`, 1);
    }
    let mismatch = false;
    for (const v of versions) {
        if (v !== VERSION) {
            warn(`Xcode MARKETING_VERSION '${v}' != requested '${VERSION}'`);
            mismatch = true;
        }
    }
    if (mismatch) {
        die(
            `Xcode MARKETING_VERSION is out of sync. Open COOL-TUNNEL.xcodeproj → COOL-TUNNEL target → General → Identity → Version, set to ${VERSION}, then re-run.`,
            1,
        );
    }
    step(`Xcode MARKETING_VERSION: ${VERSION} ✓ (all configurations agree)`);
}

// ---------------------------------------------------------------------------
// PRE-FLIGHT 3: bundled naive matches the committed pin
// ---------------------------------------------------------------------------

async function preflightNaivePin(): Promise<void> {
    step(`Verifying bundled naive matches the committed upstream pin…`);
    const code = await run(["bun", join(REPO_ROOT, "scripts", "fetch_naive.ts")], {
        cwd: REPO_ROOT,
    });
    if (code !== 0) {
        die(
            `fetch_naive pin verification failed — refusing to cut a release whose bundled naive does not match naive.upstream.json. Roll the pin explicitly with: bun scripts/fetch_naive.ts --repin`,
            2,
        );
    }
}

// ---------------------------------------------------------------------------
// PRE-FLIGHT 4: audit suite (--strict)
// ---------------------------------------------------------------------------

async function preflightAudit(): Promise<void> {
    step(
        `Running scripts/audit.sh --strict (cargo fmt/clippy/test, swift fmt lint, xcodebuild test, naive arch, schema)…`,
    );
    const code = await run(
        ["bash", join(REPO_ROOT, "scripts", "audit.sh"), "--strict"],
        { cwd: REPO_ROOT },
    );
    if (code !== 0) {
        die(
            `audit suite failed — see output above; aborting before any artefact is built`,
            6,
        );
    }
}

// ---------------------------------------------------------------------------
// BUILD 5–8
// ---------------------------------------------------------------------------

async function buildCargoClean(): Promise<void> {
    step(`Cleaning cargo target/ so cool-tunnel-core is rebuilt fresh…`);
    const code = await run(["cargo", "clean"], { cwd: join(REPO_ROOT, "core") });
    if (code !== 0) {
        die(`cargo clean failed`, 3);
    }
}

async function buildCargoUpdate(): Promise<void> {
    step(`Refreshing Cargo.lock for cool-tunnel-core ${VERSION}…`);
    // Capture stdout so we don't pollute the operator's terminal with
    // the "Locking N packages" boilerplate when nothing actually
    // changed. Errors from cargo go to stderr and stay visible.
    await captureStdout(["cargo", "update", "-p", "cool-tunnel-core"], {
        cwd: join(REPO_ROOT, "core"),
    });
}

async function buildXcodeRelease(): Promise<string> {
    step(`Building Cool Tunnel ${VERSION} (Release, universal arm64+x86_64)…`);
    // **v2.0.22 (round-4 fallout):** explicit `ARCHS` +
    // `ONLY_ACTIVE_ARCH=NO` so the .app's main Mach-O is universal,
    // matching the bundled engine + naive binaries which are
    // already universal via `lipo`.
    const distDir = join(REPO_ROOT, "dist");
    await mkdir(distDir, { recursive: true });
    const logPath = join(distDir, `build-${VERSION}.log`);
    const code = await runWithCombinedLog(
        [
            "xcodebuild",
            "-project",
            join(REPO_ROOT, "COOL-TUNNEL.xcodeproj"),
            "-scheme",
            "COOL-TUNNEL",
            "-configuration",
            "Release",
            "-destination",
            "platform=macOS",
            "ARCHS=arm64 x86_64",
            "ONLY_ACTIVE_ARCH=NO",
            "build",
        ],
        logPath,
        { cwd: REPO_ROOT },
    );
    if (code !== 0) {
        // Tail the build log so the operator sees the failing chunk
        // without having to open the file manually.
        try {
            const log = await Bun.file(logPath).text();
            const tail = log.split("\n").slice(-50).join("\n");
            process.stderr.write(`${tail}\n`);
        } catch {
            // best-effort; the die message points at the log path
        }
        die(`xcodebuild failed — see ${logPath}`, 4);
    }

    // Locate the freshly-built .app. Xcode DerivedData paths are
    // constrained (scheme name + fixed-alphabet hash, no spaces).
    // Pick the most-recently-modified COOL-TUNNEL-* directory.
    //
    // **NB:** uses `node:fs/promises stat` rather than
    // `Bun.file(path).stat()` because the latter is a file-only
    // surface — it returns false for directory existence and
    // throws on .stat() against a directory. Both DerivedData
    // entries AND the .app bundle are directories.
    const ddRoot = join(homedir(), "Library", "Developer", "Xcode", "DerivedData");
    let candidates: { path: string; mtimeMs: number }[];
    try {
        const entries = await readdir(ddRoot);
        const matched = entries.filter((e) => e.startsWith("COOL-TUNNEL-"));
        candidates = await Promise.all(
            matched.map(async (e) => {
                const full = join(ddRoot, e);
                const s = await stat(full);
                return { path: full, mtimeMs: s.mtimeMs };
            }),
        );
    } catch {
        die(
            `could not list DerivedData at ${ddRoot} — ensure Xcode has built this project at least once`,
            4,
        );
    }
    if (candidates.length === 0) {
        die(`no COOL-TUNNEL-* directory found under ${ddRoot}`, 4);
    }
    candidates.sort((a, b) => b.mtimeMs - a.mtimeMs);
    const dd = candidates[0]!.path;
    const app = join(dd, "Build", "Products", "Release", "Cool Tunnel.app");
    try {
        const s = await stat(app);
        if (!s.isDirectory()) {
            die(`expected .app bundle at ${app} but it's not a directory`, 4);
        }
    } catch {
        die(`expected .app at ${app} but it doesn't exist`, 4);
    }
    return app;
}

async function smokeCheckBundledBinaries(app: string): Promise<void> {
    // Smoke 1: bundled cool-tunnel-core --version matches expected.
    const corePath = join(app, "Contents", "Resources", "cool-tunnel-core");
    const versionLine = (await captureStdout([corePath, "--version"]))
        .split("\n")[0]
        ?.trim();
    if (!versionLine) {
        die(`bundled cool-tunnel-core produced no --version output`, 4);
    }
    const tokens = versionLine.split(/\s+/);
    const bundledVersion = tokens[tokens.length - 1];
    if (bundledVersion !== VERSION) {
        die(
            `freshly-built bundled cool-tunnel-core self-reports '${bundledVersion}', expected '${VERSION}'`,
            4,
        );
    }
    step(`Bundled cool-tunnel-core: ${bundledVersion} ✓`);

    // Smoke 2: bundled naive sha matches the committed pin.
    const manifestPath = join(app, "Contents", "Resources", "naive.upstream.json");
    const manifest = (await Bun.file(manifestPath).json()) as {
        merged_universal_sha256?: string;
    };
    const expected = manifest.merged_universal_sha256;
    if (!expected) {
        die(
            `bundled naive.upstream.json has no merged_universal_sha256 field`,
            4,
        );
    }
    const naivePath = join(app, "Contents", "Resources", "naive");
    const shasum = await captureStdout(["shasum", "-a", "256", naivePath]);
    const actual = shasum.split(/\s+/)[0];
    if (actual !== expected) {
        die(
            `bundled naive sha256 (${actual}) does not match naive.upstream.json (${expected})`,
            4,
        );
    }
    step(`Bundled naive verified against upstream pin ✓`);
}

// ---------------------------------------------------------------------------
// PRE-PACKAGE security audit
// ---------------------------------------------------------------------------

async function securityCheck(app: string): Promise<void> {
    step(`Running scripts/security_check.sh on the freshly-built .app…`);
    const code = await run(
        ["bash", join(REPO_ROOT, "scripts", "security_check.sh"), app],
        {
            cwd: REPO_ROOT,
            env: { EXPECTED_VERSION: VERSION },
        },
    );
    if (code !== 0) {
        die(
            `security_check.sh failed — see output above; aborting before packaging`,
            7,
        );
    }
}

// ---------------------------------------------------------------------------
// PACKAGE 9
// ---------------------------------------------------------------------------

async function packageRelease(app: string): Promise<void> {
    step(`Packaging release artefacts…`);
    const code = await run(
        ["bash", join(REPO_ROOT, "scripts", "package_release.sh"), VERSION, app],
        { cwd: REPO_ROOT },
    );
    if (code !== 0) {
        die(`package_release.sh failed`, 5);
    }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
    await mkdir(join(REPO_ROOT, "dist"), { recursive: true });

    await preflightCargoVersion();
    await preflightMarketingVersion();
    await preflightNaivePin();
    await preflightAudit();

    await buildCargoClean();
    await buildCargoUpdate();
    const app = await buildXcodeRelease();
    await smokeCheckBundledBinaries(app);

    await securityCheck(app);
    await packageRelease(app);

    info("");
    step(`Release ${VERSION} ready in ${join(REPO_ROOT, "dist")}/`);
    step(`Synthetic CI gate: ALL CHECKS PASSED`);
    step(
        `Next: gh release create v${VERSION} … (the package script printed the canonical command above)`,
    );
}

// Same main-guard as the VERSION assignment above — only kick off
// the pipeline when this file is the entry point.
if (IS_ENTRY) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`cut_release: ${caught.message}`);
        } else {
            die(`cut_release: unknown failure: ${String(caught)}`);
        }
    });
}

