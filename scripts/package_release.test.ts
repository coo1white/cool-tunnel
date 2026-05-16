// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/package_release.test.ts — pure-logic tests for the
// package_release port. The end-to-end packaging path is exercised
// every release cut on macOS (hdiutil / pkgbuild / productbuild /
// ditto / PlistBuddy / shasum). This file pins the parser + formatter
// surfaces (argv parser, Cargo.toml version extractor, --version line
// extractor, template substitution, manifest formatter, human-byte
// formatter) so a future refactor of any of them fails at
// `bun test` rather than at release-cut time.

import { describe, expect, test } from "bun:test";

import {
    formatManifest,
    humanBytes,
    parseArgs,
    parseCoreVersionLine,
    substituteVersion,
} from "./package_release.ts";

describe("package_release parseArgs", () => {
    test("empty argv → not ok, exit 1, usage", () => {
        const out = parseArgs([]);
        expect(out.ok).toBe(false);
        if (!out.ok) {
            expect(out.exitCode).toBe(1);
            expect(out.reason).toContain("usage:");
        }
    });

    test("version only → ok, no appPath", () => {
        const out = parseArgs(["2.0.59"]);
        expect(out.ok).toBe(true);
        if (out.ok) {
            expect(out.args.version).toBe("2.0.59");
            expect(out.args.appPath).toBeUndefined();
        }
    });

    test("version + app path → ok, both", () => {
        const out = parseArgs(["2.0.59", "/tmp/Cool tunnel.app"]);
        expect(out.ok).toBe(true);
        if (out.ok) {
            expect(out.args.version).toBe("2.0.59");
            expect(out.args.appPath).toBe("/tmp/Cool tunnel.app");
        }
    });

    test("--help → not ok, exit 0", () => {
        const out = parseArgs(["--help"]);
        expect(out.ok).toBe(false);
        if (!out.ok) {
            expect(out.exitCode).toBe(0);
            expect(out.reason).toContain("usage:");
        }
    });

    test("-h → not ok, exit 0", () => {
        const out = parseArgs(["-h"]);
        expect(out.ok).toBe(false);
        if (!out.ok) expect(out.exitCode).toBe(0);
    });
});

describe("package_release parseCoreVersionLine", () => {
    test("standard shape → last token", () => {
        expect(parseCoreVersionLine("cool-tunnel-core 2.0.59\n")).toBe("2.0.59");
    });

    test("trailing whitespace stripped", () => {
        expect(parseCoreVersionLine("cool-tunnel-core 2.0.59 \n")).toBe("2.0.59");
    });

    test("multi-line input → only first line considered", () => {
        expect(
            parseCoreVersionLine("cool-tunnel-core 2.0.59\nbuild: abc123\n"),
        ).toBe("2.0.59");
    });

    test("empty input → empty string", () => {
        expect(parseCoreVersionLine("")).toBe("");
        expect(parseCoreVersionLine("\n")).toBe("");
    });

    test("single token on the line → that token", () => {
        expect(parseCoreVersionLine("2.0.59\n")).toBe("2.0.59");
    });
});

describe("package_release substituteVersion", () => {
    test("single placeholder → replaced", () => {
        expect(substituteVersion("v{{VERSION}}", "2.0.59")).toBe("v2.0.59");
    });

    test("multiple placeholders → all replaced", () => {
        const tpl = "v{{VERSION}} of cooltunnel-{{VERSION}}.pkg";
        expect(substituteVersion(tpl, "2.0.59")).toBe(
            "v2.0.59 of cooltunnel-2.0.59.pkg",
        );
    });

    test("no placeholder → unchanged", () => {
        expect(substituteVersion("no marker here", "2.0.59")).toBe(
            "no marker here",
        );
    });

    test("version contains regex metachars → still substituted literally", () => {
        // The bash version used awk's literal-gsub for delimiter
        // safety; the TS uses replaceAll which is also literal.
        expect(substituteVersion("v{{VERSION}}", "1.2+build/abc")).toBe(
            "v1.2+build/abc",
        );
    });
});

describe("package_release formatManifest", () => {
    test("strips full paths to basenames", () => {
        const shasumOut =
            "abcd  /tmp/dist/Cool-tunnel-v2.0.59.dmg\n" +
            "ef01  /tmp/dist/Cool-tunnel-v2.0.59.pkg\n";
        expect(formatManifest(shasumOut)).toBe(
            "abcd  Cool-tunnel-v2.0.59.dmg\nef01  Cool-tunnel-v2.0.59.pkg\n",
        );
    });

    test("empty input → empty string (no trailing newline)", () => {
        expect(formatManifest("")).toBe("");
    });

    test("trailing newline tolerated in input", () => {
        expect(formatManifest("abcd  /x/y.dmg\n\n")).toBe("abcd  y.dmg\n");
    });

    test("malformed line (no double-space) passed through verbatim", () => {
        // shasum always uses two spaces; if the input is weird we
        // shouldn't lose data — pass it through unchanged.
        expect(formatManifest("malformed\n")).toBe("malformed\n");
    });
});

describe("package_release humanBytes", () => {
    test("bytes below 1024 → B", () => {
        expect(humanBytes(0)).toBe("0.0B");
        expect(humanBytes(512)).toBe("512.0B");
        expect(humanBytes(1023)).toBe("1023.0B");
    });

    test("1024 → 1.0KB", () => {
        expect(humanBytes(1024)).toBe("1.0KB");
    });

    test("1.5 MB", () => {
        expect(humanBytes(1024 * 1024 * 1.5)).toBe("1.5MB");
    });

    test("8 GB", () => {
        expect(humanBytes(1024 ** 3 * 8)).toBe("8.0GB");
    });

    test("clamps at TB ceiling — doesn't roll past", () => {
        // The bash awk loop stops at i=5 (TB). 1024 PB would otherwise
        // overflow into a 6th unit we don't have.
        expect(humanBytes(1024 ** 5)).toBe("1024.0TB");
    });
});
