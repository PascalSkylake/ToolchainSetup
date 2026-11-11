#!/usr/bin/env bash
set -euo pipefail

# Download ATfE and newlib, keep the V5 runtime, add tools, and repackage it.
# Requires curl, unzip, tar, and xz. Packaging the macOS DMG requires macOS.
# All other platforms can be packaged on any host; binaries are only copied.
usage() {
    cat <<'HELP'
Usage: build-toolchain.sh PLATFORM MAKE_BINARY VFLASH_BINARY [OUTPUT_DIR]

Platforms: Linux-x86_64, Linux-AArch64, Darwin-universal, Windows-x86_64
Use binaries built for the selected platform. Output defaults to /tmp/toolchain-artifacts
(or RUNNER_TEMP/toolchain-artifacts in GitHub Actions).

Example:
  ./build-toolchain.sh Linux-x86_64 /usr/bin/make /tmp/vflash/vflash /tmp/dist

VEXCOM_VSIX_URL optionally overrides the VEXcode 0.6.1 extension download URL.
GitHub Actions step output: archive (the completed .tar.xz file).
HELP
}
if [[ ${1:-} == --help || ${1:-} == -h ]]; then usage; exit 0; fi
[[ $# -ge 3 && $# -le 4 ]] || { usage >&2; exit 2; }
platform=$1
make_binary=$2
vflash_binary=$3
version=23.1.0
runtime=armv7a_soft_vfpv3_d16_unaligned
name="ATfE-$version-$platform"
exe=
case "$platform" in
    Linux-x86_64) vex_platform=linux-x64; extension=tar.xz ;;
    Linux-AArch64) vex_platform=linux-arm64; extension=tar.xz ;;
    Darwin-universal) vex_platform=osx; extension=dmg ;;
    Windows-x86_64) vex_platform=win32; extension=zip; exe=.exe ;;
    *) printf 'Unknown platform: %s\n' "$platform" >&2; exit 2 ;;
esac
temp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
output_dir=${4:-$temp_root/toolchain-artifacts}
case "$(uname -s)" in
    MINGW*|MSYS*)
        temp_root=$(cygpath -u "$temp_root")
        output_dir=$(cygpath -u "$output_dir")
        make_binary=$(cygpath -u "$make_binary")
        vflash_binary=$(cygpath -u "$vflash_binary")
        ;;
esac
for binary in "$make_binary" "$vflash_binary"; do
    [[ -f $binary ]] || { printf 'Binary not found: %s\n' "$binary" >&2; exit 1; }
done
if [[ $extension == dmg && $(uname -s) != Darwin ]]; then
    echo 'Package Darwin-universal on macOS so hdiutil can extract the DMG.' >&2
    exit 1
fi

mkdir -p "$output_dir"
output_dir=$(cd "$output_dir" && pwd)
work=$(mktemp -d "$temp_root/toolchain-package.XXXXXX")
mounted=false
progress_pid=
stop_progress() {
    if [[ -n $progress_pid ]]; then
        kill "$progress_pid" 2>/dev/null || true
        wait "$progress_pid" 2>/dev/null || true
        progress_pid=
    fi
}
cleanup() {
    stop_progress
    if [[ $mounted == true ]]; then hdiutil detach "$work/mount" -quiet || true; fi
    rm -rf "$work"
}
trap cleanup EXIT
mkdir "$work/stage"
bundle="$work/stage/$name"

printf 'Downloading %s...\n' "$name"
curl --fail --location --retry 3 \
    "https://github.com/arm/arm-toolchain/releases/download/release-$version-ATfE/$name.$extension" \
    --output "$work/atfe.$extension"
case "$extension" in
    tar.xz) tar -xJf - -C "$work/stage" < "$work/atfe.tar.xz" ;;
    zip) unzip -q "$work/atfe.zip" -d "$work/stage" ;;
    dmg)
        mkdir "$work/mount"
        hdiutil attach "$work/atfe.dmg" -readonly -nobrowse -mountpoint "$work/mount" -quiet
        mounted=true
        cp -R "$work/mount/$name" "$bundle"
        hdiutil detach "$work/mount" -quiet
        mounted=false
        ;;
esac
[[ -f $bundle/bin/clang$exe ]] || { echo 'Unexpected ATfE archive layout.' >&2; exit 1; }

echo 'Downloading newlib overlay...'
curl --fail --location --retry 3 \
    "https://github.com/arm/arm-toolchain/releases/download/release-$version-ATfE/ATfE-newlib-overlay-$version.tar.xz" \
    --output "$work/newlib.tar.xz"
