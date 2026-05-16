#!/usr/bin/env bun
// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/try_question_ratchet.ts — TypeScript+Bun port of
// try_question_ratchet.sh. Counts unannotated `try?` sites in the
// Swift production tree and enforces a strict cap.
//
// A site is **annotated** (exempt from the count) when either the
// same source line OR the immediately preceding line carries the
// marker `try-ok: <reason>`. The fallback to the preceding line
// accommodates the swift-format 110-column wrap rule.
//
// Lowering the cap: when you convert a site to logging `do/catch`
// OR annotate it as legitimate cleanup, drop `TRY_QUESTION_CAP`
// to the new actual count in the same commit.
//
// Modes:
//   bun scripts/try_question_ratchet.ts          count + compare
//   bun scripts/try_question_ratchet.ts --list   list unannotated sites
//
// Exit codes:
//   0  unannotated count == cap (pass) — or --list always exits 0
//   1  unannotated count != cap (fail; message says what to do)
//   2  invocation error

import { readFile } from "node:fs/promises";
import { join, relative } from "node:path";

import { Glob } from "bun";

import { die, fail, step } from "./lib/log.ts";
import { repoRoot } from "./lib/paths.ts";

/**
 * The cap. Number of unannotated `try?` occurrences allowed in
 * the Swift production tree. Drop in lockstep when you convert
 * or annotate a site.
 */
export const TRY_QUESTION_CAP = 0;

const TRY_QUESTION_RE = /\btry\?/;
const TRY_OK_MARKER = "try-ok:";

export interface UnannotatedSite {
    /** Repo-relative path of the .swift file. */
    readonly path: string;
    /** 1-based line number of the `try?` occurrence. */
    readonly lineno: number;
    /** Verbatim source line (trimmed of trailing newline). */
    readonly content: string;
}

export type ArgsParse =
    | { readonly ok: true; readonly listOnly: boolean }
    | { readonly ok: false; readonly reason: string; readonly exitCode: number };

/**
 * Pure argv parser. `--list`, `-h` / `--help`, or no args; anything
 * else is an invocation error (exit code 2).
 */
export function parseArgs(argv: readonly string[]): ArgsParse {
    if (argv.length === 0) {
        return { ok: true, listOnly: false };
    }
    const first = argv[0];
    if (first === "--list") {
        return { ok: true, listOnly: true };
    }
    if (first === "-h" || first === "--help") {
        return {
            ok: false,
            reason:
                "usage: bun scripts/try_question_ratchet.ts [--list]\n" +
                "       count unannotated `try?` sites in COOL-TUNNEL/ vs the cap.",
            exitCode: 0,
        };
    }
    return {
        ok: false,
        reason: `unknown argument: ${first}`,
        exitCode: 2,
    };
}

/**
 * Scan one file's contents for unannotated `try?` occurrences.
 * `relPath` is what the caller wants printed (repo-relative).
 * Exported so the tests can exercise the matcher without disk I/O.
 */
export function scanContent(
    content: string,
    relPath: string,
): readonly UnannotatedSite[] {
    const lines = content.split("\n");
    const out: UnannotatedSite[] = [];
    for (let i = 0; i < lines.length; i++) {
        const line = lines[i] ?? "";
        if (!TRY_QUESTION_RE.test(line)) continue;
        if (line.includes(TRY_OK_MARKER)) continue;
        if (i > 0 && (lines[i - 1] ?? "").includes(TRY_OK_MARKER)) continue;
        out.push({ path: relPath, lineno: i + 1, content: line });
    }
    return out;
}

/**
 * Walk `<repoRoot>/COOL-TUNNEL/**\/*.swift` and accumulate every
 * unannotated site. Returns paths sorted for stable output.
 */
export async function findUnannotatedSites(
    root: string,
): Promise<readonly UnannotatedSite[]> {
    const swiftRoot = join(root, "COOL-TUNNEL");
    const glob = new Glob("**/*.swift");
    const matches: string[] = [];
    for await (const match of glob.scan({ cwd: swiftRoot })) {
        matches.push(match);
    }
    matches.sort();
    const sites: UnannotatedSite[] = [];
    for (const rel of matches) {
        const abs = join(swiftRoot, rel);
        const content = await readFile(abs, "utf8");
        const relFromRepo = relative(root, abs);
        sites.push(...scanContent(content, relFromRepo));
    }
    return sites;
}

function formatSite(site: UnannotatedSite): string {
    return `${site.path}:${site.lineno}:${site.content}`;
}

async function main(): Promise<void> {
    const parsed = parseArgs(process.argv.slice(2));
    if (!parsed.ok) {
        process.stderr.write(`${parsed.reason}\n`);
        process.exit(parsed.exitCode);
    }

    const root = repoRoot(import.meta.url);
    const sites = await findUnannotatedSites(root);
    const actual = sites.length;

    if (parsed.listOnly) {
        for (const site of sites) {
            process.stdout.write(`${formatSite(site)}\n`);
        }
        process.exit(0);
    }

    if (actual > TRY_QUESTION_CAP) {
        fail(`unannotated try? count rose to ${actual} (cap=${TRY_QUESTION_CAP})`);
        process.stderr.write(
            "    add `// try-ok: <reason>` to the line if this is a legitimate cleanup use,\n",
        );
        process.stderr.write(
            "    or convert to do { try X } catch { Logger.cooltunnel(\"X\").warning(...) }\n",
        );
        process.stderr.write(
            "    audit ref: M1 in the 2026-05-11 robustness review\n\n",
        );
        process.stderr.write("    unannotated sites:\n");
        for (const site of sites) {
            process.stderr.write(`${formatSite(site)}\n`);
        }
        process.exit(1);
    }

    if (actual < TRY_QUESTION_CAP) {
        fail(`unannotated try? count dropped to ${actual} — lock the win in:`);
        process.stderr.write(
            `    set TRY_QUESTION_CAP=${actual} in scripts/try_question_ratchet.ts\n`,
        );
        process.exit(1);
    }

    step(`try? ratchet: ${actual} unannotated == cap ✓`);
}

if (import.meta.main) {
    main().catch((caught) => {
        if (caught instanceof Error) {
            die(`try_question_ratchet: ${caught.message}`);
        } else {
            die(`try_question_ratchet: unknown failure: ${String(caught)}`);
        }
    });
}
