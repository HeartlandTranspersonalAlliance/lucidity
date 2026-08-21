#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

cat > "$work_dir/event.json" <<'EOF'
{
  "workflow_run": {
    "id": 42,
    "name": "Validate locked flake",
    "conclusion": "failure",
    "head_branch": "feature/metrics",
    "head_sha": "0123456789abcdef",
    "html_url": "https://github.com/example/lucidity/actions/runs/42"
  }
}
EOF
curl() {
  if [[ " $* " == *api.github.com/* ]]; then
    printf '%s\n' '{"jobs":[{"name":"checks","conclusion":"failure","steps":[{"name":"Build controller","conclusion":"failure"}]}]}'
    return 0
  fi
  printf '%s\n' "$@" > "$NOTIFY_ARGS"
  cat > "$NOTIFY_BODY"
}
export -f curl

GITHUB_EVENT_PATH="$work_dir/event.json" \
GITHUB_STEP_SUMMARY="$work_dir/summary" \
GITHUB_REPOSITORY=example/lucidity \
GH_TOKEN=test-github-token \
NTFY_TOKEN=test-ntfy-token \
NOTIFY_ARGS="$work_dir/args" \
NOTIFY_BODY="$work_dir/body" \
    bash "$repo_root/.github/actions/notify-ci/notify.sh"

grep -Fq 'https://ntfy.heartlandta.org/lucidity-ci' "$work_dir/args"
grep -Fq 'Authorization: Bearer test-ntfy-token' "$work_dir/args"
grep -Fq 'Workflow: Validate locked flake' "$work_dir/body"
grep -Fq 'checks: Build controller' "$work_dir/body"
grep -Fq 'Published an ntfy notification' "$work_dir/summary"

rm -f "$work_dir/args" "$work_dir/body"
: > "$work_dir/summary"
GITHUB_EVENT_PATH="$work_dir/event.json" \
GITHUB_STEP_SUMMARY="$work_dir/summary" \
GITHUB_REPOSITORY=example/lucidity \
GH_TOKEN=test-github-token \
NOTIFY_ARGS="$work_dir/args" \
NOTIFY_BODY="$work_dir/body" \
    bash "$repo_root/.github/actions/notify-ci/notify.sh"
grep -Fq 'NTFY_CI_TOKEN' "$work_dir/summary"
[[ ! -e $work_dir/args && ! -e $work_dir/body ]]
