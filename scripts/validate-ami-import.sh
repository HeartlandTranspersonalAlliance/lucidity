#!/usr/bin/env bash
set -Eeuo pipefail

artifact=${1:-}
region=${AWS_REGION:-}
snapshot_kms_key_arn=${AMI_SNAPSHOT_KMS_KEY_ARN:-}
coldsnap_command=${COLDSNAP_COMMAND:-coldsnap}
coldsnap_workers=${COLDSNAP_WORKERS:-64}
run_id=${GITHUB_RUN_ID:-manual-$(date +%s)}
ami_lifecycle=${AMI_LIFECYCLE:-disposable}
ami_role=${AMI_ROLE:-worker}
source_revision=${AMI_SOURCE_REVISION:-}
expected_bootc_image_ref=${AMI_EXPECTED_BOOTC_IMAGE_REF:-}
release_version=${AMI_RELEASE_VERSION:-}
source_image_digest=${AMI_SOURCE_IMAGE_DIGEST:-}
sbom_sha256=${AMI_SBOM_SHA256:-}
switch_target_ref=${AMI_SWITCH_TARGET_REF:-}
launch_validation=${AMI_LAUNCH_VALIDATION:-false}
launch_instance_type=${AMI_TEST_INSTANCE_TYPE:-t3a.small}
launch_subnet=${AMI_TEST_SUBNET_ID:-}
launch_security_group=${AMI_TEST_SECURITY_GROUP_ID:-}
launch_instance_profile=${AMI_TEST_INSTANCE_PROFILE_NAME:-}

[[ -n ${artifact} ]] || { echo "usage: validate-ami-import.sh ARTIFACT" >&2; exit 2; }
[[ -f ${artifact} ]] || { echo "AMI artifact not found: ${artifact}" >&2; exit 1; }
[[ ${artifact} == *.ami || ${artifact} == *.raw ]] || { echo "AMI validation requires a raw .ami or .raw artifact" >&2; exit 2; }
[[ -n ${region} ]] || { echo "AWS_REGION is required" >&2; exit 2; }
[[ ${ami_lifecycle} == disposable || ${ami_lifecycle} == retained ]] || { echo "AMI_LIFECYCLE must be disposable or retained" >&2; exit 2; }
[[ ${ami_role} == controller || ${ami_role} == worker ]] || { echo "AMI_ROLE must be controller or worker" >&2; exit 2; }
if [[ -n ${switch_target_ref} ]]; then
    [[ ${ami_lifecycle} == disposable ]] || { echo "AMI_SWITCH_TARGET_REF is restricted to disposable validation" >&2; exit 2; }
    [[ ${launch_validation} == true ]] || { echo "AMI_SWITCH_TARGET_REF requires the disposable EC2 launch gate" >&2; exit 2; }
    [[ ${source_revision} =~ ^[0-9a-f]{40}$ ]] || { echo "AMI_SOURCE_REVISION must be a full lowercase Git commit SHA for switch benchmarks" >&2; exit 2; }
    [[ ${switch_target_ref} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*:sha-${source_revision}$ ]] || {
        echo "AMI_SWITCH_TARGET_REF must be the benchmark commit's fully qualified private ECR reference" >&2
        exit 2
    }
