#!/usr/bin/env bash
# scripts/cut_release.sh
#
# **v2.0.18-pre — Synthetic CI Gate.** Cool Tunnel ships without a
# paid Apple Developer account, which means no Xcode Cloud, no
# notarisation, no automated CI. This script substitutes for all
# three: every check the project would otherwise gate behind a
# cloud build runs here, locally, before a release artefact is
# allowed to leave the working tree.
#
# What it does, in order (fast pre-flight first so a wrong
# `MARKETING_VERSION` aborts before a 60-second cargo test does):
#
#   PRE-FLIGHT
#   ──────────
#   1.  Verify   core/Cargo.toml `version = "<X>"` matches argv[1].
#   2.  Verify   COOL-TUNNEL.xcodeproj's MARKETING_VERSION matches
#                argv[1]. Both Debug and Release configurations
#                must agree (we grep both occurrences).
#   3.  Refresh  bundled `naive` from upstream NaiveProxy releases
#                (fetch_naive.sh) and re-pin naive.upstream.json.
#   4.  Run      scripts/audit.sh --strict  (cargo fmt / clippy /
#                test, swift format lint, xcodebuild test, naive
#                arch guard, schema sync probe). Any failure aborts.
#
#   BUILD
#   ─────
#   5.  cargo clean inside core/.
#   6.  cargo update -p cool-tunnel-core (refreshes Cargo.lock).
#   7.  xcodebuild Release. Output captured to dist/build-${V}.log.
#   8.  Smoke check: bundled cool-tunnel-core --version and bundled
#                naive sha256 match expectations.
#
#   PRE-PACKAGE
#   ───────────
#   8b. Run scripts/security_check.sh against the built .app —
#       secret-pattern scan, code-sign on every embedded Mach-O,
#       NaiveProxy SHA pin cross-check, Info.plist version
#       assertion, LICENSE/NOTICE presence, entitlements review.
#
#   PACKAGE
#   ───────
#   9.  Hand the .app to scripts/package_release.sh which emits
#                .dmg / .pkg / .zip / .sha256 manifest into dist/.
#
# Usage:
#   scripts/cut_release.sh 2.0.18
#
# Exit codes (preserved from earlier versions for muscle memory):
#   0  success
#   1  bad arguments / version mismatch (pre-flight 1, 2)
#   2  fetch_naive failed (pre-flight 3)
#   3  cargo clean failed (build 5)
#   4  Release build / smoke check failed (build 7, 8)
#   5  package_release failed (package 9)
#   6  audit suite failed (pre-flight 4)  ← new in v2.0.18-pre
#   7  security_check failed (pre-package 8b)  ← new in v2.0.22

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version>" >&2
    echo "  e.g. $0 2.0.18" >&2
    exit 1
fi
VERSION="$1"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

mkdir -p "${REPO_ROOT}/dist"

# ---------------------------------------------------------------------------
# PRE-FLIGHT 1: core/Cargo.toml version sync
# ---------------------------------------------------------------------------
CARGO_TOML="${REPO_ROOT}/core/Cargo.toml"
CARGO_VERSION=$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "${CARGO_TOML}")
if [[ "${CARGO_VERSION}" != "${VERSION}" ]]; then
    die "core/Cargo.toml is '${CARGO_VERSION}' but you requested '${VERSION}'. Bump core/Cargo.toml first." 1
fi
log "Cargo.toml version: ${CARGO_VERSION} ✓"

# ---------------------------------------------------------------------------
# PRE-FLIGHT 2: Xcode MARKETING_VERSION sync (Debug + Release)
# ---------------------------------------------------------------------------
PBXPROJ="${REPO_ROOT}/COOL-TUNNEL.xcodeproj/project.pbxproj"
# All MARKETING_VERSION lines must match. The Xcode project today
# carries two (Debug + Release) — if a future config split adds a
# third, this check will catch it because *every* occurrence has
# to equal the requested version.
MARKETING_VERSIONS=$(grep -E 'MARKETING_VERSION[[:space:]]*=' "${PBXPROJ}" | awk '{print $3}' | tr -d ';')
if [[ -z "${MARKETING_VERSIONS}" ]]; then
    die "could not find any MARKETING_VERSION lines in ${PBXPROJ}" 1
fi
mismatch=0
while IFS= read -r v; do
    if [[ "${v}" != "${VERSION}" ]]; then
        warn "Xcode MARKETING_VERSION '${v}' != requested '${VERSION}'"
        mismatch=1
    fi
done <<< "${MARKETING_VERSIONS}"
if (( mismatch )); then
    die "Xcode MARKETING_VERSION is out of sync. Open COOL-TUNNEL.xcodeproj → COOL-TUNNEL target → General → Identity → Version, set to ${VERSION}, then re-run." 1
fi
log "Xcode MARKETING_VERSION: ${VERSION} ✓ (all configurations agree)"

# ---------------------------------------------------------------------------
# PRE-FLIGHT 3: refresh bundled naive from upstream
# ---------------------------------------------------------------------------
log "Refreshing bundled naive from upstream NaiveProxy releases…"
if ! bash "${REPO_ROOT}/scripts/fetch_naive.sh"; then
    die "fetch_naive.sh failed — bundled naive may be stale; aborting" 2
fi

