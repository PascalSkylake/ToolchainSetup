#!/usr/bin/env bash
set -euo pipefail

# Run on a matching GitHub Actions runner with Rust and native build tools.
# Linux builds need pkg-config and libudev-dev if required by vflash's dependencies.
# macOS needs both Rust targets: rustup target add aarch64-apple-darwin x86_64-apple-darwin
usage() {
    cat <<'HELP'
Usage: build-vflash.sh PLATFORM SOURCE_DIR OUTPUT_DIR

Build an existing vflash checkout with cargo --release --locked, then copy its
binary to OUTPUT_DIR. Use Linux-x86_64, Linux-AArch64, Darwin-universal, or
Windows-x86_64 on a matching runner. macOS combines both architectures with lipo.
Linux binaries use the runner's system libraries; build on the oldest supported
Linux distribution. Windows uses the MSVC toolchain and static C runtime.
HELP
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# == 3 ]] || { usage >&2; exit 2; }
platform=$1
case "$(uname -s):$(uname -m):$platform" in
    Linux:x86_64:Linux-x86_64) target=x86_64-unknown-linux-gnu ;;
    Linux:aarch64:Linux-AArch64|Linux:arm64:Linux-AArch64) target=aarch64-unknown-linux-gnu ;;
    Darwin:*:Darwin-universal) target=aarch64-apple-darwin ;;
    MINGW*:x86_64:Windows-x86_64|MSYS*:x86_64:Windows-x86_64) target=x86_64-pc-windows-msvc ;;
    *) echo "Unsupported platform or mismatched runner: $platform" >&2; exit 2 ;;
esac
source_dir=$(cd "$2" && pwd)
mkdir -p "$3"
output_dir=$(cd "$3" && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vflash-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
export CARGO_TARGET_DIR=$work/target
exe=
if [[ $platform == Windows-x86_64 ]]; then
    exe=.exe
    unset CARGO_ENCODED_RUSTFLAGS
    export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=+crt-static"
fi
build() {
    cargo build --manifest-path "$source_dir/Cargo.toml" \
        --locked --release --bin vflash --target "$1"
}
build "$target"
if [[ $platform == Darwin-universal ]]; then
    build x86_64-apple-darwin
    lipo -create "$CARGO_TARGET_DIR/aarch64-apple-darwin/release/vflash" \
        "$CARGO_TARGET_DIR/x86_64-apple-darwin/release/vflash" -output "$output_dir/vflash"
    lipo "$output_dir/vflash" -verify_arch arm64 x86_64
    codesign --force --sign - "$output_dir/vflash"
else
    cp "$CARGO_TARGET_DIR/$target/release/vflash$exe" "$output_dir/vflash$exe"
fi
printf 'Built %s/vflash%s\n' "$output_dir" "$exe"
