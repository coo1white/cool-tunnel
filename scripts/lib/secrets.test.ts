// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/secrets.test.ts — tests for the secret-scan primitives.
// Tests rehomed from security_check.test.ts when the helpers moved to
// scripts/lib/.
//
// **No real-looking secret patterns appear in this file.** The
// scanContentForSecrets tests use synthetic patterns (e.g.
// `/FAKE-SENTINEL-[0-9]+/`) and synthetic content so this test file
// itself never trips the production secret scan when it walks the
// repo.

import { describe, expect, test } from "bun:test";

import {
    looksBinary,
    posixToJsRegex,
    scanContentForSecrets,
} from "./secrets.ts";

describe("lib/secrets posixToJsRegex", () => {
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

describe("lib/secrets scanContentForSecrets", () => {
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

describe("lib/secrets looksBinary", () => {
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
        bytes.fill(65);
        bytes[8500] = 0;
        expect(looksBinary(bytes)).toBe(false);
    });

    test("empty → false (no null to find)", () => {
        expect(looksBinary(new Uint8Array(0))).toBe(false);
    });
});