# ---------------------------------------------------------------------------
# PRE-FLIGHT 4: run the audit suite (--strict so missing tools fail)
# ---------------------------------------------------------------------------
log "Running scripts/audit.sh --strict (cargo fmt/clippy/test, swift fmt lint, xcodebuild test, naive arch, schema)…"
if ! bash "${REPO_ROOT}/scripts/audit.sh" --strict; then
    die "audit suite failed — see output above; aborting before any artefact is built" 6
fi

# ---------------------------------------------------------------------------
# BUILD 5: cargo clean
# ---------------------------------------------------------------------------
log "Cleaning cargo target/ so cool-tunnel-core is rebuilt fresh…"
(cd "${REPO_ROOT}/core" && cargo clean) || die "cargo clean failed" 3

# ---------------------------------------------------------------------------
# BUILD 6: refresh Cargo.lock (no-op when version field unchanged)
# ---------------------------------------------------------------------------
log "Refreshing Cargo.lock for cool-tunnel-core ${VERSION}…"
(cd "${REPO_ROOT}/core" && cargo update -p cool-tunnel-core) >/dev/null

# ---------------------------------------------------------------------------
# BUILD 7: Xcode Release (run-script phase rebuilds Rust core)
# ---------------------------------------------------------------------------
log "Building Cool Tunnel ${VERSION} (Release)…"
if ! xcodebuild \
        -project "${REPO_ROOT}/COOL-TUNNEL.xcodeproj" \
        -scheme COOL-TUNNEL \
        -configuration Release \
        -destination 'platform=macOS' \
        build > "${REPO_ROOT}/dist/build-${VERSION}.log" 2>&1; then
    tail -50 "${REPO_ROOT}/dist/build-${VERSION}.log" >&2
    die "xcodebuild failed — see ${REPO_ROOT}/dist/build-${VERSION}.log" 4
fi

# Locate the freshly-built .app. Xcode DerivedData paths are
# constrained (scheme name + fixed-alphabet hash, no spaces); BSD
# `find` lacks `-printf` for sort-by-mtime, so `ls -td | head -1`
# is the safe pragmatic choice on macOS. (Audit ref: F2-1.)
# shellcheck disable=SC2012  # see comment above; constrained DerivedData paths.
DD="$(ls -td "${HOME}/Library/Developer/Xcode/DerivedData/COOL-TUNNEL-"* 2>/dev/null | head -1)"
APP="${DD}/Build/Products/Release/Cool Tunnel.app"
if [[ ! -d "${APP}" ]]; then
    die "expected .app at ${APP} but it doesn't exist" 4
fi

# ---------------------------------------------------------------------------
# BUILD 8: bundled-binary smoke checks
# ---------------------------------------------------------------------------
BUNDLED_RUST_VERSION="$("${APP}/Contents/Resources/cool-tunnel-core" --version 2>/dev/null | head -1 | awk '{print $NF}')"
if [[ "${BUNDLED_RUST_VERSION}" != "${VERSION}" ]]; then
    die "freshly-built bundled cool-tunnel-core self-reports '${BUNDLED_RUST_VERSION}', expected '${VERSION}'" 4
fi
log "Bundled cool-tunnel-core: ${BUNDLED_RUST_VERSION} ✓"

EXPECTED_NAIVE_SHA="$(awk -F'"' '/merged_universal_sha256/ { print $4 }' "${APP}/Contents/Resources/naive.upstream.json")"
ACTUAL_NAIVE_SHA="$(shasum -a 256 "${APP}/Contents/Resources/naive" | awk '{print $1}')"
if [[ -n "${EXPECTED_NAIVE_SHA}" && "${ACTUAL_NAIVE_SHA}" != "${EXPECTED_NAIVE_SHA}" ]]; then
    die "bundled naive sha256 (${ACTUAL_NAIVE_SHA}) does not match naive.upstream.json (${EXPECTED_NAIVE_SHA})" 4
fi
log "Bundled naive verified against upstream pin ✓"

# ---------------------------------------------------------------------------
# PRE-PACKAGE SECURITY AUDIT
# ---------------------------------------------------------------------------
# `security_check.sh` runs the secret-pattern scan, code-signature
# verification on every embedded Mach-O, NaiveProxy SHA pin
# cross-check, Info.plist version assertion, LICENSE/NOTICE/
# Disclaimer presence check, and entitlements review. Documented
# at the top of `security_check.sh` as "Run this *after* the
# Release archive completes and *before* packaging the DMG/PKG/
# ZIP" — but until now, no script enforced that ordering. A
# release operator who forgot to run it shipped without those
# checks. Wire it in here so `cut_release.sh` is the single
# source of truth for "everything that must pass before bytes
# leave the working tree".
log "Running scripts/security_check.sh on the freshly-built .app…"
if ! EXPECTED_VERSION="${VERSION}" bash "${REPO_ROOT}/scripts/security_check.sh" "${APP}"; then
    die "security_check.sh failed — see output above; aborting before packaging" 7
fi

# ---------------------------------------------------------------------------
# PACKAGE 9
# ---------------------------------------------------------------------------
log "Packaging release artefacts…"
if ! bash "${REPO_ROOT}/scripts/package_release.sh" "${VERSION}" "${APP}"; then
    die "package_release.sh failed" 5
fi

log "Release ${VERSION} ready in ${REPO_ROOT}/dist/"
log "Synthetic CI gate: ALL CHECKS PASSED"
log "Next: gh release create v${VERSION} … (the package script printed the canonical command above)"
