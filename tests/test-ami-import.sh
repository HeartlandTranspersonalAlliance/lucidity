#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mock_dir=$(mktemp -d)
trap 'rm -rf "${mock_dir}"' EXIT

artifact="${mock_dir}/worker.raw"
direct_log="${mock_dir}/direct.log"
fallback_log="${mock_dir}/fallback.log"
kms_key_arn=arn:aws:kms:us-east-2:123456789012:key/11111111-2222-3333-4444-555555555555
touch "${artifact}" "${direct_log}" "${fallback_log}"

AWS_MOCK_LOG="${direct_log}" \
AWS_MOCK_SNAPSHOT_ID=snap-123abc \
AWS_REGION=us-east-2 \
AMI_LAUNCH_VALIDATION=true \
AMI_SNAPSHOT_KMS_KEY_ARN="${kms_key_arn}" \
AMI_TEST_INSTANCE_PROFILE_NAME=mock-worker-profile \
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
grep -Fq 'ec2 terminate-instances' "${direct_log}"
grep -Fq 'ec2 deregister-image' "${direct_log}"
grep -Fq 'ec2 delete-snapshot' "${direct_log}"

if grep -Eq '(^| )(s3 cp|s3 rm|ec2 import-snapshot)( |$)' "${direct_log}"; then
    echo "EBS Direct API validation unexpectedly used the VM Import transport" >&2
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

AWS_MOCK_LOG="${fallback_log}" \
AWS_MOCK_SNAPSHOT_ID=snap-456def \
AWS_REGION=us-east-2 \
AMI_IMPORT_BUCKET=mock-import-bucket \
AMI_LAUNCH_VALIDATION=false \
AMI_SNAPSHOT_UPLOAD_MODE=vmimport \
GITHUB_RUN_ID=mock-fallback \
PATH="${repo_root}/tests/fixtures:${PATH}" \
VMIMPORT_ROLE_NAME=mock-vmimport \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}"

grep -Fq 's3 cp' "${fallback_log}"
grep -Fq 'ec2 import-snapshot' "${fallback_log}"
grep -Fq -- '--role-name mock-vmimport' "${fallback_log}"
grep -Fq 'ec2 register-image' "${fallback_log}"
grep -Fq 'ec2 delete-snapshot' "${fallback_log}"
grep -Fq 's3 rm' "${fallback_log}"
if grep -Fq 'coldsnap ' "${fallback_log}"; then
    echo "VM Import fallback unexpectedly used coldsnap" >&2
    exit 1
fi

echo "mocked EBS Direct API, VM Import fallback, and T3a launch assertions passed"
