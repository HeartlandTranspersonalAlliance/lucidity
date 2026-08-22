#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=${LUCIDITY_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
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
expected_image=${VM_EXPECTED_IMAGE:-}

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
admin_login=("${ssh_base[@]}" -i "${admin_identity}" admin@127.0.0.1)
admin_ssh=("${admin_login[@]}" sudo -n)

wait_for_ssh() {
    local identity=$1
    local attempt
    for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
        if "${ssh_base[@]}" -i "${identity}" admin@127.0.0.1 true >/dev/null 2>&1; then
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

report_controller_bootstrap_failure() {
    echo "Coolify controller bootstrap or a required dependency failed" >&2
    "${admin_ssh[@]}" systemctl --no-pager --full status \
        lucidity-nix-profile.service \
        coolify-controller-storage.service \
        docker.service \
        openbao.service \
        aws-workload-credentials-provider-sm.service \
        coolify-controller-bootstrap.service >&2 || true
    "${admin_ssh[@]}" systemctl --no-pager --full --failed >&2 || true
    "${admin_ssh[@]}" systemctl --no-pager --full list-dependencies \
        coolify-controller-bootstrap.service >&2 || true
    "${admin_ssh[@]}" journalctl --no-pager -n 400 \
        -u lucidity-nix-profile.service \
        -u coolify-controller-storage.service \
        -u docker.service \
        -u openbao.service \
        -u aws-workload-credentials-provider-sm.service \
        -u coolify-controller-bootstrap.service >&2 || true
    "${admin_ssh[@]}" journalctl -b --no-pager -n 100 \
        _AUDIT_TYPE_NAME=AVC >&2 || true
}

controller_required_dependency_failed() {
    "${admin_ssh[@]}" bash -s <<'REMOTE'
for unit in \
    lucidity-nix-profile.service \
    coolify-controller-storage.service \
    docker.service \
    openbao.service; do
    systemctl is-failed --quiet "${unit}" && exit 0
done
exit 1
REMOTE
}

wait_for_controller() {
    local state attempt
    for ((attempt = 1; attempt <= controller_wait_attempts; attempt++)); do
        state=$("${admin_ssh[@]}" systemctl is-active coolify-controller-bootstrap.service 2>/dev/null || true)
        if [[ ${state} == active ]]; then
            return 0
        fi
        if controller_required_dependency_failed; then
            report_controller_bootstrap_failure
            return 1
        fi
        if [[ ${state} == failed ]]; then
            report_controller_bootstrap_failure
            return 1
        fi
        if ! "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
            echo "VM exited while the Coolify controller initialized" >&2
            return 1
        fi
        sleep 2
    done
    echo "timed out waiting for Coolify controller bootstrap" >&2
    report_controller_bootstrap_failure
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

report_nix_bootstrap_failure() {
    echo "Determinate Nix bootstrap failed" >&2
    "${admin_ssh[@]}" systemctl --no-pager --full status \
        lucidity-nix-selinux.service \
        lucidity-nix-seed.service \
        nix.mount \
        nix-daemon.socket \
        nix-daemon.service \
        lucidity-nix-profile.service >&2 || true
    "${admin_ssh[@]}" journalctl --no-pager -n 300 \
        -u lucidity-nix-selinux.service \
        -u lucidity-nix-seed.service \
        -u nix.mount \
        -u nix-daemon.socket \
        -u nix-daemon.service \
        -u lucidity-nix-profile.service >&2 || true
    "${admin_ssh[@]}" journalctl -b --no-pager -n 100 \
        _AUDIT_TYPE_NAME=AVC >&2 || true
}

report_worker_storage_failure() {
    echo "Coolify worker storage validation failed" >&2
    "${admin_ssh[@]}" systemctl --no-pager --full status \
        coolify-worker-storage.service \
        coolify-worker-authorized-keys.service >&2 || true
    "${admin_ssh[@]}" journalctl --no-pager -n 200 \
        -u coolify-worker-storage.service \
        -u coolify-worker-authorized-keys.service >&2 || true
    "${admin_ssh[@]}" findmnt --target /data/coolify >&2 || true
    "${admin_ssh[@]}" stat -c '%n %d:%i %C' \
        /data/coolify /var/lib/coolify >&2 || true
}

assert_common_host() {
    "${admin_ssh[@]}" bash -Eeuo pipefail -s -- "${expected_image}" <<'REMOTE'
expected_image=$1
systemctl is-active --quiet docker.service
systemctl is-active --quiet sshd.service
systemctl is-active --quiet lucidity-nix-selinux.service
systemctl is-active --quiet lucidity-nix-seed.service
systemctl is-active --quiet nix-daemon.service
systemctl is-active --quiet lucidity-nix-profile.service
systemctl is-active --quiet lucidity-admin-authorized-key.service
systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
[[ $(getenforce) == Enforcing ]]
mountpoint --quiet /nix
[[ $(stat -c '%d:%i' /nix) == "$(stat -c '%d:%i' /var/lib/nix)" ]]
[[ -s /nix/receipt.json ]]
semodule -l | awk '$1 == "nix" { found = 1 } END { exit !found }'
docker info --format '{{json .ServerVersion}}' >/dev/null
docker compose version >/dev/null
if [[ -n ${expected_image} ]]; then
    bootc status --booted --format json | grep -Fq "${expected_image}"
else
    bootc status --booted >/dev/null
fi
nix_bin=/nix/var/nix/profiles/default/bin/nix
"${nix_bin}" --version
[[ $("${nix_bin}" eval --raw --expr 'toString (1 + 1)') == 2 ]]
[[ -x /var/usrlocal/bin/lucidity ]]
/var/usrlocal/bin/lucidity --help >/dev/null
[[ -L /nix/var/nix/profiles/lucidity ]]
[[ -e /var/home/admin/.nix-profile ]]
if journalctl -b --no-pager | grep -Eiq 'avc:[[:space:]]+denied.*(/nix|nix-daemon)'; then
    echo "SELinux denied Determinate Nix access" >&2
    exit 1
fi
REMOTE
}

assert_controller() {
    "${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
systemctl is-active --quiet coolify-controller-storage.service
systemctl is-active --quiet coolify-controller-bootstrap.service
systemctl is-active --quiet openbao.service
systemctl is-active --quiet aws-workload-credentials-provider-token.service
! systemctl is-failed --quiet aws-workload-credentials-provider-sm.service
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

assert_controller_connectivity() {
    "${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
systemctl is-active --quiet coolify-controller-storage.service
systemctl is-active --quiet openbao.service
systemctl is-enabled --quiet coolify-controller-bootstrap.service
! systemctl is-failed --quiet coolify-controller-bootstrap.service
mountpoint --quiet /data/coolify
matchpathcon -V /data/coolify >/dev/null
[[ $(stat -c %C /data/coolify) == *:container_file_t:* ]]
REMOTE
}

wait_for_ssh "${admin_identity}"
"${admin_login[@]}" true
"${admin_login[@]}" sudo -n true
if "${ssh_base[@]}" -i "${admin_identity}" root@127.0.0.1 true >/dev/null 2>&1; then
    echo "administrator identity unexpectedly authenticated as root" >&2
    exit 1
fi
if ! cloud_status=$("${admin_ssh[@]}" cloud-init status --wait); then
    printf '%s\n' "${cloud_status}" >&2
    "${admin_ssh[@]}" cloud-init status --long >&2 || true
    exit 1
fi
printf '%s\n' "${cloud_status}"
if ! "${admin_ssh[@]}" systemctl start lucidity-nix-profile.service; then
    report_nix_bootstrap_failure
    exit 1
fi
assert_common_host

if [[ ${role} == controller ]] && \
    "${admin_ssh[@]}" test -e /etc/lucidity/vm-connectivity-only; then
    assert_controller_connectivity
    echo "Controller VM connectivity validation passed: cloud-init, SSH, Docker, bootc, Determinate Nix, persistent controller storage, and SELinux enforcing"
    exit 0
fi

if [[ ${role} == worker ]]; then
    coolify_ssh=("${ssh_base[@]}" -i "${coolify_identity}" root@127.0.0.1)
    "${coolify_ssh[@]}" true
    if ! "${admin_ssh[@]}" systemctl is-active --quiet coolify-worker-storage.service; then
        report_worker_storage_failure
        exit 1
    fi
    if ! "${admin_ssh[@]}" systemctl is-active --quiet coolify-worker-authorized-keys.service; then
        report_worker_storage_failure
        exit 1
    fi
    if ! "${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
mountpoint --quiet /data/coolify
[[ $(stat -c '%d:%i' /data/coolify) == "$(stat -c '%d:%i' /var/lib/coolify)" ]]
[[ $(stat -c %C /data/coolify) == *:container_file_t:* ]]
REMOTE
    then
        report_worker_storage_failure
        exit 1
    fi
    echo "Worker VM initial validation passed: cloud-init, SSH, Docker, bootc, Determinate Nix, persistent Coolify storage, SELinux, and unattended updates"
    exit 0
fi

wait_for_controller
assert_controller
echo "Controller VM initial validation passed: Coolify and Determinate Nix initialized with persistent storage and SELinux enforcing"
