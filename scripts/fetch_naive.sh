#!/usr/bin/env bash
# scripts/fetch_naive.sh
#
# Authoritative pin enforcement for the bundled NaiveProxy binary.
#
# The file `COOL-TUNNEL/naive.upstream.json` is the **pin**: it
# records the upstream tag this repo claims to ship and the
# SHA-256 of the arm64 tarball, the x64 tarball, and the merged
# universal binary. The bundled binary at `COOL-TUNNEL/naive`
# MUST match the pin. Drift in either direction (binary changed,
# or upstream tag rewrote) is a supply-chain regression signal —
# this script refuses to silently absorb either.
#
# Modes:
#
#   scripts/fetch_naive.sh
#       Verify-only (no network). Computes the SHA-256 of the
#       bundled `COOL-TUNNEL/naive` and compares it against
#       `merged_universal_sha256` in the committed manifest.
#       Fast (< 100 ms). This is what `cut_release.sh` calls.
#
#   scripts/fetch_naive.sh --check-only
#       Audit mode (requires network). Re-downloads the upstream
#       tarballs at the **pinned** tag and recomputes all SHAs.
#       Reports drift in tarball SHAs (upstream tag rewrite),
#       merged-universal SHA (build-determinism break), or the
#       bundled binary (local tampering). Suitable for a daily CI
#       gate. Pre-v2.0.38 behaviour resolved "gh latest" instead;
#       that is now `--repin` only — the audit must always check
#       against the committed pin, not a moving upstream pointer.
#
#   scripts/fetch_naive.sh --repin [TAG]
#       Explicit re-pin (requires network). Resolves the tag (gh
#       latest if omitted, else the argument), downloads the
#       upstream tarballs, lipo-merges, ad-hoc-signs, and prints
#       the OLD → NEW SHA diff. Will NOT write anything to the
#       working tree unless `CT_REPIN_CONFIRM=1` is set in the
#       environment — re-pinning is an operator decision, not an
#       accident. On success rewrites `COOL-TUNNEL/naive` and
#       `COOL-TUNNEL/naive.upstream.json`; the operator commits
#       both as one atomic pin-bump commit.
#
# Exit codes:
#   0  success
#   1  invocation / parsing error / missing dependency
#   2  download / extraction / lipo failed
#   3  pin verification failed (drop-dead supply-chain signal)
#   4  --repin requested but CT_REPIN_CONFIRM=1 not set
#
# Dependencies: bash 4+, curl, tar, xz, lipo, shasum, codesign.
#   --repin also needs `gh` when no TAG argument is given.
#   --check-only and default mode do NOT need `gh`.

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/COOL-TUNNEL/naive"
MANIFEST="${DEST}.upstream.json"

# --------------------------------------------------------------------------
# Argument parsing
# --------------------------------------------------------------------------

MODE="verify"
REPIN_TAG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)
            MODE="check"
            shift
            ;;
        --repin)
            MODE="repin"
            shift
            # Optional positional tag argument follows --repin.
            if [[ $# -gt 0 && "$1" != --* ]]; then
                REPIN_TAG="$1"
                shift
            fi
            ;;
        -h|--help)
            sed -n '2,49p' "$0"
            exit 0
            ;;
        *)
            echo "unknown argument: $1" >&2
            echo "run with --help for usage" >&2
            exit 1
            ;;
    esac
done

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

# Extract a top-level scalar field from naive.upstream.json. Uses jq
# when available, falls back to a tolerant grep/sed pair otherwise so
# this script stays usable on a fresh CI runner before any brew install.
manifest_field() {
    local field="$1"
    if command -v jq >/dev/null 2>&1; then
        jq -r ".${field} // empty" "${MANIFEST}"
    else
        sed -n "s/.*\"${field}\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "${MANIFEST}" | head -n 1
    fi
}

require_manifest() {
    if [[ ! -f "${MANIFEST}" ]]; then
        echo "error: ${MANIFEST} not found." >&2
        echo "       Run scripts/fetch_naive.sh --repin to establish the initial pin." >&2
        exit 3
    fi
}

