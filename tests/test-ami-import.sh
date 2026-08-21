#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mock_dir=$(mktemp -d)
trap 'rm -rf "${mock_dir}"' EXIT

artifact="${mock_dir}/worker.raw"
direct_log="${mock_dir}/direct.log"
release_log="${mock_dir}/release.log"
release_output="${mock_dir}/release.output"
rerun_log="${mock_dir}/rerun.log"
rerun_output="${mock_dir}/rerun.output"
switch_log="${mock_dir}/switch.log"
kms_key_arn=arn:aws:kms:us-east-2:123456789012:key/11111111-2222-3333-4444-555555555555
touch "${artifact}" "${direct_log}" "${release_log}" "${release_output}" "${rerun_log}" "${rerun_output}" "${switch_log}"

AWS_MOCK_LOG="${direct_log}" \
AWS_MOCK_SNAPSHOT_ID=snap-123abc \
AWS_REGION=us-east-2 \
AMI_ROLE=controller \
AMI_LAUNCH_VALIDATION=true \
AMI_SNAPSHOT_KMS_KEY_ARN="${kms_key_arn}" \
AMI_TEST_INSTANCE_PROFILE_NAME=mock-controller-profile \
AMI_TEST_INSTANCE_TYPE=t3a.small \
AMI_TEST_SECURITY_GROUP_ID=sg-test \
AMI_TEST_SUBNET_ID=subnet-test \
COLDSNAP_COMMAND="${repo_root}/tests/fixtures/coldsnap" \
GITHUB_RUN_ID=mock-run \
PATH="${repo_root}/tests/fixtures:${PATH}" \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}"

grep -Fq 'coldsnap --region us-east-2 upload --wait --no-progress' "${direct_log}"
grep -Fq -- "--kms-key-id ${kms_key_arn}" "${direct_log}"
grep -Fq -- '--workers 64' "${direct_log}"
grep -Fq -- '--tag Key=Purpose,Value=ami-validation' "${direct_log}"
grep -Fq 'ec2 run-instances' "${direct_log}"
grep -Fq -- '--count 1' "${direct_log}"
grep -Fq -- '"VolumeSize":12' "${direct_log}"
grep -Fq -- '--credit-specification CpuCredits=standard' "${direct_log}"
grep -Fq 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2,InstanceMetadataTags=enabled' "${direct_log}"
grep -Fq 'ssm send-command' "${direct_log}"
grep -Fq 'coolify-controller-bootstrap.service' "${direct_log}"
grep -Fq 'coolify-controller-storage.service' "${direct_log}"
grep -Fq '/data/coolify/.controller-bootstrap-complete' "${direct_log}"
grep -Fq 'ec2 terminate-instances' "${direct_log}"
grep -Fq 'ec2 deregister-image' "${direct_log}"
grep -Fq 'ec2 delete-snapshot' "${direct_log}"

if grep -Eq '(^| )(s3 cp|s3 rm|ec2 import-snapshot)( |$)' "${direct_log}"; then
    echo "EBS Direct API validation unexpectedly used an S3 import transport" >&2
    exit 1
fi

if grep -Eq -- '--key-name|KeyName=' "${direct_log}"; then
    echo "mocked launch unexpectedly used an EC2 key pair" >&2
    exit 1
fi

if grep -Eq -- '--min-count|--max-count' "${direct_log}"; then
    echo "mocked launch used obsolete AWS CLI instance count options" >&2
    exit 1
fi

terminate_line=$(grep -n -m1 'ec2 terminate-instances' "${direct_log}" | cut -d: -f1)
deregister_line=$(grep -n -m1 'ec2 deregister-image' "${direct_log}" | cut -d: -f1)
delete_snapshot_line=$(grep -n -m1 'ec2 delete-snapshot' "${direct_log}" | cut -d: -f1)
((terminate_line < deregister_line && deregister_line < delete_snapshot_line)) || {
    echo "cleanup must terminate the instance before deregistering the AMI and deleting the snapshot" >&2
    exit 1
}

