#!/bin/bash
set -euo pipefail

# Builds Frameworks/IthacaDovi.xcframework (Dolby Vision 7 -> 8.1 conversion,
# Rust) from Native/IthacaDovi. Like VLCKit it is git-ignored: CI runs this via
# ci_scripts/ci_post_clone.sh, and it must be run once locally after cloning.
#
# Idempotent: a hash of every build input is stamped into the xcframework, so
# it is a no-op until the crate, the toolchain pin, the build script or the
# deployment targets change.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORK_DIR="${ROOT_DIR}/Frameworks/IthacaDovi.xcframework"
STAMP_PATH="${FRAMEWORK_DIR}/ithaca-dovi-source.sha256"
BUILD_SCRIPT="${ROOT_DIR}/scripts/build_ithaca_dovi_xcframework.sh"
SLICES=(ios-arm64 ios-arm64-simulator tvos-arm64 tvos-arm64-simulator)

source_hash() {
    (
        cd "${ROOT_DIR}"
        {
            find Native/IthacaDovi/Cargo.toml Native/IthacaDovi/Cargo.lock \
                Native/IthacaDovi/rust-toolchain.toml Native/IthacaDovi/src \
                Native/IthacaDovi/include scripts/build_ithaca_dovi_xcframework.sh \
                -type f ! -name .DS_Store -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256
            grep -E '^    (iOS|tvOS): ' project.yml
        } | shasum -a 256 | cut -d ' ' -f 1
    )
}

has_current_build() {
    [ -f "${STAMP_PATH}" ] || return 1
    [ "$(cat "${STAMP_PATH}")" = "${EXPECTED_HASH}" ] || return 1
    local slice
    for slice in "${SLICES[@]}"; do
        [ -f "${FRAMEWORK_DIR}/${slice}/libithaca_dovi.a" ] || return 1
    done
}

EXPECTED_HASH="$(source_hash)"

if has_current_build; then
    echo "IthacaDovi.xcframework is up to date."
    exit 0
fi

rustup_path="${CARGO_HOME:-${HOME}/.cargo}/bin/rustup"
if [ ! -x "${rustup_path}" ] && ! command -v rustup >/dev/null 2>&1; then
    if [ -n "${CI:-}" ] || [ -n "${CI_XCODE_CLOUD:-}" ]; then
        # A pinned rustup-init checked against these SHA-256s, never a piped
        # installer. Bump all three together from
        # https://static.rust-lang.org/rustup/archive/<ver>/<triple>/rustup-init.sha256
        rustup_version="1.29.1"
        case "$(uname -m)" in
            arm64|aarch64)
                rustup_triple="aarch64-apple-darwin"
                rustup_sha256="ec1b9233e7f72990ecd8e62063fa7f6c3dfc2bec8e97f88bff165f9100ac696a"
                ;;
            x86_64)
                rustup_triple="x86_64-apple-darwin"
                rustup_sha256="259e2b84274434085163fe8d556510571772cda2aa6d87ca6aa664f57bc644e3"
                ;;
            *)
                echo "error: no pinned rustup-init for $(uname -m)." >&2
                exit 1
                ;;
        esac
        echo "Installing rustup ${rustup_version} (no default toolchain; the build pins its own)..."
        rustup_dir="$(mktemp -d)"
        curl --proto '=https' --tlsv1.2 -sSf -o "${rustup_dir}/rustup-init" \
            "https://static.rust-lang.org/rustup/archive/${rustup_version}/${rustup_triple}/rustup-init"
        echo "${rustup_sha256}  ${rustup_dir}/rustup-init" | shasum -a 256 -c -
        chmod +x "${rustup_dir}/rustup-init"
        "${rustup_dir}/rustup-init" -y --profile minimal --default-toolchain none --no-modify-path
        rm -rf "${rustup_dir}"
    else
        cat >&2 <<'EOF'
error: rustup is required to build IthacaDovi.xcframework.
Install it from https://rustup.rs (Homebrew's `rust` formula is not enough:
it has no iOS/tvOS standard library), then rerun ./ci_scripts/install_ithaca_dovi.sh.
EOF
        exit 1
    fi
fi

"${BUILD_SCRIPT}"
printf '%s\n' "${EXPECTED_HASH}" > "${STAMP_PATH}"
echo "IthacaDovi.xcframework installed."