# Downloads tarballs for the given tag into a fresh temp dir, extracts
# them, lipo-merges into a universal binary, ad-hoc signs it, and prints
# the resulting SHAs to globals: TAR_ARM64_SHA, TAR_X64_SHA, MERGED_SHA,
# MERGED_PATH. Caller owns cleanup of WORK_DIR via the EXIT trap below.
download_and_build_universal() {
    local tag="$1"
    local arm64_asset="naiveproxy-${tag}-mac-arm64-arm64.tar.xz"
    local x64_asset="naiveproxy-${tag}-mac-x64-x64.tar.xz"
    local base_url="https://github.com/klzgrad/naiveproxy/releases/download/${tag}"

    echo "info: fetching ${arm64_asset}"
    echo "info: fetching ${x64_asset}"

    # -f: fail on HTTP error rather than write the error page.
    # -L: follow GitHub's redirect to the S3-backed asset URL.
    curl -fLs --retry 3 --retry-delay 2 \
        -o "${WORK_DIR}/${arm64_asset}" "${base_url}/${arm64_asset}"
    curl -fLs --retry 3 --retry-delay 2 \
        -o "${WORK_DIR}/${x64_asset}" "${base_url}/${x64_asset}"

    TAR_ARM64_SHA="$(shasum -a 256 "${WORK_DIR}/${arm64_asset}" | awk '{print $1}')"
    TAR_X64_SHA="$(shasum -a 256 "${WORK_DIR}/${x64_asset}" | awk '{print $1}')"
    echo "info: arm64 tarball sha256: ${TAR_ARM64_SHA}"
    echo "info: x64   tarball sha256: ${TAR_X64_SHA}"

    mkdir -p "${WORK_DIR}/arm64" "${WORK_DIR}/x64"
    tar -xJf "${WORK_DIR}/${arm64_asset}" -C "${WORK_DIR}/arm64" --strip-components=1
    tar -xJf "${WORK_DIR}/${x64_asset}"   -C "${WORK_DIR}/x64"   --strip-components=1

    local arm64_bin="${WORK_DIR}/arm64/naive"
    local x64_bin="${WORK_DIR}/x64/naive"
    if [[ ! -x "${arm64_bin}" || ! -x "${x64_bin}" ]]; then
        echo "error: extracted tarball did not contain a 'naive' executable" >&2
        exit 2
    fi

    # Defensive: upstream sometimes ships a single Mach-O that is
    # already universal, in which case `lipo -create` would refuse
    # with a duplicate-arch error. Report the slice info so a
    # future operator can adjust if upstream packaging changes.
    echo "info: arm64 input → $(lipo -info "${arm64_bin}")"
    echo "info: x64   input → $(lipo -info "${x64_bin}")"

    MERGED_PATH="${WORK_DIR}/naive-universal"
    if ! lipo -create "${arm64_bin}" "${x64_bin}" -output "${MERGED_PATH}"; then
        echo "error: lipo merge failed" >&2
        exit 2
    fi

    local merged_info
    merged_info="$(lipo -info "${MERGED_PATH}")"
    echo "info: merged    → ${merged_info}"
    if ! grep -q "arm64" <<<"${merged_info}" || ! grep -q "x86_64" <<<"${merged_info}"; then
        echo "error: merged binary is missing arm64 or x86_64 slice" >&2
        exit 2
    fi

    # Ad-hoc sign so macOS Gatekeeper does not reject it as missing
    # a signature. Apps without a Developer ID still need *some*
    # signature to launch; `-` means ad-hoc identity.
    codesign --force --sign - --timestamp=none "${MERGED_PATH}"

    MERGED_SHA="$(shasum -a 256 "${MERGED_PATH}" | awk '{print $1}')"
    echo "info: merged sha256: ${MERGED_SHA}"
}

# --------------------------------------------------------------------------
# Mode: verify (default)
# --------------------------------------------------------------------------

