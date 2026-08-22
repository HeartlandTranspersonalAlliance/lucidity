#!/usr/bin/env bash
set -Eeuo pipefail

aws_cli=${AWS_CLI:-aws}
region=${AWS_REGION:-us-east-2}
project=${LUCIDITY_AUDIT_PROJECT:-lucidity}
environment=${LUCIDITY_AUDIT_ENVIRONMENT:-production}
format=markdown
output=-

usage() {
    cat <<'EOF'
Usage: audit-production-readiness.sh [--json|--markdown] [--output PATH]

Inventory Lucidity production AWS metadata without changing resources or
reading secret values.
EOF
}

while (($# > 0)); do
    case "$1" in
        --json) format=json ;;
        --markdown) format=markdown ;;
        --output)
            shift
            [[ $# -gt 0 ]] || { echo "--output requires PATH" >&2; exit 2; }
            output=$1
            ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ ${project} =~ ^[a-z0-9][a-z0-9-]{1,31}$ ]] || { echo "LUCIDITY_AUDIT_PROJECT is invalid" >&2; exit 2; }
[[ ${environment} =~ ^[a-z0-9][a-z0-9-]{1,31}$ ]] || { echo "LUCIDITY_AUDIT_ENVIRONMENT is invalid" >&2; exit 2; }
command -v "${aws_cli}" >/dev/null 2>&1 || { echo "${aws_cli} is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

audit_dir=$(mktemp -d)
trap 'rm -rf "${audit_dir}"' EXIT
checks_file=${audit_dir}/checks.jsonl
: >"${checks_file}"

aws_call() {
    local destination=$1
    shift
    if "${aws_cli}" "$@" --output json >"${destination}" 2>"${destination}.err"; then
        return 0
    fi
    printf '{}\n' >"${destination}"
    return 1
}

record() {
    jq -nc --arg id "$1" --arg state "$2" --arg expected "$3" --argjson observed "$4" \
        '{id:$id,state:$state,expected:$expected,observed:$observed}' >>"${checks_file}"
}

unavailable() {
    record "$1" unavailable "$2" '{"reason":"AWS API unavailable or access denied"}'
}

state_for() {
    [[ $1 == true ]] && printf 'configured\n' || printf 'not_configured\n'
}

api_check() {
    local id=$1 expected=$2 filter=$3
    shift 3
    local file=${audit_dir}/${id//./-}.json result ok
    if aws_call "${file}" "$@"; then
        result=$(jq -c "${filter}" "${file}")
        ok=$(jq -r '.ok' <<<"${result}")
        record "${id}" "$(state_for "${ok}")" "${expected}" "$(jq -c '.observed' <<<"${result}")"
    else
        unavailable "${id}" "${expected}"
    fi
}

identity_file=${audit_dir}/identity.json
account_id=
identity_type=unknown
if aws_call "${identity_file}" sts get-caller-identity; then
    account_id=$(jq -r '.Account // empty' "${identity_file}")
    arn=$(jq -r '.Arn // ""' "${identity_file}")
    case "${arn}" in
        *:assumed-role/*) identity_type=assumed_role ;;
        *:role/*) identity_type=role ;;
        *:user/*) identity_type=iam_user ;;
    esac
    record identity.aws configured 'authenticated AWS identity' "$(jq -nc --arg type "${identity_type}" '{type:$type}')"
else
    unavailable identity.aws 'authenticated AWS identity'
fi

instances_file=${audit_dir}/instances.json
instance_ids=()
if aws_call "${instances_file}" ec2 describe-instances --region "${region}" --filters \
    "Name=tag:Project,Values=${project}" "Name=tag:Environment,Values=${environment}" \
    'Name=instance-state-name,Values=pending,running,stopping,stopped'; then
    for role in controller worker; do
        observed=$(jq -c --arg role "${role}" '[.Reservations[].Instances[]? | select(any(.Tags[]?; .Key == "Role" and .Value == $role))] | {count:length,running:(map(select(.State.Name == "running")) | length)}' "${instances_file}")
        ok=$(jq -r '.count == 1 and .running == 1' <<<"${observed}")
        record "compute.${role}_singleton" "$(state_for "${ok}")" 'exactly one running instance' "${observed}"
    done
    mapfile -t instance_ids < <(jq -r '.Reservations[].Instances[]?.InstanceId' "${instances_file}")
else
    unavailable compute.controller_singleton 'exactly one running instance'
    unavailable compute.worker_singleton 'exactly one running instance'
fi

api_check storage.production_volumes 'two encrypted production volumes' \
    '{observed:{count:(.Volumes|length),encrypted:([.Volumes[]?|select(.Encrypted==true)]|length)}} | . + {ok:(.observed.count == 2 and .observed.encrypted == 2)}' \
    ec2 describe-volumes --region "${region}" --filters "Name=tag:Project,Values=${project}" "Name=tag:Environment,Values=${environment}"

# The dollar expressions below are jq variables, not shell variables.
# shellcheck disable=SC2016
api_check network.no_cidr_ssh 'zero CIDR or prefix-list ingress rules reaching TCP/22' \
    '{observed:{groups:(.SecurityGroups|length),cidr_ssh_rules:([.SecurityGroups[] as $g|$g.IpPermissions[]?|select(.IpProtocol=="-1" or (.IpProtocol=="tcp" and (.FromPort//0)<=22 and (.ToPort//65535)>=22))|select(((.IpRanges//[])|length)>0 or ((.Ipv6Ranges//[])|length)>0 or ((.PrefixListIds//[])|length)>0)|$g.GroupId]|unique|length),security_group_ssh_rules:([.SecurityGroups[] as $g|$g.IpPermissions[]?|select(.IpProtocol=="-1" or (.IpProtocol=="tcp" and (.FromPort//0)<=22 and (.ToPort//65535)>=22))|select(((.UserIdGroupPairs//[])|length)>0)|$g.GroupId]|unique|length)}} | . + {ok:(.observed.cidr_ssh_rules == 0)}' \
    ec2 describe-security-groups --region "${region}" --filters "Name=tag:Project,Values=${project}" "Name=tag:Environment,Values=${environment}"

api_check compute.launch_templates 'two role launch templates' \
    '{observed:{count:(.LaunchTemplates|length)}} | . + {ok:(.observed.count == 2)}' \
    ec2 describe-launch-templates --region "${region}" --filters "Name=tag:Project,Values=${project}" "Name=tag:Environment,Values=${environment}"

api_check images.retained_roles 'at least one retained controller and worker AMI' \
    '{observed:{count:(.Images|length),controller:([.Images[]?|select(any(.Tags[]?;.Key=="Role" and .Value=="controller"))]|length),worker:([.Images[]?|select(any(.Tags[]?;.Key=="Role" and .Value=="worker"))]|length)}} | . + {ok:(.observed.controller > 0 and .observed.worker > 0)}' \
    ec2 describe-images --region "${region}" --owners self --filters "Name=tag:Project,Values=${project}"

if ((${#instance_ids[@]} > 0)); then
    joined_ids=$(IFS=,; printf '%s' "${instance_ids[*]}")
    expected_instances=${#instance_ids[@]}
    api_check management.ssm 'every observed production instance online' \
        "{observed:{count:(.InstanceInformationList|length),online:([.InstanceInformationList[]?|select(.PingStatus==\"Online\")]|length)}} | . + {ok:(.observed.count == ${expected_instances} and .observed.online == ${expected_instances})}" \
        ssm describe-instance-information --region "${region}" --filters "Key=InstanceIds,Values=${joined_ids}"
else
    record management.ssm not_configured 'every observed production instance online' '{"count":0,"online":0}'
fi

api_check account.ebs_encryption_by_default enabled \
    '{observed:{enabled:(.EbsEncryptionByDefault==true)}} | . + {ok:.observed.enabled}' \
    ec2 get-ebs-encryption-by-default --region "${region}"

api_check account.ebs_default_kms_key 'customer-managed key' \
    '{observed:{key_id:(.KmsKeyId//"")}} | . + {ok:(.observed.key_id != "" and .observed.key_id != "alias/aws/ebs")}' \
    ec2 get-ebs-default-kms-key-id --region "${region}"

api_check account.snapshot_public_access block-all-sharing \
    '{observed:{state:(.State//"unknown")}} | . + {ok:(.observed.state == "block-all-sharing")}' \
    ec2 get-snapshot-block-public-access-state --region "${region}"

# Runtime metrics, logs, probes, dashboards, and alert delivery are deliberately
# self-hosted on the controller. This AWS inventory therefore does not require or
# query CloudWatch alarms or Synthetics canaries.
record observability.self_hosted declared \
    'Prometheus, Loki, Grafana, Alloy, blackbox exporter, Alertmanager, and ntfy in the bootc images' \
    '{"provider":"controller","aws_paid_canaries":false,"cloudwatch_alarms":false}'

trails_file=${audit_dir}/trails.json
if aws_call "${trails_file}" cloudtrail describe-trails --region "${region}" --include-shadow-trails false; then
    trail_count=$(jq '.trailList|length' "${trails_file}")
    logging_count=0
    index=0
    while IFS= read -r trail_name; do
        status_file=${audit_dir}/trail-status-${index}.json
        if aws_call "${status_file}" cloudtrail get-trail-status --region "${region}" --name "${trail_name}" && [[ $(jq -r '.IsLogging==true' "${status_file}") == true ]]; then
            logging_count=$((logging_count + 1))
        fi
        index=$((index + 1))
    done < <(jq -r '.trailList[]?.Name' "${trails_file}")
    ok=$([[ ${trail_count} -gt 0 && ${logging_count} -eq ${trail_count} ]] && echo true || echo false)
    record security.cloudtrail "$(state_for "${ok}")" 'one or more trails, all logging' "$(jq -nc --argjson count "${trail_count}" --argjson logging "${logging_count}" '{count:$count,logging:$logging}')"
else
    unavailable security.cloudtrail 'one or more trails, all logging'
fi

recorders_file=${audit_dir}/recorders.json
recorder_status_file=${audit_dir}/recorder-status.json
if aws_call "${recorders_file}" configservice describe-configuration-recorders --region "${region}" && aws_call "${recorder_status_file}" configservice describe-configuration-recorder-status --region "${region}"; then
    observed=$(jq -nc --slurpfile r "${recorders_file}" --slurpfile s "${recorder_status_file}" '{count:($r[0].ConfigurationRecorders|length),recording:([$s[0].ConfigurationRecordersStatus[]?|select(.recording==true)]|length)}')
    ok=$(jq -r '.count > 0 and .recording == .count' <<<"${observed}")
    record security.aws_config "$(state_for "${ok}")" 'one or more recorders, all recording' "${observed}"
else
    unavailable security.aws_config 'one or more recorders, all recording'
fi

guardduty_file=${audit_dir}/guardduty.json
if aws_call "${guardduty_file}" guardduty list-detectors --region "${region}"; then
    detector_count=$(jq '.DetectorIds|length' "${guardduty_file}")
    enabled_count=0
    index=0
    while IFS= read -r detector_id; do
        detector_file=${audit_dir}/detector-${index}.json
        if aws_call "${detector_file}" guardduty get-detector --region "${region}" --detector-id "${detector_id}" && [[ $(jq -r '.Status=="ENABLED"' "${detector_file}") == true ]]; then
            enabled_count=$((enabled_count + 1))
        fi
        index=$((index + 1))
    done < <(jq -r '.DetectorIds[]?' "${guardduty_file}")
    ok=$([[ ${detector_count} -gt 0 && ${enabled_count} -eq ${detector_count} ]] && echo true || echo false)
    record security.guardduty "$(state_for "${ok}")" 'one or more enabled detectors' "$(jq -nc --argjson count "${detector_count}" --argjson enabled "${enabled_count}" '{count:$count,enabled:$enabled}')"
else
    unavailable security.guardduty 'one or more enabled detectors'
fi

if [[ -n ${account_id} ]]; then
    api_check security.inspector 'EC2 and ECR scanning enabled' \
        '{observed:{account_status:(.accounts[0].state.status//"UNKNOWN"),ec2:(.accounts[0].resourceState.ec2.status//"UNKNOWN"),ecr:(.accounts[0].resourceState.ecr.status//"UNKNOWN")}} | . + {ok:(.observed.account_status=="ENABLED" and .observed.ec2=="ENABLED" and .observed.ecr=="ENABLED")}' \
        inspector2 batch-get-account-status --region "${region}" --account-ids "${account_id}"
else
    unavailable security.inspector 'EC2 and ECR scanning enabled'
fi

security_hub_file=${audit_dir}/security-hub.json
if aws_call "${security_hub_file}" securityhub describe-hub-v2 --region "${region}"; then
    record security.security_hub_v2 configured subscribed '{"subscribed":true}'
else
    record security.security_hub_v2 not_configured subscribed '{"subscribed":false}'
fi

if [[ -n ${account_id} ]]; then
    budget_name=${project}-${environment}-account-annual-cost
    api_check cost.account_annual_budget "one ${budget_name} budget" \
        "[.Budgets[]?|select(.BudgetName==\"${budget_name}\")|{name:.BudgetName,type:.BudgetType,time_unit:.TimeUnit,limit:(.BudgetLimit//null)}] | {observed:{count:length,budgets:.}} | . + {ok:(.observed.count == 1)}" \
        budgets describe-budgets --account-id "${account_id}"
else
    unavailable cost.account_annual_budget 'one project production annual budget'
fi

# ListSecrets returns resource metadata only. Secret value APIs are prohibited.
api_check secrets.runtime_metadata 'one or more tagged secret containers' \
    "[.SecretList[]?|select(any(.Tags[]?;.Key==\"Project\" and .Value==\"${project}\"))|select(any(.Tags[]?;.Key==\"Environment\" and .Value==\"${environment}\"))] | {observed:{count:length,values_read:false}} | . + {ok:(.observed.count > 0)}" \
    secretsmanager list-secrets --region "${region}" --include-planned-deletion false

plans_file=${audit_dir}/backup-plans.json
vaults_file=${audit_dir}/backup-vaults.json
if aws_call "${plans_file}" backup list-backup-plans --region "${region}" && aws_call "${vaults_file}" backup list-backup-vaults --region "${region}"; then
    prefix=${project}-${environment}
    observed=$(jq -nc --slurpfile p "${plans_file}" --slurpfile v "${vaults_file}" --arg prefix "${prefix}" '{plans:([$p[0].BackupPlansList[]?|select(.BackupPlanName|startswith($prefix))]|length),vaults:([$v[0].BackupVaultList[]?|select(.BackupVaultName|startswith($prefix))]|length)}')
    ok=$(jq -r '.plans > 0 and .vaults > 0' <<<"${observed}")
    record recovery.aws_backup "$(state_for "${ok}")" 'project backup plan and vault' "${observed}"
else
    unavailable recovery.aws_backup 'project backup plan and vault'
fi

report_file=${audit_dir}/report.json
jq -s --arg region "${region}" --arg project "${project}" --arg environment "${environment}" --arg identity_type "${identity_type}" --arg observed_at "${LUCIDITY_AUDIT_NOW:-$(date --utc +%Y-%m-%dT%H:%M:%SZ)}" \
    '{schema_version:1,observed_at:$observed_at,region:$region,project:$project,environment:$environment,identity:{type:$identity_type},summary:{configured:(map(select(.state=="configured"))|length),not_configured:(map(select(.state=="not_configured"))|length),unavailable:(map(select(.state=="unavailable"))|length)},checks:.}' \
    "${checks_file}" >"${report_file}"

if [[ ${format} == json ]]; then
    rendered=${report_file}
else
    rendered=${audit_dir}/report.md
    jq -r '"# Lucidity production readiness inventory","","Observed: `\(.observed_at)` in `\(.region)` as identity type `\(.identity.type)`.","","This is read-only inventory evidence, not an approval or an OpenTofu apply.","","| Check | State | Expected | Observed |","| --- | --- | --- | --- |",(.checks[]|"| `\(.id)` | `\(.state)` | \(.expected|gsub("\\|";"\\|")) | \(.observed|tojson|gsub("\\|";"\\|")) |"),"","Summary: \(.summary.configured) configured, \(.summary.not_configured) not configured, \(.summary.unavailable) unavailable."' \
        "${report_file}" >"${rendered}"
fi

if [[ ${output} == - ]]; then
    cat "${rendered}"
else
    install -m 0600 "${rendered}" "${output}"
    echo "Wrote read-only production inventory to ${output}"
fi
