#!/usr/bin/env bash
set -Eeuo pipefail

aws_cli=${AWS_CLI:-aws}
region=${AWS_REGION:-us-east-2}
max_age_hours=${AMI_VALIDATION_MAX_AGE_HOURS:-12}
audit_now=${AUDIT_NOW:-$(date --utc +%Y-%m-%dT%H:%M:%SZ)}

[[ ${max_age_hours} =~ ^[1-9][0-9]*$ ]] || {
    echo "AMI_VALIDATION_MAX_AGE_HOURS must be a positive whole number" >&2
    exit 2
}
command -v "${aws_cli}" >/dev/null 2>&1 || { echo "${aws_cli} is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

now_epoch=$(date --utc --date="${audit_now}" +%s)
cutoff_epoch=$((now_epoch - max_age_hours * 3600))
cutoff=$(date --utc --date="@${cutoff_epoch}" +%Y-%m-%dT%H:%M:%SZ)

instances=$("${aws_cli}" ec2 describe-instances \
    --region "${region}" \
    --filters \
        'Name=tag:Project,Values=lucidity' \
        'Name=tag:Purpose,Values=ami-validation' \
        'Name=instance-state-name,Values=pending,running,stopping,stopped' \
    --output json)
images=$("${aws_cli}" ec2 describe-images \
    --region "${region}" \
    --owners self \
    --filters \
        'Name=tag:Project,Values=lucidity' \
        'Name=tag:Purpose,Values=ami-validation' \
    --output json)
snapshots=$("${aws_cli}" ec2 describe-snapshots \
    --region "${region}" \
    --owner-ids self \
    --filters \
        'Name=tag:Project,Values=lucidity' \
        'Name=tag:Purpose,Values=ami-validation' \
    --output json)

stale_instances=$(jq -c --arg cutoff "${cutoff}" '[
    .Reservations[].Instances[]
    | select(.LaunchTime < $cutoff)
    | {id:.InstanceId,created_at:.LaunchTime,state:.State.Name,run_id:([.Tags[]? | select(.Key == "GitHubRunId") | .Value][0] // "unknown")}
]' <<< "${instances}")
stale_images=$(jq -c --arg cutoff "${cutoff}" '[
    .Images[]
    | select(.CreationDate < $cutoff)
    | {id:.ImageId,created_at:.CreationDate,state:.State,run_id:([.Tags[]? | select(.Key == "GitHubRunId") | .Value][0] // "unknown")}
]' <<< "${images}")
stale_snapshots=$(jq -c --arg cutoff "${cutoff}" '[
    .Snapshots[]
    | select(.StartTime < $cutoff)
    | {id:.SnapshotId,created_at:.StartTime,state:.State,run_id:([.Tags[]? | select(.Key == "GitHubRunId") | .Value][0] // "unknown")}
]' <<< "${snapshots}")

stale_count=$(jq -n \
    --argjson instances "${stale_instances}" \
    --argjson images "${stale_images}" \
    --argjson snapshots "${stale_snapshots}" \
    '[$instances, $images, $snapshots] | map(length) | add')

if ((stale_count > 0)); then
    echo "Disposable AMI validation resources older than ${max_age_hours} hours were found:" >&2
    jq -n \
        --arg cutoff "${cutoff}" \
        --argjson instances "${stale_instances}" \
        --argjson images "${stale_images}" \
        --argjson snapshots "${stale_snapshots}" \
        '{cutoff:$cutoff,instances:$instances,images:$images,snapshots:$snapshots}' >&2
    echo "Review the recorded GitHub run before manually removing any resource." >&2
    exit 1
fi

echo "No disposable AMI validation resources older than ${max_age_hours} hours were found in ${region}."
