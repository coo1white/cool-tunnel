// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/macho.ts — pure parsers for macOS Mach-O / xcodebuild
// command output.
//
// Lifted from audit.ts which originally hosted both helpers. Multiple
// ports (security_check.ts cross-imports parseLipoInfo) point at this
// now-canonical lib/ home.

/**
 * Parse `lipo -info <path>` output for the architectures it lists.
 * The line is one of two shapes:
 *
 *   Architectures in the fat file: <path> are: arm64 x86_64
 *   Non-fat file: <path> is architecture: arm64
 *
 * Either shape is matched by tokenising on whitespace and returning
 * only the words that appear in the known macOS arch set. The bash
 * original's universal check (`*x86_64*` && `*arm64*`) is preserved
 * as `.universal`.
 */
export function parseLipoInfo(output: string): {
    readonly archs: readonly string[];
    readonly universal: boolean;
} {
    const known = new Set([
        "arm64",
        "arm64e",
        "x86_64",
        "x86_64h",
        "i386",
        "ppc",
        "ppc64",
    ]);
    const archs = output
        .split(/\s+/)
        .map((tok) => tok.trim())
        .filter((tok) => known.has(tok));
    const set = new Set(archs);
    return {
        archs,
        universal: set.has("arm64") && set.has("x86_64"),
    };
}

export type XcodebuildVerdict = "no-test-action" | "failed" | "ok";

/**
 * Classify the combined stdout+stderr of `xcodebuild test`. The bash
 * original greps for three distinct shapes:
 *
 *   - "is not currently configured for the test action" — scheme has
 *     no XCTest target wired up; treated as a documented SKIP
 *   - "** TEST FAILED **" / "Testing failed" / line starting with
 *     "xcodebuild: error" — real failure
 *   - anything else — success (or warnings we don't gate on)
 *
 * Order matters: the no-test-action probe wins over the failure
 * probe so a scheme without a test action doesn't get mis-classified.
 */
export function classifyXcodebuildOutput(output: string): XcodebuildVerdict {
    if (output.includes("is not currently configured for the test action")) {
        return "no-test-action";
    }
    if (
        output.includes("** TEST FAILED **") ||
        output.includes("Testing failed") ||
        /(^|\n)xcodebuild: error/.test(output)
    ) {
        return "failed";
    }
    return "ok";
}
