#!/usr/bin/env bash
set -Eeuo pipefail

event_name=${1:-${GITHUB_EVENT_NAME:-}}

die() {
    echo "integration classifier: $*" >&2
    exit 2
}

[[ -n ${event_name} ]] || die "EVENT_NAME is required"

case "${event_name}" in
    workflow_dispatch)
        files=""
        scope=pair
        reason=manual-pair
        ;;
    pull_request)
        if [[ -n ${CHANGED_FILES_FILE:-} ]]; then
            [[ -f ${CHANGED_FILES_FILE} ]] || die "CHANGED_FILES_FILE does not exist"
            files=$(<"${CHANGED_FILES_FILE}")
        else
            : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
            : "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"
            : "${GH_TOKEN:?GH_TOKEN is required}"
            pull_number=$(jq -er '.pull_request.number' "${GITHUB_EVENT_PATH}")
            files=$(gh api --paginate \
                "repos/${GITHUB_REPOSITORY}/pulls/${pull_number}/files" \
                --jq '.[].filename')
        fi

        controller=false
        worker=false
        shared=false
        relevant=false
        while IFS= read -r path; do
            [[ -n ${path} ]] || continue
            case "${path}" in
                docs/* | tofu/* | *.md | LICENSE)
                    ;;
                nix/den/aspects/controller/*)
                    relevant=true
                    controller=true
                    ;;
                nix/den/aspects/worker/*)
                    relevant=true
                    worker=true
                    ;;
                *)
                    relevant=true
                    shared=true
                    ;;
            esac
        done <<<"${files}"

        if [[ ${shared} == true || (${controller} == true && ${worker} == true) ]]; then
            scope=pair
            reason="shared-or-unknown-change"
        elif [[ ${controller} == true ]]; then
            scope=controller
            reason="controller-only-change"
        elif [[ ${worker} == true ]]; then
            scope=worker
            reason="worker-only-change"
        elif [[ ${relevant} == false ]]; then
            scope=none
            reason=no-boot-impact
        else
            scope=pair
            reason=conservative-fallback
        fi
        ;;
    *) die "unsupported event: ${event_name}" ;;
esac

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'scope=%s\nreason=%s\n' "${scope}" "${reason}" >>"${GITHUB_OUTPUT}"
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo '### Advisory boot integration selection'
        echo
        echo "Scope: \`${scope}\`"
        echo
        echo "Reason: ${reason}"
    } >>"${GITHUB_STEP_SUMMARY}"
fi

printf '%s\n' "${scope}"
