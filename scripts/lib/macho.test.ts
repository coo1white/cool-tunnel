// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/macho.test.ts — tests for the Mach-O / xcodebuild
// output parsers. Tests rehomed from audit.test.ts when the parsers
// moved to scripts/lib/.

import { describe, expect, test } from "bun:test";

import { classifyXcodebuildOutput, parseLipoInfo } from "./macho.ts";

describe("lib/macho parseLipoInfo", () => {
    test("universal fat file with arm64 + x86_64 → universal", () => {
        const out =
            "Architectures in the fat file: /path/to/naive are: arm64 x86_64 \n";
        const parsed = parseLipoInfo(out);
        expect(parsed.universal).toBe(true);
        expect(parsed.archs).toContain("arm64");
        expect(parsed.archs).toContain("x86_64");
    });

    test("thin arm64 binary → not universal", () => {
        const out = "Non-fat file: /path/to/naive is architecture: arm64\n";
        const parsed = parseLipoInfo(out);
        expect(parsed.universal).toBe(false);
        expect(parsed.archs).toEqual(["arm64"]);
    });

    test("thin x86_64 binary → not universal", () => {
        const out = "Non-fat file: /path/to/naive is architecture: x86_64\n";
        const parsed = parseLipoInfo(out);
        expect(parsed.universal).toBe(false);
        expect(parsed.archs).toEqual(["x86_64"]);
    });

    test("error / unknown output → empty archs, not universal", () => {
        const parsed = parseLipoInfo("lipo: can't figure out the file type\n");
        expect(parsed.universal).toBe(false);
        expect(parsed.archs).toEqual([]);
    });

    test("ignores words that look like archs but aren't in the known set", () => {
        const out = "Some bogus line mentioning aarch64 and amd64\n";
        const parsed = parseLipoInfo(out);
        expect(parsed.universal).toBe(false);
        expect(parsed.archs).toEqual([]);
    });
});

describe("lib/macho classifyXcodebuildOutput", () => {
    test("missing test action → no-test-action", () => {
        const out =
            "some preamble\n" +
            "Scheme COOL-TUNNEL is not currently configured for the test action\n" +
            "tail\n";
        expect(classifyXcodebuildOutput(out)).toBe("no-test-action");
    });

    test("TEST FAILED banner → failed", () => {
        expect(classifyXcodebuildOutput("** TEST FAILED **\n")).toBe("failed");
    });

    test("Testing failed line → failed", () => {
        expect(
            classifyXcodebuildOutput("Testing failed:\n  some-test crashed\n"),
        ).toBe("failed");
    });

    test("xcodebuild: error at line start → failed", () => {
        expect(
            classifyXcodebuildOutput(
                "first line\nxcodebuild: error: Unable to find a destination\n",
            ),
        ).toBe("failed");
    });

    test("xcodebuild: error mid-line → NOT failed (anchor on line start)", () => {
        expect(
            classifyXcodebuildOutput(
                "wrapper ran: xcodebuild: error string from previous run\n",
            ),
        ).toBe("ok");
    });

    test("no-test-action wins over failed shape (order matters)", () => {
        const out =
            "** TEST FAILED **\n" +
            "Scheme COOL-TUNNEL is not currently configured for the test action\n";
        expect(classifyXcodebuildOutput(out)).toBe("no-test-action");
    });

    test("clean output → ok", () => {
        expect(classifyXcodebuildOutput("** TEST SUCCEEDED **\n")).toBe("ok");
    });
});
