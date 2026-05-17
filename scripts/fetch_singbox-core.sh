#!/usr/bin/env bash
# scripts/fetch_singbox-core.sh — thin shim over the TypeScript+Bun port.
#
# The implementation lives in scripts/fetch_singbox-core.ts. This file
# preserves a shell entry point so existing CI workflows, documentation,
# the bin/ct wrapper, and operator muscle-memory all keep working
# unchanged when calling `bash scripts/fetch_singbox-core.sh`.
#
# Forwards every argument; preserves the child's exit code so the
# documented exit-code contract (0 success / 1 invocation /
# 2 download / 3 pin verification / 4 confirm-required) is unchanged.
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

exec bun "${REPO_ROOT}/scripts/fetch_singbox-core.ts" "$@"
