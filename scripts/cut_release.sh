#!/usr/bin/env bash
# scripts/cut_release.sh
#
# **v2.0.6 (release-pipeline hygiene):** single command that
# guarantees the .app bundle's two binaries — `naive` and
# `cool-tunnel-core` — are both freshly produced from current
# upstream / Cargo.toml on every release cut. Pre-2.0.6 a
# developer who forgot to either re-fetch naive or `cargo
# clean` could ship a release whose bundled binaries were
# stale by one or more versions; the user's concern was
# "default version is 2.0.3" inside an otherwise-2.0.5 .app.
#
# What this script does, in order:
#
#   1. Refresh `COOL-TUNNEL/naive` from the latest upstream
#      NaiveProxy release (fetch_naive.sh). Updates
#      `naive.upstream.json` in lock-step.
#   2. `cargo clean` so the next Xcode build cannot pick up
#      stale `cool-tunnel-core` artefacts from a prior
#      version's compile.
#   3. Verify `core/Cargo.toml` matches the requested release
#      version (refuse to proceed otherwise).
#   4. xcodebuild Release — triggers Xcode's "Build Rust
#      core" run-script phase, which builds a fresh universal
#      cool-tunnel-core from the just-cleaned cargo state.
#   5. Hand the resulting .app to package_release.sh, which
#      runs its own preconditions (bundled binary version
#      matches request) and emits the .dmg / .pkg / .zip /
#      core-binary / .sha256 manifest.
#
# Usage:
#   scripts/cut_release.sh 2.0.6
#
# After this completes successfully, `dist/Cool-tunnel-v…`
# files are ready to upload via `gh release create`.
#
# Exit codes:
#   0  success
#   1  bad arguments / version mismatch
#   2  fetch_naive failed
#   3  cargo clean failed
#   4  Release build failed
#   5  package_release failed

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version>" >&2
    echo "  e.g. $0 2.0.6" >&2
    exit 1
fi
VERSION="$1"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m!!!\033[0m %s\n' "$*" >&2; exit "${2:-1}"; }

# --- 1. Refresh bundled naive ----------------------------------------------
log "Refreshing bundled naive from upstream NaiveProxy releases…"
if ! bash "${REPO_ROOT}/scripts/fetch_naive.sh"; then
    die "fetch_naive.sh failed — bundled naive may be stale; aborting" 2
fi

# --- 2. Clean cargo cache so the next build starts fresh -------------------
log "Cleaning cargo target/ so cool-tunnel-core is rebuilt fresh…"
(cd "${REPO_ROOT}/core" && cargo clean) || die "cargo clean failed" 3

# --- 3. Cargo.toml version precondition -----------------------------------
CARGO_TOML="${REPO_ROOT}/core/Cargo.toml"
CARGO_VERSION=$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "${CARGO_TOML}")
if [[ "${CARGO_VERSION}" != "${VERSION}" ]]; then
    die "core/Cargo.toml is '${CARGO_VERSION}' but you requested '${VERSION}'. Bump core/Cargo.toml first." 1
fi
# Refresh Cargo.lock in case the version field was just bumped.
log "Refreshing Cargo.lock for cool-tunnel-core ${VERSION}…"
(cd "${REPO_ROOT}/core" && cargo update -p cool-tunnel-core) >/dev/null

# --- 4. Release build (rebuilds rust core via Xcode run-script phase) -----
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

# Locate the freshly-built .app
DD="$(ls -td "${HOME}/Library/Developer/Xcode/DerivedData/COOL-TUNNEL-"* 2>/dev/null | head -1)"
APP="${DD}/Build/Products/Release/Cool Tunnel.app"
if [[ ! -d "${APP}" ]]; then
    die "expected .app at ${APP} but it doesn't exist" 4
fi

# Quick smoke check — bundled rust core --version matches request
BUNDLED_RUST_VERSION="$(${APP}/Contents/Resources/cool-tunnel-core --version 2>/dev/null | head -1 | awk '{print $NF}')"
if [[ "${BUNDLED_RUST_VERSION}" != "${VERSION}" ]]; then
    die "freshly-built bundled cool-tunnel-core self-reports '${BUNDLED_RUST_VERSION}', expected '${VERSION}'" 4
fi
log "Bundled cool-tunnel-core verified: ${BUNDLED_RUST_VERSION}"

# Smoke check — bundled naive matches naive.upstream.json's pinned hash
EXPECTED_NAIVE_SHA="$(awk -F'"' '/merged_universal_sha256/ { print $4 }' "${APP}/Contents/Resources/naive.upstream.json")"
ACTUAL_NAIVE_SHA="$(shasum -a 256 "${APP}/Contents/Resources/naive" | awk '{print $1}')"
if [[ -n "${EXPECTED_NAIVE_SHA}" && "${ACTUAL_NAIVE_SHA}" != "${EXPECTED_NAIVE_SHA}" ]]; then
    die "bundled naive sha256 (${ACTUAL_NAIVE_SHA}) does not match naive.upstream.json (${EXPECTED_NAIVE_SHA})" 4
fi
log "Bundled naive verified against upstream pin."

# --- 5. Package (additional preconditions inside the script) --------------
log "Packaging release artefacts…"
if ! bash "${REPO_ROOT}/scripts/package_release.sh" "${VERSION}" "${APP}"; then
    die "package_release.sh failed" 5
fi

log "Release ${VERSION} ready in ${REPO_ROOT}/dist/"
log "Next: gh release create v${VERSION} … (the package script printed the canonical command above)"
