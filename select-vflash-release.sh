#!/usr/bin/env bash
set -euo pipefail

# Resolve once so every platform downloads binaries from the same release.
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: select-vflash-release.sh [TAG]'
    echo 'Blank selects the latest published release. Tags must look like v1.0.0.'
    echo 'Requires gh, jq, and GH_TOKEN with Contents: read access to VFLASH_REPOSITORY.'
    exit 0
fi
[[ $# -le 1 ]] || { echo 'Usage: select-vflash-release.sh [TAG]' >&2; exit 2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ -n ${GH_TOKEN:-} ]] || die 'Set VFLASH_TOKEN with Contents: read access to the private vflash repository (GH_TOKEN locally).'
repository=${VFLASH_REPOSITORY:-PascalSkylake/vflash}
tag=${1:-}
endpoint=latest
if [[ -n $tag ]]; then
    [[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Expected a release tag such as v1.0.0.'
    endpoint="tags/$tag"
fi
release=$(gh api "repos/$repository/releases/$endpoint") || die "Cannot read the vflash release in $repository. Check VFLASH_TOKEN and publish the release first."
tag=$(jq -r '.tag_name' <<< "$release")
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unsupported vflash tag: $tag"
jq -e '.draft == false and .prerelease == false' <<< "$release" >/dev/null || die 'Select a published stable vflash release.'
assets=$(jq -r '.assets[] | select(.state == "uploaded" and .size > 0) | .name' <<< "$release")
for platform in linux-x86_64 linux-aarch64 macos-universal windows-x86_64; do
    exe=
    [[ $platform != windows-x86_64 ]] || exe=.exe
    asset="vflash-${platform}_${tag#v}$exe"
    grep -Fxq "$asset" <<< "$assets" || die "Release $tag is missing $asset."
done
printf 'Using vflash release https://github.com/%s/releases/tag/%s\n' "$repository" "$tag" >&2
if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'tag=%s\n' "$tag" >> "$GITHUB_OUTPUT"; fi
printf '%s\n' "$tag"
