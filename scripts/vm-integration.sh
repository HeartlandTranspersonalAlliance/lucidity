#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=${LUCIDITY_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly repo_root

controller_vm_dir=${CONTROLLER_VM_DIR:-${repo_root}/image-output/vm-controller}
worker_vm_dir=${WORKER_VM_DIR:-${repo_root}/image-output/vm}
controller_ssh_port=${CONTROLLER_VM_SSH_PORT:-2223}
worker_ssh_port=${WORKER_VM_SSH_PORT:-2222}
worker_guest_address=${WORKER_GUEST_ADDRESS:-10.0.2.2}
wait_attempts=${INTEGRATION_WAIT_ATTEMPTS:-120}
wait_seconds=${INTEGRATION_WAIT_SECONDS:-2}
container_engine=${CONTAINER_ENGINE:-podman}

command -v ssh >/dev/null 2>&1 || { echo "ssh is required" >&2; exit 1; }
command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
[[ ${wait_attempts} =~ ^[1-9][0-9]*$ ]] || { echo "INTEGRATION_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${wait_seconds} =~ ^[0-9]+$ ]] || { echo "INTEGRATION_WAIT_SECONDS must be a non-negative integer" >&2; exit 2; }
[[ ${worker_guest_address} =~ ^[[:alnum:].:-]+$ ]] || { echo "WORKER_GUEST_ADDRESS is invalid" >&2; exit 2; }

controller_identity=${controller_vm_dir}/admin
worker_identity=${worker_vm_dir}/admin
[[ -f ${controller_identity} ]] || { echo "controller VM administrator identity is missing" >&2; exit 1; }
[[ -f ${worker_identity} ]] || { echo "worker VM administrator identity is missing" >&2; exit 1; }

ssh_base=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=5
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
)
controller_ssh=("${ssh_base[@]}" -p "${controller_ssh_port}" -i "${controller_identity}" admin@127.0.0.1 sudo -n)
worker_ssh=("${ssh_base[@]}" -p "${worker_ssh_port}" -i "${worker_identity}" admin@127.0.0.1 sudo -n)

wait_for_guest() {
    local role=$1 port=$2 identity=$3 container=$4 attempt
    for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
        if "${ssh_base[@]}" -p "${port}" -i "${identity}" admin@127.0.0.1 true >/dev/null 2>&1; then
            return 0
        fi
        if ! "${container_engine}" container inspect "${container}" >/dev/null 2>&1; then
            echo "${role} VM exited before SSH became available" >&2
            "${container_engine}" logs "${container}" >&2 || true
            return 1
        fi
        sleep "${wait_seconds}"
    done
    echo "timed out waiting for ${role} VM SSH" >&2
    return 1
}

wait_for_cloud_init() {
    local role=$1
    shift
    local -a guest_ssh=("$@")
    local attempt
    for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
        if "${guest_ssh[@]}" systemctl is-active --quiet cloud-final.service; then
            return 0
        fi
        sleep "${wait_seconds}"
    done
    echo "timed out waiting for ${role} cloud-init" >&2
    "${guest_ssh[@]}" systemctl status cloud-final.service --no-pager >&2 || true
    return 1
}

validate_guest_boot() {
    local role=$1
    shift
    local -a guest_ssh=("$@")
    local actual_role
    actual_role=$("${guest_ssh[@]}" cat /etc/lucidity/role)
    [[ ${actual_role} == "${role}" ]] || {
        echo "expected ${role} guest, found ${actual_role}" >&2
        return 1
    }
    "${guest_ssh[@]}" bootc status >/dev/null
    "${guest_ssh[@]}" systemctl is-active --quiet \
        sshd.service nix-daemon.service lucidity-nix-profile.service
}

wait_for_guest controller "${controller_ssh_port}" "${controller_identity}" coolify-controller-vm
wait_for_guest worker "${worker_ssh_port}" "${worker_identity}" coolify-worker-vm
wait_for_cloud_init controller "${controller_ssh[@]}"
wait_for_cloud_init worker "${worker_ssh[@]}"
validate_guest_boot controller "${controller_ssh[@]}"
validate_guest_boot worker "${worker_ssh[@]}"

"${controller_ssh[@]}" test -e /etc/lucidity/vm-connectivity-only
"${controller_ssh[@]}" test ! -e /data/coolify/.controller-bootstrap-complete

"${controller_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
install -d -m 0700 /root/.ssh
rm -f /root/.ssh/lucidity-worker /root/.ssh/lucidity-worker.pub
ssh-keygen -q -t ed25519 -N '' -C lucidity-controller-worker-test -f /root/.ssh/lucidity-worker
REMOTE
controller_public_key=$("${controller_ssh[@]}" cat /root/.ssh/lucidity-worker.pub)
worker_host_key=$("${worker_ssh[@]}" cat /etc/ssh/ssh_host_ed25519_key.pub)

"${worker_ssh[@]}" install -d -m 0700 /root/.ssh
printf '%s\n' "${controller_public_key}" | "${worker_ssh[@]}" tee /root/.ssh/authorized_keys >/dev/null
"${worker_ssh[@]}" chmod 0600 /root/.ssh/authorized_keys

printf '[%s]:%s %s\n' "${worker_guest_address}" "${worker_ssh_port}" "${worker_host_key}" |
    "${controller_ssh[@]}" tee /root/.ssh/known_hosts >/dev/null
"${controller_ssh[@]}" chmod 0600 /root/.ssh/known_hosts

controller_to_worker=(
    "${controller_ssh[@]}"
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile=/root/.ssh/known_hosts
    -i /root/.ssh/lucidity-worker
    -p "${worker_ssh_port}"
    "root@${worker_guest_address}"
)
connected_role=$("${controller_to_worker[@]}" cat /etc/lucidity/role)
[[ ${connected_role} == worker ]]
"${controller_to_worker[@]}" systemctl is-active --quiet sshd.service

echo "Controller and worker booted successfully; controller-to-worker SSH is operational."
