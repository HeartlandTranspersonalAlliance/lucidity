#!/usr/bin/env bash
set -Eeuo pipefail

policy=lucidity-ci-action-policy
fixture=${TMPDIR}/action-policy
workflows=${fixture}/workflows
allowlist=${fixture}/allowlist.json
mkdir -p "${workflows}"

write_allowlist() {
    jq -n --arg category "${1:-source}" --arg reason "${2-Required platform adapter.}" '
      {
        schema_version: 1,
        actions: {
          "actions/checkout": {category: $category, reason: $reason}
        }
      }
    ' >"${allowlist}"
}

write_workflow() {
    printf '%s\n' \
        'name: fixture' \
        'on: workflow_dispatch' \
        'jobs:' \
        '  fixture:' \
        '    runs-on: ubuntu-latest' \
        '    steps:' \
        "      - uses: $1" \
        '      - uses: ./.github/actions/local' >"${workflows}/fixture.yml"
}

write_allowlist
write_workflow 'actions/checkout@0123456789abcdef0123456789abcdef01234567'
"${policy}" "${workflows}" "${allowlist}"

write_workflow 'example/unapproved@0123456789abcdef0123456789abcdef01234567'
if "${policy}" "${workflows}" "${allowlist}" 2>/dev/null; then
    echo "action policy accepted an unapproved external Action" >&2
    exit 1
fi

write_workflow 'actions/checkout@v7'
if "${policy}" "${workflows}" "${allowlist}" 2>/dev/null; then
    echo "action policy accepted an unpinned external Action" >&2
    exit 1
fi

write_workflow 'actions/checkout@0123456789abcdef0123456789abcdef01234567'
jq '.actions["actions/attest"] = {category:"platform-io", reason:"Publish attestations."}' \
    "${allowlist}" >"${allowlist}.new"
mv "${allowlist}.new" "${allowlist}"
if "${policy}" "${workflows}" "${allowlist}" 2>/dev/null; then
    echo "action policy accepted an unused allowlist entry" >&2
    exit 1
fi

write_allowlist invalid-category
if "${policy}" "${workflows}" "${allowlist}" 2>/dev/null; then
    echo "action policy accepted an invalid category" >&2
    exit 1
fi

write_allowlist source ''
if "${policy}" "${workflows}" "${allowlist}" 2>/dev/null; then
    echo "action policy accepted an empty rationale" >&2
    exit 1
fi
