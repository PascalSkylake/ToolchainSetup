#!/usr/bin/env bash
set -euo pipefail

# Build GNU Make 4.4.1: static musl on Linux, native MinGW on Windows,
# and Apple Clang + lipo on macOS. All build files stay in a temporary directory.
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: build-make.sh PLATFORM OUTPUT_DIR'
    echo 'Linux requires musl-gcc, make, and binutils; Windows requires MSYS2 UCRT64 GCC; macOS requires Xcode tools.'
    exit 0
fi
[[ $# == 2 ]] || { echo 'Usage: build-make.sh PLATFORM OUTPUT_DIR' >&2; exit 2; }
platform=$1
case "$(uname -s):$(uname -m):$platform" in
    Linux:x86_64:Linux-x86_64|Linux:aarch64:Linux-AArch64|Linux:arm64:Linux-AArch64) ;;
    Darwin:*:Darwin-universal) ;;
    MINGW*:x86_64:Windows-x86_64|MSYS*:x86_64:Windows-x86_64) ;;
    *) echo "Unsupported platform or mismatched runner: $platform" >&2; exit 2 ;;
esac
mkdir -p "$2"
output_dir=$(cd "$2" && pwd)
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/make-build.XXXXXX")
trap 'rm -rf "$work"' EXIT
curl --fail --location --retry 3 https://ftp.gnu.org/gnu/make/make-4.4.1.tar.gz \
    --output "$work/make.tar.gz"
tar -xzf "$work/make.tar.gz" -C "$work"
source_dir="$work/make-4.4.1"
jobs=${JOBS:-4}
exe=

case "$platform" in
    Linux-*)
        mkdir "$work/build"
        (
            cd "$work/build"
            CC=musl-gcc CFLAGS='-O2 -std=gnu11' LDFLAGS=-static \
                "$source_dir/configure" --without-guile --disable-nls --disable-load
            make -j "$jobs"
            strip make
        )
        cp "$work/build/make" "$output_dir/make"
        # Static PIE can have a dynamic section; reject NEEDED and INTERP instead.
        readelf -d "$output_dir/make" > "$work/dynamic.txt"
        readelf -l "$output_dir/make" > "$work/segments.txt"
        if grep -q NEEDED "$work/dynamic.txt" || grep -q INTERP "$work/segments.txt"; then
            echo 'Linux make must be statically linked.' >&2
            exit 1
        fi
        ;;
    Darwin-universal)
        export MACOSX_DEPLOYMENT_TARGET=11.0
        for arch in arm64 x86_64; do
            mkdir "$work/$arch"
            (
                cd "$work/$arch"
                CC="clang -arch $arch" CFLAGS='-O2 -std=gnu11' \
                    "$source_dir/configure" --host="$arch-apple-darwin" \
                    --build="$("$source_dir/build-aux/config.guess")" \
                    --without-guile --disable-nls --disable-load
                /usr/bin/make -j "$jobs"
            )
        done
        lipo -create "$work/arm64/make" "$work/x86_64/make" -output "$output_dir/make"
        strip "$output_dir/make"
        codesign --force --sign - "$output_dir/make"
        lipo "$output_dir/make" -verify_arch arm64 x86_64
        ;;
    Windows-x86_64)
        exe=.exe
        [[ $(gcc -dumpmachine) == x86_64-w64-mingw32 ]] || {
            echo 'Use the MSYS2 UCRT64 MinGW compiler, not the MSYS compiler.' >&2
            exit 1
        }
        (
            cd "$source_dir"
            # The upstream Windows build uses gnu99 and config.h.W32.
            MSYS2_ARG_CONV_EXCL='*' cmd.exe /d /c 'build_w32.bat --without-guile gcc'
            # Link compiler support statically; retain only Windows system DLLs.
            gcc -mthreads -static -static-libgcc -s -o make.exe @GccRel/link.sc
        )
        cp "$source_dir/make.exe" "$output_dir/make.exe"
        ;;
esac
chmod +x "$output_dir/make$exe"
"$output_dir/make$exe" --version
# Included inside the final toolchain, not uploaded as separate artifacts.
cp "$source_dir/COPYING" "$output_dir/make-COPYING"
printf 'Built %s/make%s\n' "$output_dir" "$exe"
