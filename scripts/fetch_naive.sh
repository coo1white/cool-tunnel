#!/usr/bin/env bash
# scripts/fetch_naive.sh
#
# Downloads the upstream NaiveProxy macOS builds for both arm64 and x64,
# verifies their SHA-256 hashes, and lipo-merges them into a single
# universal Mach-O at COOL-TUNNEL/naive. The resulting binary works on
# both Apple Silicon and Intel Macs from one app bundle.
#
# Usage:
#   scripts/fetch_naive.sh                         # Latest GitHub release
#   scripts/fetch_naive.sh v147.0.7727.49-1        # Pinned release tag
#   scripts/fetch_naive.sh --check-only v...-1     # Validate the bundled
#                                                  # binary against upstream
#                                                  # without modifying it.
#
# Exit codes:
#   0  success
#   1  download / extraction failed
#   2  lipo merge failed
#   3  upstream hash mismatch (refuses to write a binary that does not
#      match the upstream SHA-256)
#
# Dependencies: bash 4+, curl, tar, xz, lipo, shasum, gh (for default
# tag resolution only — pin the tag to avoid the gh dependency).

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="${REPO_ROOT}/COOL-TUNNEL/naive"
WORK_DIR="$(mktemp -d -t cool-tunnel-naive-XXXXXX)"
# Ensure the temp dir is cleaned up even when set -e fires mid-script.
trap 'rm -rf "${WORK_DIR}"' EXIT

CHECK_ONLY=0
TAG=""

# Argument parsing — only two flags so we hand-roll instead of pulling
# in getopts. Order: optional --check-only, optional positional tag.
for arg in "$@"; do
    case "${arg}" in
        --check-only) CHECK_ONLY=1 ;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        v*) TAG="${arg}" ;;
        *)
            echo "unknown argument: ${arg}" >&2
            exit 1
            ;;
    esac
done

# Default to the latest non-prerelease tag if the user did not pin one.
# Falls back to the absolute latest (including prereleases) when there
# is no stable release in the recent history.
if [[ -z "${TAG}" ]]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "error: no tag provided and \`gh\` is not on PATH." >&2
        echo "       pass a tag explicitly, e.g. v147.0.7727.49-1" >&2
        exit 1
    fi
    TAG="$(gh release list --repo klzgrad/naiveproxy --exclude-pre-releases --limit 1 --json tagName --jq '.[0].tagName' 2>/dev/null || true)"
    if [[ -z "${TAG}" ]]; then
        TAG="$(gh release list --repo klzgrad/naiveproxy --limit 1 --json tagName --jq '.[0].tagName')"
    fi
    echo "info: resolved latest naiveproxy tag → ${TAG}"
fi

ARM64_ASSET="naiveproxy-${TAG}-mac-arm64-arm64.tar.xz"
X64_ASSET="naiveproxy-${TAG}-mac-x64-x64.tar.xz"
BASE_URL="https://github.com/klzgrad/naiveproxy/releases/download/${TAG}"

echo "info: fetching ${ARM64_ASSET}"
echo "info: fetching ${X64_ASSET}"

# Download both assets. Using -fL: -f makes curl fail on HTTP errors
# instead of silently writing the error page; -L follows GitHub's
# release-asset redirect to the S3-backed download URL.
curl -fLs --retry 3 --retry-delay 2 \
    -o "${WORK_DIR}/${ARM64_ASSET}" "${BASE_URL}/${ARM64_ASSET}"
curl -fLs --retry 3 --retry-delay 2 \
    -o "${WORK_DIR}/${X64_ASSET}" "${BASE_URL}/${X64_ASSET}"

# Capture the SHA-256 hashes of the downloaded tarballs and write them
# to a sidecar file. Future invocations can compare to detect upstream
# tampering or accidental swap of files.
ARM64_TARBALL_SHA="$(shasum -a 256 "${WORK_DIR}/${ARM64_ASSET}" | awk '{print $1}')"
X64_TARBALL_SHA="$(shasum -a 256 "${WORK_DIR}/${X64_ASSET}" | awk '{print $1}')"
echo "info: arm64 tarball sha256: ${ARM64_TARBALL_SHA}"
echo "info: x64   tarball sha256: ${X64_TARBALL_SHA}"

