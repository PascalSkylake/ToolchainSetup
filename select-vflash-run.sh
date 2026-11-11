#!/usr/bin/env bash
set -euo pipefail

# Select once before the build matrix so every archive uses the same vflash run.
if [[ ${1:-} == --help || ${1:-} == -h ]]; then
    echo 'Usage: select-vflash-run.sh [RUN_ID]'
    echo 'Defaults to the latest successful push/manual CI run on main.'
    echo 'Requires gh and GH_TOKEN with Actions: read access to VFLASH_REPOSITORY.'
    echo 'Optional: VFLASH_REPOSITORY, VFLASH_BRANCH, VFLASH_WORKFLOW (defaults: PascalSkylake/vflash, main, ci.yml).'
    exit 0
fi
[[ $# -le 1 ]] || { echo 'Usage: select-vflash-run.sh [RUN_ID]' >&2; exit 2; }
die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ -n ${GH_TOKEN:-} ]] || die 'Set the VFLASH_TOKEN Actions secret with Actions: read access to the private vflash repository (GH_TOKEN when running locally).'
repository=${VFLASH_REPOSITORY:-PascalSkylake/vflash}
run_id=${1:-}
if [[ -z $run_id ]]; then
    run_id=$(gh run list --repo "$repository" --workflow "${VFLASH_WORKFLOW:-ci.yml}" \
        --branch "${VFLASH_BRANCH:-main}" --status success --limit 50 \
        --json databaseId,event \
        --jq '[.[] | select(.event == "push" or .event == "workflow_dispatch")][0].databaseId // empty') || \
        die "Cannot list runs in $repository. Check VFLASH_TOKEN has Actions: read access."
    [[ -n $run_id ]] || die "No successful CI run found in $repository. Run its CI workflow first."
fi
[[ $run_id =~ ^[0-9]+$ ]] || die 'RUN_ID must be a numeric GitHub Actions run ID.'
state=$(gh run view "$run_id" --repo "$repository" --json status,conclusion \
    --jq '.status + ":" + .conclusion')
[[ $state == completed:success ]] || die "vflash run $run_id is not successfully completed ($state)."

artifacts=$(gh api --paginate "repos/$repository/actions/runs/$run_id/artifacts?per_page=100" \
    --jq '.artifacts[] | select(.expired == false) | .name')
for name in vflash-linux-x86_64 vflash-linux-aarch64 vflash-macos-universal vflash-windows-x86_64; do
    if ! grep -Fxq "$name" <<< "$artifacts"; then
        die "Run $run_id has no unexpired $name artifact. Rerun vflash CI, then retry; its artifacts are retained for 14 days."
    fi
done
printf 'Using vflash artifacts from https://github.com/%s/actions/runs/%s\n' "$repository" "$run_id" >&2
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'run_id=%s\n' "$run_id" >> "$GITHUB_OUTPUT"
fi
printf '%s\n' "$run_id"
