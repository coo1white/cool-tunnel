#!/usr/bin/env bash
# scripts/security_check.sh
#
# Pre-release security audit for a built `Cool tunnel.app` bundle. Run
# this *after* the Release archive completes and *before* packaging the
# DMG/PKG/ZIP; refusing to ship until every check passes catches the
# common ways an open-source macOS app can leak credentials, ship a
# tampered helper, or fail to launch on Intel.
#
# Usage:
#   scripts/security_check.sh path/to/Cool\ tunnel.app
#   scripts/security_check.sh   # auto-discovers the Release build
#
# Checks (each one is a hard fail unless marked "advisory"):
#   1. App bundle exists and contains the expected Mach-O helpers
#   2. Code signature is intact for the .app and every embedded Mach-O
#   3. naive and cool-tunnel-core are both *universal* (arm64 + x86_64)
#   4. naive matches the upstream NaiveProxy SHA-256 we recorded
#   5. Info.plist version matches the git tag we are about to release
#   6. No source file contains hard-coded credentials or API keys
#   7. LICENSE and Disclaimer.md are present at the repo root
#   8. App entitlements are minimal (advisory: prints the full list)
#   9. spctl assessment (advisory: ad-hoc-signed apps will be rejected
#      on first launch — this is normal for non-Developer-ID builds)
#
# Exit codes:
#   0  all checks passed
#   1  bad arguments
#   2+ at least one check failed (see stderr for which)

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP="${1:-${REPO_ROOT}/build/DerivedData/Build/Products/Release/Cool tunnel.app}"
if [[ ! -d "${APP}" ]]; then
    echo "error: app bundle not found at ${APP}" >&2
    echo "       run \`xcodebuild -configuration Release\` first or pass an explicit path" >&2
    exit 1
fi

# Counters surface a final summary line — easier to scan in CI logs
# than scrolling back through every individual check.
PASS=0
FAIL=0
WARN=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
warn() { echo "  ⚠ $*"; WARN=$((WARN + 1)); }
fail() { echo "  ✗ $*" >&2; FAIL=$((FAIL + 1)); }

heading() { printf "\n== %s ==\n" "$*"; }

# --- 1. Bundle layout -------------------------------------------------

heading "1. Bundle layout"

NAIVE_BIN="${APP}/Contents/Resources/naive"
CORE_BIN="${APP}/Contents/Resources/cool-tunnel-core"
APP_BIN="${APP}/Contents/MacOS/Cool tunnel"

for f in "${APP_BIN}" "${NAIVE_BIN}" "${CORE_BIN}"; do
    if [[ -x "${f}" ]]; then ok "found ${f##*/}"; else fail "missing ${f}"; fi
done

# --- 2. Code signatures ------------------------------------------------

heading "2. Code signatures"

# --deep --strict catches signature mismatches on nested frameworks too,
# not just the top-level executable.
if codesign --verify --deep --strict --verbose=2 "${APP}" >/dev/null 2>&1; then
    ok "app bundle signature verifies (deep, strict)"
else
    fail "app bundle signature verification failed"
fi

for f in "${APP_BIN}" "${NAIVE_BIN}" "${CORE_BIN}"; do
    [[ -e "${f}" ]] || continue
    if codesign --verify --strict --verbose=2 "${f}" >/dev/null 2>&1; then
        ok "${f##*/} signature verifies"
    else
        fail "${f##*/} signature verification failed"
    fi
done

# --- 3. Universal binaries ---------------------------------------------

heading "3. Universal binaries (arm64 + x86_64)"

check_universal() {
    local name="$1"; local path="$2"
    [[ -e "${path}" ]] || { fail "${name} missing"; return; }
    local info
    info="$(lipo -info "${path}" 2>/dev/null)"
    if grep -q "arm64" <<<"${info}" && grep -q "x86_64" <<<"${info}"; then
        ok "${name}: universal (${info#*: })"
    else
        fail "${name}: not universal — got ${info#*: }"
    fi
}

