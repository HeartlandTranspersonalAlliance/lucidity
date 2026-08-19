#!/usr/bin/env bash
set -Eeuo pipefail

event_name=${1:-${GITHUB_EVENT_NAME:-}}
base_sha=${2:-${BASE_SHA:-}}
head_sha=${3:-${HEAD_SHA:-}}
cache_mode=${4:-${LIFECYCLE_CACHE:-warm}}
target_graph=${LUCIDITY_CI_TARGET_GRAPH:-ci/lifecycle-targets.json}

die() {
    echo "workflow prepare: $*" >&2
    exit 2
}

[[ -n ${event_name} ]] || die "EVENT_NAME is required"
case "${cache_mode}" in
    warm | isolated) ;;
    *) die "cache mode must be warm or isolated" ;;
esac

[[ -f ${target_graph} ]] || die "target graph not found: ${target_graph}"
jq -e '
    def valid_name: type == "string" and test("^[a-z][a-z0-9_-]*$");
    def unique_strings:
        type == "array" and
        all(.[]; type == "string" and length > 0 and (test("[\u0000\r\n]") | not)) and
        length == (unique | length);
    def acyclic($nodes; $name; $seen):
        (($seen | index($name)) == null) and
        all($nodes[$name].ancestors[]?; acyclic($nodes; .; $seen + [$name]));
    . as $graph |
    ($graph.nodes | keys) as $names |
    type == "object" and
    .schema_version == 1 and
    (.nodes | type == "object" and length > 0) and
    (.match_order | unique_strings) and
    ((.match_order | sort) == $names) and
    (.ignored | unique_strings) and
    all($names[]; . as $name |
        ($name | valid_name) and
        ($graph.nodes[$name] | type == "object") and
        ($graph.nodes[$name].lifecycle | type == "boolean") and
        ($graph.nodes[$name].ancestors | unique_strings) and
        ($graph.nodes[$name].delta | unique_strings) and
        ($graph.nodes[$name].delta | length > 0) and
        all($graph.nodes[$name].ancestors[]; . as $ancestor |
            ($names | index($ancestor)) != null and $ancestor != $name) and
        acyclic($graph.nodes; $name; [])
    ) and
    any($names[]; $graph.nodes[.].lifecycle)
' "${target_graph}" >/dev/null || die "target graph does not satisfy schema version 1"

mapfile -t lifecycle_targets < <(
    jq -r '.nodes | to_entries[] | select(.value.lifecycle) | .key' "${target_graph}" | sort
)
[[ ${lifecycle_targets[*]} == "controller worker" ]] ||
    die "the explicit workflow adapter requires controller and worker lifecycle targets"

declare -A selected node_lifecycle impacts
for target in "${lifecycle_targets[@]}"; do
    selected["${target}"]=false
done
while IFS=$'\t' read -r node lifecycle; do
    node_lifecycle["${node}"]=${lifecycle}
done < <(jq -r '.nodes | to_entries[] | [.key, .value.lifecycle] | @tsv' "${target_graph}")
while IFS=$'\t' read -r node target; do
    impacts["${node}:${target}"]=true
done < <(
    jq -r '
        def closure($nodes; $name):
            $name, ($nodes[$name].ancestors[]? | closure($nodes; .));
        .nodes as $nodes |
        $nodes | keys[] as $target |
        select($nodes[$target].lifecycle) |
        closure($nodes; $target) as $node |
        [$node, $target] | @tsv
    ' "${target_graph}"
)

temporary_directory=$(mktemp -d)
trap 'rm -rf "${temporary_directory}"' EXIT
changed_paths_file=${temporary_directory}/changed-paths
: >"${changed_paths_file}"
for target in "${lifecycle_targets[@]}"; do
    : >"${temporary_directory}/matched-${target}"
    : >"${temporary_directory}/via-${target}"
done

mark_all_targets() {
    local target
    for target in "${lifecycle_targets[@]}"; do
        selected["${target}"]=true
    done
}

classify_path() {
    local path=$1 pattern node
    classified_node=
    classified_ignored=false

    while IFS= read -r pattern; do
        # shellcheck disable=SC2053 # The contract value is intentionally a glob.
        if [[ ${path} == ${pattern} ]]; then
            classified_ignored=true
            return
        fi
    done < <(jq -r '.ignored[]' "${target_graph}")

    while IFS= read -r node; do
        while IFS= read -r pattern; do
            # shellcheck disable=SC2053 # The contract value is intentionally a glob.
            if [[ ${path} == ${pattern} ]]; then
                classified_node=${node}
                return
            fi
        done < <(jq -r --arg node "${node}" '.nodes[$node].delta[]' "${target_graph}")
    done < <(jq -r '.match_order[]' "${target_graph}")
}

controller=false
worker=false
fallback=false
reason=
comparison_relationship=not-applicable
saw_ancestor=false
saw_ignored=false
saw_path=false

