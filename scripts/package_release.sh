#!/usr/bin/env bash
# scripts/package_release.sh — thin shim over the TypeScript+Bun port.
#
# Implementation lives in scripts/package_release.ts. This file
# preserves the legacy invocation path so bin/ct, cut_release.ts,
# and any contributor invoking `bash scripts/package_release.sh`
# keep working.
#
# Forwards every argument; preserves the child's exit code so the
# documented contract (0 pass / 1 bad arguments or precondition /
# 2 packaging step failed) is unchanged.
#
# Bun is required. Install with `brew install bun` or
# `curl -fsSL https://bun.sh/install | bash`.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v bun >/dev/null 2>&1; then
    printf '\033[1;31m!!!\033[0m %s\n' "bun not found in PATH — install with: brew install bun" >&2
    printf '    %s\n' "See https://bun.sh for other install options." >&2
    exit 1
fi

exec bun "${REPO_ROOT}/scripts/package_release.ts" "$@"
