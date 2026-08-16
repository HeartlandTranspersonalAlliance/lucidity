#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
audit_script=${repo_root}/scripts/audit-ami-validation-resources.sh
mock_aws=${repo_root}/tests/fixtures/aws-ami-audit

AUDIT_NOW=2026-08-16T12:00:00Z \
AWS_CLI="${mock_aws}" \
MOCK_AUDIT_SCENARIO=clean \
    "${audit_script}" >/dev/null

set +e
stale_output=$(AUDIT_NOW=2026-08-16T12:00:00Z \
    AWS_CLI="${mock_aws}" \
    MOCK_AUDIT_SCENARIO=stale \
    "${audit_script}" 2>&1)
stale_status=$?
set -e

[[ ${stale_status} -eq 1 ]]
grep -Fq 'i-stale' <<< "${stale_output}"
grep -Fq 'ami-stale' <<< "${stale_output}"
grep -Fq 'snap-stale' <<< "${stale_output}"
grep -Fq 'Review the recorded GitHub run' <<< "${stale_output}"

echo "AMI validation resource audit assertions passed"
