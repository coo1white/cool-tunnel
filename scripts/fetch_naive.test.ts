// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/fetch_naive.test.ts — argument-parser tests for fetch_naive.ts.
//
// The download / lipo / codesign / network paths are integration-
// tested by the daily naive-pin-audit.yml workflow against the live
// upstream. This file pins the pure-logic surface (argv parsing) so
// a future regression in mode dispatch fails at `bun test` rather
// than at release-cut time.

import { describe, expect, test } from "bun:test";

import { parseArgs } from "./fetch_naive.ts";

describe("fetch_naive parseArgs", () => {
    test("no args → verify mode", () => {
        const out = parseArgs([]);
        expect(out.mode).toBe("verify");
        expect(out.repinTag).toBe("");
    });

    test("--check-only → check mode", () => {
        const out = parseArgs(["--check-only"]);
        expect(out.mode).toBe("check");
        expect(out.repinTag).toBe("");
    });

    test("--repin without TAG → repin mode, empty tag (gh resolution at runtime)", () => {
        const out = parseArgs(["--repin"]);
        expect(out.mode).toBe("repin");
        expect(out.repinTag).toBe("");
    });

    test("--repin TAG → repin mode, tag captured", () => {
        const out = parseArgs(["--repin", "v148.0.7778.96-7"]);
        expect(out.mode).toBe("repin");
        expect(out.repinTag).toBe("v148.0.7778.96-7");
    });

    test("--repin --check-only → repin with empty tag (next flag is not a tag)", () => {
        const out = parseArgs(["--repin", "--check-only"]);
        expect(out.mode).toBe("check");
        expect(out.repinTag).toBe("");
    });
});
