// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/audit.test.ts — pure-logic tests for the audit port.
// The end-to-end suite is exercised every release cut and by every
// `bin/ct doctor` invocation; this file pins the two audit-private
// pure surfaces (argv parser + schema-field presence check) so a
// future refactor fails at `bun test` rather than at release-cut
// time.
//
// classifyXcodebuildOutput and parseLipoInfo were lifted to
// scripts/lib/macho.ts; their tests live in scripts/lib/macho.test.ts.

import { describe, expect, test } from "bun:test";

import { checkSchemaFields, parseArgs } from "./audit.ts";

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
