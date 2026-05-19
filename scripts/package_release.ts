#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/package_release.ts — release artifact packaging.
//
// Builds the four release artefacts (.dmg, .pkg, .zip, standalone
// universal cool-tunnel-core) from a Release `Cool tunnel.app` bundle
// and prints a SHA-256 manifest. Mirrors the manual flow we used for
// v0.1.2 / v0.1.3 so each release is reproducible from one command.
//
// Usage:
//   bun scripts/package_release.ts <version> [app-path]
//
// Output (under dist/):
//   Cool-tunnel-v<VERSION>.dmg               drag-and-drop image
//   Cool-tunnel-v<VERSION>.pkg               Installer.app component
//   Cool-tunnel-v<VERSION>.zip               ditto-archived bundle
//   cool-tunnel-core-v<VERSION>-universal    standalone Rust core
//   Cool-tunnel-v<VERSION>.sha256            manifest with all four hashes
//
// Exit codes (preserved from the legacy shell script for muscle memory):
//   0  success
//   1  bad arguments / missing app / precondition failure
//   2  packaging step failed
//
// Dependencies (macOS only — the bulk of this script targets Apple
// tooling): bun 1.1+, hdiutil, pkgbuild, productbuild, ditto, shasum,
// PlistBuddy.

import { existsSync, statSync } from "node:fs";
import { cp, mkdir, rm, symlink, writeFile, chmod } from "node:fs/promises";
import { basename, join } from "node:path";

import { parseCargoTomlVersion } from "./lib/cargo.ts";
import { die, ok, step } from "./lib/log.ts";
import { repoRoot } from "./lib/paths.ts";
import { captureStdout, run } from "./lib/spawn.ts";

// ---------------------------------------------------------------------------
// Argument parsing
// ---------------------------------------------------------------------------

export interface PackageArgs {
    readonly version: string;
    readonly appPath: string | undefined;
}

export type ArgsParse =
    | { readonly ok: true; readonly args: PackageArgs }
    | { readonly ok: false; readonly reason: string; readonly exitCode: number };

/**
 * Pure argv parser. First positional arg is the version; second
 * (optional) is the path to the `.app` bundle. `-h` / `--help` exits
 * 0 with usage; empty argv or unrecognised flag exits 1 (matching
 * the bash version's `[[ $# -lt 1 ]]` shape).
 */
export function parseArgs(argv: readonly string[]): ArgsParse {
    const first = argv[0];
    if (first === undefined) {
        return {
            ok: false,
            reason: "usage: bun scripts/package_release.ts <version> [app-path]",
            exitCode: 1,
        };
    }
    if (first === "-h" || first === "--help") {
        return {
            ok: false,
            reason:
                "usage: bun scripts/package_release.ts <version> [app-path]\n" +
                "       build the .dmg / .pkg / .zip / standalone-core / .sha256 artefacts.",
            exitCode: 0,
        };
    }
    return {
        ok: true,
        args: { version: first, appPath: argv[1] },
    };
}

// ---------------------------------------------------------------------------
// Pure-logic helpers (exported for tests)
// ---------------------------------------------------------------------------

/**
 * Extract the trailing token of `cool-tunnel-core --version`. The
 * binary emits `cool-tunnel-core <semver>` on the first line; the
 * bash version did `CORE_VERSION="${CORE_VERSION_LINE##* }"`. We take
 * only the first line and the last whitespace-delimited token from
 * that line.
 */
export function parseCoreVersionLine(output: string): string {
    const firstLine = output.split("\n", 1)[0] ?? "";
    const trimmed = firstLine.trim();
    if (trimmed === "") return "";
    const tokens = trimmed.split(/\s+/);
    return tokens[tokens.length - 1] ?? "";
}

/**
 * Substitute every `{{VERSION}}` literal with the supplied version
 * string. The bash version used awk's `gsub` over literal strings
 * for delimiter-safety; this is the equivalent — `replaceAll` is
 * literal-string match, no regex surprises.
 */
export function substituteVersion(template: string, version: string): string {
    return template.replaceAll("{{VERSION}}", version);
}

/**
 * Format a SHA-256 manifest line set as the bash version did. Each
 * entry becomes `<hash>  <basename>` (two spaces — `shasum`'s default
 * format). Input may be the raw multi-line output of
 * `shasum -a 256 <path1> <path2> ...` (which is `<hash>  <full-path>`)
 * — this helper strips the directory prefix to basename so the manifest
 * is portable across mirrors.
 */
export function formatManifest(shasumOutput: string): string {
    const lines = shasumOutput.split("\n").filter((line) => line.length > 0);
    const out: string[] = [];
    for (const line of lines) {
        // Match `<hash>  <path>` (two spaces between hash and path is
        // shasum's documented separator).
        const split = line.split(/  +/, 2);
        if (split.length !== 2) {
            out.push(line);
            continue;
        }
        const hash = split[0] ?? "";
        const path = split[1] ?? "";
        out.push(`${hash}  ${basename(path)}`);
    }
    return out.join("\n") + (out.length > 0 ? "\n" : "");
}

