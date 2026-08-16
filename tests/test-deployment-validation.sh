#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
validation_script=${repo_root}/scripts/validate-deployment.sh
mock_aws=${repo_root}/tests/fixtures/aws-deployment-validation
mock_curl=${repo_root}/tests/fixtures/deployment-curl
test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT

run_validation() {
    AWS_CLI="${mock_aws}" \
    AWS_REGION=us-east-2 \
    CURL_CLI="${mock_curl}" \
    DEPLOYMENT_CONTROLLER_URL=https://coolify.example.test \
    DEPLOYMENT_SSM_POLL_SECONDS=0 \
    DEPLOYMENT_WORKER_URL=https://app.example.test \
    MOCK_DEPLOYMENT_LOG="${test_dir}/calls" \
        "${validation_script}"
}

run_validation >/dev/null
grep -Fq 'enroll controller public key' "${test_dir}/calls"
grep -Fq 'root@10.20.0.20 true' "${test_dir}/calls"
grep -Fxq 'https://coolify.example.test' "${test_dir}/calls"
grep -Fxq 'https://app.example.test' "${test_dir}/calls"

: > "${test_dir}/calls"
DEPLOYMENT_ENROLL_WORKER=false run_validation >/dev/null
if grep -Fq 'enroll controller public key' "${test_dir}/calls"; then
    echo "disabled enrollment unexpectedly changed the worker" >&2
    exit 1
fi
grep -Fq 'worker enrollment' "${test_dir}/calls"

set +e
duplicate_output=$(AWS_CLI="${mock_aws}" \
    AWS_REGION=us-east-2 \
    CURL_CLI="${mock_curl}" \
    DEPLOYMENT_SSM_POLL_SECONDS=0 \
    MOCK_DEPLOYMENT_LOG="${test_dir}/calls" \
    MOCK_DEPLOYMENT_SCENARIO=duplicate-controller \
    "${validation_script}" 2>&1)
duplicate_status=$?
set -e
[[ ${duplicate_status} -eq 1 ]]
grep -Fq 'expected exactly one active lucidity production controller node; found 2' <<< "${duplicate_output}"

set +e
failure_output=$(AWS_CLI="${mock_aws}" \
    AWS_REGION=us-east-2 \
    CURL_CLI="${mock_curl}" \
    DEPLOYMENT_SSM_POLL_SECONDS=0 \
    MOCK_DEPLOYMENT_LOG="${test_dir}/calls" \
    MOCK_DEPLOYMENT_SCENARIO=controller-failure \
    "${validation_script}" 2>&1)
failure_status=$?
set -e
[[ ${failure_status} -eq 1 ]]
grep -Fq 'controller services failed with SSM status Failed' <<< "${failure_output}"

echo "Production deployment validation assertions passed"
