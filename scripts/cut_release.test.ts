// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/cut_release.test.ts — argument-parser tests for cut_release.ts.
//
// The full xcodebuild → security_check → package_release pipeline
// is exercised by every actual release cut (since v2.0.18-pre that's
// the only path artifacts can leave the working tree). This file
// pins the pure-logic surface (positional version-arg parsing) so
// regressions in argv handling fail at `bun test` rather than
// release-cut time.

import { describe, expect, test } from "bun:test";

import { parseVersionArg } from "./cut_release.ts";

describe("cut_release parseVersionArg", () => {
    test("happy path → ok with version", () => {
        const out = parseVersionArg(["2.0.53"]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.version).toBe("2.0.53");
    });

    test("empty argv → not ok with usage hint", () => {
        const out = parseVersionArg([]);
        expect(out.ok).toBe(false);
        if (!out.ok) expect(out.reason).toContain("usage:");
    });

    test("empty string version → not ok", () => {
        const out = parseVersionArg([""]);
        expect(out.ok).toBe(false);
    });

    test("flag-shaped first arg → not ok (we want a version, not a flag)", () => {
        const out = parseVersionArg(["--help"]);
        expect(out.ok).toBe(false);
    });

    test("trailing args ignored — first positional wins", () => {
        const out = parseVersionArg(["2.0.53", "extra", "--noise"]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.version).toBe("2.0.53");
    });
});
