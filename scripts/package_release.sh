#!/usr/bin/env bash
# scripts/package_release.sh
#
# Builds the three release artefacts (.dmg, .pkg, .zip) from a Release
# `Cool tunnel.app` bundle and prints a SHA-256 manifest. Mirrors the
# manual flow we used for v0.1.2/v0.1.3 so each release is reproducible
# from one command.
#
# Usage:
#   scripts/package_release.sh 0.1.4 [path/to/Cool\ tunnel.app]
#
# Output:
#   dist/Cool-tunnel-v<VERSION>.dmg     (drag-and-drop image)
#   dist/Cool-tunnel-v<VERSION>.pkg     (Installer.app component)
#   dist/Cool-tunnel-v<VERSION>.zip     (ditto-archived bundle)
#   dist/Cool-tunnel-v<VERSION>.sha256  (manifest with all three hashes)
#
# Exit codes:
#   0  success
#   1  bad arguments / missing app
#   2  packaging step failed

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${REPO_ROOT}/dist"

if [[ $# -lt 1 ]]; then
    echo "usage: $0 <version> [app-path]" >&2
    exit 1
fi
VERSION="$1"
APP="${2:-${REPO_ROOT}/build/DerivedData/Build/Products/Release/Cool tunnel.app}"

if [[ ! -d "${APP}" ]]; then
    echo "error: app bundle not found at ${APP}" >&2
    exit 1
fi

# --- U#6 (v2.0.1): Cargo.toml precondition ---------------------------------
# Reject the packaging run if `core/Cargo.toml`'s version field
# doesn't match the version arg. v2.0.0 shipped a Rust binary
# self-reporting `0.1.7` because the Cargo.toml version was never
# bumped — the in-app updater then declared "Updated to v2.0.0"
# while the verdict pill read `cool-tunnel-core 0.1.7`. Catching
# the mismatch here means future releases either ship a coherent
# binary or fail-fast at packaging time, never half-and-half.
CARGO_TOML="${REPO_ROOT}/core/Cargo.toml"
if [[ -f "${CARGO_TOML}" ]]; then
    CARGO_VERSION=$(awk -F'"' '/^version[[:space:]]*=/ { print $2; exit }' "${CARGO_TOML}")
    if [[ -z "${CARGO_VERSION}" ]]; then
        echo "error: could not parse version from ${CARGO_TOML}" >&2
        exit 1
    fi
    if [[ "${CARGO_VERSION}" != "${VERSION}" ]]; then
        echo "error: core/Cargo.toml version is '${CARGO_VERSION}' but you requested '${VERSION}'" >&2
        echo "       bump core/Cargo.toml's version field to ${VERSION} and rebuild before retrying." >&2
        exit 1
    fi
fi

# --- U#5 (v2.0.1): Resources/cool-tunnel-core precondition -----------------
# Verify the just-built .app's bundled Rust binary actually
# self-identifies as the requested version. If a developer
# remembered to bump Cargo.toml but forgot to rebuild the .app,
# `Resources/cool-tunnel-core` is still the previous version's
# binary. The Xcode build phase rebuilds it on every `xcodebuild
# build`, but a stale Release/ output dir from a prior run can
# linger — this check catches that stale output before we ship.
CORE_IN_APP="${APP}/Contents/Resources/cool-tunnel-core"
if [[ -x "${CORE_IN_APP}" ]]; then
    CORE_VERSION_LINE="$("${CORE_IN_APP}" --version 2>/dev/null | head -1 || true)"
    # Expected line: `cool-tunnel-core <semver>` — extract the
    # last whitespace-delimited token.
    CORE_VERSION="${CORE_VERSION_LINE##* }"
    if [[ "${CORE_VERSION}" != "${VERSION}" ]]; then
        echo "error: ${CORE_IN_APP##*/} self-reports '${CORE_VERSION}' (line: '${CORE_VERSION_LINE}'), expected '${VERSION}'" >&2
        echo "       the .app bundle is stale; run a fresh \`xcodebuild ... build\` to regenerate" >&2
        echo "       Resources/cool-tunnel-core from the bumped Cargo.toml, then retry." >&2
        exit 1
    fi
fi

# --- U#7 (v2.0.16): Info.plist CFBundleShortVersionString precondition -----
# Verify the .app's marketing version matches the requested
# release version. The xcodeproj's `MARKETING_VERSION` build
# setting is the source of truth here — and unlike Cargo.toml
# (which the Rust crate's `--version` reflects), the .app's
# Info.plist version is set ONLY at xcodebuild time. v2.0.15
# shipped with `MARKETING_VERSION` still at 2.0.14 even though
# Cargo.toml + bundled cool-tunnel-core were both at 2.0.15:
# the in-app updater's `verifyExtractedApp` (AU-7) caught it
# and refused to install ("New app's version does not match
# the release tag 2.0.15. Refusing to install."), but only
# after the user already downloaded the .zip. This check fails
# the release at packaging time so the broken bundle never
# leaves the build machine.
APP_PLIST="${APP}/Contents/Info.plist"
if [[ -f "${APP_PLIST}" ]]; then
    APP_SHORT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${APP_PLIST}" 2>/dev/null || echo "?")"
    if [[ "${APP_SHORT_VERSION}" != "${VERSION}" ]]; then
        echo "error: .app Info.plist CFBundleShortVersionString is '${APP_SHORT_VERSION}', expected '${VERSION}'" >&2
        echo "       bump MARKETING_VERSION in COOL-TUNNEL.xcodeproj/project.pbxproj (both Debug + Release configs)" >&2
        echo "       to ${VERSION}, run a fresh \`xcodebuild ... build\`, then retry." >&2
        exit 1
    fi
fi

mkdir -p "${DIST_DIR}"

DMG="${DIST_DIR}/Cool-tunnel-v${VERSION}.dmg"
PKG="${DIST_DIR}/Cool-tunnel-v${VERSION}.pkg"
ZIP="${DIST_DIR}/Cool-tunnel-v${VERSION}.zip"
# Standalone universal cool-tunnel-core binary as a separate
# release asset. The Settings → Rust Core → Update flow
# downloads this directly from GitHub so users can refresh
# the engine without reinstalling the whole .app.
CORE="${DIST_DIR}/cool-tunnel-core-v${VERSION}-universal"
MANIFEST="${DIST_DIR}/Cool-tunnel-v${VERSION}.sha256"

# --- DMG ---------------------------------------------------------------
# Stage with an `Applications` symlink so users can drag-install. Use
# UDZO (compressed) for the smallest download.
echo "info: building ${DMG##*/}"
STAGE="${DIST_DIR}/dmg-staging-v${VERSION}"
rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${APP}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"
hdiutil create \
    -volname "Cool Tunnel v${VERSION}" \
    -srcfolder "${STAGE}" \
    -ov -format UDZO \
    "${DMG}" >/dev/null

# --- PKG ---------------------------------------------------------------
# **v2.0.10 (poka-yoke):** the .pkg is now a *distribution*
# package wrapping a component, not a flat component package.
# The distribution wrapper carries an `installation-check`
# JavaScript that runs before any install actions: it calls
# `pgrep -x "Cool Tunnel"` and refuses (Fatal) to install
# while the app is currently running. Pre-2.0.10 a user could
# double-click the .pkg with Cool Tunnel still in the menu bar
# and Installer.app would happily try to overwrite the running
# bundle — sometimes succeeding (so the in-memory copy was the
# old version), sometimes failing mid-write (so the bundle was
# half-replaced). The pre-flight closes both failure modes.
#
# Build flow:
#   1. pkgbuild → cooltunnel-component.pkg     (the payload)
#   2. Substitute {{VERSION}} into the
#      Distribution.xml template.
#   3. productbuild --distribution …           (the wrapper)
#
# Identifier still matches the bundle id with `.pkg` so a
# productbuild-signed update can upgrade in place.
echo "info: building ${PKG##*/}"
rm -f "${PKG}"
PKG_STAGE="${DIST_DIR}/pkg-staging-v${VERSION}"
rm -rf "${PKG_STAGE}"
mkdir -p "${PKG_STAGE}"
COMPONENT_PKG="${PKG_STAGE}/cooltunnel-component.pkg"
pkgbuild \
    --component "${APP}" \
    --install-location /Applications \
    --identifier space.coolwhite.cooltunnel.pkg \
    --version "${VERSION}" \
    "${COMPONENT_PKG}" >/dev/null

DIST_XML_TEMPLATE="${REPO_ROOT}/scripts/Distribution.xml.template"
if [[ ! -f "${DIST_XML_TEMPLATE}" ]]; then
    echo "error: missing Distribution.xml template at ${DIST_XML_TEMPLATE}" >&2
    exit 2
fi
DIST_XML="${PKG_STAGE}/Distribution.xml"
# Substitute the {{VERSION}} placeholder. Use awk rather than
# sed-with-/ so the substitution is safe regardless of what
# characters appear in VERSION (sed's default delimiter chokes
# on / or .). awk's gsub takes literal strings unless we use a
# regex marker, so this is robust.
awk -v ver="${VERSION}" '{
    gsub(/\{\{VERSION\}\}/, ver)
    print
}' "${DIST_XML_TEMPLATE}" > "${DIST_XML}"

productbuild \
    --distribution "${DIST_XML}" \
    --package-path "${PKG_STAGE}" \
    "${PKG}" >/dev/null

# --- ZIP ---------------------------------------------------------------
# `ditto` preserves macOS metadata (extended attributes, code signature)
# better than `zip`. The roundtrip leaves the ad-hoc signature intact
# so right-click → Open works after extraction.
echo "info: building ${ZIP##*/}"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

# --- Standalone Rust core --------------------------------------------------
# Lift the universal cool-tunnel-core binary out of the app bundle and
# emit it as a separate, ad-hoc-signed release asset. The macOS
# Settings → Rust Core → Update flow downloads this URL directly to
# `~/Library/Application Support/COOL-TUNNEL/cool-tunnel-core-managed`
# so the engine can be refreshed without reinstalling the whole .app.
echo "info: building ${CORE##*/}"
rm -f "${CORE}"
cp "${APP}/Contents/Resources/cool-tunnel-core" "${CORE}"
chmod +x "${CORE}"

# --- SHA-256 manifest --------------------------------------------------
# Single file containing every hash so the release notes and any
# downstream mirror script can pin the exact downloads.
{
    shasum -a 256 "${DMG}"
    shasum -a 256 "${PKG}"
    shasum -a 256 "${ZIP}"
    shasum -a 256 "${CORE}"
} | awk '{ n=split($2, p, "/"); print $1 "  " p[n] }' > "${MANIFEST}"

echo ""
echo "ok: artefacts written to ${DIST_DIR}/"
# `stat -f` portability: macOS uses `-f`, Linux uses `-c` — guard with
# a probe so the script keeps working if someone runs it on Linux for
# CI experimentation later.
for f in "${DMG}" "${PKG}" "${ZIP}" "${CORE}"; do
    if size=$(stat -f '%z' "${f}" 2>/dev/null) || size=$(stat -c '%s' "${f}" 2>/dev/null); then
        # Convert bytes to a human-readable size (KB/MB/GB) using awk
        # so the output mirrors `ls -lh` without the parse-ls warning.
        human=$(awk -v b="${size}" 'BEGIN {
            split("B KB MB GB TB", u);
            for (i = 1; b >= 1024 && i < 5; i++) b /= 1024;
            printf "%.1f%s", b, u[i]
        }')
        printf "    %s  %s\n" "${f##*/}" "${human}"
    fi
done
echo ""
echo "sha256 manifest:"
sed 's/^/    /' "${MANIFEST}"

# Print the canonical `gh release create` command with ALL FIVE
# release assets pre-filled. v0.1.7.7 shipped without uploading
# the .sha256 manifest because that command was typed by hand
# from memory, leaving the in-app updater unable to verify
# (resolved in v0.1.7.8). Copy-pasting this command guarantees
# the manifest goes up alongside the binaries.
echo ""
echo "next step — publish to GitHub with ALL FIVE assets:"
echo ""
echo "  gh release create v${VERSION} \\"
echo "    ${DMG} \\"
echo "    ${PKG} \\"
echo "    ${ZIP} \\"
echo "    ${CORE} \\"
echo "    ${MANIFEST} \\"
echo "    --title \"v${VERSION} — <title>\" \\"
echo "    --notes-file <path-to-notes.md> \\"
echo "    --latest"
echo ""
echo "the .sha256 manifest is REQUIRED — the in-app updater"
echo "refuses to install a release that lacks it."

# Clean up the dmg + pkg staging directories — they served
# their purpose. The pkg-staging dir holds the intermediate
# component .pkg + the version-substituted Distribution.xml;
# both are recreated from scratch on every packaging run.
rm -rf "${STAGE}" "${PKG_STAGE}"