fi
release_metadata=false
if [[ -n ${release_version} || -n ${source_image_digest} || -n ${sbom_sha256} ]]; then
    [[ ${ami_lifecycle} == retained ]] || { echo "release metadata is restricted to retained AMIs" >&2; exit 2; }
    [[ ${release_version} =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "AMI_RELEASE_VERSION must be a v-prefixed semantic version" >&2; exit 2; }
    [[ ${source_image_digest} =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "AMI_SOURCE_IMAGE_DIGEST must be a lowercase SHA-256 OCI digest" >&2; exit 2; }
    [[ ${sbom_sha256} =~ ^[0-9a-f]{64}$ ]] || { echo "AMI_SBOM_SHA256 must be a lowercase SHA-256 digest" >&2; exit 2; }
    release_metadata=true
fi
if [[ ${ami_lifecycle} == retained ]]; then
    [[ ${launch_validation} == true ]] || { echo "retained AMIs require the EC2 launch gate" >&2; exit 2; }
    [[ ${source_revision} =~ ^[0-9a-f]{40}$ ]] || { echo "AMI_SOURCE_REVISION must be a full lowercase Git commit SHA for retained AMIs" >&2; exit 2; }
    if [[ ${release_metadata} == true ]]; then
        [[ ${expected_bootc_image_ref} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*@sha256:[0-9a-f]{64}$ ]] || {
            echo "AMI_EXPECTED_BOOTC_IMAGE_REF must use the retained release's immutable ECR digest" >&2
            exit 2
        }
        [[ ${expected_bootc_image_ref##*@} == "${source_image_digest}" ]] || {
            echo "AMI_EXPECTED_BOOTC_IMAGE_REF must match AMI_SOURCE_IMAGE_DIGEST" >&2
            exit 2
        }
    else
        [[ ${expected_bootc_image_ref} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*:sha-${source_revision}$ ]] || {
            echo "AMI_EXPECTED_BOOTC_IMAGE_REF must use the retained commit's immutable ECR tag" >&2
            exit 2
        }
    fi
fi
[[ ${snapshot_kms_key_arn} =~ ^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+$ ]] || {
    echo "AMI_SNAPSHOT_KMS_KEY_ARN must be a customer-managed KMS key ARN for EBS Direct uploads" >&2
    exit 2
}
[[ ${coldsnap_workers} =~ ^[1-9][0-9]*$ ]] || { echo "COLDSNAP_WORKERS must be a positive integer" >&2; exit 2; }
[[ ${launch_validation} == true || ${launch_validation} == false ]] || { echo "AMI_LAUNCH_VALIDATION must be true or false" >&2; exit 2; }
if [[ ${launch_validation} == true ]]; then
    [[ ${launch_instance_type} == t3a.small ]] || { echo "disposable launch validation is restricted to t3a.small" >&2; exit 2; }
    [[ -n ${launch_subnet} ]] || { echo "AMI_TEST_SUBNET_ID is required for launch validation" >&2; exit 2; }
    [[ -n ${launch_security_group} ]] || { echo "AMI_TEST_SECURITY_GROUP_ID is required for launch validation" >&2; exit 2; }
    [[ -n ${launch_instance_profile} ]] || { echo "AMI_TEST_INSTANCE_PROFILE_NAME is required for launch validation" >&2; exit 2; }
fi

ssm_reboot_wait_seconds=${AMI_SSM_REBOOT_WAIT_SECONDS:-20}
ssm_ready_attempts=${AMI_SSM_READY_ATTEMPTS:-90}
ssm_ready_interval_seconds=${AMI_SSM_READY_INTERVAL_SECONDS:-10}
[[ ${ssm_reboot_wait_seconds} =~ ^[0-9]+$ ]] || { echo "AMI_SSM_REBOOT_WAIT_SECONDS must be a non-negative integer" >&2; exit 2; }
[[ ${ssm_ready_attempts} =~ ^[1-9][0-9]*$ ]] || { echo "AMI_SSM_READY_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${ssm_ready_interval_seconds} =~ ^[0-9]+$ ]] || { echo "AMI_SSM_READY_INTERVAL_SECONDS must be a non-negative integer" >&2; exit 2; }

for command in aws jq; do
    command -v "${command}" >/dev/null 2>&1 || { echo "${command} is required" >&2; exit 1; }
done
command -v "${coldsnap_command}" >/dev/null 2>&1 || { echo "${coldsnap_command} is required for EBS Direct uploads" >&2; exit 1; }

artifact=$(realpath "${artifact}")
if [[ ${ami_lifecycle} == retained ]]; then
    artifact_purpose=ami-release
    release_status=candidate
    image_name="lucidity-${ami_role}-amd64-${source_revision}"
    image_description="Retained lucidity ${ami_role} AMD64 bootc AMI from ${source_revision}"
else
    artifact_purpose=ami-validation
    release_status=disposable
    image_name="lucidity-ami-validation-${run_id}"
    image_description="Disposable lucidity AMD64 bootc AMI validation ${run_id}"
fi
source_revision_tag=${source_revision:-none}
snapshot_release_tags=()
resource_release_tags=()
if [[ ${release_metadata} == true ]]; then
    snapshot_release_tags+=(
        --tag "Key=ReleaseVersion,Value=${release_version}"
        --tag "Key=SourceImageDigest,Value=${source_image_digest}"
        --tag "Key=SbomSha256,Value=${sbom_sha256}"
    )
    resource_release_tags+=(
        "Key=ReleaseVersion,Value=${release_version}"
        "Key=SourceImageDigest,Value=${source_image_digest}"
        "Key=SbomSha256,Value=${sbom_sha256}"
    )
fi
image_id=""
instance_id=""
snapshot_ids=()
completed_successfully=false

report_instance_readiness() {
    local readiness_output
    [[ -n ${instance_id} ]] || return 0
    echo "EC2 and SSM readiness diagnostics for ${instance_id}:" >&2
    readiness_output=$(aws ec2 describe-instance-status \
        --region "${region}" \
        --instance-ids "${instance_id}" \
        --include-all-instances \
        --query 'InstanceStatuses[0].{AvailabilityZone:AvailabilityZone,InstanceState:InstanceState.Name,SystemStatus:SystemStatus.Status,InstanceStatus:InstanceStatus.Status,SystemDetails:SystemStatus.Details,InstanceDetails:InstanceStatus.Details}' \
        --output json 2>/dev/null) && printf '%s\n' "${readiness_output}" >&2 || true
    readiness_output=$(aws ssm describe-instance-information \
        --region "${region}" \
        --filters "Key=InstanceIds,Values=${instance_id}" \
        --query 'InstanceInformationList[0].{PingStatus:PingStatus,LastPingDateTime:LastPingDateTime,AgentVersion:AgentVersion,PlatformName:PlatformName,PlatformVersion:PlatformVersion}' \
        --output json 2>/dev/null) && printf '%s\n' "${readiness_output}" >&2 || true
}

cleanup() {
    local original_status=$?
    local cleanup_status=0
    local already_known existing_snapshot_id status snapshot_id
    local -a discovered_snapshot_ids=()
    trap - EXIT
    set +e

    if [[ -n ${instance_id} ]]; then
        status=$(aws ec2 describe-instances \
            --region "${region}" \
            --instance-ids "${instance_id}" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text 2>/dev/null)
        if [[ ${status} != terminated && ${status} != None ]]; then
            aws ec2 terminate-instances \
                --region "${region}" \
                --instance-ids "${instance_id}" >/dev/null || cleanup_status=1
            aws ec2 wait instance-terminated \
                --region "${region}" \
                --instance-ids "${instance_id}" || cleanup_status=1
        fi
    fi

    preserve_release=false
    if ((original_status == 0)) && [[ ${ami_lifecycle} == retained && ${completed_successfully} == true ]]; then
        preserve_release=true
    fi

    if [[ -n ${image_id} && ${preserve_release} == false ]]; then
        aws ec2 deregister-image \
            --region "${region}" \
            --image-id "${image_id}" >/dev/null || cleanup_status=1
    fi

    if [[ ${preserve_release} == false ]]; then
        mapfile -t discovered_snapshot_ids < <(aws ec2 describe-snapshots \
            --region "${region}" \
            --owner-ids self \
            --filters \
                "Name=tag:Project,Values=lucidity" \
                "Name=tag:Purpose,Values=${artifact_purpose}" \
                "Name=tag:GitHubRunId,Values=${run_id}" \
                "Name=tag:Role,Values=${ami_role}" \
            --query 'Snapshots[].SnapshotId' \
            --output text 2>/dev/null | tr '\t' '\n')
    fi
    for snapshot_id in "${discovered_snapshot_ids[@]}"; do
        [[ ${snapshot_id} =~ ^snap-[0-9a-f]+$ ]] || continue
        already_known=false
        for existing_snapshot_id in "${snapshot_ids[@]}"; do
            if [[ ${existing_snapshot_id} == "${snapshot_id}" ]]; then
                already_known=true
                break
            fi
        done
        if [[ ${already_known} == false ]]; then
            snapshot_ids+=("${snapshot_id}")
        fi
    done

    for snapshot_id in "${snapshot_ids[@]}"; do
        [[ ${preserve_release} == false ]] || break
        deleted=false
        for _ in {1..6}; do
            if aws ec2 delete-snapshot \
                --region "${region}" \
                --snapshot-id "${snapshot_id}" >/dev/null 2>&1; then
                deleted=true
                break
            fi
            sleep 10
        done
        [[ ${deleted} == true ]] || { echo "failed to delete AMI snapshot ${snapshot_id}" >&2; cleanup_status=1; }
    done

    if ((original_status != 0)); then
        exit "${original_status}"
    fi
    exit "${cleanup_status}"
}
trap cleanup EXIT

if [[ ${ami_lifecycle} == retained ]]; then
    existing_image=$(aws ec2 describe-images \
        --region "${region}" \
        --owners self \
        --filters \
            "Name=name,Values=${image_name}" \
            "Name=tag:Project,Values=lucidity" \
            "Name=tag:Purpose,Values=ami-release" \
            "Name=tag:Role,Values=${ami_role}" \
            "Name=tag:SourceRevision,Values=${source_revision}" \
            "Name=tag:ReleaseStatus,Values=validated" \
        --output json)
    existing_count=$(jq '.Images | length' <<< "${existing_image}")
    ((existing_count <= 1)) || { echo "multiple validated AMIs exist for ${ami_role} ${source_revision}" >&2; exit 1; }
    if ((existing_count == 1)); then
        image_id=$(jq -r '.Images[0].ImageId' <<< "${existing_image}")
        mapfile -t snapshot_ids < <(jq -r '.Images[0].BlockDeviceMappings[].Ebs.SnapshotId // empty' <<< "${existing_image}")
        [[ ${image_id} =~ ^ami-[0-9a-f]+$ && ${#snapshot_ids[@]} -eq 1 ]] || { echo "existing retained AMI metadata is incomplete" >&2; exit 1; }
        [[ $(jq -r '.Images[0].State' <<< "${existing_image}") == available ]] || { echo "existing retained AMI is not available" >&2; exit 1; }
        [[ $(jq -r '.Images[0].Architecture' <<< "${existing_image}") == x86_64 ]] || { echo "existing retained AMI is not x86_64" >&2; exit 1; }
        [[ $(jq -r '.Images[0].BootMode' <<< "${existing_image}") == uefi ]] || { echo "existing retained AMI is not UEFI-only" >&2; exit 1; }
        [[ $(jq -r '.Images[0].EnaSupport' <<< "${existing_image}") == true ]] || { echo "existing retained AMI does not enable ENA" >&2; exit 1; }
        [[ $(jq -r '.Images[0].ImdsSupport' <<< "${existing_image}") == v2.0 ]] || { echo "existing retained AMI does not require IMDSv2" >&2; exit 1; }
        existing_snapshot=$(aws ec2 describe-snapshots --region "${region}" --snapshot-ids "${snapshot_ids[0]}" --output json)
        [[ $(jq -r '.Snapshots[0].Encrypted' <<< "${existing_snapshot}") == true ]] || { echo "existing retained AMI snapshot is not encrypted" >&2; exit 1; }
        [[ $(jq -r '.Snapshots[0].KmsKeyId' <<< "${existing_snapshot}") == "${snapshot_kms_key_arn}" ]] || { echo "existing retained AMI snapshot uses the wrong KMS key" >&2; exit 1; }
        if [[ ${release_metadata} == true ]]; then
            for tag_entry in \
                "ReleaseVersion=${release_version}" \
                "SourceImageDigest=${source_image_digest}" \
                "SbomSha256=${sbom_sha256}"; do
                tag_key=${tag_entry%%=*}
                expected_value=${tag_entry#*=}
                existing_value=$(jq -r --arg key "${tag_key}" '.Images[0].Tags[]? | select(.Key == $key) | .Value' <<< "${existing_image}")
                [[ -z ${existing_value} || ${existing_value} == "${expected_value}" ]] || {
                    echo "existing retained AMI ${image_id} has conflicting ${tag_key} metadata" >&2
                    exit 1
                }
            done
            aws ec2 create-tags \
                --region "${region}" \
                --resources "${image_id}" "${snapshot_ids[0]}" \
                --tags \
                    "Key=Project,Value=lucidity" \
                    "Key=Purpose,Value=ami-release" \
                    "Key=Role,Value=${ami_role}" \
                    "Key=SourceRevision,Value=${source_revision}" \
                    "Key=ReleaseStatus,Value=validated" \
                    "${resource_release_tags[@]}"
        fi
        completed_successfully=true
        if [[ -n ${GITHUB_OUTPUT:-} ]]; then
            {
                echo "ami_id=${image_id}"
                echo "snapshot_id=${snapshot_ids[0]}"
            } >> "${GITHUB_OUTPUT}"
        fi
        echo "Retaining existing validated ${ami_role} AMI ${image_id} for ${source_revision}"
        exit 0
    fi
fi

echo "Uploading the ${ami_lifecycle} AMI artifact directly to an encrypted EBS snapshot"
snapshot_id=$("${coldsnap_command}" \
    --region "${region}" \
    upload \
    --wait \
    --no-progress \
    --kms-key-id "${snapshot_kms_key_arn}" \
    --workers "${coldsnap_workers}" \
    --description "${image_description}" \
    --tag "Key=Name,Value=${image_name}" \
    --tag "Key=Project,Value=lucidity" \
    --tag "Key=Purpose,Value=${artifact_purpose}" \
    --tag "Key=Role,Value=${ami_role}" \
    --tag "Key=GitHubRunId,Value=${run_id}" \
    --tag "Key=SourceRevision,Value=${source_revision_tag}" \
    --tag "Key=ReleaseStatus,Value=${release_status}" \
    "${snapshot_release_tags[@]}" \
    "${artifact}")
[[ ${snapshot_id} =~ ^snap-[0-9a-f]+$ ]] || { echo "coldsnap did not return a snapshot ID" >&2; exit 1; }
snapshot_ids=("${snapshot_id}")
(( ${#snapshot_ids[@]} > 0 )) || { echo "snapshot upload did not return a snapshot ID" >&2; exit 1; }

snapshot=$(aws ec2 describe-snapshots \
    --region "${region}" \
    --snapshot-ids "${snapshot_ids[0]}" \
    --output json)
[[ $(jq -r '.Snapshots[0].Encrypted' <<< "${snapshot}") == true ]] || { echo "uploaded snapshot is not encrypted" >&2; exit 1; }
[[ $(jq -r '.Snapshots[0].KmsKeyId // empty' <<< "${snapshot}") == "${snapshot_kms_key_arn}" ]] || {
    echo "direct snapshot does not use the configured KMS key" >&2
    exit 1
}
snapshot_volume_size=$(jq -r '.Snapshots[0].VolumeSize // empty' <<< "${snapshot}")
[[ ${snapshot_volume_size} =~ ^[1-9][0-9]*$ ]] || { echo "uploaded snapshot did not return a valid volume size" >&2; exit 1; }

aws ec2 create-tags \
    --region "${region}" \
    --resources "${snapshot_ids[0]}" \
    --tags \
        "Key=Name,Value=${image_name}" \
        "Key=Project,Value=lucidity" \
        "Key=Purpose,Value=${artifact_purpose}" \
        "Key=Role,Value=${ami_role}" \
        "Key=GitHubRunId,Value=${run_id}" \
        "Key=SourceRevision,Value=${source_revision_tag}" \
        "Key=ReleaseStatus,Value=${release_status}" \
        "${resource_release_tags[@]}"

block_device_mappings=$(jq -cn \
    --arg snapshot_id "${snapshot_ids[0]}" \
    '[{DeviceName:"/dev/xvda",Ebs:{SnapshotId:$snapshot_id,DeleteOnTermination:true,VolumeType:"gp3"}}]')
image_tags=$(jq -cn \
    --arg name "${image_name}" \
    --arg project lucidity \
    --arg purpose "${artifact_purpose}" \
    --arg role "${ami_role}" \
    --arg run_id "${run_id}" \
    --arg source_revision "${source_revision_tag}" \
    --arg release_status "${release_status}" \
    --arg release_version "${release_version}" \
    --arg source_image_digest "${source_image_digest}" \
    --arg sbom_sha256 "${sbom_sha256}" \
    '[
        {Key:"Name",Value:$name},
        {Key:"Project",Value:$project},
        {Key:"Purpose",Value:$purpose},
        {Key:"Role",Value:$role},
        {Key:"GitHubRunId",Value:$run_id},
        {Key:"SourceRevision",Value:$source_revision},
        {Key:"ReleaseStatus",Value:$release_status}
    ] + if $release_version == "" then [] else [
        {Key:"ReleaseVersion",Value:$release_version},
        {Key:"SourceImageDigest",Value:$source_image_digest},
        {Key:"SbomSha256",Value:$sbom_sha256}
    ] end')
register_tag_specification=$(jq -cn --argjson tags "${image_tags}" '[{ResourceType:"image",Tags:$tags}]')
register_response=$(aws ec2 register-image \
    --region "${region}" \
    --name "${image_name}" \
    --description "${image_description}" \
    --architecture x86_64 \
    --virtualization-type hvm \
    --root-device-name /dev/xvda \
    --block-device-mappings "${block_device_mappings}" \
    --boot-mode uefi \
    --ena-support \
    --imds-support v2.0 \
    --tag-specifications "${register_tag_specification}" \
    --output json)
image_id=$(jq -r '.ImageId' <<< "${register_response}")
[[ -n ${image_id} && ${image_id} != null ]] || { echo "EC2 did not return a registered AMI ID" >&2; exit 1; }

aws ec2 wait image-available \
    --region "${region}" \
    --image-ids "${image_id}"
image=$(aws ec2 describe-images \
    --region "${region}" \
    --image-ids "${image_id}" \
    --output json)
[[ $(jq -r '.Images[0].State' <<< "${image}") == available ]] || { echo "registered AMI is not available" >&2; exit 1; }
[[ $(jq -r '.Images[0].Architecture' <<< "${image}") == x86_64 ]] || { echo "registered AMI is not x86_64" >&2; exit 1; }
[[ $(jq -r '.Images[0].RootDeviceType' <<< "${image}") == ebs ]] || { echo "registered AMI is not EBS-backed" >&2; exit 1; }
[[ $(jq -r '.Images[0].BootMode' <<< "${image}") == uefi ]] || { echo "registered AMI is not UEFI-only" >&2; exit 1; }
[[ $(jq -r '.Images[0].EnaSupport' <<< "${image}") == true ]] || { echo "registered AMI does not enable ENA" >&2; exit 1; }
[[ $(jq -r '.Images[0].ImdsSupport' <<< "${image}") == v2.0 ]] || { echo "registered AMI does not require IMDSv2" >&2; exit 1; }
[[ $(jq -r '.Images[0].BlockDeviceMappings[0].Ebs.DeleteOnTermination' <<< "${image}") == true ]] || { echo "AMI root volume is not deleted on instance termination" >&2; exit 1; }
[[ $(jq -r '.Images[0].BlockDeviceMappings[0].Ebs.VolumeType' <<< "${image}") == gp3 ]] || { echo "AMI root volume is not gp3" >&2; exit 1; }

if [[ ${launch_validation} == true ]]; then
    security_group=$(aws ec2 describe-security-groups \
        --region "${region}" \
        --group-ids "${launch_security_group}" \
        --output json)
    public_ssh_rules=$(jq '[
        .SecurityGroups[0].IpPermissions[]
        | select((.IpProtocol == "-1") or ((.FromPort // 65536) <= 22 and (.ToPort // -1) >= 22))
        | ((.IpRanges // []) + (.Ipv6Ranges // []))[]
    ] | length' <<< "${security_group}")
    [[ ${public_ssh_rules} == 0 ]] || { echo "launch validation security group exposes public SSH" >&2; exit 1; }

    tag_specifications=$(jq -cn --arg run_id "${run_id}" '[
        {ResourceType:"instance",Tags:[
            {Key:"Name",Value:("lucidity-ami-validation-" + $run_id)},
            {Key:"Project",Value:"lucidity"},
            {Key:"Purpose",Value:"ami-validation"},
            {Key:"GitHubRunId",Value:$run_id}
        ]},
        {ResourceType:"volume",Tags:[
            {Key:"Project",Value:"lucidity"},
            {Key:"Purpose",Value:"ami-validation"},
            {Key:"GitHubRunId",Value:$run_id}
        ]},
        {ResourceType:"network-interface",Tags:[
            {Key:"Project",Value:"lucidity"},
            {Key:"Purpose",Value:"ami-validation"},
            {Key:"GitHubRunId",Value:$run_id}
        ]}
    ]')
    launch_block_devices=$(jq -cn \
        --argjson volume_size "${snapshot_volume_size}" \
        '[{
            DeviceName:"/dev/xvda",
            Ebs:{DeleteOnTermination:true,Encrypted:true,VolumeSize:$volume_size,VolumeType:"gp3"}
        }]')

    echo "Launching disposable ${launch_instance_type} without a key pair or inbound SSH"
    instance_response=$(aws ec2 run-instances \
        --region "${region}" \
        --image-id "${image_id}" \
        --instance-type "${launch_instance_type}" \
        --count 1 \
        --subnet-id "${launch_subnet}" \
        --security-group-ids "${launch_security_group}" \
        --iam-instance-profile "Name=${launch_instance_profile}" \
        --associate-public-ip-address \
        --credit-specification CpuCredits=standard \
        --metadata-options HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2,InstanceMetadataTags=enabled \
        --block-device-mappings "${launch_block_devices}" \
        --tag-specifications "${tag_specifications}" \
        --output json)
    instance_id=$(jq -r '.Instances[0].InstanceId // empty' <<< "${instance_response}")
    [[ -n ${instance_id} ]] || { echo "EC2 did not return a validation instance ID" >&2; exit 1; }

    aws ec2 wait instance-running --region "${region}" --instance-ids "${instance_id}"

    ssm_online=false
    for ((readiness_attempt = 1; readiness_attempt <= ssm_ready_attempts; readiness_attempt++)); do
        ping_status=$(aws ssm describe-instance-information \
            --region "${region}" \
            --filters "Key=InstanceIds,Values=${instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text)
        if [[ ${ping_status} == Online ]]; then
            ssm_online=true
            break
        fi
        sleep "${ssm_ready_interval_seconds}"
    done
    report_instance_readiness
    [[ ${ssm_online} == true ]] || { echo "validation instance did not become available through SSM" >&2; exit 1; }

    if [[ -n ${switch_target_ref} ]]; then
        switch_registry=${switch_target_ref%%/*}
        switch_auth_json=$(jq -cn \
            --arg registry "${switch_registry}" \
            '{auths:{($registry):{}},credHelpers:{($registry):"ecr-login"}}')
        switch_auth_base64=$(printf '%s' "${switch_auth_json}" | base64 --wrap=0)
        switch_started_at=$(date +%s)
        switch_commands=$(jq -cn \
            --arg auth_base64 "${switch_auth_base64}" \
            --arg target "${switch_target_ref}" \
            '{commands:[
                "set -eu",
                "install -d -m 0700 /var/lib/lucidity-update-rollback",
                "source_image=$(bootc status --format=json --format-version=1 --booted | jq -r .status.booted.image.image.image); test -n \"${source_image}\"; test \"${source_image}\" != null; printf \u0027%s\\n\u0027 \"${source_image}\" > /var/lib/lucidity-update-rollback/source-image-ref",
                "docker volume create lucidity-update-rollback >/dev/null",
                "volume_path=$(docker volume inspect lucidity-update-rollback | jq -r \u0027.[0].Mountpoint\u0027); printf \u0027%s\\n\u0027 lucidity-update-rollback-marker > \"${volume_path}/marker\"",
                "sync",
                "install -d -m 0700 /run/ostree",
                ("printf \u0027%s\u0027 \u0027" + $auth_base64 + "\u0027 | base64 --decode > /run/ostree/auth.json"),
                "chmod 0600 /run/ostree/auth.json",
                ("bootc switch \u0027" + $target + "\u0027"),
                "systemd-run --unit=lucidity-bootc-switch-benchmark-reboot --on-active=10s /usr/bin/systemctl reboot"
            ]}')
        command_response=$(aws ssm send-command \
            --region "${region}" \
            --document-name AWS-RunShellScript \
            --instance-ids "${instance_id}" \
            --comment "lucidity bootc switch benchmark ${run_id}" \
            --parameters "${switch_commands}" \
            --timeout-seconds 3600 \
            --output json)
        command_id=$(jq -r '.Command.CommandId // empty' <<< "${command_response}")
        [[ -n ${command_id} ]] || { echo "SSM did not return a bootc switch command ID" >&2; exit 1; }

        switch_staged=false
        for _ in {1..720}; do
            set +e
            invocation=$(aws ssm get-command-invocation \
                --region "${region}" \
                --command-id "${command_id}" \
                --instance-id "${instance_id}" \
                --output json 2>/dev/null)
            invocation_status=$?
            set -e
            if ((invocation_status != 0)); then
                sleep 5
                continue
            fi
            command_status=$(jq -r '.Status' <<< "${invocation}")
            case "${command_status}" in
                Success)
                    switch_staged=true
                    jq -r '.StandardOutputContent' <<< "${invocation}"
                    break
                    ;;
                Pending|InProgress|Delayed) sleep 5 ;;
                *)
                    jq -r '.StandardOutputContent, .StandardErrorContent' <<< "${invocation}" >&2
                    echo "SSM bootc switch failed with status ${command_status}" >&2
                    exit 1
                    ;;
            esac
        done
        [[ ${switch_staged} == true ]] || { echo "SSM bootc switch did not complete within the polling window" >&2; exit 1; }
        switch_staged_at=$(date +%s)
        sleep "${ssm_reboot_wait_seconds}"
    fi

    ssm_commands=$(jq -cn \
        --arg lifecycle "${ami_lifecycle}" \
        --arg role "${ami_role}" \
        --arg expected_bootc_image_ref "${expected_bootc_image_ref}" \
        --arg switch_target_ref "${switch_target_ref}" \
        '{commands:[
            "set -eu",
            "test \"$(uname -m)\" = x86_64",
            "test \"$(getenforce)\" = Enforcing",
            "systemctl is-active --quiet amazon-ssm-agent.service",
            "systemctl is-active --quiet docker.service",
            "bootc status",
            "docker info >/dev/null",
            "imds_code=$(curl --silent --output /dev/null --write-out %{http_code} --max-time 3 http://169.254.169.254/latest/meta-data/ || true); test \"${imds_code}\" = 401"
        ]} |
        if $switch_target_ref != "" then
            .commands += [
                ("test \"$(bootc status --format=json --format-version=1 --booted | jq -r .status.booted.image.image.image)\" = \"" + $switch_target_ref + "\""),
                "echo LUCIDITY_SWITCH_TARGET_BOOTED",
                "systemctl is-active --quiet lucidity-bootc-ecr-auth.service",
                "test \"$(jq -r '.credHelpers[]' /run/ostree/auth.json)\" = ecr-login",
                "test -s /var/lib/lucidity-update-rollback/source-image-ref",
                "volume_path=$(docker volume inspect lucidity-update-rollback | jq -r \u0027.[0].Mountpoint\u0027); test \"$(cat \"${volume_path}/marker\")\" = lucidity-update-rollback-marker",
                "bootc upgrade --check"
            ]
        elif $lifecycle == "retained" then
            .commands += [
                ("test \"$(bootc status --format=json --format-version=1 --booted | jq -r .status.booted.image.image.image)\" = \"" + $expected_bootc_image_ref + "\""),
                "systemctl is-active --quiet lucidity-nix-profile.service",
                "systemctl is-active --quiet lucidity-bootc-ecr-auth.service",
                "jq -e \u0027type == \u0022object\u0022 and length == 0\u0027 /run/ostree/auth.json >/dev/null",
                "grep -Fxq \u0027credential-helpers = [\u0022ecr-login\u0022]\u0027 /etc/containers/registries.conf.d/50-lucidity-ecr.conf",
                "test -x /nix/var/nix/profiles/lucidity/bin/docker-credential-ecr-login",
                "bootc upgrade --check"
            ]
        else . end |
        if $role == "controller" then
            .commands += [
                "if systemctl is-failed --quiet coolify-controller-bootstrap.service; then echo LUCIDITY_CONTROLLER_BOOTSTRAP_FAILED; systemctl --no-pager --full status coolify-controller-bootstrap.service; exit 1; fi",
                "systemctl is-active --quiet coolify-controller-storage.service",
                "systemctl is-active --quiet coolify-controller-bootstrap.service",
                "mountpoint --quiet /data/coolify",
                "test -e /data/coolify/.controller-bootstrap-complete",
                "test -s /data/coolify/source/.env"
            ]
        else . end')
    command_succeeded=false
    validation_attempts=1
    if [[ -n ${switch_target_ref} || ${ami_lifecycle} == retained || ${ami_role} == controller ]]; then
        validation_attempts=90
    fi
    for ((validation_attempt = 1; validation_attempt <= validation_attempts; validation_attempt++)); do
        command_response=$(aws ssm send-command \
            --region "${region}" \
            --document-name AWS-RunShellScript \
            --instance-ids "${instance_id}" \
            --comment "lucidity bootc AMI validation ${run_id}" \
            --parameters "${ssm_commands}" \
            --output json 2>/dev/null || true)
        if [[ -n ${command_response} ]]; then
            command_id=$(jq -r '.Command.CommandId // empty' <<< "${command_response}")
        else
            command_id=""
        fi
        if [[ -z ${command_id} ]]; then
            if [[ -z ${switch_target_ref} && ${ami_role} != controller ]]; then
                echo "SSM did not return a command ID" >&2
                exit 1
            fi
            sleep 10
            continue
        fi

        command_finished=false
        for _ in {1..60}; do
            set +e
            invocation=$(aws ssm get-command-invocation \
                --region "${region}" \
                --command-id "${command_id}" \
                --instance-id "${instance_id}" \
                --output json 2>/dev/null)
            invocation_status=$?
            set -e
            if ((invocation_status != 0)); then
                sleep 5
                continue
            fi
            command_status=$(jq -r '.Status' <<< "${invocation}")
            case "${command_status}" in
                Success)
                    command_succeeded=true
                    command_finished=true
                    jq -r '.StandardOutputContent' <<< "${invocation}"
                    break
                    ;;
                Pending|InProgress|Delayed) sleep 5 ;;
                *)
                    command_finished=true
                    command_output=$(jq -r '.StandardOutputContent' <<< "${invocation}")
                    if grep -Eq 'LUCIDITY_SWITCH_TARGET_BOOTED|LUCIDITY_CONTROLLER_BOOTSTRAP_FAILED' <<< "${command_output}"; then
                        jq -r '.StandardOutputContent, .StandardErrorContent' <<< "${invocation}" >&2
                        echo "SSM guest validation failed with status ${command_status}" >&2
                        exit 1
                    fi
                    if ((validation_attempt == validation_attempts)); then
                        jq -r '.StandardOutputContent, .StandardErrorContent' <<< "${invocation}" >&2
                    fi
                    break
                    ;;
            esac
        done
        [[ ${command_succeeded} == true ]] && break
        [[ ${command_finished} == true || -n ${switch_target_ref} ]] || break
        sleep 10
    done
    [[ ${command_succeeded} == true ]] || { echo "SSM guest validation did not complete within the polling window" >&2; exit 1; }
    if [[ -n ${switch_target_ref} ]]; then
        switch_validated_at=$(date +%s)
        rollback_started_at=${switch_validated_at}
        rollback_commands=$(jq -cn '{commands:[
            "set -eu",
            "bootc rollback",
            "systemd-run --unit=lucidity-bootc-rollback-validation-reboot --on-active=10s /usr/bin/systemctl reboot"
        ]}')
        command_response=$(aws ssm send-command \
            --region "${region}" \
            --document-name AWS-RunShellScript \
            --instance-ids "${instance_id}" \
            --comment "lucidity bootc rollback validation ${run_id}" \
            --parameters "${rollback_commands}" \
            --timeout-seconds 600 \
            --output json)
        command_id=$(jq -r '.Command.CommandId // empty' <<< "${command_response}")
        [[ -n ${command_id} ]] || { echo "SSM did not return a bootc rollback command ID" >&2; exit 1; }

        rollback_staged=false
        for _ in {1..120}; do
            set +e
            invocation=$(aws ssm get-command-invocation \
                --region "${region}" \
                --command-id "${command_id}" \
                --instance-id "${instance_id}" \
                --output json 2>/dev/null)
            invocation_status=$?
            set -e
            if ((invocation_status != 0)); then
                sleep 5
                continue
            fi
            command_status=$(jq -r '.Status' <<< "${invocation}")
            case "${command_status}" in
                Success)
                    rollback_staged=true
                    jq -r '.StandardOutputContent' <<< "${invocation}"
                    break
                    ;;
                Pending|InProgress|Delayed) sleep 5 ;;
                *)
                    jq -r '.StandardOutputContent, .StandardErrorContent' <<< "${invocation}" >&2
                    echo "SSM bootc rollback failed with status ${command_status}" >&2
                    exit 1
                    ;;
            esac
        done
        [[ ${rollback_staged} == true ]] || { echo "SSM bootc rollback did not complete within the polling window" >&2; exit 1; }
        rollback_staged_at=$(date +%s)
        sleep "${ssm_reboot_wait_seconds}"

        rollback_validation_commands=$(jq -cn '{commands:[
            "set -eu",
            "test \"$(uname -m)\" = x86_64",
            "test \"$(getenforce)\" = Enforcing",
            "systemctl is-active --quiet amazon-ssm-agent.service",
            "systemctl is-active --quiet docker.service",
            "source_image=$(cat /var/lib/lucidity-update-rollback/source-image-ref); test -n \"${source_image}\"; test \"${source_image}\" != null; test \"$(bootc status --format=json --format-version=1 --booted | jq -r .status.booted.image.image.image)\" = \"${source_image}\"",
            "volume_path=$(docker volume inspect lucidity-update-rollback | jq -r \u0027.[0].Mountpoint\u0027); test \"$(cat \"${volume_path}/marker\")\" = lucidity-update-rollback-marker",
            "echo LUCIDITY_ROLLBACK_SOURCE_BOOTED"
        ]}')
        rollback_validated=false
        for _ in {1..90}; do
            command_response=$(aws ssm send-command \
                --region "${region}" \
                --document-name AWS-RunShellScript \
                --instance-ids "${instance_id}" \
                --comment "lucidity bootc rollback guest validation ${run_id}" \
                --parameters "${rollback_validation_commands}" \
                --output json 2>/dev/null || true)
            if [[ -n ${command_response} ]]; then
                command_id=$(jq -r '.Command.CommandId // empty' <<< "${command_response}")
            else
                command_id=""
            fi
            if [[ -z ${command_id} ]]; then
                sleep 10
                continue
            fi

            command_finished=false
            for _ in {1..60}; do
                set +e
                invocation=$(aws ssm get-command-invocation \
                    --region "${region}" \
                    --command-id "${command_id}" \
                    --instance-id "${instance_id}" \
                    --output json 2>/dev/null)
                invocation_status=$?
                set -e
                if ((invocation_status != 0)); then
                    sleep 5
                    continue
                fi
                command_status=$(jq -r '.Status' <<< "${invocation}")
                case "${command_status}" in
                    Success)
                        rollback_validated=true
                        command_finished=true
                        jq -r '.StandardOutputContent' <<< "${invocation}"
                        break
                        ;;
                    Pending|InProgress|Delayed) sleep 5 ;;
                    *)
                        command_finished=true
                        command_output=$(jq -r '.StandardOutputContent' <<< "${invocation}")
                        if grep -Fq LUCIDITY_ROLLBACK_SOURCE_BOOTED <<< "${command_output}"; then
                            jq -r '.StandardOutputContent, .StandardErrorContent' <<< "${invocation}" >&2
                            echo "SSM rollback guest validation failed with status ${command_status}" >&2
                            exit 1
                        fi
                        break
                        ;;
                esac
            done
            [[ ${rollback_validated} == true ]] && break
            [[ ${command_finished} == true ]] || break
            sleep 10
        done
        [[ ${rollback_validated} == true ]] || { echo "SSM rollback guest validation did not complete within the polling window" >&2; exit 1; }

        rollback_validated_at=$(date +%s)
        switch_stage_seconds=$((switch_staged_at - switch_started_at))
        switch_reboot_validation_seconds=$((switch_validated_at - switch_staged_at))
        switch_total_seconds=$((switch_validated_at - switch_started_at))
        rollback_stage_seconds=$((rollback_staged_at - rollback_started_at))
        rollback_reboot_validation_seconds=$((rollback_validated_at - rollback_staged_at))
        lifecycle_total_seconds=$((rollback_validated_at - switch_started_at))
        echo "Bootc switch and rollback validation: switch=${switch_total_seconds}s rollback-stage=${rollback_stage_seconds}s rollback-reboot-and-validation=${rollback_reboot_validation_seconds}s total=${lifecycle_total_seconds}s"
        if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
            {
                echo "## Disposable bootc switch and rollback validation"
                echo
                echo "- Target: \`${switch_target_ref}\`"
                echo "- Switch pull and stage: ${switch_stage_seconds}s"
                echo "- Reboot and guest validation: ${switch_reboot_validation_seconds}s"
                echo "- Switch through validated target: ${switch_total_seconds}s"
                echo "- Rollback stage: ${rollback_stage_seconds}s"
                echo "- Rollback reboot and source validation: ${rollback_reboot_validation_seconds}s"
                echo "- Complete switch and rollback lifecycle: ${lifecycle_total_seconds}s"
                echo "- Docker volume marker: preserved through both reboots"
                echo "- Benchmark AMI, snapshot, and T3a instance: disposable and removed during cleanup"
            } >> "${GITHUB_STEP_SUMMARY}"
        fi
    fi
    echo "SSM validated the disposable bootc guest ${instance_id}; cleanup will terminate it"
fi

if [[ ${ami_lifecycle} == retained ]]; then
    aws ec2 create-tags \
        --region "${region}" \
        --resources "${image_id}" "${snapshot_ids[0]}" \
        --tags \
            "Key=Project,Value=lucidity" \
            "Key=Purpose,Value=ami-release" \
            "Key=Role,Value=${ami_role}" \
            "Key=SourceRevision,Value=${source_revision}" \
            "Key=ReleaseStatus,Value=validated" \
            "${resource_release_tags[@]}"
fi

completed_successfully=true
if [[ ${ami_lifecycle} == retained ]]; then
    echo "AWS registered and boot-validated retained ${ami_role} AMI ${image_id} from snapshot ${snapshot_ids[0]}"
else
    echo "AWS registered the AMD64 bootc snapshot as ${image_id}; cleanup will now remove all disposable validation resources"
fi
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    {
        echo "ami_id=${image_id}"
        echo "snapshot_id=${snapshot_ids[0]}"
    } >> "${GITHUB_OUTPUT}"
fi
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        if [[ ${ami_lifecycle} == retained ]]; then
            echo "## Retained AMI release"
        else
            echo "## AMI snapshot validation"
        fi
        echo
        echo "AWS uploaded the AMD64 raw bootc disk using EBS Direct, verified the encrypted EBS snapshot, and registered it as an AMI."
        echo
        echo "- Snapshot transport: \`ebs-direct\`"
        if [[ ${ami_lifecycle} == retained ]]; then
            echo "- Role: \`${ami_role}\`"
            echo "- Source revision: \`${source_revision}\`"
            if [[ ${release_metadata} == true ]]; then
                echo "- Release: \`${release_version}\`"
                echo "- Source image digest: \`${source_image_digest}\`"
                echo "- SPDX SBOM SHA-256: \`${sbom_sha256}\`"
            fi
            echo "- Snapshot: \`${snapshot_ids[0]}\` (retained and encrypted)"
            echo "- AMI: \`${image_id}\` (retained; select this ID explicitly in OpenTofu)"
        else
            echo "- Snapshot: \`${snapshot_ids[0]}\` (disposable; removed during cleanup)"
            echo "- AMI: \`${image_id}\` (disposable; removed during cleanup)"
        fi
        if [[ -n ${instance_id} ]]; then
            echo "- T3a instance: \`${instance_id}\` (disposable; terminated during cleanup)"
        fi
        echo "- Region: \`${region}\`"
    } >> "${GITHUB_STEP_SUMMARY}"
fi
