#!/usr/bin/env bash
set -Eeuo pipefail

event_name=${1:-${GITHUB_EVENT_NAME:-}}
lifecycle_scope=${2:-${LIFECYCLE_SCOPE:-none}}
cache_mode=${3:-${LIFECYCLE_CACHE:-warm}}

die() {
    echo "workflow prepare: $*" >&2
    exit 2
}

[[ -n ${event_name} ]] || die "EVENT_NAME is required"
case "${cache_mode}" in
    warm | isolated) ;;
    *) die "cache mode must be warm or isolated" ;;
esac

controller=false
worker=false
reason=automatic-hermetic

case "${event_name}" in
    workflow_dispatch)
        case "${lifecycle_scope}" in
            none)
                reason=manual-hermetic
                ;;
            controller)
                controller=true
                reason=manual-controller-qualification
                ;;
            worker)
                worker=true
                reason=manual-worker-qualification
                ;;
            both)
                controller=true
                worker=true
                reason=manual-both-qualification
                ;;
            *)
                die "lifecycle scope must be none, controller, worker, or both"
                ;;
        esac
        ;;
    pull_request | merge_group | push)
        [[ ${lifecycle_scope} == none ]] ||
            die "automatic events cannot request lifecycle qualification"
        ;;
    *)
        die "unsupported event: ${event_name}"
        ;;
esac

plan=$(jq -cn \
    --arg event "${event_name}" \
    --arg cache_mode "${cache_mode}" \
    --arg lifecycle_scope "${lifecycle_scope}" \
    --argjson controller "${controller}" \
    --argjson worker "${worker}" \
    --arg reason "${reason}" \
    '{
        schema_version: 3,
        event: $event,
        cache_mode: $cache_mode,
        lifecycle_scope: $lifecycle_scope,
        targets: {
            controller: {run: $controller},
            worker: {run: $worker}
        },
        reason: $reason
    }')

if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'plan=%s\n' "${plan}" >>"${GITHUB_OUTPUT}"
fi

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo '### Authoritative CI plan'
        echo
        echo "\`${plan}\`"
    } >>"${GITHUB_STEP_SUMMARY}"
fi

printf '%s\n' "${plan}"
