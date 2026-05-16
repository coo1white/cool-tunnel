// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/security_check.test.ts — pure-logic tests for the
// security_check port. The end-to-end path runs on macOS at every
// release cut (codesign / lipo / shasum / PlistBuddy / spctl).
// This file pins the parser + scanner surfaces so a future refactor
// of any of them fails at `bun test` rather than at release-cut time.
//
// **No real-looking secret patterns appear in this file.** The
// scanContentForSecrets tests use synthetic patterns (e.g.
// `/FAKE-SENTINEL-[0-9]+/`) and synthetic content so this test file
// itself never trips the production secret scan when it walks the
// repo.

import { describe, expect, test } from "bun:test";

import {
    hasAgplLicenseHeader,
    looksBinary,
    parseArgs,
    parseLockfileVersion,
    parseToolchainChannel,
    posixToJsRegex,
    scanContentForSecrets,
} from "./security_check.ts";

describe("security_check parseArgs", () => {
    test("no args → ok, no appPath (auto-discover)", () => {
        const out = parseArgs([]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.args.appPath).toBeUndefined();
    });

    test("single positional → ok, that path", () => {
        const out = parseArgs(["/tmp/Cool tunnel.app"]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.args.appPath).toBe("/tmp/Cool tunnel.app");
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

    test("extra args after path → not ok, exit 1", () => {
        const out = parseArgs(["/tmp/x.app", "extra"]);
        expect(out.ok).toBe(false);
        if (!out.ok) {
            expect(out.exitCode).toBe(1);
            expect(out.reason).toContain("extra");
        }
    });
});

describe("security_check posixToJsRegex", () => {
    test("[[:space:]] → \\s", () => {
        expect(posixToJsRegex("a[[:space:]]+b")).toBe("a\\s+b");
    });

    test("[[:digit:]] → \\d", () => {
        expect(posixToJsRegex("[[:digit:]]{3}")).toBe("\\d{3}");
    });

    test("[[:alpha:]] → [A-Za-z]", () => {
        expect(posixToJsRegex("[[:alpha:]]+")).toBe("[A-Za-z]+");
    });

    test("[[:alnum:]] → [A-Za-z0-9]", () => {
        expect(posixToJsRegex("[[:alnum:]]+")).toBe("[A-Za-z0-9]+");
    });

    test("no POSIX classes → unchanged", () => {
        expect(posixToJsRegex("AKIA[0-9A-Z]{16}")).toBe("AKIA[0-9A-Z]{16}");
    });

    test("multiple classes in one pattern → all replaced", () => {
        expect(posixToJsRegex("foo[[:space:]]+[[:digit:]]+")).toBe(
            "foo\\s+\\d+",
        );
    });
});

describe("security_check scanContentForSecrets", () => {
    // Synthetic patterns — none look like real credentials, so this
    // test file itself never trips the production scan.
    const REGEXES = [/FAKE-SENTINEL-[0-9]+/, /WIDGET-PREFIX-[A-Z]{4}/];

    test("matching line → reported with 1-based lineno", () => {
        const content = "line one\nFAKE-SENTINEL-42 here\nline three\n";
        const matches = scanContentForSecrets(content, "x.txt", REGEXES);
        expect(matches.length).toBe(1);
        const m = matches[0];
        expect(m?.lineno).toBe(2);
        expect(m?.path).toBe("x.txt");
        expect(m?.content).toContain("FAKE-SENTINEL-42");
    });

    test("no match → empty array", () => {
        const matches = scanContentForSecrets(
            "nothing matches in this content\n",
            "x.txt",
            REGEXES,
        );
        expect(matches).toEqual([]);
    });

    test("multiple lines, multiple matches → all reported", () => {
        const content =
            "FAKE-SENTINEL-1\n" +
            "innocuous\n" +
            "WIDGET-PREFIX-ABCD some context\n";
        const matches = scanContentForSecrets(content, "y.txt", REGEXES);
        expect(matches.length).toBe(2);
        expect(matches[0]?.lineno).toBe(1);
        expect(matches[1]?.lineno).toBe(3);
    });

    test("one line matches multiple patterns → reported once (first wins)", () => {
        // bash grep with multiple patterns would emit one line per
        // matching pattern; our TS version collapses to one match per
        // line — first pattern that fires is enough to flag the line.
        const overlapping = [/AA[0-9]+/, /\d{2,}/];
        const content = "AA42\n";
        const matches = scanContentForSecrets(content, "z.txt", overlapping);
        expect(matches.length).toBe(1);
    });

    test("path is reflected verbatim", () => {
        const matches = scanContentForSecrets(
            "FAKE-SENTINEL-1\n",
            "deep/nested/path.swift",
            REGEXES,
        );
        expect(matches[0]?.path).toBe("deep/nested/path.swift");
    });
});

describe("security_check looksBinary", () => {
    test("text bytes → false", () => {
        const text = new TextEncoder().encode("hello world\nthis is text\n");
        expect(looksBinary(text)).toBe(false);
    });

    test("contains null byte in first 8 KB → true", () => {
        const bytes = new Uint8Array(100);
        bytes[50] = 0;
        expect(looksBinary(bytes)).toBe(true);
    });

    test("null byte past 8 KB ceiling → false (not scanned)", () => {
        const bytes = new Uint8Array(9000);
        bytes.fill(65); // 'A'
        bytes[8500] = 0;
        expect(looksBinary(bytes)).toBe(false);
    });

    test("empty → false (no null to find)", () => {
        expect(looksBinary(new Uint8Array(0))).toBe(false);
    });
});

describe("security_check parseLockfileVersion", () => {
    test("standard Cargo.lock entry → version extracted", () => {
        const lock =
            '[[package]]\n' +
            'name = "serde"\n' +
            'version = "1.0.197"\n' +
            'source = "registry+..."\n\n' +
            '[[package]]\n' +
            'name = "cool-tunnel-core"\n' +
            'version = "2.0.59"\n';
        expect(parseLockfileVersion(lock, "cool-tunnel-core")).toBe("2.0.59");
    });

    test("missing package → null", () => {
        const lock =
            '[[package]]\nname = "other"\nversion = "1.0"\n';
        expect(parseLockfileVersion(lock, "cool-tunnel-core")).toBeNull();
    });

    test("first occurrence wins on duplicate name lines", () => {
        const lock =
            'name = "x"\n' +
            'version = "1.0"\n' +
            'name = "x"\n' +
            'version = "2.0"\n';
        expect(parseLockfileVersion(lock, "x")).toBe("1.0");
    });

    test("name line not followed by a quoted line → null", () => {
        const lock = 'name = "x"\n# end of file\n';
        expect(parseLockfileVersion(lock, "x")).toBeNull();
    });
});

describe("security_check parseToolchainChannel", () => {
    test("standard pin → extracted", () => {
        const toml = '[toolchain]\nchannel = "1.95.0"\nprofile = "minimal"\n';
        expect(parseToolchainChannel(toml)).toBe("1.95.0");
    });

    test("whitespace tolerated around =", () => {
        expect(parseToolchainChannel('channel   =   "stable"\n')).toBe("stable");
    });

    test("missing channel → null", () => {
        expect(parseToolchainChannel('profile = "minimal"\n')).toBeNull();
    });

    test("indented channel → not anchored, null", () => {
        // ^channel anchor means an indented `channel = "x"` inside
        // a nested table doesn't match.
        expect(parseToolchainChannel('    channel = "x"\n')).toBeNull();
    });
});

describe("security_check hasAgplLicenseHeader", () => {
    test("both anchors present → true", () => {
        const license =
            "                    GNU AFFERO GENERAL PUBLIC LICENSE\n" +
            "                       Version 3, 19 November 2007\n";
        expect(hasAgplLicenseHeader(license)).toBe(true);
    });

    test("missing 'Version 3' → false", () => {
        expect(hasAgplLicenseHeader("GNU AFFERO GENERAL PUBLIC LICENSE\n")).toBe(
            false,
        );
    });

    test("missing AGPL anchor → false (e.g. Apache-2.0)", () => {
        expect(
            hasAgplLicenseHeader("Apache License\n  Version 3 of nothing\n"),
        ).toBe(false);
    });

    test("empty → false", () => {
        expect(hasAgplLicenseHeader("")).toBe(false);
    });
});
