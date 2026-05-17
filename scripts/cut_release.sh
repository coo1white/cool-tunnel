#!/usr/bin/env bash
# scripts/cut_release.sh — thin shim over the TypeScript+Bun port.
#
# The implementation lives in scripts/cut_release.ts. This file
# preserves the legacy invocation path so the bin/ct wrapper, this
# repo's documentation, and operator muscle-memory all keep working
# when calling `bash scripts/cut_release.sh <version>`.
#
# Forwards every argument; preserves the child's exit code so the
# documented exit-code contract (0 success / 1 version mismatch /
# 2 fetch_singbox-core / 3 cargo clean / 4 build / 5 package / 6 audit /
# 7 security_check) is unchanged.
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

exec bun "${REPO_ROOT}/scripts/cut_release.ts" "$@"
