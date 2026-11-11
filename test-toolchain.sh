#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# Run on the platform being packaged. No robot is required.
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: test-toolchain.sh PLATFORM ARCHIVE.tar.xz'
    exit 0
fi
[[ $# == 2 ]] || { echo 'Usage: test-toolchain.sh PLATFORM ARCHIVE.tar.xz' >&2; exit 2; }
platform=$1
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
bundle="$work/unpacked tools/ATfE-23.1.0-$platform"
make="$bundle/tools/make$exe"
clang="$bundle/bin/clang$exe"
linker="$bundle/bin/ld.lld$exe"
[[ ! -e $bundle/tools/ninja && ! -e $bundle/tools/ninja.exe ]]
for binary in "$make" "$clang" "$linker" "$bundle/tools/vflash/vflash$exe" "$bundle/tools/vexcom/vexcom$exe"; do
    [[ -f $binary ]]
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
        linker=$(cygpath -m "$linker")
        ;;
esac

cat > "$work/build test/main.c" <<'EOF'
extern int helper(void);
int main(void) { return helper(); }
EOF
echo 'int helper(void) { return 42; }' > "$work/build test/helper.c"
cat > "$work/build test/Makefile" <<'EOF'
.PHONY: all fail
all: firmware.elf
%.o: %.c
	"$(CLANG)" --target=armv7a-none-eabi -ffreestanding -c $< -o $@
firmware.elf: main.o helper.o
	"$(LINKER)" -Ttext=0x03800000 -e main $^ -o $@
fail:
	@exit 7
EOF
make_args=(-C "$work/build test" "CLANG=$clang" "LINKER=$linker")
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
