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
        default_registry_port=5001
        ;;
    worker)
        default_vm_dir=${repo_root}/image-output/vm
        default_vm_name=coolify-worker-vm
        default_ssh_port=2222
        default_registry_port=5000
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
registry_host=${VM_REGISTRY_HOST:-10.0.2.2:${default_registry_port}}
repository=${VM_UPDATE_REPOSITORY:-coolify-bootc-${role}}
v1_ref=${registry_host}/${repository}:lifecycle-v1
v2_ref=${registry_host}/${repository}:lifecycle-v2

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required" >&2; exit 1; }
[[ ${wait_attempts} =~ ^[0-9]+$ && ${wait_attempts} -gt 0 ]] || { echo "VM_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${controller_wait_attempts} =~ ^[0-9]+$ && ${controller_wait_attempts} -gt 0 ]] || { echo "VM_CONTROLLER_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${registry_host} =~ ^[[:alnum:].:-]+$ ]] || { echo "VM_REGISTRY_HOST contains invalid characters" >&2; exit 2; }
[[ ${repository} =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || { echo "VM_UPDATE_REPOSITORY is invalid" >&2; exit 2; }
[[ -f ${admin_identity} ]] || { echo "run make vm-init-${role} first" >&2; exit 1; }
if [[ ${role} == worker && ! -f ${coolify_identity} ]]; then
    echo "run make vm-init-worker first" >&2
    exit 1
fi
"${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1 || { echo "VM is not running" >&2; exit 1; }

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
if [[ ${role} == worker ]]; then
    coolify_ssh=("${ssh_base[@]}" -i "${coolify_identity}" root@127.0.0.1)
fi

reboot_and_wait() {
    local old_boot_id candidate attempt
    old_boot_id=$("${admin_ssh[@]}" cat /proc/sys/kernel/random/boot_id)
    "${admin_ssh[@]}" systemctl reboot >/dev/null 2>&1 || true
    for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
        candidate=$("${admin_ssh[@]}" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
        if [[ -n ${candidate} && ${candidate} != "${old_boot_id}" ]]; then
            return 0
        fi
        if ! "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
            echo "VM exited during reboot" >&2
            return 1
        fi
        sleep 2
    done
    echo "VM did not return after reboot" >&2
    return 1
}

wait_for_worker() {
    local attempt
    [[ ${role} == worker ]] || return 0
    for ((attempt = 1; attempt <= wait_attempts; attempt++)); do
        if "${admin_ssh[@]}" systemctl is-active --quiet docker.service 2>/dev/null && \
            "${admin_ssh[@]}" systemctl is-active --quiet coolify-worker-storage.service 2>/dev/null && \
            "${coolify_ssh[@]}" true >/dev/null 2>&1; then
            return 0
        fi
        if "${admin_ssh[@]}" systemctl is-failed --quiet coolify-worker-storage.service; then
            echo "Coolify worker storage failed after an OS deployment change" >&2
            "${admin_ssh[@]}" journalctl -u coolify-worker-storage.service --no-pager -n 200 >&2 || true
            return 1
        fi
        if "${admin_ssh[@]}" systemctl is-failed --quiet coolify-worker-authorized-keys.service; then
            echo "Coolify worker SSH authorization failed after an OS deployment change" >&2
            "${admin_ssh[@]}" journalctl -u coolify-worker-authorized-keys.service -u docker.service --no-pager -n 200 >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timed out waiting for Docker and the Coolify worker SSH identity after an OS deployment change" >&2
    return 1
}

wait_for_controller() {
    local state attempt
    [[ ${role} == controller ]] || return 0
    for ((attempt = 1; attempt <= controller_wait_attempts; attempt++)); do
        state=$("${admin_ssh[@]}" systemctl is-active coolify-controller-bootstrap.service 2>/dev/null || true)
        if [[ ${state} == active ]]; then
            return 0
        fi
        if "${admin_ssh[@]}" systemctl is-failed --quiet coolify-controller-storage.service; then
            echo "Coolify controller storage failed after an OS deployment change" >&2
            "${admin_ssh[@]}" journalctl -u coolify-controller-storage.service -u coolify-controller-bootstrap.service --no-pager -n 200 >&2 || true
            return 1
        fi
        if [[ ${state} == failed ]]; then
            echo "Coolify controller bootstrap failed after an OS deployment change" >&2
            "${admin_ssh[@]}" journalctl -u coolify-controller-bootstrap.service --no-pager -n 200 >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timed out waiting for Coolify controller after an OS deployment change" >&2
    return 1
}

assert_deployment() {
    local expected_version=$1
    local expected_ref=$2
    local marker=$3
    local expected_env_hash=${4:-}
    local expected_key_hash=${5:-}
    local expected_services_hash=${6:-}
    "${admin_ssh[@]}" bash -Eeuo pipefail -s -- \
        "${role}" "${expected_version}" "${expected_ref}" "${marker}" \
        "${expected_env_hash}" "${expected_key_hash}" "${expected_services_hash}" <<'REMOTE'
role=$1
expected_version=$2
expected_ref=$3
expected_marker=$4
assertion="read image version"
report_assertion_failure() {
    local status=$?
    trap - ERR
    echo "${role} deployment assertion failed while checking: ${assertion}" >&2
    bootc status --booted >&2 || true
    systemctl --no-pager --full status \
        docker.service \
        determinate-nix-install.service \
        nix-daemon.service \
        nix.mount \
        coolify-worker-storage.service \
        coolify-controller-storage.service \
        coolify-controller-bootstrap.service \
        aws-workload-credentials-provider-sm.service >&2 || true
    if [[ ${role} == controller ]]; then
        stat -c 'controller storage context: %C' /data/coolify >&2 || true
        mountpoint /data/coolify >&2 || true
        docker compose \
            --env-file /data/coolify/source/.env \
            --file /data/coolify/source/docker-compose.yml \
            --file /data/coolify/source/docker-compose.prod.yml \
            ps >&2 || true
    fi
    exit "${status}"
}
trap report_assertion_failure ERR
assertion="wait for Determinate Nix installation"
systemctl start determinate-nix-install.service
[[ $(cat /usr/lib/coolify-aws/image-version) == "${expected_version}" ]]
assertion="read the booted image reference"
bootc status --booted --format json | grep -Fq "${expected_ref}"
assertion="verify SELinux enforcing mode"
[[ $(getenforce) == Enforcing ]]
assertion="verify Docker is active"
systemctl is-active --quiet docker.service
assertion="verify Determinate Nix installation is active"
systemctl is-active --quiet determinate-nix-install.service
assertion="verify the Nix daemon is active"
systemctl is-active --quiet nix-daemon.service
assertion="verify /nix is mounted from persistent storage"
mountpoint --quiet /nix
[[ $(stat -c '%d:%i' /nix) == "$(stat -c '%d:%i' /var/lib/nix)" ]]
assertion="read the persistent Nix smoke build"
[[ $(</var/lib/coolify-aws/nix-smoke-result) == "Determinate Nix guest build passed" ]]
assertion="verify the deployment has no Nix SELinux denials"
if journalctl -b --no-pager | grep -Eiq 'avc:[[:space:]]+denied.*(/nix|nix-daemon)'; then
    echo "SELinux denied Determinate Nix access" >&2
    exit 1
fi

if [[ ${role} == worker ]]; then
    assertion="verify worker storage is active"
    systemctl is-active --quiet coolify-worker-storage.service
    assertion="verify persistent worker storage is mounted"
    mountpoint --quiet /data/coolify
    [[ $(stat -c '%d:%i' /data/coolify) == "$(stat -c '%d:%i' /var/lib/coolify)" ]]
    assertion="verify the persistent worker storage SELinux label"
    [[ $(stat -c %C /data/coolify) == *:container_file_t:* ]]
    assertion="read the persistent worker Coolify marker"
    [[ $(cat /data/coolify/.update-rollback-marker) == "${expected_marker}" ]]
    assertion="read the persistent worker volume"
    volume_path=$(docker volume inspect --format '{{ .Mountpoint }}' coolify-update-rollback-test)
    [[ $(cat "${volume_path}/marker") == "${expected_marker}" ]]
    assertion="verify the worker boot has no relevant SELinux denials"
    if journalctl -b --no-pager | grep -Eiq 'avc:[[:space:]]+denied.*(/data/coolify|/var/lib/coolify|container_t)'; then
        echo "SELinux denied Coolify worker access" >&2
        exit 1
    fi
    exit 0
fi

expected_env_hash=$5
expected_key_hash=$6
expected_services_hash=$7
assertion="verify controller storage is active"
systemctl is-active --quiet coolify-controller-storage.service
assertion="verify controller bootstrap is active"
systemctl is-active --quiet coolify-controller-bootstrap.service
assertion="verify the Secrets Manager provider is enabled"
systemctl is-enabled --quiet aws-workload-credentials-provider-sm.service
if [[ -e /etc/coolify-controller/runtime-secrets.env ]]; then
    assertion="verify the configured Secrets Manager provider is active"
    systemctl is-active --quiet aws-workload-credentials-provider-sm.service
else
    assertion="verify the unconfigured Secrets Manager provider did not fail"
    ! systemctl is-failed --quiet aws-workload-credentials-provider-sm.service
fi
assertion="verify persistent controller storage is mounted"
mountpoint --quiet /data/coolify
assertion="verify the persistent controller storage SELinux label"
[[ $(stat -c %C /data/coolify) == *:container_file_t:* ]]
assertion="read the persistent controller marker"
[[ $(cat /data/coolify/.update-rollback-marker) == "${expected_marker}" ]]
env_file=/data/coolify/source/.env
key_file=/data/coolify/ssh/id.root@host.docker.internal
assertion="verify the persistent controller environment"
[[ $(sha256sum "${env_file}" | cut -d ' ' -f 1) == "${expected_env_hash}" ]]
assertion="verify the persistent controller SSH key"
[[ $(sha256sum "${key_file}" | cut -d ' ' -f 1) == "${expected_key_hash}" ]]
compose=(
    docker compose
    --env-file "${env_file}"
    --file /data/coolify/source/docker-compose.yml
    --file /data/coolify/source/docker-compose.prod.yml
)
if [[ -s /data/coolify/source/docker-compose.custom.yml ]]; then
    compose+=(--file /data/coolify/source/docker-compose.custom.yml)
fi
assertion="resolve the expected controller services"
expected_services=$("${compose[@]}" config --services | sort -u)
assertion="resolve the running controller services"
running_services=$("${compose[@]}" ps --services --status running | sort -u)
assertion="verify every configured controller service is running"
[[ -n ${expected_services} && ${running_services} == "${expected_services}" ]]
assertion="verify the persistent controller service set"
[[ $(printf '%s' "${running_services}" | sha256sum | cut -d ' ' -f 1) == "${expected_services_hash}" ]]
assertion="verify the controller boot has no relevant SELinux denials"
if journalctl -b --no-pager | grep -Eiq 'avc:[[:space:]]+denied.*(/data/coolify|/var/lib/coolify|container_t)'; then
    echo "SELinux denied Coolify controller access" >&2
    exit 1
fi
REMOTE
}

timer_masked=false
cleanup() {
    if [[ ${timer_masked} == true ]]; then
        "${admin_ssh[@]}" systemctl unmask bootc-fetch-apply-updates.timer >/dev/null 2>&1 || true
        "${admin_ssh[@]}" systemctl start bootc-fetch-apply-updates.timer >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT

marker="coolify-${role}-update-rollback-$(date -u +%s)"
env_hash=""
key_hash=""
services_hash=""
"${admin_ssh[@]}" systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
"${admin_ssh[@]}" systemctl mask --now bootc-fetch-apply-updates.timer
timer_masked=true

if [[ ${role} == worker ]]; then
    "${admin_ssh[@]}" bash -Eeuo pipefail -s -- "${marker}" <<'REMOTE'
marker=$1
printf '%s\n' "${marker}" > /data/coolify/.update-rollback-marker
chmod 0600 /data/coolify/.update-rollback-marker
restorecon /data/coolify/.update-rollback-marker
docker volume create coolify-update-rollback-test >/dev/null
volume_path=$(docker volume inspect --format '{{ .Mountpoint }}' coolify-update-rollback-test)
printf '%s\n' "${marker}" > "${volume_path}/marker"
REMOTE
else
    wait_for_controller
    mapfile -t controller_hashes < <("${admin_ssh[@]}" bash -Eeuo pipefail -s -- "${marker}" <<'REMOTE'
marker=$1
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
expected_services=$("${compose[@]}" config --services | sort -u)
running_services=$("${compose[@]}" ps --services --status running | sort -u)
[[ -n ${expected_services} && ${running_services} == "${expected_services}" ]]
printf '%s\n' "${marker}" > /data/coolify/.update-rollback-marker
chown 9999:root /data/coolify/.update-rollback-marker
chmod 0600 /data/coolify/.update-rollback-marker
restorecon /data/coolify/.update-rollback-marker
sha256sum "${env_file}" | cut -d ' ' -f 1
sha256sum "${key_file}" | cut -d ' ' -f 1
printf '%s' "${running_services}" | sha256sum | cut -d ' ' -f 1
REMOTE
    )
    [[ ${#controller_hashes[@]} == 3 ]] || { echo "failed to capture controller persistence state" >&2; exit 1; }
    env_hash=${controller_hashes[0]}
    key_hash=${controller_hashes[1]}
    services_hash=${controller_hashes[2]}
fi

"${admin_ssh[@]}" bootc switch --transport registry --retain "${v1_ref}"
reboot_and_wait
wait_for_worker
wait_for_controller
assert_deployment lifecycle-v1 "${v1_ref}" "${marker}" "${env_hash}" "${key_hash}" "${services_hash}"

"${admin_ssh[@]}" bootc upgrade --tag lifecycle-v2
reboot_and_wait
wait_for_worker
wait_for_controller
assert_deployment lifecycle-v2 "${v2_ref}" "${marker}" "${env_hash}" "${key_hash}" "${services_hash}"

"${admin_ssh[@]}" bootc rollback
reboot_and_wait
wait_for_worker
wait_for_controller
assert_deployment lifecycle-v1 "${v1_ref}" "${marker}" "${env_hash}" "${key_hash}" "${services_hash}"

"${admin_ssh[@]}" systemctl unmask bootc-fetch-apply-updates.timer
"${admin_ssh[@]}" systemctl start bootc-fetch-apply-updates.timer
timer_masked=false
trap - EXIT

echo "${role^} VM update/rollback validation passed: v1 -> v2 -> v1 with Docker, Nix, role state, and enforcing SELinux preserved"