/**
 * Convert a byte count to a human-readable string ("1.5MB", "942KB",
 * "8.0GB"). Matches the bash version's awk: iterate through
 * `B / KB / MB / GB / TB`, dividing by 1024 each step until either
 * the value falls below 1024 or we reach the TB ceiling.
 */
export function humanBytes(bytes: number): string {
    const units = ["B", "KB", "MB", "GB", "TB"] as const;
    let n = bytes;
    let i = 0;
    while (n >= 1024 && i < units.length - 1) {
        n /= 1024;
        i += 1;
    }
    return `${n.toFixed(1)}${units[i]}`;
}

/**
 * hdiutil's implicit sizing for `-srcfolder` can under-allocate the
 * temporary image it mounts while copying large .app bundles. Size the
 * image from `du -sk` with a 40% cushion plus 32 MiB for filesystem
 * metadata and rounding.
 */
export function dmgMegabytesForStage(kibibytes: number): number {
    const payloadMiB = Math.ceil(kibibytes / 1024);
    return Math.max(64, Math.ceil(payloadMiB * 1.4) + 32);
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
    const { version, appPath } = parsed.args;

    const root = repoRoot(import.meta.url);
    const distDir = join(root, "dist");

    const app =
        appPath ??
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
        process.exit(1);
    }

    // --- U#6: Cargo.toml precondition ------------------------------------
    const cargoToml = join(root, "core", "Cargo.toml");
    if (existsSync(cargoToml)) {
        const content = await Bun.file(cargoToml).text();
        const cargoVersion = parseCargoTomlVersion(content);
        if (cargoVersion === null) {
            process.stderr.write(
                `error: could not parse version from ${cargoToml}\n`,
            );
            process.exit(1);
        }
        if (cargoVersion !== version) {
            process.stderr.write(
                `error: core/Cargo.toml version is '${cargoVersion}' but you requested '${version}'\n`,
            );
            process.stderr.write(
                `       bump core/Cargo.toml's version field to ${version} and rebuild before retrying.\n`,
            );
            process.exit(1);
        }
    }

    // --- U#5: Resources/cool-tunnel-core precondition --------------------
    const coreInApp = join(app, "Contents", "Resources", "cool-tunnel-core");
    if (existsSync(coreInApp)) {
        try {
            const versionLine = await captureStdout([coreInApp, "--version"]);
            const coreVersion = parseCoreVersionLine(versionLine);
            if (coreVersion !== version) {
                process.stderr.write(
                    `error: cool-tunnel-core self-reports '${coreVersion}' (line: '${versionLine.split("\n", 1)[0] ?? ""}'), expected '${version}'\n`,
                );
                process.stderr.write(
                    `       the .app bundle is stale; run a fresh \`xcodebuild ... build\` to regenerate\n`,
                );
                process.stderr.write(
                    `       Resources/cool-tunnel-core from the bumped Cargo.toml, then retry.\n`,
                );
                process.exit(1);
            }
        } catch (caught) {
            // `captureStdout` throws on non-zero exit; preserve the bash
            // `2>/dev/null || true` semantics — if --version fails we just
            // can't verify the embedded binary, so we skip the check.
            void caught;
        }
    }

    // --- U#7: Info.plist CFBundleShortVersionString precondition ---------
    const appPlist = join(app, "Contents", "Info.plist");
    if (existsSync(appPlist)) {
        let appShortVersion = "?";
        try {
            const out = await captureStdout([
                "/usr/libexec/PlistBuddy",
                "-c",
                "Print :CFBundleShortVersionString",
                appPlist,
            ]);
            appShortVersion = out.trim();
        } catch (caught) {
            void caught;
        }
        if (appShortVersion !== version) {
            process.stderr.write(
                `error: .app Info.plist CFBundleShortVersionString is '${appShortVersion}', expected '${version}'\n`,
            );
            process.stderr.write(
                `       bump MARKETING_VERSION in COOL-TUNNEL.xcodeproj/project.pbxproj (both Debug + Release configs)\n`,
            );
            process.stderr.write(
                `       to ${version}, run a fresh \`xcodebuild ... build\`, then retry.\n`,
            );
            process.exit(1);
        }
    }

    await mkdir(distDir, { recursive: true });

    const dmg = join(distDir, `Cool-tunnel-v${version}.dmg`);
    const pkg = join(distDir, `Cool-tunnel-v${version}.pkg`);
    const zip = join(distDir, `Cool-tunnel-v${version}.zip`);
    const core = join(distDir, `cool-tunnel-core-v${version}-universal`);
    const manifest = join(distDir, `Cool-tunnel-v${version}.sha256`);

    // --- DMG -------------------------------------------------------------
    process.stdout.write(`info: building ${basename(dmg)}\n`);
    const stage = join(distDir, `dmg-staging-v${version}`);
    await rm(stage, { recursive: true, force: true });
    await rm(dmg, { force: true });
    await mkdir(stage, { recursive: true });
    await cp(app, join(stage, basename(app)), { recursive: true });
    await symlink("/Applications", join(stage, "Applications"));
    const duOutput = await captureStdout(["du", "-sk", stage]);
    const stageSizeText = duOutput.trim().split(/\s+/)[0] ?? "";
    const stageSizeKiB = Number.parseInt(stageSizeText, 10);
    if (!Number.isFinite(stageSizeKiB) || stageSizeKiB <= 0) {
        die(`could not determine DMG staging size for ${stage}`, 2);
    }
    const dmgSize = `${dmgMegabytesForStage(stageSizeKiB)}m`;
    if (
        (await run([
            "hdiutil",
            "create",
            "-size",
            dmgSize,
            "-volname",
            `Cool Tunnel v${version}`,
            "-srcfolder",
            stage,
            "-ov",
            "-format",
            "UDZO",
            dmg,
        ])) !== 0
    ) {
        die(`hdiutil create failed`, 2);
    }

    // --- PKG -------------------------------------------------------------
    process.stdout.write(`info: building ${basename(pkg)}\n`);
    await rm(pkg, { force: true });
    const pkgStage = join(distDir, `pkg-staging-v${version}`);
    await rm(pkgStage, { recursive: true, force: true });
    await mkdir(pkgStage, { recursive: true });
    const componentPkg = join(pkgStage, "cooltunnel-component.pkg");
    if (
        (await run([
            "pkgbuild",
            "--component",
            app,
            "--install-location",
            "/Applications",
            "--identifier",
            "space.coolwhite.cooltunnel.pkg",
            "--version",
            version,
            componentPkg,
        ])) !== 0
    ) {
        die(`pkgbuild failed`, 2);
    }

    const distXmlTemplate = join(root, "scripts", "Distribution.xml.template");
    if (!existsSync(distXmlTemplate)) {
        process.stderr.write(
            `error: missing Distribution.xml template at ${distXmlTemplate}\n`,
        );
        process.exit(2);
    }
    const template = await Bun.file(distXmlTemplate).text();
    const distXml = join(pkgStage, "Distribution.xml");
    await writeFile(distXml, substituteVersion(template, version));

    if (
        (await run([
            "productbuild",
            "--distribution",
            distXml,
            "--package-path",
            pkgStage,
            pkg,
        ])) !== 0
    ) {
        die(`productbuild failed`, 2);
    }

    // --- ZIP -------------------------------------------------------------
    process.stdout.write(`info: building ${basename(zip)}\n`);
    await rm(zip, { force: true });
    if (
        (await run([
            "ditto",
            "-c",
            "-k",
            "--sequesterRsrc",
            "--keepParent",
            app,
            zip,
        ])) !== 0
    ) {
        die(`ditto failed`, 2);
    }

    // --- Standalone Rust core --------------------------------------------
    process.stdout.write(`info: building ${basename(core)}\n`);
    await rm(core, { force: true });
    await cp(join(app, "Contents", "Resources", "cool-tunnel-core"), core);
    await chmod(core, 0o755);

    // --- SHA-256 manifest ------------------------------------------------
    const shasumOut = await captureStdout([
        "shasum",
        "-a",
        "256",
        dmg,
        pkg,
        zip,
        core,
    ]);
    await writeFile(manifest, formatManifest(shasumOut));

    process.stdout.write(`\n`);
    ok(`artefacts written to ${distDir}/`);

    for (const f of [dmg, pkg, zip, core]) {
        try {
            const size = statSync(f).size;
            process.stdout.write(
                `    ${basename(f)}  ${humanBytes(size)}\n`,
            );
        } catch (caught) {
            void caught;
        }
    }
    process.stdout.write(`\n`);
    process.stdout.write(`sha256 manifest:\n`);
    const manifestText = await Bun.file(manifest).text();
    for (const line of manifestText.split("\n")) {
        if (line.length > 0) process.stdout.write(`    ${line}\n`);
    }

    process.stdout.write(`\n`);
    process.stdout.write(
        `next step — publish to GitHub with ALL FIVE assets:\n\n`,
    );
    process.stdout.write(`  gh release create v${version} \\\n`);
    process.stdout.write(`    ${dmg} \\\n`);
    process.stdout.write(`    ${pkg} \\\n`);
    process.stdout.write(`    ${zip} \\\n`);
    process.stdout.write(`    ${core} \\\n`);
    process.stdout.write(`    ${manifest} \\\n`);
    process.stdout.write(`    --title "v${version} — <title>" \\\n`);
    process.stdout.write(`    --notes-file <path-to-notes.md> \\\n`);
    process.stdout.write(`    --latest\n\n`);
    process.stdout.write(
        `the .sha256 manifest is REQUIRED — the in-app updater\n`,
    );
    process.stdout.write(`refuses to install a release that lacks it.\n`);

    // Clean up staging dirs.
    await rm(stage, { recursive: true, force: true });
    await rm(pkgStage, { recursive: true, force: true });

    process.exit(0);
}

if (import.meta.main) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`package_release: ${caught.message}`, 2);
        } else {
            die(`package_release: unknown failure: ${String(caught)}`, 2);
        }
    });
}
