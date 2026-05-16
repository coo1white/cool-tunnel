// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/try_question_ratchet.test.ts — pure-logic tests for the
// ratchet. The end-to-end ratchet count is exercised by CI on every
// PR; this file pins the matcher rules (same-line marker, preceding-
// line marker fallback, false-positive avoidance) so a future
// regex tweak fails at `bun test` rather than hiding a real `try?`
// drift inside the count.

import { describe, expect, test } from "bun:test";

import { parseArgs, scanContent } from "./try_question_ratchet.ts";

describe("try_question_ratchet parseArgs", () => {
    test("no args → ok, count mode", () => {
        const out = parseArgs([]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.listOnly).toBe(false);
    });

    test("--list → ok, list mode", () => {
        const out = parseArgs(["--list"]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.listOnly).toBe(true);
    });

    test("--help → not ok, exit 0", () => {
        const out = parseArgs(["--help"]);
        expect(out.ok).toBe(false);
        if (!out.ok) {
            expect(out.exitCode).toBe(0);
            expect(out.reason).toContain("usage:");
        }
    });

    test("unknown flag → not ok, exit 2", () => {
        const out = parseArgs(["--nope"]);
        expect(out.ok).toBe(false);
        if (!out.ok) expect(out.exitCode).toBe(2);
    });
});

describe("try_question_ratchet scanContent", () => {
    test("bare try? on a line is unannotated", () => {
        const sites = scanContent("let x = try? foo()\n", "Sample.swift");
        expect(sites.length).toBe(1);
        expect(sites[0].lineno).toBe(1);
    });

    test("try? + same-line // try-ok: marker is exempt", () => {
        const sites = scanContent(
            "let x = try? foo()  // try-ok: cleanup on shutdown\n",
            "Sample.swift",
        );
        expect(sites.length).toBe(0);
    });

    test("try? with marker on preceding line is exempt", () => {
        const src =
            "// try-ok: extremely long rationale that pushed annotation up a line\n" +
            "let x = try? someVeryLongMethodCallThatExceededTheColumnLimit()\n";
        const sites = scanContent(src, "Sample.swift");
        expect(sites.length).toBe(0);
    });

    test("multiple try? sites with mixed annotations + bash-compat quirk", () => {
        // Matches the bash ratchet exactly: line 4 is exempted because
        // the immediately preceding line carries `try-ok:` (even though
        // that marker was for line 3's own `try?`). Line 6 is also
        // exempted by the standalone `// try-ok:` on line 5. Only line 7
        // is counted — its preceding line is plain code.
        const src =
            "let preamble = 0\n" +
            "let standalone = try? one()\n" +
            "let with_marker = try? two()  // try-ok: cleanup\n" +
            "let following = try? three()\n" +
            "// try-ok: standalone marker\n" +
            "let after_marker = try? four()\n" +
            "let counted = try? five()\n";
        const sites = scanContent(src, "Sample.swift");
        const lines = sites.map((s) => s.lineno);
        expect(lines).toEqual([2, 7]);
    });

    test("try with no question mark does not match", () => {
        const sites = scanContent(
            "do { try foo() } catch { log(error) }\n",
            "Sample.swift",
        );
        expect(sites.length).toBe(0);
    });

    test("word containing 'try' but not the keyword does not match", () => {
        const sites = scanContent(
            "let retry = retry?.value ?? 0\n",
            "Sample.swift",
        );
        expect(sites.length).toBe(0);
    });

    test("preceding line marker only counts for the IMMEDIATELY-next line", () => {
        const src =
            "// try-ok: c\n" +
            "let benign = 1\n" +
            "let unannotated = try? four()\n";
        const sites = scanContent(src, "Sample.swift");
        expect(sites.length).toBe(1);
        expect(sites[0].lineno).toBe(3);
    });

    test("path is reflected verbatim in each emitted site", () => {
        const sites = scanContent("let x = try? foo()\n", "Foo/Bar.swift");
        expect(sites[0].path).toBe("Foo/Bar.swift");
    });
});
