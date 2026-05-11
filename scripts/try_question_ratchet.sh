#!/usr/bin/env bash
# scripts/try_question_ratchet.sh
#
# Counts `try?` sites in the Swift production tree and enforces a
# strict cap. New `try?` is a hard fail; reductions are also a hard
# fail until the cap is updated in this script (the failure message
# says exactly what to set it to). The point is to ratchet the
# count down toward zero as the obvious cases get converted to
# `do { try ... } catch { Logger.cooltunnel(...).warning(...) }`,
# closing M1 in the 2026-05-11 robustness review.
#
# Pure cleanup paths (closing a FileHandle whose error doesn't matter)
# are legitimate uses of `try?`; this ratchet doesn't distinguish —
# the cap moves down as the obvious cases get converted, and the long
# tail of justified cleanup `try?` stays parked at whatever number
# remains.
#
# If a Swift test target is added later under tests/, exclude its
# `*.swift` from the count rather than letting test cleanup paths
# inflate the cap.
#
# Usage:
#   scripts/try_question_ratchet.sh
#
# Exit codes:
#   0  count == cap (pass)
#   1  count != cap (fail — message tells the operator what to do)

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# **The cap.** Lower this number when a PR converts `try?` sites
# to logging `do/catch`. The audit.sh + CI step that calls this
# script fails if the actual count diverges in either direction.
TRY_QUESTION_CAP=54

ACTUAL=$(grep -rEo '\btry\?' "${REPO_ROOT}/COOL-TUNNEL" --include='*.swift' | wc -l | tr -d ' ')
if [[ -z "${ACTUAL}" ]]; then
    ACTUAL=0
fi

if (( ACTUAL > TRY_QUESTION_CAP )); then
    printf '\033[1;31m!!!\033[0m try? count rose to %s (cap=%s)\n' "${ACTUAL}" "${TRY_QUESTION_CAP}" >&2
    echo "    prefer do { try ... } catch { Logger.cooltunnel(\"X\").warning(...) } over try?" >&2
    echo "    audit ref: M1 in the 2026-05-11 robustness review" >&2
    echo "" >&2
    echo "    every try? site:" >&2
    grep -rnE '\btry\?' "${REPO_ROOT}/COOL-TUNNEL" --include='*.swift' >&2
    exit 1
fi

if (( ACTUAL < TRY_QUESTION_CAP )); then
    printf '\033[1;31m!!!\033[0m try? count dropped to %s — lock the win in:\n' "${ACTUAL}" >&2
    echo "    set TRY_QUESTION_CAP=${ACTUAL} in scripts/try_question_ratchet.sh" >&2
    exit 1
fi

printf '\033[1;34m==>\033[0m try? ratchet: %s == cap ✓\n' "${ACTUAL}"
exit 0
