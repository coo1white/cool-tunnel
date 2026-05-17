#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/fetch_singbox-core.ts — sing-box upstream pin enforcement.
//
// Authoritative pin enforcement for the bundled sing-box binary.
//
// The file `COOL-TUNNEL/singbox-core.upstream.json` is the **pin**:
// it records the upstream tag this repo claims to ship and the
// SHA-256 of the arm64 tarball, the x64 tarball, and the merged
// universal binary. The bundled binary at `COOL-TUNNEL/sing-box`
// MUST match the pin. Drift in either direction (binary changed,
// or upstream tag rewrote) is a supply-chain regression signal —
// this script refuses to silently absorb either.
//
// Modes:
//
//   fetch_singbox-core.ts
//       Verify-only (no network). Computes the SHA-256 of the
//       bundled `COOL-TUNNEL/sing-box` and compares it against
//       `merged_universal_sha256` in the committed manifest.
//       Fast (< 100 ms). This is what `cut_release.ts` calls.
//
//   fetch_singbox-core.ts --check-only
//       Audit mode (requires network). Re-downloads the upstream
//       tarballs at the **pinned** tag and recomputes all SHAs.
//       Reports drift in tarball SHAs (upstream tag rewrite),
//       merged-universal SHA (build-determinism break), or the
//       bundled binary (local tampering). Suitable for a daily CI
//       gate.
//
//   fetch_singbox-core.ts --repin [TAG]
//       Explicit re-pin (requires network). Resolves the tag (gh
//       latest if omitted, else the argument), downloads the
//       upstream tarballs, lipo-merges, ad-hoc-signs, and prints
//       the OLD → NEW SHA diff. Will NOT write anything to the
//       working tree unless `CT_REPIN_CONFIRM=1` is set in the
//       environment.
//
// Exit codes (preserved from the legacy shell script for muscle memory):
//   0  success
//   1  invocation / parsing error / missing dependency
//   2  download / extraction / lipo failed
//   3  pin verification failed (drop-dead supply-chain signal)
//   4  --repin requested but CT_REPIN_CONFIRM=1 not set
//
// Dependencies: bun 1.1+, curl, tar, gzip, lipo, shasum, codesign.
//   --repin also needs `gh` when no TAG argument is given.

import { mkdtemp, rm, chmod, rename } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";

import { die, err, info, ok, warn } from "./lib/log.ts";
import { captureStdout, runOrDie } from "./lib/spawn.ts";
import { repoRoot } from "./lib/paths.ts";

const REPO_ROOT = repoRoot(import.meta.url);
const DEST = join(REPO_ROOT, "COOL-TUNNEL", "sing-box");
const MANIFEST = join(REPO_ROOT, "COOL-TUNNEL", "singbox-core.upstream.json");

// ---------------------------------------------------------------------------
// Manifest helpers
// ---------------------------------------------------------------------------

interface SingboxCoreManifest {
    upstream_tag: string;
    arm64_tarball_sha256: string;
    x64_tarball_sha256: string;
    merged_universal_sha256: string;
    fetched_at?: string;
}

async function readManifest(): Promise<SingboxCoreManifest> {
    const file = Bun.file(MANIFEST);
    if (!(await file.exists())) {
        err(`${MANIFEST} not found.`);
        err(`       Run scripts/fetch_singbox-core.ts --repin to establish the initial pin.`);
        process.exit(3);
    }
    try {
        return (await file.json()) as SingboxCoreManifest;
    } catch (caught) {
        err(`manifest is not valid JSON: ${(caught as Error).message}`);
        process.exit(3);
    }
}

async function sha256OfFile(path: string): Promise<string> {
    // Use shasum to match the legacy script's output exactly — the
    // hex format and byte-for-byte ordering match `shasum -a 256`.
    // Bun.hash() would also work but introduces a needless source of
    // possible divergence in a security-critical pin path.
    const stdout = await captureStdout(["shasum", "-a", "256", path]);
    const first = stdout.split(/\s+/)[0];
    if (!first || !/^[0-9a-f]{64}$/.test(first)) {
        throw new Error(`shasum returned unexpected output: ${stdout}`);
    }
    return first;
}

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