if [[ "${MODE}" == "verify" ]]; then
    require_manifest
    if [[ ! -f "${DEST}" ]]; then
        echo "error: ${DEST} not found." >&2
        echo "       The bundled binary is committed to the repo; this should not happen on a clean checkout." >&2
        exit 3
    fi

    EXPECTED_MERGED_SHA="$(manifest_field merged_universal_sha256)"
    EXPECTED_TAG="$(manifest_field upstream_tag)"
    if [[ -z "${EXPECTED_MERGED_SHA}" ]]; then
        echo "error: manifest has no merged_universal_sha256 field — refusing to proceed." >&2
        exit 3
    fi
    ACTUAL_MERGED_SHA="$(shasum -a 256 "${DEST}" | awk '{print $1}')"
    if [[ "${ACTUAL_MERGED_SHA}" != "${EXPECTED_MERGED_SHA}" ]]; then
        echo "error: bundled naive does not match the committed pin." >&2
        echo "       expected: ${EXPECTED_MERGED_SHA} (upstream ${EXPECTED_TAG})" >&2
        echo "       actual  : ${ACTUAL_MERGED_SHA}" >&2
        echo "       Either the bundled binary was tampered with, or the manifest is out of date." >&2
        echo "       Roll the pin explicitly with: scripts/fetch_naive.sh --repin" >&2
        exit 3
    fi
    echo "ok: bundled naive matches pin (upstream ${EXPECTED_TAG}, sha256 ${EXPECTED_MERGED_SHA})"
    exit 0
fi

# --------------------------------------------------------------------------
# Network-using modes share a temp workspace.
# --------------------------------------------------------------------------

WORK_DIR="$(mktemp -d -t cool-tunnel-naive-XXXXXX)"
# shellcheck disable=SC2064  # WORK_DIR is set above; we want EXPANSION-AT-DEFINE here.
trap "rm -rf '${WORK_DIR}'" EXIT

# --------------------------------------------------------------------------
# Mode: check-only (audit upstream against committed pin)
# --------------------------------------------------------------------------

if [[ "${MODE}" == "check" ]]; then
    require_manifest

    EXPECTED_TAG="$(manifest_field upstream_tag)"
    EXPECTED_ARM64_SHA="$(manifest_field arm64_tarball_sha256)"
    EXPECTED_X64_SHA="$(manifest_field x64_tarball_sha256)"
    EXPECTED_MERGED_SHA="$(manifest_field merged_universal_sha256)"
    if [[ -z "${EXPECTED_TAG}" || -z "${EXPECTED_ARM64_SHA}" || -z "${EXPECTED_X64_SHA}" || -z "${EXPECTED_MERGED_SHA}" ]]; then
        echo "error: manifest is incomplete — missing one of upstream_tag, arm64_tarball_sha256, x64_tarball_sha256, merged_universal_sha256." >&2
        exit 3
    fi

    echo "info: auditing upstream ${EXPECTED_TAG} against committed pin"
    download_and_build_universal "${EXPECTED_TAG}"

    fail=0
    if [[ "${TAR_ARM64_SHA}" != "${EXPECTED_ARM64_SHA}" ]]; then
        echo "DRIFT: arm64 tarball SHA changed at upstream ${EXPECTED_TAG}" >&2
        echo "       pinned : ${EXPECTED_ARM64_SHA}" >&2
        echo "       current: ${TAR_ARM64_SHA}" >&2
        fail=1
    fi
    if [[ "${TAR_X64_SHA}" != "${EXPECTED_X64_SHA}" ]]; then
        echo "DRIFT: x64 tarball SHA changed at upstream ${EXPECTED_TAG}" >&2
        echo "       pinned : ${EXPECTED_X64_SHA}" >&2
        echo "       current: ${TAR_X64_SHA}" >&2
        fail=1
    fi
    if [[ "${MERGED_SHA}" != "${EXPECTED_MERGED_SHA}" ]]; then
        echo "DRIFT: merged-universal SHA does not reproduce" >&2
        echo "       pinned : ${EXPECTED_MERGED_SHA}" >&2
        echo "       current: ${MERGED_SHA}" >&2
        fail=1
    fi
    if [[ -f "${DEST}" ]]; then
        ACTUAL_BUNDLED_SHA="$(shasum -a 256 "${DEST}" | awk '{print $1}')"
        if [[ "${ACTUAL_BUNDLED_SHA}" != "${EXPECTED_MERGED_SHA}" ]]; then
            echo "DRIFT: bundled binary does not match pin" >&2
            echo "       pinned : ${EXPECTED_MERGED_SHA}" >&2
            echo "       bundled: ${ACTUAL_BUNDLED_SHA}" >&2
            fail=1
        fi
    fi

    if (( fail )); then
        echo "" >&2
        echo "Any DRIFT here is a supply-chain signal:" >&2
        echo "  - upstream tag rewrite, or"  >&2
        echo "  - mirror tampering / TLS-MITM during a previous pin, or" >&2
        echo "  - local working-tree tampering." >&2
        echo "Do not roll the pin until the root cause is understood." >&2
        exit 3
    fi
    echo "ok: upstream ${EXPECTED_TAG} reproduces pinned SHAs (tarballs + merged)"
    echo "ok: bundled binary matches pin"
    exit 0
