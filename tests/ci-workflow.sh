#!/usr/bin/env bash
set -Eeuo pipefail

prepare=lucidity-ci-workflow-prepare
gate=lucidity-ci-workflow-gate

for event in pull_request merge_group push; do
    plan=$(${prepare} "${event}" none warm)
    jq -e --arg event "${event}" '
        .schema_version == 3 and
        .event == $event and
        .cache_mode == "warm" and
        .lifecycle_scope == "none" and
        (.targets.controller.run | not) and
        (.targets.worker.run | not) and
        .reason == "automatic-hermetic"
    ' <<<"${plan}" >/dev/null
done

controller_plan=$(${prepare} workflow_dispatch controller warm)
jq -e '
    .targets.controller.run and
    (.targets.worker.run | not) and
    .lifecycle_scope == "controller" and
    .reason == "manual-controller-qualification"
' <<<"${controller_plan}" >/dev/null

worker_plan=$(${prepare} workflow_dispatch worker isolated)
jq -e '
    (.targets.controller.run | not) and
    .targets.worker.run and
    .cache_mode == "isolated" and
    .lifecycle_scope == "worker" and
    .reason == "manual-worker-qualification"
' <<<"${worker_plan}" >/dev/null

both_plan=$(${prepare} workflow_dispatch both warm)
jq -e '
    .targets.controller.run and
    .targets.worker.run and
    .reason == "manual-both-qualification"
' <<<"${both_plan}" >/dev/null

manual_plan=$(${prepare} workflow_dispatch none warm)
jq -e '
    (.targets.controller.run | not) and
    (.targets.worker.run | not) and
    .reason == "manual-hermetic"
' <<<"${manual_plan}" >/dev/null

if ${prepare} merge_group worker warm 2>/dev/null; then
    echo "workflow planner accepted lifecycle scope on an automatic event" >&2
    exit 1
fi
if ${prepare} workflow_dispatch invalid warm 2>/dev/null; then
    echo "workflow planner accepted an invalid lifecycle scope" >&2
    exit 1
fi
if ${prepare} workflow_dispatch worker invalid 2>/dev/null; then
    echo "workflow planner accepted an invalid cache mode" >&2
    exit 1
fi
if ${prepare} schedule none warm 2>/dev/null; then
    echo "workflow planner accepted an unsupported scheduled event" >&2
    exit 1
fi

export GITHUB_OUTPUT=${TMPDIR}/github-output
${prepare} workflow_dispatch worker warm >/dev/null
grep -Fq 'plan={' "${GITHUB_OUTPUT}"
if grep -Eq '^(controller|worker|fallback|reason|cache_mode)=' "${GITHUB_OUTPUT}"; then
    echo "workflow planner published deprecated scalar outputs" >&2
    exit 1
fi
unset GITHUB_OUTPUT

WORKFLOW_PLAN=${controller_plan} \
    PREPARE_RESULT=success \
    CONTROLLER_RESULT=success \
    WORKER_RESULT=skipped \
    ${gate} >/dev/null
if WORKFLOW_PLAN=${controller_plan} \
    PREPARE_RESULT=success \
    CONTROLLER_RESULT=skipped \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted a skipped planned controller lifecycle" >&2
    exit 1
fi
if WORKFLOW_PLAN=${manual_plan} \
    PREPARE_RESULT=success \
    CONTROLLER_RESULT=success \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted an unplanned controller lifecycle result" >&2
    exit 1
fi
if WORKFLOW_PLAN=${manual_plan} \
    PREPARE_RESULT=failure \
    CONTROLLER_RESULT=skipped \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted a failed Nix prepare job" >&2
    exit 1
fi
invalid_plan=$(jq 'del(.lifecycle_scope)' <<<"${manual_plan}")
if WORKFLOW_PLAN=${invalid_plan} \
    PREPARE_RESULT=success \
    CONTROLLER_RESULT=skipped \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted a plan that did not satisfy the versioned schema" >&2
    exit 1
fi