type Mode = "verify" | "check" | "repin";

interface ParsedArgs {
    mode: Mode;
    repinTag: string;
}

function parseArgs(argv: readonly string[]): ParsedArgs {
    let mode: Mode = "verify";
    let repinTag = "";
    let i = 0;
    while (i < argv.length) {
        const arg = argv[i];
        if (arg === undefined) {
            break;
        }
        switch (arg) {
            case "--check-only":
                mode = "check";
                i++;
                break;
            case "--repin": {
                mode = "repin";
                i++;
                // Optional positional tag argument.
                const maybeTag = argv[i];
                if (maybeTag !== undefined && !maybeTag.startsWith("--")) {
                    repinTag = maybeTag;
                    i++;
                }
                break;
            }
            case "-h":
            case "--help":
                printHelp();
                process.exit(0);
            default:
                err(`unknown argument: ${arg}`);
                err(`run with --help for usage`);
                process.exit(1);
        }
    }
    return { mode, repinTag };
}

function printHelp(): void {
    process.stdout.write(`\
fetch_singbox-core.ts — bundled sing-box pin enforcement

Usage:
    bun scripts/fetch_singbox-core.ts                     # verify (default)
    bun scripts/fetch_singbox-core.ts --check-only        # audit pin against upstream
    bun scripts/fetch_singbox-core.ts --repin [TAG]       # explicit re-pin

See top-of-file comment for details and exit codes.
`);
}

// ---------------------------------------------------------------------------
// Download / build / SHA the upstream tarballs
// ---------------------------------------------------------------------------

interface UpstreamArtefacts {
    tarArm64Sha: string;
    tarX64Sha: string;
    mergedSha: string;
    mergedPath: string;
    workDir: string;
}

/**
 * Strip the leading `v` from a release tag for the asset filename.
 * Upstream tags are `vX.Y.Z`; release assets are
 * `sing-box-X.Y.Z-darwin-<arch>.tar.gz`.
 */
function tagToAssetStem(tag: string): string {
    return tag.startsWith("v") ? tag.slice(1) : tag;
}

