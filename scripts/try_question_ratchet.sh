#!/usr/bin/env bash
# scripts/try_question_ratchet.sh
#
# Counts unannotated `try?` sites in the Swift production tree and
# enforces a strict cap. The ratchet captures the **silent-error
# anti-pattern** — `try? someThrowingCall()` where the caller didn't
# mean cleanup-best-effort but never reads or logs the error.
#
# How sites are exempt
# --------------------
# Add `// try-ok: <one-line reason>` to the same source line as the
# `try?` to opt that occurrence out of the count. The reason is
# free-form prose; it has to fit on the line so the rationale is
# unmissable next to the code. Examples:
#
#   try? handle.close()  // try-ok: close on cleanup; no recovery possible
#
#   defer { try? FileManager.default.removeItem(at: tempRoot) }  // try-ok: temp dir teardown
#
# Lines without `try-ok:` count toward the cap. Adding a new `try?`
# without the annotation hard-fails CI; the failure message lists
# every unannotated occurrence so the reviewer can decide whether
# to annotate or convert.
#
# Why annotation rather than a single global cap
# ----------------------------------------------
# The pre-v2.0.39 ratchet capped total `try?` count and dropped from
# 59 to 54 across M1's sweep. The residual is intentional cleanup-
# path usage (close FileHandle, sleep cancellation, defer-block
# tempdir removal, shutdown system-proxy disable). Lumping those
# together with future silent-error introductions meant *any* new
# cleanup `try?` cost cap-budget. Annotation-aware counting
# separates the two: legitimate cleanup is annotated and zero-cost;
# the cap below represents the residual that hasn't been *either*
# converted to logging do/catch *or* annotated yet, and should
# trend to zero.
#
# Modes
# -----
#   scripts/try_question_ratchet.sh
#       Default — count and compare. Exit 0 on match, 1 on drift.
#
#   scripts/try_question_ratchet.sh --list
#       Print every unannotated occurrence and exit 0. Useful for
#       deciding which sites to annotate or convert next.
#
# Exit codes:
#   0  unannotated count == cap (pass)
#   1  unannotated count != cap (fail; message says what to do)
#   2  invocation error

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# **The cap.** Number of `try?` sites in the Swift production tree
# that are NOT yet annotated `// try-ok: <reason>`. Lower this when
# you either convert a site to logging `do/catch` or annotate it as
# legitimate cleanup.
TRY_QUESTION_CAP=0

# Argument parsing — only one optional flag.
LIST_ONLY=0
case "${1:-}" in
    --list) LIST_ONLY=1 ;;
    -h|--help)
        sed -n '2,50p' "$0"
        exit 0
        ;;
    "") ;;
    *)
        echo "unknown argument: $1" >&2
        exit 2
        ;;
esac

# `grep -rnE` outputs `path:lineno:contents`. A `try?` line is
# annotated if either:
#   (a) the same source line carries `try-ok:`, or
#   (b) the immediately preceding line carries `try-ok:` (the
#       fall-back form used for sites whose end-of-line annotation
#       would exceed the swift-format 110-column rule).
#
# Filtering is line-based — confirmed by `awk` audit that no source
# line currently carries more than one `try?` token. If multi-`try?`
# lines ever land, decide per-site whether the annotation applies to
# every `try?` on the line (typical case) or split across lines.
#
# Implementation: emit each `try?` line as `file:lineno:contents`,
# strip out the same-line form first, then for the survivors look
# up `file:(lineno-1):*` and strip any that match `try-ok:`.
ALL_OCCURRENCES=$(grep -rnE '\btry\?' "${REPO_ROOT}/COOL-TUNNEL" --include='*.swift' || true)
SAME_LINE_FILTERED=$(echo "${ALL_OCCURRENCES}" | grep -vE 'try-ok:' || true)
if [[ -n "${SAME_LINE_FILTERED}" ]]; then
    UNANNOTATED=""
    while IFS= read -r entry; do
        # entry is `path:lineno:contents`; tease apart.
        path=$(echo "${entry}" | cut -d: -f1)
        lineno=$(echo "${entry}" | cut -d: -f2)
        prev=$((lineno - 1))
        if (( prev < 1 )); then
            UNANNOTATED="${UNANNOTATED}${entry}"$'\n'
            continue
        fi
        prev_line=$(sed -n "${prev}p" "${path}")
        if echo "${prev_line}" | grep -q 'try-ok:'; then
            continue  # annotated on the preceding line
        fi
        UNANNOTATED="${UNANNOTATED}${entry}"$'\n'
    done <<< "${SAME_LINE_FILTERED}"
    # Strip the trailing newline so wc -l doesn't double-count blank input.
    UNANNOTATED="${UNANNOTATED%$'\n'}"
else
    UNANNOTATED=""
fi

if [[ "${LIST_ONLY}" -eq 1 ]]; then
    if [[ -n "${UNANNOTATED}" ]]; then
        echo "${UNANNOTATED}"
    fi
    exit 0
fi

if [[ -z "${UNANNOTATED}" ]]; then
    ACTUAL=0
else
    ACTUAL=$(echo "${UNANNOTATED}" | wc -l | tr -d ' ')
fi

if (( ACTUAL > TRY_QUESTION_CAP )); then
    printf '\033[1;31m!!!\033[0m unannotated try? count rose to %s (cap=%s)\n' "${ACTUAL}" "${TRY_QUESTION_CAP}" >&2
    # SC2016 disabled: the backticks are literal markdown formatting
    # for the help text, not bash command substitution.
    # shellcheck disable=SC2016
    echo '    add `// try-ok: <reason>` to the line if this is a legitimate cleanup use,' >&2
    echo '    or convert to do { try X } catch { Logger.cooltunnel("X").warning(...) }' >&2
    echo "    audit ref: M1 in the 2026-05-11 robustness review" >&2
    echo "" >&2
    echo "    unannotated sites:" >&2
    echo "${UNANNOTATED}" >&2
    exit 1
fi

if (( ACTUAL < TRY_QUESTION_CAP )); then
    printf '\033[1;31m!!!\033[0m unannotated try? count dropped to %s — lock the win in:\n' "${ACTUAL}" >&2
    echo "    set TRY_QUESTION_CAP=${ACTUAL} in scripts/try_question_ratchet.sh" >&2
    exit 1
fi

printf '\033[1;34m==>\033[0m try? ratchet: %s unannotated == cap ✓\n' "${ACTUAL}"
exit 0
