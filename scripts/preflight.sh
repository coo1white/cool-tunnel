#!/usr/bin/env bash
# scripts/preflight.sh
#
# Runs the same lint / test floor that CI enforces — locally, and as
# fast as the local machine permits. Mirrors `.github/workflows/ci.yml`:
# every check below has a CI counterpart and the flags match (`--locked`,
# `--strict`, `xcrun swift-format`). If everything passes here, the
# corresponding CI step should pass — modulo runner-environment
# differences (e.g. swift-format version drift between the local Xcode
# and the macos-14 runner image).
#
# Why this exists: `cut_release.sh` xcodebuilds Release. That step is
# 5–15 min of wall-clock and pulls in the bundled `naive`. If a release
# would have been rejected by CI for a fmt drift or a swift-format
# violation, finding that out at minute 12 is wasteful. Pre-flight
# fails in seconds and saves the cycle.
#
# Invoked by:
#   - cut_release.sh — as Step 0, before fetch_naive / cargo clean /
#     xcodebuild. Set SKIP_PREFLIGHT=1 to bypass (in genuine emergencies
#     only — CI will still reject).
#   - contributors — directly, before opening a PR. Same effect as the
#     test sweep block in CONTRIBUTING.md, fewer commands to type.
#
# Usage:
#   scripts/preflight.sh                 # full floor
#   scripts/preflight.sh --skip-tests    # skip cargo test (faster; CI still runs it)
#   scripts/preflight.sh --skip-deny     # skip cargo deny (when cargo-deny isn't installed locally)
#
# Exit codes:
#   0  every check passed
#   1  at least one check failed
#   2  required tooling missing (cargo / shellcheck / xcrun) and not skippable

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_DIR="${REPO_ROOT}/core"

# --- argument parsing -----------------------------------------------------

SKIP_TESTS=0
SKIP_DENY=0
for arg in "$@"; do
    case "${arg}" in
        --skip-tests) SKIP_TESTS=1 ;;
        --skip-deny)  SKIP_DENY=1 ;;
        -h|--help)
            # Print the header comment block (lines 2 through ~32).
            sed -n '2,32p' "$0"
            exit 0
            ;;
        *)
            printf 'preflight: unknown argument: %s\n' "${arg}" >&2
            exit 2
            ;;
    esac
done

# --- printing helpers (match cut_release.sh's vocabulary) -----------------

log()   { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m  ok\033[0m %s\n' "$*"; }
bad()   { printf '\033[1;31mfail\033[0m %s\n' "$*"; }
fatal() { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit 2; }

# --- preconditions --------------------------------------------------------

# These three are non-negotiable. If a developer doesn't have cargo
# plus the `shellcheck` and `xcrun` binaries on PATH, they're not in
# a position to ship a release of this product. Fail loudly.
command -v cargo      >/dev/null 2>&1 || fatal "cargo not found in PATH (install via https://rustup.rs/)"
command -v shellcheck >/dev/null 2>&1 || fatal "shellcheck not found in PATH (brew install shellcheck)"
command -v xcrun      >/dev/null 2>&1 || fatal "xcrun not found in PATH (install Xcode + Command Line Tools)"

# --- check runner ---------------------------------------------------------

FAILED=0

# Run a check. First arg is the human-readable label (and command name
# echoed in the log). Remaining args are the command + its args. We
# wrap the call in `if/then/else` so that a non-zero exit doesn't trip
# `set -e` — we want to count failures and report all of them, not bail
# on the first one.
run_check() {
    local label="$1"
    shift
    log "${label}"
    if "$@"; then
        ok "${label}"
    else
        bad "${label}"
        FAILED=$((FAILED + 1))
    fi
}

# Wrapper: run a command from inside a directory using a subshell, so
# the parent CWD is not modified between checks. Both helpers are
# invoked indirectly via `run_check "$label" in_core <cmd>...` —
# shellcheck can't see indirect invocation through positional args,
# hence the SC2329 disable.
# shellcheck disable=SC2329
in_core() { (cd "${CORE_DIR}" && "$@"); }
# shellcheck disable=SC2329
in_root() { (cd "${REPO_ROOT}" && "$@"); }

# --- Rust floor -----------------------------------------------------------

run_check "cargo fmt --all -- --check" \
    in_core cargo fmt --all -- --check

run_check "cargo clippy --locked --all-targets --all-features -- -D warnings" \
    in_core cargo clippy --locked --all-targets --all-features -- -D warnings

if [[ "${SKIP_TESTS}" -eq 0 ]]; then
    run_check "cargo test --locked --all-features" \
        in_core cargo test --locked --all-features
else
    log "cargo test --locked --all-features  (skipped: --skip-tests)"
fi

if [[ "${SKIP_DENY}" -eq 0 ]]; then
    if command -v cargo-deny >/dev/null 2>&1; then
        run_check "cargo deny check" \
            in_core cargo deny check
    else
        bad "cargo deny check — cargo-deny not installed; install via 'cargo install cargo-deny' or pass --skip-deny"
        FAILED=$((FAILED + 1))
    fi
else
    log "cargo deny check  (skipped: --skip-deny)"
fi

# --- Swift floor ----------------------------------------------------------

# Always invoke via `xcrun`. Bare `swift-format` exits 127 on macos-14
# CI runners because the toolchain bin isn't on the default $PATH —
# this gave us a silent no-op lint job for months until F8a fixed it.
# (See `docs/adr/0001-audit-rules-locked-2026-05-05.md`.)
run_check "xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL" \
    in_root xcrun swift-format lint -r --strict --configuration .swift-format COOL-TUNNEL

# --- Shell floor ----------------------------------------------------------

# Expand the glob in the parent shell so `run_check` receives explicit
# file args, not a literal '*' that wouldn't expand inside the function.
SHELL_FILES=("${REPO_ROOT}"/scripts/*.sh)
run_check "shellcheck scripts/*.sh" \
    shellcheck "${SHELL_FILES[@]}"

# --- summary --------------------------------------------------------------

echo ""
if [[ "${FAILED}" -eq 0 ]]; then
    log "preflight: ALL GREEN — local lint floor matches CI."
    exit 0
fi
bad "preflight: ${FAILED} check(s) failed — CI will reject. Fix locally and re-run."
exit 1
