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
    DEPLOYMENT_CONTROLLER_AMI_ID=ami-01111111111111111 \
    DEPLOYMENT_CONTROLLER_IMAGE_DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    DEPLOYMENT_REQUIRE_RELEASE_IDENTITY=true \
    DEPLOYMENT_SSM_POLL_SECONDS=0 \
    DEPLOYMENT_WORKER_URL=https://app.example.test \
    DEPLOYMENT_WORKER_AMI_ID=ami-02222222222222222 \
    DEPLOYMENT_WORKER_IMAGE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    MOCK_DEPLOYMENT_LOG="${test_dir}/calls" \
        "${validation_script}"
}

run_validation >/dev/null
grep -Fq 'enroll controller public key' "${test_dir}/calls"
grep -Fq 'root@100.96.0.2 true' "${test_dir}/calls"
grep -Fq 'sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${test_dir}/calls"
grep -Fq 'sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "${test_dir}/calls"
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
    DEPLOYMENT_REQUIRE_HTTPS=false \
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
    DEPLOYMENT_REQUIRE_HTTPS=false \
    DEPLOYMENT_SSM_POLL_SECONDS=0 \
    MOCK_DEPLOYMENT_LOG="${test_dir}/calls" \
    MOCK_DEPLOYMENT_SCENARIO=controller-failure \
    "${validation_script}" 2>&1)
failure_status=$?
set -e
[[ ${failure_status} -eq 1 ]]
grep -Fq 'controller services failed with SSM status Failed' <<< "${failure_output}"

set +e
ssh_output=$(AWS_CLI="${mock_aws}" \
    AWS_REGION=us-east-2 \
    CURL_CLI="${mock_curl}" \
    DEPLOYMENT_CONTROLLER_URL=https://coolify.example.test \
    DEPLOYMENT_WORKER_URL=https://app.example.test \
    DEPLOYMENT_SSM_POLL_SECONDS=0 \
    MOCK_DEPLOYMENT_LOG="${test_dir}/calls" \
    MOCK_DEPLOYMENT_SCENARIO=vpc-ssh-exposed \
    "${validation_script}" 2>&1)
ssh_status=$?
set -e
[[ ${ssh_status} -eq 1 ]]
grep -Fq 'administrative and raw service ports must not be publicly reachable through VPC security groups' <<< "${ssh_output}"

echo "Deployment validation assertions passed"
