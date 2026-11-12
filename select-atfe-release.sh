#!/usr/bin/env bash
set -euo pipefail

if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: select-atfe-release.sh [VERSION]'
    echo 'Blank selects the highest stable ATfE version and checks its required assets.'
    echo 'Requires gh and jq. SKIP_PUBLISHED=true checks GITHUB_REPOSITORY releases.'
    echo 'SKIP_UNREADY=true skips incomplete upstream releases instead of failing.'
    exit 0
fi
[[ $# -le 1 ]] || { echo 'Usage: select-atfe-release.sh [VERSION]' >&2; exit 2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
skip() {
    printf '%s\n' "$*" >&2
    if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'build=false\n' >> "$GITHUB_OUTPUT"; fi
    exit 0
}
version=${1:-}
if [[ -n $version ]]; then
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Expected an ATfE version such as 23.1.0.'
    release=$(gh api "repos/arm/arm-toolchain/releases/tags/release-$version-ATfE")
else
    # This repository also releases other Arm toolchains; /releases/latest is not sufficient.
    releases=$(gh api --paginate --slurp 'repos/arm/arm-toolchain/releases?per_page=100')
    release=$(jq -c 'add | map(select(.draft == false and .prerelease == false)
        | select(.tag_name | test("^release-[0-9]+\\.[0-9]+\\.[0-9]+-ATfE$")))
        | max_by(.tag_name | ltrimstr("release-") | rtrimstr("-ATfE") | split(".") | map(tonumber))' <<< "$releases")
    [[ $release != null ]] || die 'No stable ATfE release found.'
    tag=$(jq -r '.tag_name' <<< "$release")
    version=${tag#release-}
    version=${version%-ATfE}
fi
jq -e '.draft == false and .prerelease == false' <<< "$release" >/dev/null || die 'Select a published stable ATfE release.'
assets=$(jq -r '.assets[] | select(.state == "uploaded" and .size > 0) | .name' <<< "$release")
for asset in "ATfE-$version-Linux-x86_64.tar.xz" "ATfE-$version-Linux-AArch64.tar.xz" \
    "ATfE-$version-Darwin-universal.dmg" "ATfE-$version-Windows-x86_64.zip" \
    "ATfE-newlib-overlay-$version.tar.xz"; do
    if ! grep -Fxq "$asset" <<< "$assets"; then
        [[ ${SKIP_UNREADY:-false} != true ]] || skip "ATfE $version is not ready: missing $asset. Will check again next time."
        die "ATfE $version is missing $asset."
    fi
done
if [[ ${SKIP_PUBLISHED:-false} == true ]]; then
    [[ -n ${GITHUB_REPOSITORY:-} ]] || die 'Set GITHUB_REPOSITORY to check existing toolchain releases.'
    existing=$(gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100")
    if jq -e --arg tag "atfe-$version" 'add | any(.tag_name == $tag and .draft == false)' <<< "$existing" >/dev/null; then
        skip "Toolchain atfe-$version is already published."
    fi
fi
printf 'Selected ATfE %s\n' "$version" >&2
if [[ -n ${GITHUB_OUTPUT:-} ]]; then printf 'version=%s\nbuild=true\n' "$version" >> "$GITHUB_OUTPUT"; fi
printf '%s\n' "$version"
