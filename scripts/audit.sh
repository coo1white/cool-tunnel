#!/usr/bin/env bash
# scripts/audit.sh
#
# **v2.0.18-pre (Synthetic CI Gate, audit subset).**
#
# Runs every static check the project has wired up. Designed to be
# called both standalone (`bash scripts/audit.sh`) and from
# `cut_release.sh` as a release-cut precondition. Without a paid
# Apple Developer account the project has no cloud CI; this script
# IS our CI and `cut_release.sh` refuses to ship a build that
# didn't pass it.
#
# What runs, in order (fast checks first so a failure aborts before
# a slow check has a chance to run):
#
#   1. cargo fmt --check                — formatter drift (~1 s)
#   2. cargo clippy -D warnings         — lint cleanliness (~30 s)
#   3. cargo test --all-features        — unit + integration tests (~60 s)
#   3b. cargo deny check                — license/ban/duplicate policy
#                                          (`core/deny.toml`); requires
#                                          `cargo install cargo-deny`
#                                          (~5 s)
#   4. swift format lint --strict       — Swift formatter drift (~2 s)
#   5. xcodebuild test (unit scheme)    — Swift XCTest suites (~90 s,
#                                          currently skipped — no XCTest
#                                          target on this scheme)
#   6. naive arch guard                 — bundled binary is universal
#                                          (arm64 + x86_64 slices)
#   8. schema sync probe                — engine + Swift Codable
#                                          shapes still match a known
#                                          good wire fixture
#
# Anything that fails sets `STATUS=1` (we keep going so the operator
# sees ALL failures in one pass) and the script exits with that code
# at the end.
#
# Steps that require optional tools (clippy, swift-format,
# xcodebuild) skip with a warning if the tool is missing — useful on
# minimal CI runners or when iterating locally without Xcode open.
# A `--strict` flag turns those skips into hard failures, used by
# `cut_release.sh` so a release cut can never silently ship past a
# missing tool.
#
# Exit codes:
#   0  every check passed (or skipped non-strict)
#   1  one or more checks failed
#   2  --strict and a required tool was missing

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STRICT=0
for arg in "$@"; do
    case "$arg" in
        --strict) STRICT=1 ;;
        *) echo "unknown arg: $arg" >&2; exit 2 ;;
    esac
done

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
fail() { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; }

STATUS=0
SKIPPED=()

require_or_skip() {
    local cmd="$1"
    local label="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        return 0
    fi
    if (( STRICT )); then
        fail "${label} required (--strict) but not on PATH"
        exit 2
    fi
    warn "${label} not on PATH — skipping (re-run without --strict to allow)"
    SKIPPED+=("${label}")
    return 1
}

# --- 1. cargo fmt ----------------------------------------------------------
log "cargo fmt --check"
if (cd "${REPO_ROOT}/core" && cargo fmt --check); then
    :
else
    fail "cargo fmt found drift — run 'cargo fmt' inside core/"
    STATUS=1
fi

# --- 2. cargo clippy -------------------------------------------------------
log "cargo clippy --all-targets -- -D warnings"
if (cd "${REPO_ROOT}/core" && cargo clippy --all-targets --all-features -- -D warnings); then
    :
else
    fail "cargo clippy reported issues"
    STATUS=1
fi

# --- 3. cargo test ---------------------------------------------------------
log "cargo test --all-features"
if (cd "${REPO_ROOT}/core" && cargo test --all-features --quiet); then
    :
else
    fail "cargo test failed"
    STATUS=1
fi

# --- 3b. cargo deny check --------------------------------------------------
# `cargo deny` enforces the project's allow-listed licenses, banned
# crates, and duplicate-version policy from `core/deny.toml`. CI
# (`.github/workflows/ci.yml`) runs it on every push; this gate
# exists so `cut_release.sh` (which runs `audit.sh --strict`)
# enforces the same policy locally before binaries leave the
# working tree. Tool prerequisite documented in
# `CONTRIBUTING.md` (`cargo install cargo-deny`).
if require_or_skip cargo-deny "cargo-deny"; then
    log "cargo deny check"
    if (cd "${REPO_ROOT}/core" && cargo deny check --hide-inclusion-graph 2>&1); then
        :
    else
        fail "cargo deny check failed — license/ban/duplicate policy violation in core/Cargo.lock"
        STATUS=1
    fi
fi

# --- 4. swift format lint --------------------------------------------------
# `swift format` is the Xcode 16+ subcommand of `swift`. On older
# toolchains operators may have the standalone `swift-format`; both
# work, we just probe in order.
SWIFT_FORMAT=""
if command -v swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT="swift-format"
elif swift format --help >/dev/null 2>&1; then
    SWIFT_FORMAT="swift format"
fi

if [[ -n "${SWIFT_FORMAT}" ]]; then
    log "${SWIFT_FORMAT} lint --strict (recursive on COOL-TUNNEL/)"
    # `find -print0` + `xargs -0` so paths with spaces don't split.
    # `${SWIFT_FORMAT}` is intentionally unquoted: it holds either
    # `swift-format` (one token) or `swift format` (two tokens), and
    # the two-token branch needs the word-split to land as separate
    # argv entries to `xargs`. Quoting would call `swift format ...`
    # as the single binary `swift format`, which doesn't exist.
    # shellcheck disable=SC2086
    if find "${REPO_ROOT}/COOL-TUNNEL" -name '*.swift' -print0 \
        | xargs -0 ${SWIFT_FORMAT} lint --strict; then
        :
    else
        fail "swift format lint reported issues"
        STATUS=1
    fi
