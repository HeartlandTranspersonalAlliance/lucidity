#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root

role=${1:-worker}
case "${role}" in
    controller)
        default_vm_dir=${repo_root}/image-output/vm-controller
        default_vm_name=coolify-controller-vm
        default_ssh_port=2223
        ;;
    worker)
        default_vm_dir=${repo_root}/image-output/vm
        default_vm_name=coolify-worker-vm
        default_ssh_port=2222
        ;;
    *) echo "unsupported VM role '${role}'; expected controller or worker" >&2; exit 2 ;;
esac

vm_dir=${VM_DIR:-${default_vm_dir}}
vm_name=${VM_NAME:-${default_vm_name}}
ssh_port=${VM_SSH_PORT:-${default_ssh_port}}
admin_identity=${vm_dir}/admin
coolify_identity=${vm_dir}/coolify
container_engine=${CONTAINER_ENGINE:-podman}
wait_attempts=${VM_WAIT_ATTEMPTS:-120}
controller_wait_attempts=${VM_CONTROLLER_WAIT_ATTEMPTS:-450}

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required" >&2; exit 1; }
[[ ${wait_attempts} =~ ^[0-9]+$ && ${wait_attempts} -gt 0 ]] || { echo "VM_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${controller_wait_attempts} =~ ^[0-9]+$ && ${controller_wait_attempts} -gt 0 ]] || { echo "VM_CONTROLLER_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ -f ${admin_identity} ]] || { echo "run make vm-init-${role} first" >&2; exit 1; }
if [[ ${role} == worker && ! -f ${coolify_identity} ]]; then
    echo "run make vm-init-worker first" >&2
    exit 1
fi
"${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1 || { echo "VM is not running; run make vm-start-${role}" >&2; exit 1; }

ssh_base=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=3
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "${ssh_port}"
)
admin_ssh=("${ssh_base[@]}" -i "${admin_identity}" root@127.0.0.1)

wait_for_ssh() {
    local identity=$1
    local attempt
    for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
        if "${ssh_base[@]}" -i "${identity}" root@127.0.0.1 true >/dev/null 2>&1; then
            return 0
        fi
        if ! "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
            echo "VM exited before SSH became available" >&2
            "${container_engine}" logs "${vm_name}" >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timed out waiting for VM SSH" >&2
    return 1
}

wait_for_controller() {
    local state attempt
    for ((attempt = 1; attempt <= controller_wait_attempts; attempt++)); do
        state=$("${admin_ssh[@]}" systemctl is-active coolify-controller-bootstrap.service 2>/dev/null || true)
        if [[ ${state} == active ]]; then
            return 0
        fi
        if "${admin_ssh[@]}" systemctl is-failed --quiet coolify-controller-storage.service; then
            echo "Coolify controller storage failed" >&2
            "${admin_ssh[@]}" journalctl -u coolify-controller-storage.service -u coolify-controller-bootstrap.service --no-pager -n 200 >&2 || true
            return 1
        fi
        if [[ ${state} == failed ]]; then
            echo "Coolify controller bootstrap failed" >&2
            "${admin_ssh[@]}" journalctl -u coolify-controller-bootstrap.service --no-pager -n 200 >&2 || true
            return 1
        fi
        if ! "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
            echo "VM exited while the Coolify controller initialized" >&2
            return 1
        fi
        sleep 2
    done
    echo "timed out waiting for Coolify controller bootstrap" >&2
    "${admin_ssh[@]}" journalctl -u coolify-controller-bootstrap.service --no-pager -n 200 >&2 || true
    return 1
}

controller_state() {
    "${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
env_file=/data/coolify/source/.env
key_file=/data/coolify/ssh/id.root@host.docker.internal
compose=(
    docker compose
    --env-file "${env_file}"
    --file /data/coolify/source/docker-compose.yml
    --file /data/coolify/source/docker-compose.prod.yml
)
if [[ -s /data/coolify/source/docker-compose.custom.yml ]]; then
    compose+=(--file /data/coolify/source/docker-compose.custom.yml)
fi
expected=$("${compose[@]}" config --services | sort -u)
running=$("${compose[@]}" ps --services --status running | sort -u)
[[ -n ${expected} && ${running} == "${expected}" ]]
sha256sum "${env_file}" | cut -d ' ' -f 1
sha256sum "${key_file}" | cut -d ' ' -f 1
printf '%s' "${running}" | sha256sum | cut -d ' ' -f 1
REMOTE
}

assert_common_host() {
    "${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
systemctl is-active --quiet docker.service
systemctl is-active --quiet sshd.service
systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
[[ $(getenforce) == Enforcing ]]
docker info --format '{{json .ServerVersion}}' >/dev/null
docker compose version >/dev/null
bootc status >/dev/null
REMOTE
}

assert_controller() {
    "${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
systemctl is-active --quiet coolify-controller-storage.service
systemctl is-active --quiet coolify-controller-bootstrap.service
systemctl is-active --quiet aws-workload-credentials-provider-token.service
systemctl is-enabled --quiet aws-workload-credentials-provider-sm.service
if [[ -e /etc/coolify-controller/runtime-secrets.env ]]; then
    systemctl is-active --quiet aws-workload-credentials-provider-sm.service
else
    ! systemctl is-failed --quiet aws-workload-credentials-provider-sm.service
fi
mountpoint --quiet /data/coolify
matchpathcon -V /data/coolify >/dev/null
[[ $(stat -c %C /data/coolify) == *:container_file_t:* ]]
[[ -s /data/coolify/source/.env ]]
[[ -s /data/coolify/ssh/id.root@host.docker.internal ]]
[[ -e /data/coolify/.controller-bootstrap-complete ]]
for key in APP_ID APP_KEY DB_PASSWORD REDIS_PASSWORD PUSHER_APP_ID PUSHER_APP_KEY PUSHER_APP_SECRET; do
    grep -Eq "^${key}=.+$" /data/coolify/source/.env
done
public_key=$(< /data/coolify/ssh/id.root@host.docker.internal.pub)
grep -Fqx -- "${public_key}" /root/.ssh/authorized_keys
if journalctl -b --no-pager | grep -Eiq 'avc:[[:space:]]+denied.*(/data/coolify|/var/lib/coolify|container_t)'; then
    echo "SELinux denied Coolify controller access" >&2
    exit 1
fi
REMOTE
    controller_state >/dev/null
}

wait_for_ssh "${admin_identity}"
if ! cloud_status=$("${admin_ssh[@]}" cloud-init status --wait); then
    printf '%s\n' "${cloud_status}" >&2
    "${admin_ssh[@]}" cloud-init status --long >&2 || true
    exit 1
fi
printf '%s\n' "${cloud_status}"
assert_common_host

if [[ ${role} == worker ]]; then
    coolify_ssh=("${ssh_base[@]}" -i "${coolify_identity}" root@127.0.0.1)
    "${coolify_ssh[@]}" true
    "${admin_ssh[@]}" systemctl is-active --quiet coolify-worker-authorized-keys.service
    echo "Worker VM initial validation passed: cloud-init, both SSH identities, Docker, Compose, bootc, SELinux, and unattended-update timer"
    exit 0
fi

wait_for_controller
assert_controller
echo "Controller VM initial validation passed: Coolify initialized with persistent storage and SELinux enforcing"
