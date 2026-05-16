// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/secrets.ts — pure helpers for secret-pattern scanning.
//
// Lifted from security_check.ts which originally hosted these three
// helpers. The orchestration that loads the pattern bank, walks the
// repo, and applies the binary-file skip heuristic stays in
// security_check.ts; these are the pure functions it composes.
//
// **No real-looking secret patterns appear in this file.** The
// production pattern bank lives in security_check.ts; this module
// only exposes the pattern-application primitives.

export interface SecretMatch {
    readonly path: string;
    readonly lineno: number;
    readonly content: string;
}

/**
 * Translate the small subset of POSIX-ERE character classes the
 * production bash patterns use (`[[:space:]]`, `[[:digit:]]`,
 * `[[:alpha:]]`, `[[:alnum:]]`) into the JS-RegExp equivalents.
 * The rest of the production patterns are already cross-compatible.
 */
export function posixToJsRegex(pattern: string): string {
    return pattern
        .replaceAll("[[:space:]]", "\\s")
        .replaceAll("[[:digit:]]", "\\d")
        .replaceAll("[[:alpha:]]", "[A-Za-z]")
        .replaceAll("[[:alnum:]]", "[A-Za-z0-9]");
}

/**
 * Scan one file's text for any of the given regexes. Each match is
 * reported as `(path, 1-based lineno, line content)`. First-pattern-
 * wins per line: if a line matches two regexes, only the first one
 * fires (matches the bash `grep -E` semantics with combined
 * patterns).
 */
export function scanContentForSecrets(
    content: string,
    relPath: string,
    regexes: readonly RegExp[],
): readonly SecretMatch[] {
    const out: SecretMatch[] = [];
    const lines = content.split("\n");
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i] ?? "";
        for (const re of regexes) {
            if (re.test(line)) {
                out.push({ path: relPath, lineno: i + 1, content: line });
                break;
            }
        }
    }
    return out;
}

/**
 * Heuristic: a file is "binary" if its first 8 KB contains a null
 * byte. Mirrors `grep --binary-files=without-match`'s effect — we
 * skip such files entirely from the secret scan.
 */
export function looksBinary(bytes: Uint8Array): boolean {
    const limit = Math.min(bytes.length, 8192);
    for (let i = 0; i < limit; i++) {
        if (bytes[i] === 0) return true;
    }
    return false;
}