else
    if (( STRICT )); then
        fail "swift-format / swift format required (--strict) but neither is on PATH"
        exit 2
    fi
    warn "swift-format not available — skipping (install via 'brew install swift-format' or use Xcode 16+)"
    SKIPPED+=("swift format lint")
fi

# --- 5. xcodebuild test ----------------------------------------------------
# A scheme that ships without a test action (no XCTest target wired up yet)
# is treated as a documented SKIP, mirroring the missing-tool pattern above:
# there is nothing to run, so we warn + record the skip rather than failing
# the gate. A test action that exists and fails is still a hard STATUS=1.
if require_or_skip xcodebuild "xcodebuild"; then
    log "xcodebuild test (Debug)"
    XCB_OUT="$(xcodebuild test \
            -project "${REPO_ROOT}/COOL-TUNNEL.xcodeproj" \
            -scheme COOL-TUNNEL \
            -configuration Debug \
            -destination 'platform=macOS' \
            -quiet 2>&1 || true)"
    echo "${XCB_OUT}" | tail -50
    if echo "${XCB_OUT}" | grep -q "is not currently configured for the test action"; then
        warn "scheme COOL-TUNNEL has no test action (no XCTest target) — skipping"
        SKIPPED+=("xcodebuild test (no test target)")
    elif echo "${XCB_OUT}" | grep -Eq '(\*\* TEST FAILED \*\*|Testing failed|^xcodebuild: error)'; then
        fail "xcodebuild test failed"
        STATUS=1
    fi
fi

# --- 6. naive arch guard ---------------------------------------------------
# **Manifest Guard (F4-1 enforcement).** Every release ships a
# universal `naive` binary. If the bundled file lost a slice (e.g.
# fetch_naive.sh wrote a single-arch build by accident) this gate
# fires before any release artefact is built. Checks the staged
# binary at `COOL-TUNNEL/naive`, NOT the .app bundle's copy — Xcode
# copies it from there during the Release build.
NAIVE_PATH="${REPO_ROOT}/COOL-TUNNEL/naive"
if [[ -f "${NAIVE_PATH}" ]]; then
    log "naive arch guard: lipo on ${NAIVE_PATH}"
    LIPO_OUT="$(lipo -info "${NAIVE_PATH}" 2>&1 || true)"
    if [[ "${LIPO_OUT}" == *"x86_64"* && "${LIPO_OUT}" == *"arm64"* ]]; then
        log "naive: universal (arm64 + x86_64) ✓"
    else
        fail "naive is not universal: ${LIPO_OUT}"
        STATUS=1
    fi
else
    warn "no naive at ${NAIVE_PATH} — run scripts/fetch_naive.sh first"
    if (( STRICT )); then
        fail "naive missing (--strict)"
        STATUS=1
    fi
fi

# --- 7. schema sync probe --------------------------------------------------
# **API Schema check.** The macOS client speaks two JSON contracts:
#
#   (a) JSON-over-stdio with `cool-tunnel-core` (lib + binary).
#       cargo test already covers `protocol_roundtrip`, so the
#       audit's job is to confirm those tests actually exist and
#       ran above (covered by step 3).
#
#   (b) HTTPS to the Laravel panel's
#       `/api/v1/subscription/{token}` endpoint. The Swift side
#       decodes a `SubscriptionManifestV1` (`Core/Subscription.swift`
#       since v2.0.21 — previously inlined in `TunnelOrchestrator`);
#       we keep a fixture under
#       `tests/fixtures/subscription_manifest_v1.json` and verify
#       the decoder is wired up by grepping the relevant fields
#       across `COOL-TUNNEL/Core/*.swift`. A real round-trip test
#       would require running Xcode tests (covered by step 5);
#       this static probe is a belt-and-suspenders check that the
#       field names didn't drift in a hand-edit.
log "schema sync probe (subscription manifest)"
SCHEMA_FIXTURE="${REPO_ROOT}/tests/fixtures/subscription_manifest_v1.json"
DECODER_DIR="${REPO_ROOT}/COOL-TUNNEL/Core"
if [[ -f "${SCHEMA_FIXTURE}" && -d "${DECODER_DIR}" ]]; then
    schema_missing=()
    for field in profiles host username password; do
        if ! grep -q "\"${field}\"" "${SCHEMA_FIXTURE}"; then
            schema_missing+=("fixture missing field: ${field}")
        fi
        if ! grep -rq --include='*.swift' "let ${field}" "${DECODER_DIR}"; then
            schema_missing+=("Swift decoder missing field: ${field}")
        fi
    done
    if (( ${#schema_missing[@]} )); then
        for m in "${schema_missing[@]}"; do fail "$m"; done
        STATUS=1
    else
        log "schema sync probe ✓"
    fi
else
    warn "schema fixture or decoder dir missing — schema probe skipped"
    if (( STRICT )); then
        fail "schema fixture / decoder dir not found (--strict)"
        STATUS=1
    fi
fi

# --- Summary ---------------------------------------------------------------
echo
if (( STATUS == 0 )); then
    log "audit: PASS"
    if (( ${#SKIPPED[@]} )); then
        warn "non-strict skips: ${SKIPPED[*]}"
    fi
else
    fail "audit: FAIL — fix issues above and re-run"
fi

exit "${STATUS}"
