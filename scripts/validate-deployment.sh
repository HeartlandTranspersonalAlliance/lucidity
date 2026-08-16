#!/usr/bin/env bash
set -Eeuo pipefail

aws_cli=${AWS_CLI:-aws}
curl_cli=${CURL_CLI:-curl}
region=${AWS_REGION:-}
project=${DEPLOYMENT_PROJECT:-lucidity}
environment=${DEPLOYMENT_ENVIRONMENT:-production}
enroll_worker=${DEPLOYMENT_ENROLL_WORKER:-true}
controller_url=${DEPLOYMENT_CONTROLLER_URL:-}
worker_url=${DEPLOYMENT_WORKER_URL:-}
poll_seconds=${DEPLOYMENT_SSM_POLL_SECONDS:-5}
max_attempts=${DEPLOYMENT_SSM_MAX_ATTEMPTS:-120}

[[ -n ${region} ]] || { echo "AWS_REGION is required" >&2; exit 2; }
[[ ${project} =~ ^[a-z0-9][a-z0-9-]{1,31}$ ]] || { echo "DEPLOYMENT_PROJECT is invalid" >&2; exit 2; }
[[ ${environment} =~ ^[a-z0-9][a-z0-9-]{1,31}$ ]] || { echo "DEPLOYMENT_ENVIRONMENT is invalid" >&2; exit 2; }
[[ ${enroll_worker} == true || ${enroll_worker} == false ]] || { echo "DEPLOYMENT_ENROLL_WORKER must be true or false" >&2; exit 2; }
[[ ${poll_seconds} =~ ^[0-9]+$ ]] || { echo "DEPLOYMENT_SSM_POLL_SECONDS must be a non-negative integer" >&2; exit 2; }
[[ ${max_attempts} =~ ^[1-9][0-9]*$ ]] || { echo "DEPLOYMENT_SSM_MAX_ATTEMPTS must be a positive integer" >&2; exit 2; }

for command in "${aws_cli}" "${curl_cli}" jq base64; do
    command -v "${command}" >/dev/null 2>&1 || { echo "${command} is required" >&2; exit 1; }
done

declare -A instance_ids private_ips vpc_ids

discover_node() {
    local role=$1
    local count instance root_volume_id response volume

    response=$("${aws_cli}" ec2 describe-instances \
        --region "${region}" \
        --filters \
            "Name=tag:Project,Values=${project}" \
            "Name=tag:Environment,Values=${environment}" \
            "Name=tag:Role,Values=${role}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --output json)
    count=$(jq '[.Reservations[].Instances[]] | length' <<< "${response}")
    [[ ${count} -eq 1 ]] || {
        echo "expected exactly one active ${project} ${environment} ${role} node; found ${count}" >&2
        return 1
    }
    instance=$(jq -c '.Reservations[].Instances[]' <<< "${response}")
    [[ $(jq -r '.State.Name' <<< "${instance}") == running ]] || { echo "${role} node is not running" >&2; return 1; }
    [[ $(jq -r '.Architecture' <<< "${instance}") == x86_64 ]] || { echo "${role} node is not x86_64" >&2; return 1; }
    [[ $(jq -r '.MetadataOptions.HttpTokens' <<< "${instance}") == required ]] || { echo "${role} node does not require IMDSv2" >&2; return 1; }

    instance_ids[${role}]=$(jq -r '.InstanceId' <<< "${instance}")
    private_ips[${role}]=$(jq -r '.PrivateIpAddress' <<< "${instance}")
    vpc_ids[${role}]=$(jq -r '.VpcId' <<< "${instance}")
    [[ ${instance_ids[${role}]} =~ ^i-[0-9a-f]+$ ]] || { echo "${role} node has an invalid instance ID" >&2; return 1; }
    [[ ${private_ips[${role}]} =~ ^(10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}|192\.168\.[0-9]{1,3}\.[0-9]{1,3})$ ]] || { echo "${role} node has an unexpected private address" >&2; return 1; }
    [[ ${vpc_ids[${role}]} =~ ^vpc-[0-9a-f]+$ ]] || { echo "${role} node has an invalid VPC ID" >&2; return 1; }

    root_volume_id=$(jq -r '.RootDeviceName as $root | .BlockDeviceMappings[] | select(.DeviceName == $root) | .Ebs.VolumeId' <<< "${instance}")
    [[ ${root_volume_id} =~ ^vol-[0-9a-f]+$ ]] || { echo "${role} node has no valid root EBS volume" >&2; return 1; }
    volume=$("${aws_cli}" ec2 describe-volumes \
        --region "${region}" \
        --volume-ids "${root_volume_id}" \
        --output json)
    [[ $(jq '.Volumes | length' <<< "${volume}") -eq 1 ]] || { echo "${role} root EBS volume was not found" >&2; return 1; }
    [[ $(jq -r '.Volumes[0].Encrypted' <<< "${volume}") == true ]] || { echo "${role} root EBS volume is not encrypted" >&2; return 1; }
    [[ $(jq -r '.Volumes[0].State' <<< "${volume}") == in-use ]] || { echo "${role} root EBS volume is not attached" >&2; return 1; }
}