if AWS_REGION=us-east-2 \
    AMI_LAUNCH_VALIDATION=true \
    AMI_EXPECTED_BOOTC_IMAGE_REF=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    AMI_LIFECYCLE=retained \
    AMI_RELEASE_VERSION=v0.1.0 \
    AMI_ROLE=worker \
    AMI_SBOM_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    AMI_SOURCE_IMAGE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    AMI_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}" 2>/dev/null; then
    echo "retained AMI validation accepted a bootc digest different from the release digest" >&2
    exit 1
fi

AWS_MOCK_LOG="${release_log}" \
AWS_MOCK_SNAPSHOT_ID=snap-789abc \
AWS_REGION=us-east-2 \
AMI_LAUNCH_VALIDATION=true \
AMI_EXPECTED_BOOTC_IMAGE_REF=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
AMI_LIFECYCLE=retained \
AMI_RELEASE_VERSION=v0.1.0 \
AMI_ROLE=worker \
AMI_SBOM_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
AMI_SNAPSHOT_KMS_KEY_ARN="${kms_key_arn}" \
AMI_SOURCE_IMAGE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
AMI_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
AMI_TEST_INSTANCE_PROFILE_NAME=mock-worker-profile \
AMI_TEST_INSTANCE_TYPE=t3a.small \
AMI_TEST_SECURITY_GROUP_ID=sg-test \
AMI_TEST_SUBNET_ID=subnet-test \
COLDSNAP_COMMAND="${repo_root}/tests/fixtures/coldsnap" \
GITHUB_OUTPUT="${release_output}" \
GITHUB_RUN_ID=mock-release \
PATH="${repo_root}/tests/fixtures:${PATH}" \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}"

grep -Fq -- '--tag Key=Purpose,Value=ami-release' "${release_log}"
grep -Fq -- '--tag Key=Role,Value=worker' "${release_log}"
grep -Fq -- 'Name=tag:Role,Values=worker' "${release_log}"
grep -Fq -- '--tag Key=SourceRevision,Value=0123456789abcdef0123456789abcdef01234567' "${release_log}"
grep -Fq -- '--tag Key=ReleaseVersion,Value=v0.1.0' "${release_log}"
grep -Fq -- '--tag Key=SourceImageDigest,Value=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "${release_log}"
grep -Fq -- '--tag Key=SbomSha256,Value=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "${release_log}"
grep -Fq 'lucidity-bootc-ecr-auth.service' "${release_log}"
grep -Fq '50-lucidity-ecr.conf' "${release_log}"
grep -Fq '/nix/var/nix/profiles/lucidity/bin/docker-credential-ecr-login' "${release_log}"
grep -Fq 'ec2 terminate-instances' "${release_log}"
grep -Fq 'ami_id=ami-test' "${release_output}"
grep -Fq 'snapshot_id=snap-789abc' "${release_output}"
if grep -Eq 'ec2 (deregister-image|delete-snapshot)' "${release_log}"; then
    echo "a successful retained AMI release was removed during cleanup" >&2
    exit 1
fi

AWS_MOCK_EXISTING_AMI=true \
AWS_MOCK_LOG="${rerun_log}" \
AWS_MOCK_SNAPSHOT_ID=snap-789abc \
AWS_REGION=us-east-2 \
AMI_LAUNCH_VALIDATION=true \
AMI_EXPECTED_BOOTC_IMAGE_REF=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
AMI_LIFECYCLE=retained \
AMI_RELEASE_VERSION=v0.1.0 \
AMI_ROLE=worker \
AMI_SBOM_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
AMI_SNAPSHOT_KMS_KEY_ARN="${kms_key_arn}" \
AMI_SOURCE_IMAGE_DIGEST=sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
AMI_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
AMI_TEST_INSTANCE_PROFILE_NAME=mock-worker-profile \
AMI_TEST_INSTANCE_TYPE=t3a.small \
AMI_TEST_SECURITY_GROUP_ID=sg-test \
AMI_TEST_SUBNET_ID=subnet-test \
COLDSNAP_COMMAND="${repo_root}/tests/fixtures/coldsnap" \
GITHUB_OUTPUT="${rerun_output}" \
GITHUB_RUN_ID=mock-rerun \
PATH="${repo_root}/tests/fixtures:${PATH}" \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}"

