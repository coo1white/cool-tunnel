// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/audit.test.ts — pure-logic tests for the audit port.
// The end-to-end suite is exercised every release cut and by every
// `bin/ct doctor` invocation; this file pins the four pure surfaces
// (argv parser, xcodebuild output classifier, lipo output parser,
// schema-field presence check) so a future refactor of any of them
// fails at `bun test` rather than at release-cut time.

import { describe, expect, test } from "bun:test";

import {
    checkSchemaFields,
    classifyXcodebuildOutput,
    parseArgs,
    parseLipoInfo,
} from "./audit.ts";

describe("audit parseArgs", () => {
    test("no args → ok, non-strict", () => {
        const out = parseArgs([]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.options.strict).toBe(false);
    });

    test("--strict → ok, strict on", () => {
        const out = parseArgs(["--strict"]);
        expect(out.ok).toBe(true);
        if (out.ok) expect(out.options.strict).toBe(true);
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

    test("unknown flag → not ok, exit 2", () => {
        const out = parseArgs(["--nope"]);
        expect(out.ok).toBe(false);
        if (!out.ok) {
            expect(out.exitCode).toBe(2);
            expect(out.reason).toContain("unknown arg");
        }
    });
});

describe("audit classifyXcodebuildOutput", () => {
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
        // The bash grep uses `^xcodebuild: error`; mid-line mentions
        // (e.g. inside a quoted shell command) shouldn't trip it.
        expect(
            classifyXcodebuildOutput(
                "wrapper ran: xcodebuild: error string from previous run\n",
            ),
        ).toBe("ok");
    });

    test("no-test-action wins over failed shape (order matters)", () => {
        // If a future xcodebuild version emits both shapes together,
        // we still treat it as a documented SKIP rather than a hard
        // failure. Matches bash's elif ordering.
        const out =
            "** TEST FAILED **\n" +
            "Scheme COOL-TUNNEL is not currently configured for the test action\n";
        expect(classifyXcodebuildOutput(out)).toBe("no-test-action");
    });

    test("clean output → ok", () => {
        expect(classifyXcodebuildOutput("** TEST SUCCEEDED **\n")).toBe("ok");
    });
});

describe("audit parseLipoInfo", () => {
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

describe("audit checkSchemaFields", () => {
    const FIELDS = ["profiles", "host", "username", "password"];

    test("all fields present in both fixture and Swift → no missing", () => {
        const fixture =
            '{"profiles":[{"host":"x","username":"u","password":"p"}]}';
        const swift = new Map([
            [
                "Subscription.swift",
                `struct Profile: Decodable {
                    let host: String
                    let username: String
                    let password: String
                }
                let profiles: [Profile]
                `,
            ],
        ]);
        expect(checkSchemaFields(fixture, swift, FIELDS)).toEqual([]);
    });

    test("missing field in fixture → reports fixture", () => {
        const fixture = '{"profiles":[{"host":"x","username":"u"}]}'; // no password
        const swift = new Map([
            [
                "Subscription.swift",
                "let profiles: [P]\nlet host: String\nlet username: String\nlet password: String\n",
            ],
        ]);
        const missing = checkSchemaFields(fixture, swift, FIELDS);
        expect(missing).toContain("fixture missing field: password");
        expect(missing).not.toContain("Swift decoder missing field: password");
    });

    test("missing field in Swift → reports Swift", () => {
        const fixture =
            '{"profiles":[{"host":"x","username":"u","password":"p"}]}';
        const swift = new Map([
            // No `let password` anywhere
            [
                "Subscription.swift",
                "let profiles: [P]\nlet host: String\nlet username: String\n",
            ],
        ]);
        const missing = checkSchemaFields(fixture, swift, FIELDS);
        expect(missing).toContain("Swift decoder missing field: password");
        expect(missing).not.toContain("fixture missing field: password");
    });

    test("substring mismatch does not satisfy field check", () => {
        // `passwordHash` should NOT count as the bare `password` field.
        const fixture = '{"passwordHash":"x"}';
        const swift = new Map([["S.swift", "let passwordHash: String\n"]]);
        const missing = checkSchemaFields(fixture, swift, ["password"]);
        expect(missing).toContain("fixture missing field: password");
        expect(missing).toContain("Swift decoder missing field: password");
    });

    test("at least one Swift source containing the field is enough", () => {
        const fixture = '{"host":"x"}';
        const swift = new Map([
            ["A.swift", "// unrelated\n"],
            ["B.swift", "let host: String\n"],
        ]);
        expect(checkSchemaFields(fixture, swift, ["host"])).toEqual([]);
    });
});