async function downloadAndBuildUniversal(tag: string): Promise<UpstreamArtefacts> {
    const workDir = await mkdtemp(join(tmpdir(), "cool-tunnel-singbox-"));
    const stem = tagToAssetStem(tag);
    const arm64Asset = `sing-box-${stem}-darwin-arm64.tar.gz`;
    const x64Asset = `sing-box-${stem}-darwin-amd64.tar.gz`;
    const baseUrl = `https://github.com/SagerNet/sing-box/releases/download/${tag}`;

    info(`fetching ${arm64Asset}`);
    info(`fetching ${x64Asset}`);

    // -f: fail on HTTP error rather than write the error page.
    // -L: follow GitHub's redirect to the S3-backed asset URL.
    // --retry handles transient CDN flakes without hand-rolling a loop.
    await runOrDie(
        [
            "curl",
            "-fLs",
            "--retry",
            "3",
            "--retry-delay",
            "2",
            "-o",
            join(workDir, arm64Asset),
            `${baseUrl}/${arm64Asset}`,
        ],
        { failMessage: `failed to download ${arm64Asset}`, exitCode: 2 },
    );
    await runOrDie(
        [
            "curl",
            "-fLs",
            "--retry",
            "3",
            "--retry-delay",
            "2",
            "-o",
            join(workDir, x64Asset),
            `${baseUrl}/${x64Asset}`,
        ],
        { failMessage: `failed to download ${x64Asset}`, exitCode: 2 },
    );

    const tarArm64Sha = await sha256OfFile(join(workDir, arm64Asset));
    const tarX64Sha = await sha256OfFile(join(workDir, x64Asset));
    info(`arm64 tarball sha256: ${tarArm64Sha}`);
    info(`x64   tarball sha256: ${tarX64Sha}`);

    await runOrDie(["mkdir", "-p", join(workDir, "arm64"), join(workDir, "x64")]);
    // sing-box ships gzip-compressed tarballs (.tar.gz), so -z (not -J).
    // --strip-components=1 drops the leading `sing-box-X.Y.Z-darwin-<arch>/`
    // directory so the binary lands directly under arm64/ and x64/.
    await runOrDie(
        ["tar", "-xzf", join(workDir, arm64Asset), "-C", join(workDir, "arm64"), "--strip-components=1"],
        { failMessage: `tar extract failed for arm64`, exitCode: 2 },
    );
    await runOrDie(
        ["tar", "-xzf", join(workDir, x64Asset), "-C", join(workDir, "x64"), "--strip-components=1"],
        { failMessage: `tar extract failed for x64`, exitCode: 2 },
    );

    const arm64Bin = join(workDir, "arm64", "sing-box");
    const x64Bin = join(workDir, "x64", "sing-box");
    if (!(await Bun.file(arm64Bin).exists()) || !(await Bun.file(x64Bin).exists())) {
        err(`extracted tarball did not contain a 'sing-box' executable`);
        process.exit(2);
    }

    // Defensive: report each input's slice info so a future operator
    // can adjust if upstream packaging changes (e.g., upstream starts
    // shipping a universal binary in both tarballs).
    info(`arm64 input → ${(await captureStdout(["lipo", "-info", arm64Bin])).trim()}`);
    info(`x64   input → ${(await captureStdout(["lipo", "-info", x64Bin])).trim()}`);

    const mergedPath = join(workDir, "sing-box-universal");
    await runOrDie(
        ["lipo", "-create", arm64Bin, x64Bin, "-output", mergedPath],
        { failMessage: `lipo merge failed`, exitCode: 2 },
    );

    const mergedInfo = (await captureStdout(["lipo", "-info", mergedPath])).trim();
    info(`merged    → ${mergedInfo}`);
    if (!mergedInfo.includes("arm64") || !mergedInfo.includes("x86_64")) {
        err(`merged binary is missing arm64 or x86_64 slice`);
        process.exit(2);
    }

    // Ad-hoc sign so macOS Gatekeeper doesn't reject for missing
    // a signature. Apps without a Developer ID still need *some*
    // signature to launch; `-` means ad-hoc identity.
    await runOrDie(
        ["codesign", "--force", "--sign", "-", "--timestamp=none", mergedPath],
        { failMessage: `codesign ad-hoc failed`, exitCode: 2 },
    );

    const mergedSha = await sha256OfFile(mergedPath);
    info(`merged sha256: ${mergedSha}`);

    return { tarArm64Sha, tarX64Sha, mergedSha, mergedPath, workDir };
}

// ---------------------------------------------------------------------------
// Mode: verify (default)
// ---------------------------------------------------------------------------

async function modeVerify(): Promise<void> {
    const manifest = await readManifest();

    if (!(await Bun.file(DEST).exists())) {
        err(`${DEST} not found.`);
        err(`       The bundled binary is committed to the repo; this should not happen on a clean checkout.`);
        process.exit(3);
    }

    if (!manifest.merged_universal_sha256) {
        err(`manifest has no merged_universal_sha256 field — refusing to proceed.`);
        process.exit(3);
    }

    const actual = await sha256OfFile(DEST);
    if (actual !== manifest.merged_universal_sha256) {
        err(`bundled sing-box does not match the committed pin.`);
        err(`       expected: ${manifest.merged_universal_sha256} (upstream ${manifest.upstream_tag})`);
        err(`       actual  : ${actual}`);
        err(`       Either the bundled binary was tampered with, or the manifest is out of date.`);
        err(`       Roll the pin explicitly with: scripts/fetch_singbox-core.ts --repin`);
        process.exit(3);
    }

    ok(
        `bundled sing-box matches pin (upstream ${manifest.upstream_tag}, sha256 ${manifest.merged_universal_sha256})`,
    );
}

// ---------------------------------------------------------------------------
// Mode: check (audit upstream against committed pin)
// ---------------------------------------------------------------------------