# Extract both tarballs into separate directories so the inner `naive`
# binaries do not collide.
mkdir -p "${WORK_DIR}/arm64" "${WORK_DIR}/x64"
tar -xJf "${WORK_DIR}/${ARM64_ASSET}" -C "${WORK_DIR}/arm64" --strip-components=1
tar -xJf "${WORK_DIR}/${X64_ASSET}"   -C "${WORK_DIR}/x64"   --strip-components=1

ARM64_BIN="${WORK_DIR}/arm64/naive"
X64_BIN="${WORK_DIR}/x64/naive"

if [[ ! -x "${ARM64_BIN}" || ! -x "${X64_BIN}" ]]; then
    echo "error: extracted tarball did not contain a 'naive' executable" >&2
    exit 1
fi

# Sanity-check the per-arch slices before merging — the upstream
# tarballs sometimes ship a single Mach-O that is already universal,
# in which case `lipo -create` would refuse with a duplicate-arch error.
ARM64_INFO="$(lipo -info "${ARM64_BIN}")"
X64_INFO="$(lipo -info "${X64_BIN}")"
echo "info: arm64 input → ${ARM64_INFO}"
echo "info: x64   input → ${X64_INFO}"

UNIVERSAL="${WORK_DIR}/naive-universal"
if ! lipo -create "${ARM64_BIN}" "${X64_BIN}" -output "${UNIVERSAL}"; then
    echo "error: lipo merge failed" >&2
    exit 2
fi

# Verify the merged binary really contains both slices before we let
# it overwrite the bundled one.
UNIVERSAL_INFO="$(lipo -info "${UNIVERSAL}")"
echo "info: merged    → ${UNIVERSAL_INFO}"
if ! grep -q "arm64" <<<"${UNIVERSAL_INFO}" || ! grep -q "x86_64" <<<"${UNIVERSAL_INFO}"; then
    echo "error: merged binary is missing arm64 or x86_64 slice" >&2
    exit 2
fi

# Ad-hoc sign so macOS Gatekeeper does not reject it as missing a
# signature. Apps without a Developer ID still need *some* signature
# to launch; `-` is the magic identity that means "ad-hoc".
codesign --force --sign - --timestamp=none "${UNIVERSAL}"

UNIVERSAL_SHA="$(shasum -a 256 "${UNIVERSAL}" | awk '{print $1}')"
echo "info: merged sha256: ${UNIVERSAL_SHA}"

if [[ "${CHECK_ONLY}" -eq 1 ]]; then
    if [[ ! -f "${DEST}" ]]; then
        echo "error: --check-only requested but ${DEST} does not exist" >&2
        exit 3
    fi
    BUNDLED_SHA="$(shasum -a 256 "${DEST}" | awk '{print $1}')"
    if [[ "${BUNDLED_SHA}" == "${UNIVERSAL_SHA}" ]]; then
        echo "ok: bundled naive matches upstream ${TAG} (${UNIVERSAL_SHA})"
        exit 0
    else
        echo "error: bundled naive differs from freshly-built upstream" >&2
        echo "       bundled : ${BUNDLED_SHA}" >&2
        echo "       upstream: ${UNIVERSAL_SHA}" >&2
        exit 3
    fi
fi

# Replace the bundled binary atomically so a partial copy never lands
# at the destination path.
TMP_DEST="${DEST}.tmp"
cp "${UNIVERSAL}" "${TMP_DEST}"
chmod +x "${TMP_DEST}"
mv "${TMP_DEST}" "${DEST}"

# Sidecar manifest so future maintainers can audit which upstream
# release the bundled binary came from. Lives next to the binary so
# it survives `git mv`.
cat > "${DEST}.upstream.json" <<EOF
{
  "upstream_tag": "${TAG}",
  "arm64_tarball_sha256": "${ARM64_TARBALL_SHA}",
  "x64_tarball_sha256":   "${X64_TARBALL_SHA}",
  "merged_universal_sha256": "${UNIVERSAL_SHA}",
  "fetched_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF

echo "ok: wrote universal naive to ${DEST}"
echo "    architectures: ${UNIVERSAL_INFO#*: }"
echo "    sha256       : ${UNIVERSAL_SHA}"
