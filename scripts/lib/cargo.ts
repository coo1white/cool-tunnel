// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/cargo.ts — pure parsers for Cargo.toml, Cargo.lock,
// and rust-toolchain.toml.
//
// Lifted from the original script-private homes in
// package_release.ts (parseCargoTomlVersion) and security_check.ts
// (parseLockfileVersion + parseToolchainChannel). Multiple ports
// cross-imported them; canonical home is now scripts/lib/.

/**
 * Extract the first top-level `version = "..."` field from a
 * Cargo.toml. The bash original used
 * `awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }'` — first
 * anchored match wins. Indented `version = "..."` lines inside a
 * dependency-table block don't match because the regex is anchored
 * to start-of-line.
 */
export function parseCargoTomlVersion(content: string): string | null {
    const re = /^version\s*=\s*"([^"]*)"/m;
    const match = re.exec(content);
    return match ? (match[1] ?? null) : null;
}

/**
 * Extract the version string from a Cargo.lock entry for the named
 * package. Cargo.lock has the shape:
 *
 *   [[package]]
 *   name = "<name>"
 *   version = "X.Y.Z"
 *   ...
 *
 * The bash original used `awk '/^name = "cool-tunnel-core"/{getline; print}'`
 * — find the exact `name = "<name>"` line, then return the next line
 * (which is the version line). We preserve that exact semantics:
 * next line is the version line; extract the quoted value from it.
 */
export function parseLockfileVersion(
    content: string,
    name: string,
): string | null {
    const lines = content.split("\n");
    for (let i = 0; i < lines.length - 1; i++) {
        if (lines[i] === `name = "${name}"`) {
            const next = lines[i + 1] ?? "";
            const match = /"([^"]+)"/.exec(next);
            if (match) return match[1] ?? null;
        }
    }
    return null;
}

/**
 * Extract the `channel = "..."` pin from a rust-toolchain.toml.
 * Anchored to start of line; first match wins; indented lines
 * (inside a nested table) don't match.
 */
export function parseToolchainChannel(content: string): string | null {
    const re = /^channel\s*=\s*"([^"]*)"/m;
    const match = re.exec(content);
    return match ? (match[1] ?? null) : null;
}
