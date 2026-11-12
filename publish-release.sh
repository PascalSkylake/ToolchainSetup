#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: publish-release.sh OWNER/REPO ATFE_VERSION VFLASH_TAG ARCHIVE_DIR'
    echo 'Publish exactly four tested tar.xz files. Requires gh, jq, and GH_TOKEN (Contents: write).'
    echo 'GITHUB_SHA selects the release commit in Actions; RELEASE_TARGET overrides it.'
    exit 0
fi
[[ $# == 4 ]] || { echo 'Usage: publish-release.sh OWNER/REPO ATFE_VERSION VFLASH_TAG ARCHIVE_DIR' >&2; exit 2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
repository=$1
version=$2
vflash_tag=$3
[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid ATfE version.'
[[ $vflash_tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Invalid vflash tag.'
tag="atfe-$version"
archives=()
names=()
for platform in Linux-x86_64 Linux-AArch64 Darwin-universal Windows-x86_64; do
    name="ATfE-$version-$platform.tar.xz"
    [[ -s $4/$name ]] || die "Missing or empty archive: $4/$name"
    archives+=("$4/$name")
    names+=("$name")
done
# Do not interpret authentication/network errors as a missing release.
releases=$(gh api --paginate --slurp "repos/$repository/releases?per_page=100")
existing=$(jq -c --arg tag "$tag" 'add | map(select(.tag_name == $tag)) | first // null' <<< "$releases")
notes="ATfE $version with the newlib armv7a_soft_vfpv3_d16_unaligned runtime, shared headers, GNU Make 4.4.1, and VEXcom from VEXcode 0.6.1.

ATfE: https://github.com/arm/arm-toolchain/releases/tag/release-$version-ATfE
vflash: https://github.com/${VFLASH_REPOSITORY:-PascalSkylake/vflash}/releases/tag/$vflash_tag"
if [[ $existing != null ]]; then
    jq -e '.draft == true' <<< "$existing" >/dev/null || die "$tag is already published; refusing to replace its assets."
    gh release edit "$tag" --repo "$repository" --target "${RELEASE_TARGET:-${GITHUB_SHA:-main}}" \
        --title "ATfE $version" --notes "$notes"
else
    gh release create "$tag" --repo "$repository" --draft \
        --target "${RELEASE_TARGET:-${GITHUB_SHA:-main}}" --title "ATfE $version" --notes "$notes"
fi
# A failed upload leaves a draft that the next scheduled/manual run can resume.
gh release upload "$tag" --repo "$repository" --clobber "${archives[@]}"
assets=$(gh release view "$tag" --repo "$repository" --json assets --jq '.assets[].name')
[[ $(printf '%s\n' "$assets" | LC_ALL=C sort) == $(printf '%s\n' "${names[@]}" | LC_ALL=C sort) ]] || \
    die 'Release assets do not match the four expected archives; leaving the release as a draft.'
gh release edit "$tag" --repo "$repository" --draft=false
printf 'Published https://github.com/%s/releases/tag/%s\n' "$repository" "$tag"
