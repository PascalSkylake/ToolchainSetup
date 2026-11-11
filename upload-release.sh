#!/usr/bin/env bash
set -euo pipefail

# Authenticate gh (e.g. GH_TOKEN in Actions) and create the release first.
# Usage: upload-release.sh OWNER/REPO TAG ARCHIVE [ARCHIVE ...]
# Example: ./upload-release.sh RIT-VEX-U/ForkTemplate 23.1 /tmp/dist/*.tar.xz
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: upload-release.sh OWNER/REPO TAG ARCHIVE [ARCHIVE ...]'
    echo 'Upload archives to an existing release using gh and GH_TOKEN.'
    exit 0
fi
[[ $# -ge 3 ]] || { echo 'Usage: upload-release.sh OWNER/REPO TAG ARCHIVE [ARCHIVE ...]' >&2; exit 2; }
repository=$1
release=$2
shift 2
for archive in "$@"; do
    [[ -f $archive ]] || { printf 'Archive not found: %s\n' "$archive" >&2; exit 1; }
done
gh release upload "$release" --repo "$repository" "$@"
