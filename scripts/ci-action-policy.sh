#!/usr/bin/env bash
set -Eeuo pipefail

workflows_dir=${1:-}
allowlist=${2:-}
[[ $# -eq 2 && -d ${workflows_dir} && -f ${allowlist} ]] || {
    echo "usage: lucidity-ci-action-policy WORKFLOWS_DIR ALLOWLIST" >&2
    exit 2
}

jq -e '
  .schema_version == 1 and
  (.actions | type == "object" and length > 0) and
  all(
    .actions[];
    (.category | IN("bootstrap", "cache", "cloud-identity", "platform-automation", "platform-io", "source")) and
    (.reason | type == "string" and length > 0)
  )
' "${allowlist}" >/dev/null

if rg -n -P '^\s*(?:-\s*)?uses:\s*(?!\./)[^@\s]+@(?![0-9a-f]{40}(?:\s|$))' "${workflows_dir}"; then
    echo "external GitHub Actions must be pinned to full commit SHAs" >&2
    exit 1
fi

mapfile -t used_actions < <(
    rg --no-filename -o -P '^\s*(?:-\s*)?uses:\s*\K[^@\s]+' "${workflows_dir}" |
        grep -v '^\./' | sort -u
)
mapfile -t allowed_actions < <(jq -r '.actions | keys[]' "${allowlist}" | sort)

for action in "${used_actions[@]}"; do
    if ! jq -e --arg action "${action}" '.actions | has($action)' "${allowlist}" >/dev/null; then
        echo "external GitHub Action is not approved: ${action}" >&2
        exit 1
    fi
done

for action in "${allowed_actions[@]}"; do
    if ! printf '%s\n' "${used_actions[@]}" | grep -Fxq "${action}"; then
        echo "GitHub Action allowlist entry is unused: ${action}" >&2
        exit 1
    fi
done