async function modeCheck(): Promise<void> {
    const manifest = await readManifest();
    const missing = [
        ["upstream_tag", manifest.upstream_tag],
        ["arm64_tarball_sha256", manifest.arm64_tarball_sha256],
        ["x64_tarball_sha256", manifest.x64_tarball_sha256],
        ["merged_universal_sha256", manifest.merged_universal_sha256],
    ].filter(([, v]) => !v);
    if (missing.length > 0) {
        err(
            `manifest is incomplete — missing one of upstream_tag, arm64_tarball_sha256, x64_tarball_sha256, merged_universal_sha256.`,
        );
        process.exit(3);
    }

    info(`auditing upstream ${manifest.upstream_tag} against committed pin`);
    const artefacts = await downloadAndBuildUniversal(manifest.upstream_tag);
    try {
        let failed = false;
        if (artefacts.tarArm64Sha !== manifest.arm64_tarball_sha256) {
            err(`DRIFT: arm64 tarball SHA changed at upstream ${manifest.upstream_tag}`);
            err(`       pinned : ${manifest.arm64_tarball_sha256}`);
            err(`       current: ${artefacts.tarArm64Sha}`);
            failed = true;
        }
        if (artefacts.tarX64Sha !== manifest.x64_tarball_sha256) {
            err(`DRIFT: x64 tarball SHA changed at upstream ${manifest.upstream_tag}`);
            err(`       pinned : ${manifest.x64_tarball_sha256}`);
            err(`       current: ${artefacts.tarX64Sha}`);
            failed = true;
        }
        if (artefacts.mergedSha !== manifest.merged_universal_sha256) {
            err(`DRIFT: merged-universal SHA does not reproduce`);
            err(`       pinned : ${manifest.merged_universal_sha256}`);
            err(`       current: ${artefacts.mergedSha}`);
            failed = true;
        }
        if (await Bun.file(DEST).exists()) {
            const bundledSha = await sha256OfFile(DEST);
            if (bundledSha !== manifest.merged_universal_sha256) {
                err(`DRIFT: bundled binary does not match pin`);
                err(`       pinned : ${manifest.merged_universal_sha256}`);
                err(`       bundled: ${bundledSha}`);
                failed = true;
            }
        }

        if (failed) {
            err("");
            err(`Any DRIFT here is a supply-chain signal:`);
            err(`  - upstream tag rewrite, or`);
            err(`  - mirror tampering / TLS-MITM during a previous pin, or`);
            err(`  - local working-tree tampering.`);
            err(`Do not roll the pin until the root cause is understood.`);
            process.exit(3);
        }
        ok(`upstream ${manifest.upstream_tag} reproduces pinned SHAs (tarballs + merged)`);
        ok(`bundled binary matches pin`);
    } finally {
        await rm(artefacts.workDir, { recursive: true, force: true });
    }
}

// ---------------------------------------------------------------------------
// Mode: repin (explicit operator action)
// ---------------------------------------------------------------------------

