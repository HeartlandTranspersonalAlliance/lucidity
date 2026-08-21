#!/usr/bin/env bash
set -Eeuo pipefail

event_file=${GITHUB_EVENT_PATH:?}
summary_file=${GITHUB_STEP_SUMMARY:-/dev/null}
api_url=${GITHUB_API_URL:-https://api.github.com}
repository=${GITHUB_REPOSITORY:?}
ntfy_url=${NTFY_URL:-https://ntfy.heartlandta.org}
ntfy_topic=${NTFY_TOPIC:-lucidity-ci}
curl_bin=${CURL_BIN:-curl}
jq_bin=${JQ_BIN:-jq}

workflow=$("$jq_bin" -r '.workflow_run.name // "unknown workflow"' "$event_file")
conclusion=$("$jq_bin" -r '.workflow_run.conclusion // "unknown"' "$event_file")
run_id=$("$jq_bin" -r '.workflow_run.id // empty' "$event_file")
run_url=$("$jq_bin" -r '.workflow_run.html_url // empty' "$event_file")
head_branch=$("$jq_bin" -r '.workflow_run.head_branch // "unknown"' "$event_file")
head_sha=$("$jq_bin" -r '.workflow_run.head_sha // "unknown"' "$event_file")

case "$conclusion" in
    failure|cancelled|timed_out|action_required|stale|startup_failure) ;;
    *)
        printf 'No notification required for %s (%s).\n' "$workflow" "$conclusion" >> "$summary_file"
        exit 0
        ;;
esac

if [[ -z ${NTFY_TOKEN:-} ]]; then
    printf 'ntfy notification skipped for %s: NTFY_CI_TOKEN is not configured.\n' "$workflow" >> "$summary_file"
    exit 0
fi

jobs='[]'
if [[ $run_id =~ ^[0-9]+$ ]]; then
    jobs_endpoint="${api_url}/repos/${repository}/actions/runs/${run_id}/jobs?filter=latest&per_page=100"
    jobs=$("$curl_bin" --fail --silent --show-error \
        --header "Authorization: Bearer ${GH_TOKEN}" \
        --header 'Accept: application/vnd.github+json' \
        --header 'X-GitHub-Api-Version: 2022-11-28' \
        "$jobs_endpoint" 2>/dev/null || printf '{"jobs":[]}')
fi

# jq expressions use their own interpolation syntax.
# shellcheck disable=SC2016
failed=$("$jq_bin" -r '
  [.jobs[]? |
    select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required") |
    .name as $job |
    ([.steps[]? | select(.conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out") | .name] | join(", ")) as $steps |
    if $steps == "" then $job else "\($job): \($steps)" end
  ] | if length == 0 then "No failed job metadata was available." else join("\n") end
' <<<"$jobs")

# shellcheck disable=SC2016
body=$("$jq_bin" -nr \
    --arg workflow "$workflow" \
    --arg conclusion "$conclusion" \
    --arg branch "$head_branch" \
    --arg sha "${head_sha:0:12}" \
    --arg failed "$failed" \
    '"Workflow: \($workflow)\nConclusion: \($conclusion)\nBranch: \($branch)\nCommit: \($sha)\n\nFailed jobs/steps:\n\($failed)" | .[0:3500]')

curl_args=(
    --fail --silent --show-error
    --request POST
    --header "Authorization: Bearer ${NTFY_TOKEN}"
    --header 'Title: Lucidity CI failure'
    --header 'Priority: high'
    --header 'Tags: warning,github_actions'
)
if [[ $run_url == https://github.com/* ]]; then
    curl_args+=(--header "Click: ${run_url//$'\n'/}")
fi

if ! printf '%s' "$body" | "$curl_bin" "${curl_args[@]}" --data-binary @- "${ntfy_url}/${ntfy_topic}" >/dev/null; then
    printf '::warning::Unable to publish the ntfy notification for %s\n' "$workflow"
    printf 'ntfy notification delivery failed for %s; this advisory workflow remains non-blocking.\n' "$workflow" >> "$summary_file"
    exit 0
fi

printf 'Published an ntfy notification for %s (%s).\n' "$workflow" "$conclusion" >> "$summary_file"
