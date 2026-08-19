#!/usr/bin/env bash
set -Eeuo pipefail

prepare=lucidity-ci-workflow-prepare
gate=lucidity-ci-workflow-gate
repository=${TMPDIR}/repository
test_source_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export LUCIDITY_CI_TARGET_GRAPH=${test_source_root}/ci/lifecycle-targets.json
invalid_graph=${TMPDIR}/invalid-lifecycle-targets.json
jq '.nodes.common.ancestors = ["controller"]' "${LUCIDITY_CI_TARGET_GRAPH}" >"${invalid_graph}"
if LUCIDITY_CI_TARGET_GRAPH=${invalid_graph} ${prepare} push '' '' warm 2>/dev/null; then
    echo "workflow planner accepted a cyclic target graph" >&2
    exit 1
fi

mkdir -p "${repository}"
cd "${repository}"
git init -q
git config user.email ci@example.invalid
git config user.name "CI Test"

mkdir -p docs nix/den/aspects/controller nix/den/aspects/worker
printf 'initial\n' >nix/den/aspects/controller/default.nix
printf 'initial\n' >nix/den/aspects/worker/default.nix
printf 'initial\n' >docs/README.md
printf 'initial\n' >flake.nix
git add .
git commit -qm initial

base=$(git rev-parse HEAD)
printf 'controller\n' >>nix/den/aspects/controller/default.nix
git commit -qam controller
head=$(git rev-parse HEAD)
controller_plan=$(${prepare} merge_group "${base}" "${head}" warm)
jq -e --arg base "${base}" --arg head "${head}" '
    .schema_version == 2 and
    .target_graph_schema_version == 1 and
    .event == "merge_group" and
    .cache_mode == "warm" and
    .comparison.base_sha == $base and
    .comparison.head_sha == $head and
    .comparison.relationship == "ancestor" and
    .targets.controller.run and
    (.targets.worker.run | not) and
    .targets.controller.matched_paths == ["nix/den/aspects/controller/default.nix"] and
    .targets.controller.via == ["controller"] and
    (.fallback | not) and
    .reason == "controller-only"
' <<<"${controller_plan}" >/dev/null

base=${head}
printf 'worker\n' >>nix/den/aspects/worker/default.nix
git commit -qam worker
head=$(git rev-parse HEAD)
${prepare} merge_group "${base}" "${head}" warm |
    jq -e '(.targets.controller.run | not) and .targets.worker.run and (.fallback | not) and .reason == "worker-only"' >/dev/null

base=${head}
printf 'docs\n' >>docs/README.md
git commit -qam docs
head=$(git rev-parse HEAD)
${prepare} merge_group "${base}" "${head}" warm |
    jq -e '(.targets.controller.run | not) and (.targets.worker.run | not) and (.fallback | not) and .reason == "non-lifecycle"' >/dev/null

base=${head}
printf 'controller mixed\n' >>nix/den/aspects/controller/default.nix
printf 'worker mixed\n' >>nix/den/aspects/worker/default.nix
git commit -qam mixed
head=$(git rev-parse HEAD)
${prepare} merge_group "${base}" "${head}" warm |
    jq -e '.targets.controller.run and .targets.worker.run and (.fallback | not) and .reason == "mixed-target-change"' >/dev/null

base=${head}
git mv nix/den/aspects/controller/default.nix nix/den/aspects/worker/controller-renamed.nix
git commit -qm rename
head=$(git rev-parse HEAD)
${prepare} merge_group "${base}" "${head}" warm |
    jq -e '.targets.controller.run and .targets.worker.run and (.fallback | not) and .reason == "mixed-target-change"' >/dev/null

base=${head}
printf 'shared\n' >>flake.nix
git commit -qam shared
head=$(git rev-parse HEAD)
${prepare} merge_group "${base}" "${head}" warm |
    jq -e '
        .targets.controller.run and
        .targets.worker.run and
        .targets.controller.matched_paths == ["flake.nix"] and
        .targets.worker.matched_paths == ["flake.nix"] and
        .targets.controller.via == ["common"] and
        .targets.worker.via == ["common"] and
        (.fallback | not) and
        .reason == "shared-change"
    ' >/dev/null

base=${head}
printf 'unknown\n' >unmapped.file
git add unmapped.file
git commit -qm unknown
head=$(git rev-parse HEAD)
export GITHUB_OUTPUT=${TMPDIR}/github-output
${prepare} merge_group "${base}" "${head}" warm |
    jq -e '.targets.controller.run and .targets.worker.run and .fallback and .reason == "unknown-path"' >/dev/null
grep -Fxq 'controller=true' "${GITHUB_OUTPUT}"
grep -Fxq 'worker=true' "${GITHUB_OUTPUT}"
grep -Fxq 'fallback=true' "${GITHUB_OUTPUT}"
grep -Fxq 'reason=unknown-path' "${GITHUB_OUTPUT}"
grep -Fxq 'cache_mode=warm' "${GITHUB_OUTPUT}"
grep -Fq 'plan={' "${GITHUB_OUTPUT}"
unset GITHUB_OUTPUT

${prepare} merge_group invalid "${head}" warm |
    jq -e '.targets.controller.run and .targets.worker.run and .fallback and .comparison.relationship == "invalid" and .reason == "invalid-sha"' >/dev/null
divergent_head=$(printf 'divergent\n' | git commit-tree "$(git rev-parse "${head}^{tree}")")
${prepare} merge_group "${head}" "${divergent_head}" warm |
    jq -e '.targets.controller.run and .targets.worker.run and .fallback and .comparison.relationship == "non-ancestor" and .reason == "non-ancestral-sha"' >/dev/null
${prepare} merge_group "${head}" "${head}" warm |
    jq -e '(.targets.controller.run | not) and (.targets.worker.run | not) and (.fallback | not) and .reason == "no-changes"' >/dev/null
${prepare} schedule '' '' warm |
    jq -e '.targets.controller.run and .targets.worker.run and .reason == "scheduled"' >/dev/null
${prepare} workflow_dispatch '' '' isolated |
    jq -e '.targets.controller.run and .targets.worker.run and .cache_mode == "isolated" and .reason == "manual"' >/dev/null
pull_request_plan=$(${prepare} pull_request '' '' warm)
jq -e '(.targets.controller.run | not) and (.targets.worker.run | not) and .reason == "hermetic-only"' <<<"${pull_request_plan}" >/dev/null
${prepare} push '' '' warm |
    jq -e '(.targets.controller.run | not) and (.targets.worker.run | not) and .reason == "hermetic-only"' >/dev/null
${prepare} unexpected '' '' warm |
    jq -e '.targets.controller.run and .targets.worker.run and .fallback and .reason == "unknown-event"' >/dev/null

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
if WORKFLOW_PLAN=${pull_request_plan} \
    PREPARE_RESULT=success \
    CONTROLLER_RESULT=success \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted an unplanned controller lifecycle result" >&2
    exit 1
fi
if WORKFLOW_PLAN=${pull_request_plan} \
    PREPARE_RESULT=failure \
    CONTROLLER_RESULT=skipped \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted a failed Nix prepare job" >&2
    exit 1
fi
invalid_plan=$(jq 'del(.changed_paths)' <<<"${pull_request_plan}")
if WORKFLOW_PLAN=${invalid_plan} \
    PREPARE_RESULT=success \
    CONTROLLER_RESULT=skipped \
    WORKER_RESULT=skipped \
    ${gate} 2>/dev/null; then
    echo "gate accepted a plan that did not satisfy the versioned schema" >&2
    exit 1
fi