# The host-independent overlay has no enclosing top-level directory.
tar -xJf - -C "$bundle" < "$work/newlib.tar.xz"
runtimes="$bundle/lib/clang-runtimes"
newlib="$runtimes/newlib/arm-none-eabi"
for required in "$bundle/bin/newlib.cfg" "$runtimes/newlib/multilib.yaml" \
    "$newlib/include/stdio.h" "$newlib/include/c++/v1/vector" \
    "$newlib/$runtime/lib/libc.a" "$newlib/$runtime/lib/libm.a" \
    "$newlib/$runtime/lib/libc++.a" "$newlib/$runtime/lib/libclang_rt.builtins.a"; do
    [[ -f $required ]] || { printf 'Newlib overlay is missing %s\n' "$required" >&2; exit 1; }
done
printf 'Keeping only newlib/arm-none-eabi/%s and shared headers...\n' "$runtime"
# Keep metadata files (including multilib.yaml); remove other runtime directories.
for directory in "$runtimes"/*; do
    if [[ -d $directory && $directory != "$runtimes/newlib" ]]; then rm -rf "$directory"; fi
done
for directory in "$runtimes/newlib"/*; do
    if [[ -d $directory && $directory != "$newlib" ]]; then rm -rf "$directory"; fi
done
for directory in "$newlib"/*; do
    if [[ -d $directory && $directory != "$newlib/include" && $directory != "$newlib/$runtime" ]]; then
        rm -rf "$directory"
    fi
done

echo 'Downloading VEXcode extension for vexcom...'
curl --fail --location --retry 3 \
    "${VEXCOM_VSIX_URL:-https://openvsxorg.blob.core.windows.net/resources/VEXRobotics/vexcode/0.6.1/VEXRobotics.vexcode-0.6.1.vsix}" \
    --output "$work/vexcode.vsix"
# Copy the whole platform directory so vexcom keeps its DLLs/dylibs.
unzip -q "$work/vexcode.vsix" "extension/resources/tools/vexcom/$vex_platform/*" -d "$work/vsix"
vexcom_dir="$work/vsix/extension/resources/tools/vexcom/$vex_platform"
[[ -f $vexcom_dir/vexcom$exe ]] || { echo 'vexcom is missing from the VSIX.' >&2; exit 1; }
mkdir -p "$bundle/tools/vexcom" "$bundle/tools/vflash"
cp -R "$vexcom_dir/." "$bundle/tools/vexcom/"
cp "$make_binary" "$bundle/tools/make$exe"
cp "$vflash_binary" "$bundle/tools/vflash/vflash$exe"
if [[ -f $(dirname "$make_binary")/make-COPYING ]]; then
    cp "$(dirname "$make_binary")/make-COPYING" "$bundle/tools/make-COPYING"
fi
chmod +x "$bundle/tools/make$exe" "$bundle/tools/vexcom/vexcom$exe" "$bundle/tools/vflash/vflash$exe"

printf 'Packaging %s.tar.xz...\n' "$name"
# CI has no terminal, so xz's interactive progress display is unavailable.
# Report compressed output size periodically without extra dependencies.
: > "$work/$name.tar.xz"
(
    started=$SECONDS
    next_report=30
    while sleep 1; do
        elapsed=$((SECONDS - started))
        if (( elapsed >= next_report )); then
            bytes=$(wc -c < "$work/$name.tar.xz")
            printf 'Packaging %s: %ss elapsed, %s MiB compressed output written\n' \
                "$name" "$elapsed" "$((bytes / 1024 / 1024))"
            next_report=$((elapsed + 30))
        fi
    done
) &
progress_pid=$!
# Shell redirection avoids GNU tar's host:path handling of Windows drive letters.
# pipefail ensures either tar or xz failing prevents publication of the archive.
COPYFILE_DISABLE=1 tar -cf - -C "$work/stage" "$name" | xz -c > "$work/$name.tar.xz"
stop_progress
mv "$work/$name.tar.xz" "$output_dir/$name.tar.xz"
archive="$output_dir/$name.tar.xz"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    # upload-artifact needs a Windows path when the script runs in Git Bash.
    case "$(uname -s)" in MINGW*|MSYS*) archive=$(cygpath -m "$archive") ;; esac
    printf 'archive=%s\n' "$archive" >> "$GITHUB_OUTPUT"
fi
printf 'Created %s\n' "$archive"