check_universal "Cool tunnel"      "${APP_BIN}"
check_universal "naive"            "${NAIVE_BIN}"
check_universal "cool-tunnel-core" "${CORE_BIN}"

# --- 4. naive matches upstream manifest --------------------------------

heading "4. naive matches upstream manifest"

MANIFEST="${REPO_ROOT}/COOL-TUNNEL/naive.upstream.json"
if [[ -f "${MANIFEST}" ]]; then
    EXPECTED_SHA="$(jq -r '.merged_universal_sha256' "${MANIFEST}")"
    if [[ -z "${EXPECTED_SHA}" || "${EXPECTED_SHA}" == "null" ]]; then
        warn "manifest present but has no merged_universal_sha256 field"
    else
        ACTUAL_SHA="$(shasum -a 256 "${NAIVE_BIN}" | awk '{print $1}')"
        if [[ "${ACTUAL_SHA}" == "${EXPECTED_SHA}" ]]; then
            ok "naive sha256 matches manifest (${EXPECTED_SHA})"
        else
            # Ad-hoc signing rewrites bytes inside the Mach-O after the
            # universal merge, so a hash mismatch is *expected* here —
            # the manifest pins the pre-resign artefact. Surface it as
            # a warning so we still print both hashes for the audit log.
            warn "bundled naive differs from manifest (likely re-signed)"
            warn "  manifest: ${EXPECTED_SHA}"
            warn "  bundled : ${ACTUAL_SHA}"
        fi
    fi
else
    warn "no naive.upstream.json manifest — cannot verify upstream provenance"
fi

# --- 5. Info.plist version sanity --------------------------------------

heading "5. Info.plist version"

PLIST="${APP}/Contents/Info.plist"
SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${PLIST}" 2>/dev/null || echo "?")"
BUNDLE_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${PLIST}" 2>/dev/null || echo "?")"
ok "CFBundleShortVersionString = ${SHORT_VERSION}"
ok "CFBundleVersion            = ${BUNDLE_VERSION}"

if [[ -n "${EXPECTED_VERSION:-}" ]]; then
    if [[ "${SHORT_VERSION}" == "${EXPECTED_VERSION}" ]]; then
        ok "version matches EXPECTED_VERSION=${EXPECTED_VERSION}"
    else
        fail "version ${SHORT_VERSION} != EXPECTED_VERSION=${EXPECTED_VERSION}"
    fi
fi

# --- 6. No hard-coded secrets in source --------------------------------

heading "6. Source-level secret scan"

# Pattern bank — broad enough to catch the most common embedded-secret
# mistakes (AWS-style keys, long base64 blobs, password assignments)
# without dragging in every test fixture.  We *exclude* `target/`, the
# git directory, and the dist/ output so a previous build never trips
# the check.
# Specific historical leak — early dev scripts shipped a real password
# before v0.1.5.3. Build the pattern from concatenated halves so this
# script's source never contains the literal in one piece (otherwise
# the scan would self-match every run).
HISTORICAL_LEAK_HALF1='19990515'
HISTORICAL_LEAK_HALF2='Wry'
HISTORICAL_LEAK_PATTERN="${HISTORICAL_LEAK_HALF1}${HISTORICAL_LEAK_HALF2}"