wait_for_ssm() {
    local instance_id=$1
    local role=$2
    local attempt response status

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        response=$("${aws_cli}" ssm describe-instance-information \
            --region "${region}" \
            --filters "Key=InstanceIds,Values=${instance_id}" \
            --output json)
        status=$(jq -r --arg id "${instance_id}" '.InstanceInformationList[]? | select(.InstanceId == $id) | .PingStatus' <<< "${response}")
        [[ ${status} == Online ]] && return 0
        sleep "${poll_seconds}"
    done
    echo "${role} node did not become online in Systems Manager" >&2
    return 1
}

ssm_run() {
    local instance_id=$1
    local label=$2
    local command_text=$3
    local attempt command_id parameters response status

    parameters=$(jq -nc --arg command "${command_text}" '{commands: [$command]}')
    command_id=$("${aws_cli}" ssm send-command \
        --region "${region}" \
        --document-name AWS-RunShellScript \
        --instance-ids "${instance_id}" \
        --comment "lucidity deployment validation: ${label}" \
        --timeout-seconds 600 \
        --parameters "${parameters}" \
        --query 'Command.CommandId' \
        --output text)
    [[ ${command_id} =~ ^[0-9a-f-]+$ ]] || { echo "SSM returned an invalid command ID for ${label}" >&2; return 1; }

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if ! response=$("${aws_cli}" ssm get-command-invocation \
            --region "${region}" \
            --command-id "${command_id}" \
            --instance-id "${instance_id}" \
            --output json 2>/dev/null); then
            sleep "${poll_seconds}"
            continue
        fi
        status=$(jq -r '.Status' <<< "${response}")
        case "${status}" in
            Success)
                SSM_STDOUT=$(jq -r '.StandardOutputContent' <<< "${response}")
                return 0
                ;;
            Pending|InProgress|Delayed)
                sleep "${poll_seconds}"
                ;;
            *)
                echo "${label} failed with SSM status ${status}" >&2
                jq -r '.StandardErrorContent' <<< "${response}" >&2
                return 1
                ;;
        esac
    done
    echo "${label} did not finish before the SSM validation timeout" >&2
    return 1
}

