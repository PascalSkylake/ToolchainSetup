#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# Run on the platform being packaged. No robot is required.
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: test-toolchain.sh PLATFORM ARCHIVE.tar.xz'
    echo 'ATFE_VERSION must match the packaged version (default: 23.1.0).'
    exit 0
fi
[[ $# == 2 ]] || { echo 'Usage: test-toolchain.sh PLATFORM ARCHIVE.tar.xz' >&2; exit 2; }
platform=$1
version=${ATFE_VERSION:-23.1.0}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid ATFE_VERSION.' >&2; exit 2; }
exe=
case "$platform" in
    Linux-x86_64|Linux-AArch64|Darwin-universal) ;;
    Windows-x86_64) exe=.exe ;;
    *) echo "Unknown platform: $platform" >&2; exit 2 ;;
esac
temp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
archive=$2
case "$(uname -s)" in
    MINGW*|MSYS*)
        temp_root=$(cygpath -u "$temp_root")
        archive=$(cygpath -u "$archive")
        ;;
esac
work=$(mktemp -d "$temp_root/toolchain-test.XXXXXX")
trap 'rm -rf "$work"' EXIT
# Exercise paths with spaces, including when native Windows make launches clang.
mkdir "$work/unpacked tools" "$work/build test"
tar -xJf - -C "$work/unpacked tools" < "$archive"
bundle="$work/unpacked tools/ATfE-$version-$platform"
# The shipped bundle has only the four directories present in ATfE 22.
shopt -s nullglob dotglob
for entry in "$bundle"/*; do
    case "${entry##*/}" in
        bin|include|lib|tools) [[ -d $entry ]] ;;
        *) printf 'Unexpected top-level bundle entry: %s\n' "$entry" >&2; exit 1 ;;
    esac
done
for entry in "$bundle/tools"/*; do
    case "${entry##*/}" in
        "make$exe"|vexcom|vflash) ;;
        *) printf 'Unexpected bundled tool: %s\n' "$entry" >&2; exit 1 ;;
    esac
done
[[ ! -e $bundle/bin/clangd && ! -e $bundle/bin/clangd.exe ]]
make="$bundle/tools/make$exe"
clang="$bundle/bin/clang$exe"
[[ ! -e $bundle/tools/ninja && ! -e $bundle/tools/ninja.exe ]]
for binary in "$make" "$clang" "$bundle/bin/ld.lld$exe" "$bundle/tools/vflash/vflash$exe" "$bundle/tools/vexcom/vexcom$exe"; do
    [[ -f $binary ]]
done
runtime=armv7a_soft_vfpv3_d16_unaligned
runtimes="$bundle/lib/clang-runtimes"
newlib="$runtimes/newlib/arm-none-eabi"
for required in "$bundle/bin/newlib.cfg" "$runtimes/newlib/multilib.yaml" \
    "$newlib/include/stdio.h" "$newlib/include/c++/v1/vector" \
    "$newlib/$runtime/lib/libc.a" "$newlib/$runtime/lib/libm.a" \
    "$newlib/$runtime/lib/libc++.a" "$newlib/$runtime/lib/libclang_rt.builtins.a"; do
    [[ -f $required ]] || { printf 'Missing packaged newlib file: %s\n' "$required" >&2; exit 1; }
