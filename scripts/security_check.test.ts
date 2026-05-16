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

import { hasAgplLicenseHeader, parseArgs } from "./security_check.ts";

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
