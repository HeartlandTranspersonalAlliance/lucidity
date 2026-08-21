#!/usr/bin/env bash
set -Eeuo pipefail

plan=${WORKFLOW_PLAN:-}
prepare_result=${PREPARE_RESULT:-}
controller_result=${CONTROLLER_RESULT:-}
worker_result=${WORKER_RESULT:-}

fail() {
    echo "::error::$*" >&2
    exit 1
}

[[ -n ${plan} ]] || fail "the Nix prepare job did not publish a workflow plan"
jq -e '
    type == "object" and
    .schema_version == 3 and
    (.event == "pull_request" or .event == "merge_group" or
        .event == "push" or .event == "workflow_dispatch") and
    (.targets | type == "object" and keys == ["controller", "worker"]) and
    all(.targets[];
        type == "object" and
        (keys == ["run"]) and
        (.run | type == "boolean")) and
    (.cache_mode == "warm" or .cache_mode == "isolated") and
    (.lifecycle_scope == "none" or .lifecycle_scope == "controller" or
        .lifecycle_scope == "worker" or .lifecycle_scope == "both") and
    (.reason | type == "string" and length > 0)
' <<<"${plan}" >/dev/null || fail "the Nix prepare job published an invalid workflow plan"

[[ ${prepare_result} == success ]] || fail "Nix prepare concluded ${prepare_result:-without a result}"

require_result() {
    local role=$1 planned=$2 result=$3 expected
    if [[ ${planned} == true ]]; then
        expected=success
    else
        expected=skipped
    fi
    [[ ${result} == "${expected}" ]] ||
        fail "${role} lifecycle concluded ${result:-without a result}; the prepare plan requires ${expected}"
}

require_result controller "$(jq -r '.targets.controller.run' <<<"${plan}")" "${controller_result}"
require_result worker "$(jq -r '.targets.worker.run' <<<"${plan}")" "${worker_result}"

echo "Required CI gate passed for plan: ${plan}"
