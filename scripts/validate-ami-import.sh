#!/usr/bin/env bash
set -Eeuo pipefail

artifact=${1:-}
region=${AWS_REGION:-}
bucket=${AMI_IMPORT_BUCKET:-}
vmimport_role=${VMIMPORT_ROLE_NAME:-}
poll_attempts=${AMI_IMPORT_POLL_ATTEMPTS:-180}
poll_interval=${AMI_IMPORT_POLL_INTERVAL:-30}
run_id=${GITHUB_RUN_ID:-manual-$(date +%s)}
launch_validation=${AMI_LAUNCH_VALIDATION:-false}
launch_instance_type=${AMI_TEST_INSTANCE_TYPE:-t3a.small}
launch_subnet=${AMI_TEST_SUBNET_ID:-}
launch_security_group=${AMI_TEST_SECURITY_GROUP_ID:-}
launch_instance_profile=${AMI_TEST_INSTANCE_PROFILE_NAME:-}

[[ -n ${artifact} ]] || { echo "usage: validate-ami-import.sh ARTIFACT" >&2; exit 2; }
[[ -f ${artifact} ]] || { echo "AMI artifact not found: ${artifact}" >&2; exit 1; }
[[ ${artifact} == *.ami || ${artifact} == *.raw ]] || { echo "AMI validation requires a raw .ami or .raw artifact" >&2; exit 2; }
[[ -n ${region} ]] || { echo "AWS_REGION is required" >&2; exit 2; }
[[ -n ${bucket} ]] || { echo "AMI_IMPORT_BUCKET is required" >&2; exit 2; }
[[ -n ${vmimport_role} ]] || { echo "VMIMPORT_ROLE_NAME is required" >&2; exit 2; }
[[ ${poll_attempts} =~ ^[1-9][0-9]*$ ]] || { echo "AMI_IMPORT_POLL_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${poll_interval} =~ ^[1-9][0-9]*$ ]] || { echo "AMI_IMPORT_POLL_INTERVAL must be a positive integer" >&2; exit 2; }
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

artifact=$(realpath "${artifact}")
object_key="validation/${run_id}/$(basename "${artifact}")"
import_task_id=""
image_id=""
instance_id=""
snapshot_ids=()

cleanup() {
    local original_status=$?
    local cleanup_status=0
    local cleanup_task status
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

    if [[ -n ${import_task_id} ]]; then
        cleanup_task=$(aws ec2 describe-import-snapshot-tasks \
            --region "${region}" \
            --import-task-ids "${import_task_id}" \
            --output json 2>/dev/null)
        status=$(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Status // empty' <<< "${cleanup_task}")
        if (( ${#snapshot_ids[@]} == 0 )); then
            mapfile -t snapshot_ids < <(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId // empty' <<< "${cleanup_task}")
        fi
        if [[ ${status} == active ]]; then
            aws ec2 cancel-import-task \
                --region "${region}" \
                --import-task-id "${import_task_id}" >/dev/null || cleanup_status=1
        fi
    fi

    if [[ -n ${image_id} ]]; then
        aws ec2 deregister-image \
            --region "${region}" \
            --image-id "${image_id}" >/dev/null || cleanup_status=1
    fi

    for snapshot_id in "${snapshot_ids[@]}"; do
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
        [[ ${deleted} == true ]] || { echo "failed to delete validation snapshot ${snapshot_id}" >&2; cleanup_status=1; }
    done

    aws s3 rm "s3://${bucket}/${object_key}" \
        --region "${region}" \
        --only-show-errors >/dev/null || cleanup_status=1

    if ((original_status != 0)); then
        exit "${original_status}"
    fi
    exit "${cleanup_status}"
}
trap cleanup EXIT

echo "Uploading disposable AMI artifact to s3://${bucket}/${object_key}"
aws s3 cp "${artifact}" "s3://${bucket}/${object_key}" \
    --region "${region}" \
    --only-show-errors

disk_container=$(jq -cn \
    --arg bucket "${bucket}" \
    --arg key "${object_key}" \
    '{Description:"lucidity AMD64 bootc disk",Format:"RAW",UserBucket:{S3Bucket:$bucket,S3Key:$key}}')

import_response=$(aws ec2 import-snapshot \
    --region "${region}" \
    --role-name "${vmimport_role}" \
    --encrypted \
    --description "lucidity AMD64 bootc snapshot validation ${run_id}" \
    --disk-container "${disk_container}" \
    --output json)
import_task_id=$(jq -r '.ImportTaskId' <<< "${import_response}")
[[ -n ${import_task_id} && ${import_task_id} != null ]] || { echo "EC2 did not return an import task ID" >&2; exit 1; }
echo "Started ${import_task_id}"

task_response=""
for ((attempt = 1; attempt <= poll_attempts; attempt++)); do
    task_response=$(aws ec2 describe-import-snapshot-tasks \
        --region "${region}" \
        --import-task-ids "${import_task_id}" \
        --output json)
    status=$(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Status' <<< "${task_response}")
    status_message=$(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.StatusMessage // ""' <<< "${task_response}")
    progress=$(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Progress // "0"' <<< "${task_response}")
    echo "${import_task_id}: ${status} ${progress}% ${status_message}"

    case "${status}" in
        completed) break ;;
        active) sleep "${poll_interval}" ;;
        *) echo "snapshot import failed with status ${status}: ${status_message}" >&2; exit 1 ;;
    esac
done

status=$(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.Status' <<< "${task_response}")
[[ ${status} == completed ]] || { echo "snapshot import did not complete within the polling window" >&2; exit 1; }

mapfile -t snapshot_ids < <(jq -r '.ImportSnapshotTasks[0].SnapshotTaskDetail.SnapshotId // empty' <<< "${task_response}")
(( ${#snapshot_ids[@]} > 0 )) || { echo "completed import did not return a snapshot ID" >&2; exit 1; }

snapshot=$(aws ec2 describe-snapshots \
    --region "${region}" \
    --snapshot-ids "${snapshot_ids[0]}" \
    --output json)
[[ $(jq -r '.Snapshots[0].Encrypted' <<< "${snapshot}") == true ]] || { echo "imported snapshot is not encrypted" >&2; exit 1; }

if [[ ${launch_validation} == true ]]; then
    aws ec2 create-tags \
        --region "${region}" \
        --resources "${snapshot_ids[0]}" \
        --tags \
            "Key=Name,Value=lucidity-ami-validation-${run_id}" \
            "Key=Project,Value=lucidity" \
            "Key=Purpose,Value=ami-validation" \
            "Key=GitHubRunId,Value=${run_id}"
fi

block_device_mappings=$(jq -cn \
    --arg snapshot_id "${snapshot_ids[0]}" \
    '[{DeviceName:"/dev/xvda",Ebs:{SnapshotId:$snapshot_id,DeleteOnTermination:true,VolumeType:"gp3"}}]')
image_name="lucidity-ami-validation-${run_id}"
register_tag_arguments=()
if [[ ${launch_validation} == true ]]; then
    register_tag_arguments=(
        --tag-specifications
        "ResourceType=image,Tags=[{Key=Name,Value=${image_name}},{Key=Project,Value=lucidity},{Key=Purpose,Value=ami-validation},{Key=GitHubRunId,Value=${run_id}}]"
    )
fi
register_response=$(aws ec2 register-image \
    --region "${region}" \
    --name "${image_name}" \
    --description "Disposable lucidity AMD64 bootc AMI validation ${run_id}" \
    --architecture x86_64 \
    --virtualization-type hvm \
    --root-device-name /dev/xvda \
    --block-device-mappings "${block_device_mappings}" \
    --boot-mode uefi \
    --ena-support \
    --imds-support v2.0 \
    "${register_tag_arguments[@]}" \
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
[[ $(jq -r '.Images[0].State' <<< "${image}") == available ]] || { echo "imported AMI is not available" >&2; exit 1; }
[[ $(jq -r '.Images[0].Architecture' <<< "${image}") == x86_64 ]] || { echo "imported AMI is not x86_64" >&2; exit 1; }
[[ $(jq -r '.Images[0].RootDeviceType' <<< "${image}") == ebs ]] || { echo "imported AMI is not EBS-backed" >&2; exit 1; }
[[ $(jq -r '.Images[0].BootMode' <<< "${image}") == uefi ]] || { echo "imported AMI is not UEFI-only" >&2; exit 1; }
[[ $(jq -r '.Images[0].EnaSupport' <<< "${image}") == true ]] || { echo "imported AMI does not enable ENA" >&2; exit 1; }
[[ $(jq -r '.Images[0].ImdsSupport' <<< "${image}") == v2.0 ]] || { echo "imported AMI does not require IMDSv2" >&2; exit 1; }
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
    launch_block_devices=$(jq -cn '[{
        DeviceName:"/dev/xvda",
        Ebs:{DeleteOnTermination:true,Encrypted:true,VolumeSize:10,VolumeType:"gp3"}
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

    ssm_commands=$(jq -cn '{commands:[
        "set -eu",
        "test \"$(uname -m)\" = x86_64",
        "test \"$(getenforce)\" = Enforcing",
        "systemctl is-active --quiet amazon-ssm-agent.service",
        "systemctl is-active --quiet docker.service",
        "bootc status",
        "docker info >/dev/null",
        "imds_code=$(curl --silent --output /dev/null --write-out %{http_code} --max-time 3 http://169.254.169.254/latest/meta-data/ || true); test \"${imds_code}\" = 401"
    ]}')
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

echo "AWS registered the AMD64 bootc snapshot as ${image_id}; cleanup will now remove the AMI, snapshot, and S3 object"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo "## AMI import validation"
        echo
        echo "AWS imported the AMD64 raw bootc disk as an encrypted EBS snapshot and registered it as an AMI."
        echo
        echo "- Import task: \`${import_task_id}\`"
        echo "- AMI: \`${image_id}\` (disposable; removed during cleanup)"
        if [[ -n ${instance_id} ]]; then
            echo "- T3a instance: \`${instance_id}\` (disposable; terminated during cleanup)"
        fi
        echo "- Region: \`${region}\`"
    } >> "${GITHUB_STEP_SUMMARY}"
fi
