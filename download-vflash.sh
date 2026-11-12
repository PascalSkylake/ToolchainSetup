#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: download-vflash.sh PLATFORM RELEASE_TAG OUTPUT_DIR'
    echo 'Download a versioned vflash release binary using gh and GH_TOKEN (Contents: read).'
    echo 'VFLASH_REPOSITORY defaults to PascalSkylake/vflash.'
    exit 0
fi
[[ $# == 3 ]] || { echo 'Usage: download-vflash.sh PLATFORM RELEASE_TAG OUTPUT_DIR' >&2; exit 2; }
exe=
case "$1" in
    Linux-x86_64) artifact=vflash-linux-x86_64 ;;
    Linux-AArch64) artifact=vflash-linux-aarch64 ;;
    Darwin-universal) artifact=vflash-macos-universal ;;
    Windows-x86_64) artifact=vflash-windows-x86_64; exe=.exe ;;
    *) echo "Unknown platform: $1" >&2; exit 2 ;;
esac
[[ $2 =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Expected a release tag such as v1.0.0.' >&2; exit 2; }
asset="${artifact}_${2#v}$exe"
[[ -n ${GH_TOKEN:-} ]] || { echo 'Set VFLASH_TOKEN in Actions, or GH_TOKEN locally, with Contents: read access to vflash.' >&2; exit 1; }
repository=${VFLASH_REPOSITORY:-PascalSkylake/vflash}
temp_root=${RUNNER_TEMP:-${TMPDIR:-/tmp}}
output_dir=$3
case "$(uname -s)" in
    MINGW*|MSYS*)
        temp_root=$(cygpath -u "$temp_root")
        output_dir=$(cygpath -u "$output_dir")
        ;;
esac
work=$(mktemp -d "$temp_root/vflash-download.XXXXXX")
trap 'rm -rf "$work"' EXIT
gh release download "$2" --repo "$repository" --pattern "$asset" --dir "$work" || {
    echo "Could not download $asset from release $2; check token access and release assets." >&2
    exit 1
}
[[ -s $work/$asset ]] || { echo "Missing or empty release asset: $asset" >&2; exit 1; }
mkdir -p "$output_dir"
cp "$work/$asset" "$output_dir/vflash$exe"
# Release downloads do not preserve Unix executable permissions.
chmod +x "$output_dir/vflash$exe"
printf 'Downloaded %s from vflash %s as vflash%s\n' "$asset" "$2" "$exe"
