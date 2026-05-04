#!/usr/bin/env bash
# scripts/build_rust_core.sh
#
# Builds the `cool-tunnel-core` Rust binary and copies it into the Xcode
# build output directory. Called from the "Build Rust core" Xcode run
# script phase, but also runnable from the CLI for local testing.
#
# Behaviour by configuration:
#   Debug    → single-arch build for the host CPU (fast iteration)
#   Release  → universal binary (arm64 + x86_64) merged with `lipo`
#
# Required environment (when called from Xcode):
#   CONFIGURATION                  Debug | Release
#   NATIVE_ARCH                    arm64 | x86_64
#   BUILT_PRODUCTS_DIR             absolute path to the build product dir
#   UNLOCALIZED_RESOURCES_FOLDER_PATH   relative path to Resources/ inside
#                                       the bundle
#   SRCROOT                        the Xcode project root (we cd to
#                                  $SRCROOT/core before invoking cargo)
#
# When run outside Xcode, the script picks sensible defaults so a
# developer can verify universal builds locally:
#   CONFIGURATION=Release scripts/build_rust_core.sh
#
# Exit codes:
#   0  success
#   1  cargo not on PATH and not found in the well-known install paths
#   2  cargo build failed
#   3  lipo merge failed (Release only)

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRCROOT="${SRCROOT:-${REPO_ROOT}}"
CONFIGURATION="${CONFIGURATION:-Release}"
NATIVE_ARCH="${NATIVE_ARCH:-$(uname -m)}"

# Locate cargo. Xcode does not source the user's shell rc, so $HOME/.cargo
# is the fallback even when rustup put cargo on PATH for the user's
# interactive sessions.
CARGO=""
for candidate in "${HOME}/.cargo/bin/cargo" "/opt/homebrew/bin/cargo" "/usr/local/bin/cargo"; do
    if [[ -x "${candidate}" ]]; then
        CARGO="${candidate}"
        break
    fi
done
if [[ -z "${CARGO}" ]]; then
    if command -v cargo >/dev/null 2>&1; then
        CARGO="$(command -v cargo)"
    else
        echo "error: cargo not found. Install Rust via https://rustup.rs/ and rebuild." >&2
        exit 1
    fi
fi

cd "${SRCROOT}/core"

case "${CONFIGURATION}" in
    Release)
        PROFILE="release"
        FLAGS=("--release")
        ;;
    *)
        PROFILE="debug"
        FLAGS=()
        ;;
esac

# Map every reasonable spelling of the host CPU back to the canonical
# Rust target triples.
host_target() {
    case "${NATIVE_ARCH}" in
        arm64|aarch64) echo "aarch64-apple-darwin" ;;
        x86_64)        echo "x86_64-apple-darwin"  ;;
        *)             echo "aarch64-apple-darwin" ;;
    esac
}

build_target() {
    local target="$1"
    echo "info: building cool-tunnel-core (${PROFILE}, ${target})"
    # Bash 3.2 (the macOS default) chokes on `${arr[@]}` when the array
    # is empty under `set -u`; the `${arr[@]+"${arr[@]}"}` idiom expands
    # to nothing in that case instead of raising "unbound variable".
    # **Shell-F#5 (v0.1.7.16):** `--locked` makes the build refuse
    # to silently regenerate `Cargo.lock` if it's out of date.
    # The LTSC posture treats Cargo.lock as a release artefact;
    # without `--locked`, a missing or stale lockfile would be
    # silently regenerated against newer transitive deps,
    # defeating reproducibility.
    if ! "${CARGO}" build --locked ${FLAGS[@]+"${FLAGS[@]}"} --target "${target}" --bin cool-tunnel-core; then
        echo "error: cargo build failed for ${target}" >&2
        exit 2
    fi
}

if [[ "${CONFIGURATION}" == "Release" ]]; then
    # Universal: build both arches, lipo them together. This costs about
    # 2x the build time of a single arch but produces a binary that
    # runs natively on both Apple Silicon and Intel — no Rosetta, no
    # per-platform downloads.
    build_target "aarch64-apple-darwin"
    build_target "x86_64-apple-darwin"

    UNIVERSAL_OUT="target/release/cool-tunnel-core-universal"
    if ! lipo -create \
        "target/aarch64-apple-darwin/release/cool-tunnel-core" \
        "target/x86_64-apple-darwin/release/cool-tunnel-core" \
        -output "${UNIVERSAL_OUT}"; then
        echo "error: lipo merge failed" >&2
        exit 3
    fi

    # Sanity-check before copying — better to fail the build than to
    # ship a "universal" binary that is missing one slice.
    INFO="$(lipo -info "${UNIVERSAL_OUT}")"
    echo "info: merged → ${INFO}"
    if ! grep -q "arm64" <<<"${INFO}" || ! grep -q "x86_64" <<<"${INFO}"; then
        echo "error: merged binary missing arm64 or x86_64 slice" >&2
        exit 3
    fi

    SOURCE_BIN="${UNIVERSAL_OUT}"
else
    HOST_TARGET="$(host_target)"
    build_target "${HOST_TARGET}"
    SOURCE_BIN="target/${HOST_TARGET}/${PROFILE}/cool-tunnel-core"
fi

# When run outside Xcode the destination variables are not set; default
# to placing the binary in target/<profile>/ for ad-hoc inspection.
if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -n "${UNLOCALIZED_RESOURCES_FOLDER_PATH:-}" ]]; then
    DEST_DIR="${BUILT_PRODUCTS_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}"
else
    DEST_DIR="target/${PROFILE}"
fi
mkdir -p "${DEST_DIR}"
cp "${SOURCE_BIN}" "${DEST_DIR}/cool-tunnel-core"
chmod +x "${DEST_DIR}/cool-tunnel-core"

# Cargo on macOS leaves the binary with a "linker-signed" stub that
# `codesign --verify --strict` rejects. Apply a proper ad-hoc signature
# so the security check accepts it and so the Swift CodeSignVerifier
# (which uses SecStaticCodeCheckValidity) accepts it before spawning.
# The `-` identity means ad-hoc; --force overwrites the stub in place.
codesign --force --sign - --timestamp=none "${DEST_DIR}/cool-tunnel-core"

echo "info: cool-tunnel-core (${CONFIGURATION}) copied to ${DEST_DIR} and ad-hoc signed"