fi

# --------------------------------------------------------------------------
# Mode: repin (explicit operator action)
# --------------------------------------------------------------------------

if [[ "${MODE}" == "repin" ]]; then
    if [[ -z "${REPIN_TAG}" ]]; then
        if ! command -v gh >/dev/null 2>&1; then
            echo "error: --repin without TAG requires \`gh\` to resolve the latest release." >&2
            echo "       Either install gh, or pass a tag: scripts/fetch_naive.sh --repin vX.Y.Z" >&2
            exit 1
        fi
        REPIN_TAG="$(gh release list --repo klzgrad/naiveproxy --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
        if [[ -z "${REPIN_TAG}" ]]; then
            REPIN_TAG="$(gh release list --repo klzgrad/naiveproxy --limit 1 --json tagName --jq '.[0].tagName')"
        fi
        echo "info: resolved latest naiveproxy tag → ${REPIN_TAG}"
    fi

    download_and_build_universal "${REPIN_TAG}"

    # Show the operator what they would be rolling to.
    echo ""
    echo "== Pin diff =="
    if [[ -f "${MANIFEST}" ]]; then
        OLD_TAG="$(manifest_field upstream_tag)"
        OLD_ARM64="$(manifest_field arm64_tarball_sha256)"
        OLD_X64="$(manifest_field x64_tarball_sha256)"
        OLD_MERGED="$(manifest_field merged_universal_sha256)"
        echo "  tag           : ${OLD_TAG} → ${REPIN_TAG}"
        echo "  arm64 tarball : ${OLD_ARM64} → ${TAR_ARM64_SHA}"
        echo "  x64   tarball : ${OLD_X64} → ${TAR_X64_SHA}"
        echo "  merged sha256 : ${OLD_MERGED} → ${MERGED_SHA}"
    else
        echo "  (no existing manifest — this would be the initial pin)"
        echo "  tag           : ${REPIN_TAG}"
        echo "  arm64 tarball : ${TAR_ARM64_SHA}"
        echo "  x64   tarball : ${TAR_X64_SHA}"
        echo "  merged sha256 : ${MERGED_SHA}"
    fi
    echo ""

    if [[ "${CT_REPIN_CONFIRM:-}" != "1" ]]; then
        echo "Re-pinning would rewrite both COOL-TUNNEL/naive and naive.upstream.json." >&2
        echo "To proceed, re-run with CT_REPIN_CONFIRM=1 set in the environment:" >&2
        echo "" >&2
        echo "    CT_REPIN_CONFIRM=1 scripts/fetch_naive.sh --repin ${REPIN_TAG}" >&2
        echo "" >&2
        echo "The change MUST land as a single commit (binary + manifest) that names" >&2
        echo "the old → new tag transition in the message." >&2
        exit 4
    fi

    # Replace the bundled binary atomically so a partial copy never
    # lands at the destination path.
    TMP_DEST="${DEST}.tmp"
    cp "${MERGED_PATH}" "${TMP_DEST}"
    chmod +x "${TMP_DEST}"
    mv "${TMP_DEST}" "${DEST}"

    # Rewrite the manifest. We intentionally always rewrite here
    # (no "same SHAs → preserve fetched_at" guard) because reaching
    # this branch requires CT_REPIN_CONFIRM=1 — the operator has
    # already committed to a deliberate update.
    cat > "${MANIFEST}" <<EOF
{
  "upstream_tag": "${REPIN_TAG}",
  "arm64_tarball_sha256": "${TAR_ARM64_SHA}",
  "x64_tarball_sha256":   "${TAR_X64_SHA}",
  "merged_universal_sha256": "${MERGED_SHA}",
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

    echo ""
    echo "ok: wrote universal naive to ${DEST}"
    echo "ok: wrote pin manifest to  ${MANIFEST}"
    echo "    tag    : ${REPIN_TAG}"
    echo "    sha256 : ${MERGED_SHA}"
    echo ""
    echo "Next: commit both files together. Suggested message:"
    echo "  chore(naive): repin to ${REPIN_TAG}"
    exit 0
fi

echo "internal error: unreachable mode ${MODE}" >&2
exit 1