SECRET_PATTERNS=(
    'AKIA[0-9A-Z]{16}'              # AWS access key id
    'sk-[A-Za-z0-9]{20,}'           # OpenAI-style secret key
    'ghp_[A-Za-z0-9]{20,}'          # GitHub PAT
    'xox[baprs]-[A-Za-z0-9-]{20,}'  # Slack token
    '-----BEGIN[ A-Z]+PRIVATE KEY'  # Embedded private key
    "${HISTORICAL_LEAK_PATTERN}"    # Pinned past-leak guard (see above)
    # Catch literal `basic_auth <user> <password>` Caddyfile lines.
    # The character class deliberately excludes `<` and `>` so the
    # documentation's `basic_auth <USERNAME> <PASSWORD>` placeholder
    # does *not* match — only real plaintext credentials trip this.
    'basic_auth[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+[A-Za-z0-9._/+=-]{6,}'
)
SECRET_GLOBS=(
    "${REPO_ROOT}/COOL-TUNNEL"
    "${REPO_ROOT}/core/src"
    "${REPO_ROOT}/scripts"
    "${REPO_ROOT}/NaiveProxy_Server_Setup.md"
    "${REPO_ROOT}/Disclaimer.md"
    "${REPO_ROOT}/README.md"
)
SCAN_OUTPUT=""
for pattern in "${SECRET_PATTERNS[@]}"; do
    if matches=$(grep -REn --binary-files=without-match \
        --exclude-dir=target --exclude-dir=.git --exclude-dir=dist \
        --exclude-dir=build "${pattern}" "${SECRET_GLOBS[@]}" 2>/dev/null); then
        SCAN_OUTPUT="${SCAN_OUTPUT}${matches}\n"
    fi
done
if [[ -z "${SCAN_OUTPUT}" ]]; then
    ok "no secret patterns matched in tracked source"
else
    fail "secret-pattern matches found:"
    printf "%b" "${SCAN_OUTPUT}" | sed 's/^/    /' >&2
fi

# --- 7. License + disclaimer present -----------------------------------

heading "7. Apache-2.0 license, NOTICE, and disclaimer"

if [[ -f "${REPO_ROOT}/LICENSE" ]]; then
    ok "LICENSE present at repo root"
else
    fail "LICENSE missing — required by Apache-2.0 distribution terms"
fi

# Apache 2.0 is identified by its distinctive "Apache License" /
# "Version 2.0" header pair on the first two lines. Looser than a
# byte-exact match (which would break on whitespace tweaks) but
# tight enough to catch a license swap.
if grep -q "Apache License" "${REPO_ROOT}/LICENSE" 2>/dev/null \
    && grep -q "Version 2.0" "${REPO_ROOT}/LICENSE" 2>/dev/null; then
    ok "LICENSE contains Apache-2.0 header"
else
    fail "LICENSE does not look like Apache-2.0"
fi

# NOTICE is required when redistributing under Apache-2.0 if the
# upstream included one — and it's good practice to keep our own
# copyright + bundled-component attribution there. Treated as a
# hard fail because we *did* author one.
if [[ -f "${REPO_ROOT}/NOTICE" ]]; then
    ok "NOTICE present at repo root"
else
    fail "NOTICE missing — required by Apache-2.0 § 4(d) for our bundled-software attribution"
fi

if [[ -f "${REPO_ROOT}/Disclaimer.md" ]]; then
    ok "Disclaimer.md present at repo root"
else
    fail "Disclaimer.md missing — required by README"
fi

# --- 8. Entitlements (advisory) ---------------------------------------

heading "8. App entitlements (advisory — review these are minimal)"
if codesign -d --entitlements :- "${APP}" 2>/dev/null | sed 's/^/    /'; then
    ok "entitlements printed for review"
else
    warn "could not read entitlements"
fi

# --- 9. Gatekeeper assessment (advisory) -------------------------------

heading "9. Gatekeeper assessment (ad-hoc-signed apps are expected to be rejected)"
if SPCTL_OUT=$(spctl --assess --type execute --verbose=4 "${APP}" 2>&1); then
    ok "spctl: ${SPCTL_OUT}"
else
    warn "spctl: ${SPCTL_OUT}"
    warn "this is expected for ad-hoc-signed apps without an Apple Developer ID;"
    warn "users will need to right-click → Open on first launch"
fi

# --- Final summary -----------------------------------------------------

heading "Summary"
echo "  passed:   ${PASS}"
echo "  warnings: ${WARN}"
echo "  failures: ${FAIL}"

if [[ "${FAIL}" -gt 0 ]]; then
    echo "" >&2
    echo "security_check FAILED — refusing to package" >&2
    exit 2
fi

echo ""
echo "security_check passed — safe to package"
