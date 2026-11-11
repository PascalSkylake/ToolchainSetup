#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: download-vflash.sh PLATFORM RUN_ID OUTPUT_DIR'
    echo 'Download a vflash CI binary using gh and GH_TOKEN (Actions: read).'
    echo 'VFLASH_REPOSITORY defaults to PascalSkylake/vflash.'
    exit 0
fi
[[ $# == 3 ]] || { echo 'Usage: download-vflash.sh PLATFORM RUN_ID OUTPUT_DIR' >&2; exit 2; }
exe=
case "$1" in
    Linux-x86_64) artifact=vflash-linux-x86_64 ;;
    Linux-AArch64) artifact=vflash-linux-aarch64 ;;
    Darwin-universal) artifact=vflash-macos-universal ;;
    Windows-x86_64) artifact=vflash-windows-x86_64; exe=.exe ;;
    *) echo "Unknown platform: $1" >&2; exit 2 ;;
esac
[[ $2 =~ ^[0-9]+$ ]] || { echo 'RUN_ID must be numeric.' >&2; exit 2; }
[[ -n ${GH_TOKEN:-} ]] || { echo 'Set VFLASH_TOKEN in Actions, or GH_TOKEN locally, with Actions: read access to vflash.' >&2; exit 1; }
repository=${VFLASH_REPOSITORY:-PascalSkylake/vflash}
work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/vflash-download.XXXXXX")
trap 'rm -rf "$work"' EXIT
# gh extracts a single named artifact directly into this directory.
gh run download "$2" --repo "$repository" --name "$artifact" --dir "$work" || {
    echo "Could not download $artifact from run $2; check token access and artifact expiration." >&2
    exit 1
}
[[ -f $work/vflash$exe ]] || { echo "Artifact $artifact does not contain vflash$exe at its root." >&2; exit 1; }
mkdir -p "$3"
cp "$work/vflash$exe" "$3/vflash$exe"
# GitHub's zipped artifacts do not preserve Unix executable permissions.
chmod +x "$3/vflash$exe"
printf 'Downloaded %s from vflash run %s\n' "$artifact" "$2"
