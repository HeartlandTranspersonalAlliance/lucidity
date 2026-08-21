#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
audit_script=${repo_root}/scripts/audit-production-readiness.sh
mock_aws=${repo_root}/tests/fixtures/aws-production-readiness
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT

AWS_CLI="${mock_aws}" AWS_REGION=us-east-2 \
LUCIDITY_AUDIT_NOW=2026-08-21T01:00:00Z MOCK_READINESS_SCENARIO=empty \
    bash "${audit_script}" --json --output "${test_dir}/empty.json" >/dev/null

jq -e '
  .schema_version == 1 and
  .identity.type == "assumed_role" and
  .summary.not_configured > 0 and
  any(.checks[]; .id == "security.security_hub_v2" and .state == "not_configured") and
  any(.checks[]; .id == "secrets.runtime_metadata" and .observed.values_read == false)
' "${test_dir}/empty.json" >/dev/null

AWS_CLI="${mock_aws}" AWS_REGION=us-east-2 \
LUCIDITY_AUDIT_NOW=2026-08-21T01:00:00Z MOCK_READINESS_SCENARIO=configured \
    bash "${audit_script}" --markdown --output "${test_dir}/configured.md" >/dev/null

# Backticks are literal Markdown delimiters in these assertions.
# shellcheck disable=SC2016
grep -Fq '`compute.controller_singleton` | `configured`' "${test_dir}/configured.md"
# shellcheck disable=SC2016
grep -Fq '`network.no_cidr_ssh` | `configured`' "${test_dir}/configured.md"
grep -Fq '0 unavailable' "${test_dir}/configured.md"

if rg -qi 'get-secret-value|batch-get-secret-value' "${audit_script}" "${test_dir}"; then
    echo "production audit contains or emitted a forbidden secret value operation" >&2
    exit 1
fi

echo "Production readiness audit assertions passed"