classify_merge_group() {
    local diff_file status old_path new_path path target impact_count selected_count selected_target
    local -a paths

    if [[ ! ${base_sha} =~ ^[0-9a-f]{40}$ || ! ${head_sha} =~ ^[0-9a-f]{40}$ ]] ||
        ! git cat-file -e "${base_sha}^{commit}" 2>/dev/null ||
        ! git cat-file -e "${head_sha}^{commit}" 2>/dev/null; then
        mark_all_targets
        fallback=true
        reason=invalid-sha
        comparison_relationship=invalid
        return
    fi
    if ! git merge-base --is-ancestor "${base_sha}" "${head_sha}"; then
        mark_all_targets
        fallback=true
        reason=non-ancestral-sha
        comparison_relationship=non-ancestor
        return
    fi
    comparison_relationship=ancestor

    diff_file=${temporary_directory}/diff
    if ! git diff --no-ext-diff --name-status --find-renames -z \
        "${base_sha}" "${head_sha}" -- >"${diff_file}"; then
        mark_all_targets
        fallback=true
        reason=diff-error
        comparison_relationship=diff-error
        return
    fi

    while IFS= read -r -d '' status; do
        paths=()
        if [[ ! ${status} =~ ^([ADMTUXB]|[RC][0-9]{1,3})$ ]]; then
            mark_all_targets
            fallback=true
            reason=malformed-diff
            return
        fi
        if [[ ${status} == R* || ${status} == C* ]]; then
            IFS= read -r -d '' old_path || {
                mark_all_targets
                fallback=true
                reason=malformed-diff
                return
            }
            IFS= read -r -d '' new_path || {
                mark_all_targets
                fallback=true
                reason=malformed-diff
                return
            }
            paths=("${old_path}" "${new_path}")
        else
            IFS= read -r -d '' path || {
                mark_all_targets
                fallback=true
                reason=malformed-diff
                return
            }
            paths=("${path}")
        fi

        for path in "${paths[@]}"; do
            saw_path=true
            printf '%s\0' "${path}" >>"${changed_paths_file}"
            classify_path "${path}"
            if [[ ${classified_ignored} == true ]]; then
                saw_ignored=true
                continue
            fi
            if [[ -z ${classified_node} ]]; then
                fallback=true
                continue
            fi

            impact_count=0
            for target in "${lifecycle_targets[@]}"; do
                if [[ ${impacts["${classified_node}:${target}"]:-false} == true ]]; then
                    selected["${target}"]=true
                    printf '%s\0' "${path}" >>"${temporary_directory}/matched-${target}"
                    printf '%s\0' "${classified_node}" >>"${temporary_directory}/via-${target}"
                    impact_count=$((impact_count + 1))
                fi
            done
            if [[ ${node_lifecycle["${classified_node}"]} == false ]]; then
                saw_ancestor=true
            fi
            if ((impact_count == 0)); then
                fallback=true
            fi
        done
    done <"${diff_file}"

    selected_count=0
    selected_target=
    for target in "${lifecycle_targets[@]}"; do
        if [[ ${selected["${target}"]} == true ]]; then
            selected_count=$((selected_count + 1))
            selected_target=${target}
        fi
    done

    if [[ ${fallback} == true ]]; then
        mark_all_targets
        reason=unknown-path
    elif [[ ${saw_ancestor} == true ]]; then
        reason=shared-change
    elif ((selected_count > 1)); then
        reason=mixed-target-change
    elif ((selected_count == 1)); then
        reason=${selected_target}-only
    elif [[ ${saw_ignored} == true ]]; then
        reason=non-lifecycle
    elif [[ ${saw_path} == false ]]; then
        reason=no-changes
    else
        mark_all_targets
        fallback=true
        reason=unclassified
    fi
}

case "${event_name}" in
    merge_group)
        classify_merge_group
        ;;
    schedule)
        mark_all_targets
        reason=scheduled
        ;;
    workflow_dispatch)
        mark_all_targets
        reason=manual
        ;;
    pull_request | push)
        reason=hermetic-only
        ;;
    *)
        mark_all_targets
        fallback=true
        reason=unknown-event
        ;;
esac

controller=${selected[controller]}
worker=${selected[worker]}
changed_paths=$(jq -Rsc 'split("\u0000") | map(select(length > 0)) | unique' "${changed_paths_file}")
targets='{}'
for target in "${lifecycle_targets[@]}"; do
    matched_paths=$(jq -Rsc 'split("\u0000") | map(select(length > 0)) | unique' \
        "${temporary_directory}/matched-${target}")
    via=$(jq -Rsc 'split("\u0000") | map(select(length > 0)) | unique' \
        "${temporary_directory}/via-${target}")
    entry=$(jq -cn \
        --argjson run "${selected["${target}"]}" \
        --argjson matched_paths "${matched_paths}" \
        --argjson via "${via}" \
        '{run: $run, matched_paths: $matched_paths, via: $via}')
    targets=$(jq -cn \
        --argjson targets "${targets}" \
        --arg target "${target}" \
        --argjson entry "${entry}" \
        '$targets + {($target): $entry}')
done

plan=$(jq -cn \
    --arg event "${event_name}" \
    --arg cache_mode "${cache_mode}" \
    --arg base_sha "${base_sha}" \
    --arg head_sha "${head_sha}" \
    --arg relationship "${comparison_relationship}" \
    --argjson targets "${targets}" \
    --argjson fallback "${fallback}" \
    --arg reason "${reason}" \
    --argjson changed_paths "${changed_paths}" \
    '{
        schema_version: 2,
        target_graph_schema_version: 1,
        event: $event,
        cache_mode: $cache_mode,
        comparison: {
            base_sha: $base_sha,
            head_sha: $head_sha,
            relationship: $relationship
        },
        targets: $targets,
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
