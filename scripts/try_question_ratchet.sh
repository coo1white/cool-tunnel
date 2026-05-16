#!/usr/bin/env bash
# scripts/try_question_ratchet.sh — thin shim over the TypeScript+Bun port.
#
# Implementation lives in scripts/try_question_ratchet.ts. This file
# preserves the legacy invocation path so bin/ct, CI (ci.yml), and
# scripts/audit.sh all keep working when calling
# `bash scripts/try_question_ratchet.sh [--list]`.
#
# Forwards every argument; preserves the child's exit code so the
# documented contract (0 pass / 1 drift / 2 invocation error)
# is unchanged.
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

exec bun "${REPO_ROOT}/scripts/try_question_ratchet.ts" "$@"
