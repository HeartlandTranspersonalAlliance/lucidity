#!/usr/bin/env bash
set -Eeuo pipefail

artifact=${1:-}
region=${AWS_REGION:-}
bucket=${AMI_IMPORT_BUCKET:-}
vmimport_role=${VMIMPORT_ROLE_NAME:-}
poll_attempts=${AMI_IMPORT_POLL_ATTEMPTS:-180}
poll_interval=${AMI_IMPORT_POLL_INTERVAL:-30}
run_id=${GITHUB_RUN_ID:-manual-$(date +%s)}

[[ -n ${artifact} ]] || { echo "usage: validate-ami-import.sh ARTIFACT" >&2; exit 2; }
[[ -f ${artifact} ]] || { echo "AMI artifact not found: ${artifact}" >&2; exit 1; }
[[ ${artifact} == *.ami || ${artifact} == *.raw ]] || { echo "AMI validation requires a raw .ami or .raw artifact" >&2; exit 2; }
[[ -n ${region} ]] || { echo "AWS_REGION is required" >&2; exit 2; }
[[ -n ${bucket} ]] || { echo "AMI_IMPORT_BUCKET is required" >&2; exit 2; }
[[ -n ${vmimport_role} ]] || { echo "VMIMPORT_ROLE_NAME is required" >&2; exit 2; }
[[ ${poll_attempts} =~ ^[1-9][0-9]*$ ]] || { echo "AMI_IMPORT_POLL_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${poll_interval} =~ ^[1-9][0-9]*$ ]] || { echo "AMI_IMPORT_POLL_INTERVAL must be a positive integer" >&2; exit 2; }

for command in aws jq; do
    command -v "${command}" >/dev/null 2>&1 || { echo "${command} is required" >&2; exit 1; }
done

artifact=$(realpath "${artifact}")
object_key="validation/${run_id}/$(basename "${artifact}")"
import_task_id=""
image_id=""
snapshot_ids=()

cleanup() {
    local original_status=$?
    local cleanup_status=0
    local cleanup_task status
    trap - EXIT
    set +e

    if [[ -n ${import_task_id} ]]; then
        cleanup_task=$(aws ec2 describe-import-image-tasks \
            --region "${region}" \
            --import-task-ids "${import_task_id}" \
            --output json 2>/dev/null)
        status=$(jq -r '.ImportImageTasks[0].Status // empty' <<< "${cleanup_task}")
        if [[ -z ${image_id} ]]; then
            image_id=$(jq -r '.ImportImageTasks[0].ImageId // empty' <<< "${cleanup_task}")
        fi
        if (( ${#snapshot_ids[@]} == 0 )); then
            mapfile -t snapshot_ids < <(jq -r '.ImportImageTasks[0].SnapshotDetails[].SnapshotId // empty' <<< "${cleanup_task}")
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

disk_containers=$(jq -cn \
    --arg bucket "${bucket}" \
    --arg key "${object_key}" \
    '[{Description:"lucidity AMD64 bootc disk",Format:"RAW",UserBucket:{S3Bucket:$bucket,S3Key:$key}}]')

import_response=$(aws ec2 import-image \
    --region "${region}" \
    --architecture x86_64 \
    --platform Linux \
    --usage-operation RunInstances \
    --role-name "${vmimport_role}" \
    --boot-mode uefi \
    --description "lucidity AMD64 bootc AMI validation ${run_id}" \
    --disk-containers "${disk_containers}" \
    --output json)
import_task_id=$(jq -r '.ImportTaskId' <<< "${import_response}")
[[ -n ${import_task_id} && ${import_task_id} != null ]] || { echo "EC2 did not return an import task ID" >&2; exit 1; }
echo "Started ${import_task_id}"

task_response=""
for ((attempt = 1; attempt <= poll_attempts; attempt++)); do
    task_response=$(aws ec2 describe-import-image-tasks \
        --region "${region}" \
        --import-task-ids "${import_task_id}" \
        --output json)
    status=$(jq -r '.ImportImageTasks[0].Status' <<< "${task_response}")
    status_message=$(jq -r '.ImportImageTasks[0].StatusMessage // ""' <<< "${task_response}")
    progress=$(jq -r '.ImportImageTasks[0].Progress // "0"' <<< "${task_response}")
    echo "${import_task_id}: ${status} ${progress}% ${status_message}"

    case "${status}" in
        completed) break ;;
        active) sleep "${poll_interval}" ;;
        *) echo "AMI import failed with status ${status}: ${status_message}" >&2; exit 1 ;;
    esac
done

status=$(jq -r '.ImportImageTasks[0].Status' <<< "${task_response}")
[[ ${status} == completed ]] || { echo "AMI import did not complete within the polling window" >&2; exit 1; }

image_id=$(jq -r '.ImportImageTasks[0].ImageId' <<< "${task_response}")
mapfile -t snapshot_ids < <(jq -r '.ImportImageTasks[0].SnapshotDetails[].SnapshotId // empty' <<< "${task_response}")
[[ -n ${image_id} && ${image_id} != null ]] || { echo "completed import did not return an AMI ID" >&2; exit 1; }
(( ${#snapshot_ids[@]} > 0 )) || { echo "completed import did not return a snapshot ID" >&2; exit 1; }

image=$(aws ec2 describe-images \
    --region "${region}" \
    --image-ids "${image_id}" \
    --output json)
[[ $(jq -r '.Images[0].State' <<< "${image}") == available ]] || { echo "imported AMI is not available" >&2; exit 1; }
[[ $(jq -r '.Images[0].Architecture' <<< "${image}") == x86_64 ]] || { echo "imported AMI is not x86_64" >&2; exit 1; }
[[ $(jq -r '.Images[0].RootDeviceType' <<< "${image}") == ebs ]] || { echo "imported AMI is not EBS-backed" >&2; exit 1; }

echo "AWS accepted the AMD64 bootc artifact as ${image_id}; cleanup will now remove the AMI, snapshots, and S3 object"
if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo "## AMI import validation"
        echo
        echo "AWS VM Import/Export accepted the AMD64 raw bootc artifact."
        echo
        echo "- Import task: \`${import_task_id}\`"
        echo "- AMI: \`${image_id}\` (disposable; removed during cleanup)"
        echo "- Region: \`${region}\`"
    } >> "${GITHUB_STEP_SUMMARY}"
fi
