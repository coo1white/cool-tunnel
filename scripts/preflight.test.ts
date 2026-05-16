// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/preflight.test.ts — pure-logic tests for the preflight
// argv parser. The end-to-end gate suite is exercised every time a
// contributor runs `bin/ct preflight` (and every PR via CI's own
// jobs); this file pins the flag-shape so a future refactor of the
// parser fails at `bun test` rather than at release-cut time.

import { describe, expect, test } from "bun:test";

import { parseArgs } from "./preflight.ts";

describe("preflight parseArgs", () => {
    test("no args → ok, no skips", () => {
        const out = parseArgs([]);
        expect(out.ok).toBe(true);
        if (out.ok) {
            expect(out.options.skipTests).toBe(false);
            expect(out.options.skipDeny).toBe(false);
        }
    });

    test("--skip-tests → ok, skipTests on", () => {
        const out = parseArgs(["--skip-tests"]);
        expect(out.ok).toBe(true);
        if (out.ok) {
            expect(out.options.skipTests).toBe(true);
            expect(out.options.skipDeny).toBe(false);
        }
    });

    test("--skip-deny → ok, skipDeny on", () => {
        const out = parseArgs(["--skip-deny"]);
        expect(out.ok).toBe(true);
        if (out.ok) {
            expect(out.options.skipTests).toBe(false);
            expect(out.options.skipDeny).toBe(true);
        }
    });

    test("both flags in either order → both on", () => {
        const a = parseArgs(["--skip-tests", "--skip-deny"]);
        const b = parseArgs(["--skip-deny", "--skip-tests"]);
        expect(a.ok).toBe(true);
        expect(b.ok).toBe(true);
        if (a.ok && b.ok) {
            expect(a.options).toEqual({ skipTests: true, skipDeny: true });
            expect(b.options).toEqual({ skipTests: true, skipDeny: true });
        }
    });

    test("--help → not ok, exit 0, usage", () => {
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

    test("unknown flag → not ok, exit 2", () => {
        const out = parseArgs(["--nope"]);
        expect(out.ok).toBe(false);
        if (!out.ok) {
            expect(out.exitCode).toBe(2);
            expect(out.reason).toContain("unknown argument");
        }
    });

    test("unknown flag after a valid one still fails", () => {
        const out = parseArgs(["--skip-tests", "--bogus"]);
        expect(out.ok).toBe(false);
        if (!out.ok) expect(out.exitCode).toBe(2);
    });
});