done
for directory in "$runtimes"/* "$runtimes/newlib"/* "$newlib"/*; do
    [[ -d $directory ]] || continue
    case "$directory" in
        "$runtimes/newlib"|"$newlib"|"$newlib/include"|"$newlib/$runtime") ;;
        *) printf 'Unexpected packaged runtime directory: %s\n' "$directory" >&2; exit 1 ;;
    esac
done
"$make" --version > "$work/make-version.txt"
grep -q '^GNU Make 4[.]4[.]1[[:space:]]*$' "$work/make-version.txt"
"$clang" --version
"$bundle/tools/vflash/vflash$exe" --help > /dev/null
"$bundle/tools/vexcom/vexcom$exe" --help > /dev/null

case "$platform" in
    Linux-*)
        readelf -h "$make" > "$work/header.txt"
        if [[ $platform == Linux-AArch64 ]]; then
            grep -q 'Machine:.*AArch64' "$work/header.txt"
        else
            grep -q 'Machine:.*X86-64' "$work/header.txt"
        fi
        readelf -d "$make" > "$work/dynamic.txt"
        readelf -l "$make" > "$work/segments.txt"
        if grep -q NEEDED "$work/dynamic.txt" || grep -q INTERP "$work/segments.txt"; then
            echo 'Packaged make depends on external Linux libraries or a loader.' >&2
            exit 1
        fi
        ;;
    Darwin-universal)
        lipo "$make" -verify_arch arm64 x86_64
        lipo "$bundle/tools/vflash/vflash" -verify_arch arm64 x86_64
        codesign --verify "$make"
        arch -arm64 "$make" --version
        arch -x86_64 "$make" --version
        otool -arch all -L "$make" > "$work/libraries.txt"
        while read -r library _; do
            case "$library" in
                /usr/lib/*|/System/Library/*) ;;
                *) echo "Unexpected make library: $library" >&2; exit 1 ;;
            esac
        done < <(awk '/^[[:space:]]/ {print $1}' "$work/libraries.txt")
        ;;
    Windows-x86_64)
        objdump -f "$make" > "$work/header.txt"
        grep -q 'file format pei-x86-64' "$work/header.txt"
        objdump -p "$make" > "$work/imports.txt"
        while read -r library; do
            case "$library" in
                kernel32.dll|user32.dll|gdi32.dll|winspool.drv|comdlg32.dll|advapi32.dll|shell32.dll|ole32.dll|oleaut32.dll|uuid.dll|odbc32.dll|odbccp32.dll|msvcrt.dll|ucrtbase.dll|api-ms-win-*.dll) ;;
                *) echo "Non-system make dependency: $library" >&2; exit 1 ;;
            esac
        done < <(awk '/DLL Name:/ {print tolower($3)}' "$work/imports.txt")
        # Prove make itself can start without the MSYS2 DLL directories in PATH.
        system_root=$(cygpath -u "$SYSTEMROOT")
        PATH="$system_root/System32:$system_root" "$make" --version
        clang=$(cygpath -m "$clang")
        ;;
esac

cat > "$work/build test/main.c" <<'EOF'
#include <string.h>
extern int helper(void);
int main(void) { return helper() + (int)strlen("newlib"); }
EOF
echo 'int helper(void) { return 42; }' > "$work/build test/helper.c"
cat > "$work/build test/Makefile" <<'EOF'
.PHONY: all fail
TARGET_FLAGS = --config=newlib.cfg --target=arm-none-eabi -march=armv7-a -mfpu=vfpv3-d16 -mfloat-abi=softfp -munaligned-access -fno-exceptions -fno-rtti
all: firmware.elf
%.o: %.c
	"$(CLANG)" $(TARGET_FLAGS) -fno-builtin -c $< -o $@
firmware.elf: main.o helper.o
	"$(CLANG)" $(TARGET_FLAGS) -nostartfiles -Wl,-Ttext=0x03800000,-e,main $^ -o $@
fail:
	@exit 7
EOF
make_args=(-C "$work/build test" "CLANG=$clang")
# Test native Windows command execution rather than accidentally relying on sh.
if [[ $platform == Windows-x86_64 ]]; then make_args+=(SHELL=cmd.exe '.SHELLFLAGS=/c'); fi
"$make" "${make_args[@]}" -j2 all
[[ -s "$work/build test/firmware.elf" ]]
"$make" "${make_args[@]}" --question all
"$bundle/bin/llvm-readelf$exe" -h "$work/build test/firmware.elf" > "$work/elf.txt"
grep -q 'Machine:.*ARM' "$work/elf.txt"
if "$make" "${make_args[@]}" fail > "$work/failure.txt" 2>&1; then
    echo 'Make did not propagate a failing recipe.' >&2
    exit 1
fi
printf 'Passed packaged toolchain tests for %s\n' "$platform"
