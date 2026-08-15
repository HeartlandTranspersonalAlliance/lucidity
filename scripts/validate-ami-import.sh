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
if [[ ${ami_lifecycle} == retained ]]; then
    [[ ${launch_validation} == true ]] || { echo "retained AMIs require the disposable EC2 launch gate" >&2; exit 2; }
    [[ ${source_revision} =~ ^[0-9a-f]{40}$ ]] || { echo "AMI_SOURCE_REVISION must be a full lowercase Git commit SHA for retained AMIs" >&2; exit 2; }
    [[ ${expected_bootc_image_ref} =~ ^[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/[a-z0-9]+([._/-][a-z0-9]+)*:sha-${source_revision}$ ]] || {
        echo "AMI_EXPECTED_BOOTC_IMAGE_REF must be the retained commit's fully qualified private ECR reference" >&2
        exit 2
    }
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
image_id=""
instance_id=""
snapshot_ids=()
completed_successfully=false

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
        "Key=ReleaseStatus,Value=${release_status}"

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
    '[
        {Key:"Name",Value:$name},
        {Key:"Project",Value:$project},
        {Key:"Purpose",Value:$purpose},
        {Key:"Role",Value:$role},
        {Key:"GitHubRunId",Value:$run_id},
        {Key:"SourceRevision",Value:$source_revision},
        {Key:"ReleaseStatus",Value:$release_status}
    ]')
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
    aws ec2 wait instance-status-ok --region "${region}" --instance-ids "${instance_id}"

    ssm_online=false
    for _ in {1..90}; do
        ping_status=$(aws ssm describe-instance-information \
            --region "${region}" \
            --filters "Key=InstanceIds,Values=${instance_id}" \
            --query 'InstanceInformationList[0].PingStatus' \
            --output text)
        if [[ ${ping_status} == Online ]]; then
            ssm_online=true
            break
        fi
        sleep 10
    done
    [[ ${ssm_online} == true ]] || { echo "validation instance did not become available through SSM" >&2; exit 1; }

    ssm_commands=$(jq -cn \
        --arg lifecycle "${ami_lifecycle}" \
        --arg expected_bootc_image_ref "${expected_bootc_image_ref}" \
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
        if $lifecycle == "retained" then
            .commands += [
                ("test \"$(bootc status --format=json --format-version=1 --booted | jq -r .status.booted.image.image.image)\" = \"" + $expected_bootc_image_ref + "\""),
                "systemctl is-active --quiet coolify-bootc-ecr-auth.service",
                "test \"$(jq -r '.credHelpers[]' /run/ostree/auth.json)\" = ecr-login",
                "bootc upgrade --check"
            ]
        else . end')
    command_response=$(aws ssm send-command \
        --region "${region}" \
        --document-name AWS-RunShellScript \
        --instance-ids "${instance_id}" \
        --comment "lucidity bootc AMI validation ${run_id}" \
        --parameters "${ssm_commands}" \
        --output json)
    command_id=$(jq -r '.Command.CommandId // empty' <<< "${command_response}")
    [[ -n ${command_id} ]] || { echo "SSM did not return a command ID" >&2; exit 1; }

    command_succeeded=false
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
                jq -r '.StandardOutputContent' <<< "${invocation}"
                break
                ;;
            Pending|InProgress|Delayed) sleep 5 ;;
            *)
                jq -r '.StandardOutputContent, .StandardErrorContent' <<< "${invocation}" >&2
                echo "SSM guest validation failed with status ${command_status}" >&2
                exit 1
                ;;
        esac
    done
    [[ ${command_succeeded} == true ]] || { echo "SSM guest validation did not complete within the polling window" >&2; exit 1; }
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
            "Key=ReleaseStatus,Value=validated"
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
