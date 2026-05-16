// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (C) 2026 coolwhite LLC
// See LICENSE for full terms.
//
// scripts/lib/paths.ts — repo-root resolution.
//
// All maintenance scripts compute the repo root the same way: ascend
// from their own file path until you hit the directory containing
// `scripts/`. That's the canonical "wherever this file lives, the
// repo is one level up" pattern, identical to the bash:
//
//   REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * Returns the repository root, given the URL of the calling
 * script (use `import.meta.url`). The TS files live in `scripts/`
 * or `scripts/lib/`; either depth resolves to the same root.
 */
export function repoRoot(importMetaUrl: string): string {
    const here = dirname(fileURLToPath(importMetaUrl));
    // If we're in scripts/lib, climb two. If we're in scripts/, climb one.
    // Detect by checking which ancestor contains the canonical Cargo.toml.
    let candidate = here;
    for (let depth = 0; depth < 5; depth++) {
        if (Bun.file(join(candidate, "core", "Cargo.toml")).size > 0) {
            return resolve(candidate);
        }
        candidate = dirname(candidate);
    }
    throw new Error(
        `repoRoot: could not locate the cool-tunnel repo root from ${here}`,
    );
}