grep -Fq 'ec2 describe-images' "${rerun_log}"
grep -Fq 'ec2 describe-snapshots' "${rerun_log}"
grep -Fq 'ec2 create-tags' "${rerun_log}"
grep -Fq 'ami_id=ami-abc123' "${rerun_output}"
if grep -Eq '(^| )(coldsnap|ec2 register-image|ec2 run-instances|ec2 deregister-image|ec2 delete-snapshot)( |$)' "${rerun_log}"; then
    echo "an idempotent retained AMI rerun recreated or removed AWS resources" >&2
    exit 1
fi

AWS_MOCK_LOG="${switch_log}" \
AWS_MOCK_SNAPSHOT_ID=snap-5a17c4 \
AWS_REGION=us-east-2 \
AMI_LAUNCH_VALIDATION=true \
AMI_LIFECYCLE=disposable \
AMI_SNAPSHOT_KMS_KEY_ARN="${kms_key_arn}" \
AMI_SOURCE_REVISION=0123456789abcdef0123456789abcdef01234567 \
AMI_SSM_REBOOT_WAIT_SECONDS=0 \
AMI_SWITCH_TARGET_REF=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker:sha-0123456789abcdef0123456789abcdef01234567 \
AMI_TEST_INSTANCE_PROFILE_NAME=mock-worker-profile \
AMI_TEST_INSTANCE_TYPE=t3a.small \
AMI_TEST_SECURITY_GROUP_ID=sg-test \
AMI_TEST_SUBNET_ID=subnet-test \
COLDSNAP_COMMAND="${repo_root}/tests/fixtures/coldsnap" \
GITHUB_RUN_ID=mock-switch \
PATH="${repo_root}/tests/fixtures:${PATH}" \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}"

[[ $(grep -c 'ssm send-command' "${switch_log}") -ge 4 ]] || {
    echo "switch validation must stage and validate both the target and rollback boots" >&2
    exit 1
}
grep -Fq "bootc switch '123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker:sha-0123456789abcdef0123456789abcdef01234567'" "${switch_log}"
switch_auth_json='{"auths":{"123456789012.dkr.ecr.us-east-2.amazonaws.com":{}},"credHelpers":{"123456789012.dkr.ecr.us-east-2.amazonaws.com":"ecr-login"}}'
switch_auth_base64=$(printf '%s' "${switch_auth_json}" | base64 --wrap=0)
grep -Fq "printf '%s' '${switch_auth_base64}' | base64 --decode > /run/ostree/auth.json" "${switch_log}"
grep -Fq 'docker volume create lucidity-update-rollback' "${switch_log}"
grep -Fq 'lucidity-update-rollback-marker' "${switch_log}"
grep -Fq 'lucidity-bootc-switch-benchmark-reboot' "${switch_log}"
grep -Fq 'bootc rollback' "${switch_log}"
grep -Fq 'lucidity-bootc-rollback-validation-reboot' "${switch_log}"
grep -Fq 'LUCIDITY_ROLLBACK_SOURCE_BOOTED' "${switch_log}"

switch_line=$(grep -n -m1 -- '--comment lucidity bootc switch benchmark' "${switch_log}" | cut -d: -f1)
target_validation_line=$(grep -n -m1 -- '--comment lucidity bootc AMI validation' "${switch_log}" | cut -d: -f1)
rollback_line=$(grep -n -m1 -- '--comment lucidity bootc rollback validation' "${switch_log}" | cut -d: -f1)
rollback_validation_line=$(grep -n -m1 -- '--comment lucidity bootc rollback guest validation' "${switch_log}" | cut -d: -f1)
((switch_line < target_validation_line && target_validation_line < rollback_line && rollback_line < rollback_validation_line)) || {
    echo "switch, target validation, rollback, and rollback validation must run in order" >&2
    exit 1
}
grep -Fq 'ec2 terminate-instances' "${switch_log}"
grep -Fq 'ec2 deregister-image' "${switch_log}"
grep -Fq 'ec2 delete-snapshot' "${switch_log}"

echo "mocked EBS Direct API, retained release, update/rollback lifecycle, and T3a launch assertions passed"
