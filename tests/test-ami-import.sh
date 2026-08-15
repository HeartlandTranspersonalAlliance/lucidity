#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
mock_dir=$(mktemp -d)
trap 'rm -rf "${mock_dir}"' EXIT

artifact="${mock_dir}/worker.raw"
mock_log="${mock_dir}/aws.log"
touch "${artifact}" "${mock_log}"

AWS_MOCK_LOG="${mock_log}" \
AWS_REGION=us-east-2 \
AMI_IMPORT_BUCKET=mock-import-bucket \
AMI_LAUNCH_VALIDATION=true \
AMI_TEST_INSTANCE_PROFILE_NAME=mock-worker-profile \
AMI_TEST_INSTANCE_TYPE=t3a.small \
AMI_TEST_SECURITY_GROUP_ID=sg-test \
AMI_TEST_SUBNET_ID=subnet-test \
GITHUB_RUN_ID=mock-run \
PATH="${repo_root}/tests/fixtures:${PATH}" \
VMIMPORT_ROLE_NAME=mock-vmimport \
    "${repo_root}/scripts/validate-ami-import.sh" "${artifact}"

grep -Fq 'ec2 run-instances' "${mock_log}"
grep -Fq -- '--count 1' "${mock_log}"
grep -Fq -- '"VolumeSize":12' "${mock_log}"
grep -Fq -- '--credit-specification CpuCredits=standard' "${mock_log}"
grep -Fq 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2,InstanceMetadataTags=enabled' "${mock_log}"
grep -Fq 'ssm send-command' "${mock_log}"
grep -Fq 'ec2 terminate-instances' "${mock_log}"
grep -Fq 'ec2 deregister-image' "${mock_log}"
grep -Fq 'ec2 delete-snapshot' "${mock_log}"
grep -Fq 's3 rm' "${mock_log}"

if grep -Eq -- '--key-name|KeyName=' "${mock_log}"; then
    echo "mocked launch unexpectedly used an EC2 key pair" >&2
    exit 1
fi

if grep -Eq -- '--min-count|--max-count' "${mock_log}"; then
    echo "mocked launch used obsolete AWS CLI instance count options" >&2
    exit 1
fi

terminate_line=$(grep -n -m1 'ec2 terminate-instances' "${mock_log}" | cut -d: -f1)
deregister_line=$(grep -n -m1 'ec2 deregister-image' "${mock_log}" | cut -d: -f1)
delete_snapshot_line=$(grep -n -m1 'ec2 delete-snapshot' "${mock_log}" | cut -d: -f1)
((terminate_line < deregister_line && deregister_line < delete_snapshot_line)) || {
    echo "cleanup must terminate the instance before deregistering the AMI and deleting the snapshot" >&2
    exit 1
}

echo "mocked AMI import and T3a launch assertions passed"