validate_https_url() {
    local label=$1
    local url=$2

    [[ -z ${url} ]] && return 0
    [[ ${url} =~ ^https://[^[:space:]]+$ ]] || { echo "${label} URL must be an HTTPS URL without whitespace" >&2; return 2; }
    "${curl_cli}" --fail --location --silent --show-error \
        --connect-timeout 10 --max-time 30 --max-redirs 3 \
        --output /dev/null "${url}"
    echo "${label} HTTPS endpoint passed"
}

# The dollar expressions in these command bodies expand on the SSM-managed node.
# shellcheck disable=SC2016
common_command='
set -Eeuo pipefail
cloud-init status --wait >/dev/null
if ! systemctl start determinate-nix-install.service; then
    systemctl --no-pager --full status determinate-nix-install.service nix-directory.service nix.mount nix-daemon.socket nix-daemon.service >&2 || true
    journalctl --no-pager -n 300 -u determinate-nix-install.service -u nix-directory.service -u nix.mount -u nix-daemon.socket -u nix-daemon.service >&2 || true
    journalctl -b --no-pager -n 100 _AUDIT_TYPE_NAME=AVC >&2 || true
    exit 1
fi
systemctl is-active --quiet amazon-ssm-agent.service
systemctl is-active --quiet docker.service
systemctl is-active --quiet sshd.service
systemctl is-active --quiet determinate-nix-install.service
systemctl is-active --quiet nix-daemon.service
systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
[[ $(getenforce) == Enforcing ]]
mountpoint --quiet /nix
[[ $(stat -c "%d:%i" /nix) == "$(stat -c "%d:%i" /var/lib/nix)" ]]
[[ -s /nix/receipt.json ]]
docker info --format "{{json .ServerVersion}}" >/dev/null
docker compose version >/dev/null
bootc status >/dev/null
nix_bin=/nix/var/nix/profiles/default/bin/nix
"${nix_bin}" --version
"${nix_bin}" build \
    --no-write-lock-file \
    --out-link /var/lib/coolify-aws/nix-smoke-result \
    /usr/share/coolify-aws/nix-smoke
[[ $(</var/lib/coolify-aws/nix-smoke-result) == "Determinate Nix guest build passed" ]]
if journalctl -b --no-pager | grep -Eiq "avc:[[:space:]]+denied.*(/nix|nix-daemon)"; then
    exit 1
fi
[[ $(curl --silent --output /dev/null --write-out "%{http_code}" http://169.254.169.254/latest/meta-data/) == 401 ]]
'

# shellcheck disable=SC2016
controller_command='
set -Eeuo pipefail
systemctl is-active --quiet coolify-controller-storage.service
systemctl is-active --quiet coolify-controller-bootstrap.service
systemctl is-active --quiet aws-workload-credentials-provider-token.service
systemctl is-enabled --quiet aws-workload-credentials-provider-sm.service
mountpoint --quiet /data/coolify
matchpathcon -V /data/coolify >/dev/null
[[ $(stat -c %C /data/coolify) == *:container_file_t:* ]]
[[ -s /data/coolify/source/.env ]]
[[ -s /data/coolify/ssh/id.root@host.docker.internal ]]
[[ -s /data/coolify/ssh/id.root@host.docker.internal.pub ]]
[[ -e /data/coolify/.controller-bootstrap-complete ]]
compose=(docker compose --env-file /data/coolify/source/.env --file /data/coolify/source/docker-compose.yml --file /data/coolify/source/docker-compose.prod.yml)
if [[ -s /data/coolify/source/docker-compose.custom.yml ]]; then
    compose+=(--file /data/coolify/source/docker-compose.custom.yml)
fi
expected=$("${compose[@]}" config --services | sort -u)
running=$("${compose[@]}" ps --services --status running | sort -u)
[[ -n ${expected} && ${running} == "${expected}" ]]
if journalctl -b --no-pager | grep -Eiq "avc:[[:space:]]+denied.*(/data/coolify|/var/lib/coolify|container_t)"; then
    exit 1
fi
'

worker_command='
set -Eeuo pipefail
systemctl is-active --quiet coolify-worker-authorized-keys.service
[[ -s /etc/coolify-worker/authorized_keys ]]
'

discover_node controller
discover_node worker
[[ ${vpc_ids[controller]} == "${vpc_ids[worker]}" ]] || { echo "controller and worker are not in the same VPC" >&2; exit 1; }
echo "Discovered one hardened running controller and worker with encrypted root storage"

for role in controller worker; do
    wait_for_ssm "${instance_ids[${role}]}" "${role}"
    ssm_run "${instance_ids[${role}]}" "${role} host" "${common_command}"
done
echo "Both nodes passed the common host and SSM checks"

ssm_run "${instance_ids[controller]}" "controller services" "${controller_command}"
echo "Controller storage and Coolify services passed"

if [[ ${enroll_worker} == true ]]; then
    # shellcheck disable=SC2016
    ssm_run "${instance_ids[controller]}" "read controller public key" '
set -Eeuo pipefail
key=/data/coolify/ssh/id.root@host.docker.internal.pub
[[ -s ${key} ]]
ssh-keygen -l -f "${key}" >/dev/null
cat "${key}"
'
    controller_public_key=${SSM_STDOUT%$'\n'}
    [[ ${controller_public_key} =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521))[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || {
        echo "controller returned an invalid SSH public key" >&2
        exit 1
    }
    encoded_public_key=$(printf '%s\n' "${controller_public_key}" | base64 -w 0)
    ssm_run "${instance_ids[worker]}" "enroll controller public key" "
set -Eeuo pipefail
key_file=/etc/coolify-worker/authorized_keys
install -d -m 0700 /etc/coolify-worker
touch \"\${key_file}\"
chmod 0600 \"\${key_file}\"
candidate=\$(mktemp)
printf '%s' '${encoded_public_key}' | base64 -d > \"\${candidate}\"
ssh-keygen -l -f \"\${candidate}\" >/dev/null
grep -Fqx -- \"\$(<\"\${candidate}\")\" \"\${key_file}\" || cat \"\${candidate}\" >> \"\${key_file}\"
rm -f \"\${candidate}\"
systemctl restart coolify-worker-authorized-keys.service
systemctl is-active --quiet coolify-worker-authorized-keys.service
"
    echo "Worker enrollment passed"
else
    ssm_run "${instance_ids[worker]}" "worker enrollment" "${worker_command}"
fi

# shellcheck disable=SC2016
ssm_run "${instance_ids[worker]}" "read worker SSH host key" '
set -Eeuo pipefail
key=/etc/ssh/ssh_host_ed25519_key.pub
[[ -s ${key} ]]
ssh-keygen -l -f "${key}" >/dev/null
cat "${key}"
'
worker_host_key=${SSM_STDOUT%$'\n'}
[[ ${worker_host_key} =~ ^ssh-ed25519[[:space:]]+[A-Za-z0-9+/]+={0,3}([[:space:]].*)?$ ]] || {
    echo "worker returned an invalid SSH host key" >&2
    exit 1
}
encoded_host_key=$(printf '%s\n' "${worker_host_key}" | base64 -w 0)
ssm_run "${instance_ids[controller]}" "controller to worker SSH" "
set -Eeuo pipefail
known_hosts=\$(mktemp)
trap 'rm -f \"\${known_hosts}\"' EXIT
printf '%s %s\\n' '${private_ips[worker]}' \"\$(printf '%s' '${encoded_host_key}' | base64 -d)\" > \"\${known_hosts}\"
ssh -i /data/coolify/ssh/id.root@host.docker.internal \\
    -o BatchMode=yes \\
    -o ConnectTimeout=10 \\
    -o IdentitiesOnly=yes \\
    -o StrictHostKeyChecking=yes \\
    -o UserKnownHostsFile=\"\${known_hosts}\" \\
    root@${private_ips[worker]} true
"
echo "Controller-to-worker private SSH passed with the SSM-authenticated host key"

validate_https_url "Controller" "${controller_url}"
validate_https_url "Worker application" "${worker_url}"

if [[ -n ${GITHUB_STEP_SUMMARY:-} ]]; then
    {
        echo "## Production deployment acceptance passed"
        echo
        echo "- Controller and worker: running, encrypted, IMDSv2-only, SSM online, persistent Nix healthy"
        echo "- Controller: Coolify storage and complete Compose service set healthy"
        echo "- Worker: controller public key enrolled and private SSH verified"
        [[ -z ${controller_url} ]] || echo "- Controller HTTPS endpoint healthy"
        [[ -z ${worker_url} ]] || echo "- Worker application HTTPS endpoint healthy"
    } >> "${GITHUB_STEP_SUMMARY}"
fi

echo "Production deployment acceptance passed"