async function modeRepin(requestedTag: string): Promise<void> {
    let tag = requestedTag;
    if (!tag) {
        try {
            const stdout = await captureStdout([
                "gh",
                "release",
                "list",
                "--repo",
                "SagerNet/sing-box",
                "--exclude-pre-releases",
                "--limit",
                "1",
                "--json",
                "tagName",
                "--jq",
                ".[0].tagName",
            ]);
            tag = stdout.trim();
        } catch {
            // gh missing or first attempt failed; try without the
            // --exclude-pre-releases filter as the legacy script did.
            try {
                const stdout = await captureStdout([
                    "gh",
                    "release",
                    "list",
                    "--repo",
                    "SagerNet/sing-box",
                    "--limit",
                    "1",
                    "--json",
                    "tagName",
                    "--jq",
                    ".[0].tagName",
                ]);
                tag = stdout.trim();
            } catch {
                err(`--repin without TAG requires \`gh\` to resolve the latest release.`);
                err(`       Either install gh, or pass a tag: scripts/fetch_singbox-core.ts --repin vX.Y.Z`);
                process.exit(1);
            }
        }
        if (!tag) {
            err(`could not resolve latest sing-box tag via gh`);
            process.exit(1);
        }
        info(`resolved latest sing-box tag → ${tag}`);
    }

    const artefacts = await downloadAndBuildUniversal(tag);

    try {
        // Show the operator what they would be rolling to.
        process.stdout.write("\n== Pin diff ==\n");
        const existing = await Bun.file(MANIFEST).exists();
        if (existing) {
            const oldManifest = await readManifest();
            process.stdout.write(`  tag           : ${oldManifest.upstream_tag} → ${tag}\n`);
            process.stdout.write(
                `  arm64 tarball : ${oldManifest.arm64_tarball_sha256} → ${artefacts.tarArm64Sha}\n`,
            );
            process.stdout.write(
                `  x64   tarball : ${oldManifest.x64_tarball_sha256} → ${artefacts.tarX64Sha}\n`,
            );
            process.stdout.write(
                `  merged sha256 : ${oldManifest.merged_universal_sha256} → ${artefacts.mergedSha}\n`,
            );
        } else {
            process.stdout.write(`  (no existing manifest — this would be the initial pin)\n`);
            process.stdout.write(`  tag           : ${tag}\n`);
            process.stdout.write(`  arm64 tarball : ${artefacts.tarArm64Sha}\n`);
            process.stdout.write(`  x64   tarball : ${artefacts.tarX64Sha}\n`);
            process.stdout.write(`  merged sha256 : ${artefacts.mergedSha}\n`);
        }
        process.stdout.write("\n");

        if (process.env["CT_REPIN_CONFIRM"] !== "1") {
            warn(`Re-pinning would rewrite both COOL-TUNNEL/sing-box and singbox-core.upstream.json.`);
            warn(`To proceed, re-run with CT_REPIN_CONFIRM=1 set in the environment:`);
            warn("");
            warn(`    CT_REPIN_CONFIRM=1 scripts/fetch_singbox-core.ts --repin ${tag}`);
            warn("");
            warn(
                `The change MUST land as a single commit (binary + manifest) that names the old → new tag transition in the message.`,
            );
            process.exit(4);
        }

        // Replace the bundled binary atomically so a partial copy
        // never lands at the destination path.
        const tmpDest = `${DEST}.tmp`;
        await Bun.write(tmpDest, Bun.file(artefacts.mergedPath));
        await chmod(tmpDest, 0o755);
        await rename(tmpDest, DEST);

        // Rewrite the manifest. We intentionally always rewrite
        // here (no "same SHAs → preserve fetched_at" guard) because
        // reaching this branch requires CT_REPIN_CONFIRM=1.
        const fetchedAt = new Date().toISOString().replace(/\.\d+Z$/, "Z");
        const newManifest: SingboxCoreManifest = {
            upstream_tag: tag,
            arm64_tarball_sha256: artefacts.tarArm64Sha,
            x64_tarball_sha256: artefacts.tarX64Sha,
            merged_universal_sha256: artefacts.mergedSha,
            fetched_at: fetchedAt,
        };
        await Bun.write(MANIFEST, `${JSON.stringify(newManifest, null, 2)}\n`);

        process.stdout.write("\n");
        ok(`wrote universal sing-box to ${DEST}`);
        ok(`wrote pin manifest to     ${MANIFEST}`);
        process.stdout.write(`    tag    : ${tag}\n`);
        process.stdout.write(`    sha256 : ${artefacts.mergedSha}\n\n`);
        process.stdout.write(`Next: commit both files together. Suggested message:\n`);
        process.stdout.write(`  chore(singbox-core): repin to ${tag}\n`);
    } finally {
        await rm(artefacts.workDir, { recursive: true, force: true });
    }
}

// ---------------------------------------------------------------------------
// Dispatch
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
    const args = parseArgs(process.argv.slice(2));
    switch (args.mode) {
        case "verify":
            await modeVerify();
            return;
        case "check":
            await modeCheck();
            return;
        case "repin":
            await modeRepin(args.repinTag);
            return;
    }
}

// **Test-friendly main-guard:** dispatch only when this file is
// the process entry point. Without the guard, `bun test`
// importing `parseArgs` from this module would run the full
// verify-mode pipeline at import time.
//
// Defensive top-level: anything that escapes the main flow as a
// thrown Error (network glitch, JSON parse failure, etc.) lands
// here with a clean message instead of a stack trace.
if (import.meta.main) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`fetch_singbox-core: ${caught.message}`);
        } else {
            die(`fetch_singbox-core: unknown failure: ${String(caught)}`);
        }
    });
}

// Re-export key helpers for unit tests.
export { parseArgs, readManifest, sha256OfFile, type SingboxCoreManifest };
