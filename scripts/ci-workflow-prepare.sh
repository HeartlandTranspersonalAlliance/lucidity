#!/usr/bin/env bash
set -Eeuo pipefail

event_name=${1:-${GITHUB_EVENT_NAME:-}}
base_sha=${2:-${BASE_SHA:-}}
head_sha=${3:-${HEAD_SHA:-}}
cache_mode=${4:-${LIFECYCLE_CACHE:-warm}}

die() {
    echo "workflow prepare: $*" >&2
    exit 2
}

[[ -n ${event_name} ]] || die "EVENT_NAME is required"
case "${cache_mode}" in
    warm | isolated) ;;
    *) die "cache mode must be warm or isolated" ;;
esac

path_class() {
    case "$1" in
        nix/den/aspects/controller/*) printf 'controller\n' ;;
        nix/den/aspects/worker/*) printf 'worker\n' ;;
        docs/* | *.md | LICENSE | VERSION | .editorconfig | .gitignore | .github/dependabot.yml)
            printf 'none\n'
            ;;
        tofu/* | nix/infra/* | .github/workflows/infra.yml | .github/workflows/audit-ami-resources.yml | \
            .github/workflows/validate-deployment.yml | .github/workflows/update-flake-lock.yml)
            printf 'none\n'
            ;;
        flake.nix | flake.lock | image/* | ci/* | secretspec.toml | nix/* | scripts/* | tests/* | \
            .github/workflows/*)
            printf 'shared\n'
            ;;
        *) printf 'unknown\n' ;;
    esac
}

controller=false
worker=false
fallback=false
reason=
changed_paths='[]'

classify_merge_group() {
    local temporary_directory diff_file paths_file status old_path new_path path
    local saw_shared=false saw_none=false saw_path=false
    local -a paths

    if [[ ! ${base_sha} =~ ^[0-9a-f]{40}$ || ! ${head_sha} =~ ^[0-9a-f]{40}$ ]] ||
        ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
        ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
        controller=true
        worker=true
        fallback=true
        reason="invalid-sha"
        return
    fi

    temporary_directory=$(mktemp -d)
    trap 'rm -rf "${temporary_directory}"; trap - RETURN' RETURN
    diff_file=${temporary_directory}/diff
    paths_file=${temporary_directory}/paths
    : >"${paths_file}"
    if ! git diff --name-status --find-renames -z "${base_sha}" "${head_sha}" >"${diff_file}"; then
        controller=true
        worker=true
        fallback=true
        reason="diff-error"
        return
    fi

    while IFS= read -r -d '' status; do
        paths=()
        if [[ ! ${status} =~ ^([ADMTUXB]|[RC][0-9]{1,3})$ ]]; then
            controller=true
            worker=true
            fallback=true
            reason="malformed-diff"
            return
        fi
        if [[ ${status} == R* || ${status} == C* ]]; then
            IFS= read -r -d '' old_path || {
                controller=true
                worker=true
                fallback=true
                reason="malformed-diff"
                return
            }
            IFS= read -r -d '' new_path || {
                controller=true
                worker=true
                fallback=true
                reason="malformed-diff"
                return
            }
            paths=("${old_path}" "${new_path}")
        else
            IFS= read -r -d '' path || {
                controller=true
                worker=true
                fallback=true
                reason="malformed-diff"
                return
            }
            paths=("${path}")
        fi

        for path in "${paths[@]}"; do
            saw_path=true
            printf '%s\0' "${path}" >>"${paths_file}"
            case "$(path_class "${path}")" in
                controller) controller=true ;;
                worker) worker=true ;;
                shared) saw_shared=true ;;
                none) saw_none=true ;;
                unknown) fallback=true ;;
            esac
        done
    done <"${diff_file}"

    if ! changed_paths=$(jq -Rsc 'split("\u0000") | map(select(length > 0)) | unique' "${paths_file}"); then
        controller=true
        worker=true
        fallback=true
        reason="malformed-diff"
        changed_paths='[]'
        return
    fi
    if [[ ${fallback} == true ]]; then
        controller=true
        worker=true
        reason="unknown-path"
    elif [[ ${saw_shared} == true ]]; then
        controller=true
        worker=true
        reason="shared-change"
    elif [[ ${controller} == true && ${worker} == true ]]; then
        reason="mixed-role-change"
    elif [[ ${controller} == true ]]; then
        reason="controller-only"
    elif [[ ${worker} == true ]]; then
        reason="worker-only"
    elif [[ ${saw_none} == true ]]; then
        reason="non-lifecycle"
    elif [[ ${saw_path} == false ]]; then
        reason="no-changes"
    else
        controller=true
        worker=true
        fallback=true
        reason=unclassified
    fi
}

case "${event_name}" in
    merge_group)
        classify_merge_group
        ;;
    schedule)
        controller=true
        worker=true
        reason=scheduled
        ;;
    workflow_dispatch)
        controller=true
        worker=true
        reason=manual
        ;;
    pull_request | push)
        reason="hermetic-only"
        ;;
    *)
        controller=true
        worker=true
        fallback=true
        reason="unknown-event"
        ;;
esac

plan=$(jq -cn \
    --arg event "${event_name}" \
    --arg cache_mode "${cache_mode}" \
    --argjson controller "${controller}" \
    --argjson worker "${worker}" \
    --argjson fallback "${fallback}" \
    --arg reason "${reason}" \
    --argjson changed_paths "${changed_paths}" \
    '{
        schema_version: 1,
        event: $event,
        cache_mode: $cache_mode,
        lifecycle: {controller: $controller, worker: $worker},
        fallback: $fallback,
        reason: $reason,
        changed_paths: $changed_paths
    }')

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    {
        printf 'controller=%s\n' "${controller}"
        printf 'worker=%s\n' "${worker}"
        printf 'fallback=%s\n' "${fallback}"
        printf 'reason=%s\n' "${reason}"
        printf 'cache_mode=%s\n' "${cache_mode}"
        printf 'plan=%s\n' "${plan}"
    } >>"${GITHUB_OUTPUT}"
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo '### Authoritative CI plan'
        echo
        echo "\`${plan}\`"
    } >>"${GITHUB_STEP_SUMMARY}"
fi

printf '%s\n' "${plan}"
