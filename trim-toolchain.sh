#!/usr/bin/env bash
set -euo pipefail

# Match the components in the installed ATfE 22 bundles, using the selected
# version's binaries, headers and libraries. Ninja is deliberately excluded.
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: trim-toolchain.sh PLATFORM BUNDLE_DIR'
    echo 'Remove components outside the ATfE 22 bundle layout from a staging directory.'
    echo 'ATFE_VERSION selects the compiler resource directory (default: 23.1.0).'
    exit 0
fi
[[ $# == 2 ]] || { echo 'Usage: trim-toolchain.sh PLATFORM BUNDLE_DIR' >&2; exit 2; }
platform=$1
bundle=$2
version=${ATFE_VERSION:-23.1.0}
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Invalid ATFE_VERSION.' >&2; exit 2; }
major=${version%%.*}
runtime=armv7a_soft_vfpv3_d16_unaligned
exe=
case "$platform" in
    Linux-x86_64|Linux-AArch64|Darwin-universal) ;;
    Windows-x86_64) exe=.exe ;;
    *) echo "Unknown platform: $platform" >&2; exit 2 ;;
esac
case "$(uname -s)" in MINGW*|MSYS*) bundle=$(cygpath -u "$bundle") ;; esac
[[ -f $bundle/bin/clang$exe && -d $bundle/lib/clang-runtimes/newlib/arm-none-eabi/$runtime ]] || {
    echo 'Expected a staged ATfE bundle with the newlib overlay.' >&2
    exit 1
}

# Include hidden entries so upstream additions cannot silently grow the bundle.
shopt -s nullglob dotglob
keep_only() {
    local directory=$1 entry name keep
    shift
    for entry in "$directory"/*; do
        keep=false
        for name in "$@"; do
            if [[ ${entry##*/} == "$name" ]]; then keep=true; break; fi
        done
        if [[ $keep == false ]]; then rm -rf -- "$entry"; fi
    done
}

keep_only "$bundle" bin include lib tools
bin_files=(Omax.cfg OmaxLTO.cfg Osize.cfg llvmlibc.cfg newlib.cfg git-clang-format)
for tool in clang clang++ clang-check clang-cl clang-cpp clang-format clang-scan-deps \
    dsymutil elf2bin ld.lld ld64.lld lld lld-link llvm-ar llvm-config llvm-cov \
    llvm-cxxfilt llvm-dwarfdump llvm-mc llvm-nm llvm-objcopy llvm-objdump llvm-profdata \
    llvm-ranlib llvm-readelf llvm-readobj llvm-size llvm-strings llvm-strip llvm-symbolizer wasm-ld; do
    bin_files+=("$tool$exe")
done
case "$platform" in
    Linux-*)
        bin_files+=("clang-$major")
        keep_only "$bundle/lib" clang clang-runtimes libLTO.so "libLTO.so.${version%.*}"
        ;;
    Darwin-universal)
        bin_files+=("clang-$major")
        keep_only "$bundle/lib" clang clang-runtimes libLTO.dylib
        ;;
    Windows-x86_64)
        bin_files+=(LTO.dll git-clang-format.bat)
        keep_only "$bundle/lib" clang clang-runtimes LTO.lib
        ;;
esac
keep_only "$bundle/bin" "${bin_files[@]}"
keep_only "$bundle/include" llvm-c
keep_only "$bundle/lib/clang" "$major"
keep_only "$bundle/lib/clang/$major" include share
keep_only "$bundle/lib/clang/$major/share" cfi_ignorelist.txt
keep_only "$bundle/lib/clang-runtimes" newlib multilib.yaml
keep_only "$bundle/lib/clang-runtimes/newlib" arm-none-eabi multilib.yaml
keep_only "$bundle/lib/clang-runtimes/newlib/arm-none-eabi" include "$runtime"
keep_only "$bundle/tools" "make$exe" vexcom vflash
keep_only "$bundle/tools/vflash" "vflash$exe"
case "$platform" in
    Linux-*) keep_only "$bundle/tools/vexcom" vexcom ;;
    Darwin-universal) keep_only "$bundle/tools/vexcom" vexcom libusb-1.0.0.dylib ;;
    Windows-x86_64) keep_only "$bundle/tools/vexcom" vexcom.exe libcurl.dll libusb-1.0.dll ;;
esac
printf 'Trimmed %s to the ATfE 22 component layout (without Ninja).\n' "$bundle"
