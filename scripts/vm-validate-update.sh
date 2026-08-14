#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root

vm_dir=${VM_DIR:-${repo_root}/image-output/vm}
vm_name=${VM_NAME:-coolify-worker-vm}
ssh_port=${VM_SSH_PORT:-2222}
admin_identity=${vm_dir}/admin
container_engine=${CONTAINER_ENGINE:-podman}
wait_attempts=${VM_WAIT_ATTEMPTS:-120}
registry_host=${VM_REGISTRY_HOST:-10.0.2.2:5000}
repository=${VM_UPDATE_REPOSITORY:-coolify-bootc-worker}
v1_ref=${registry_host}/${repository}:lifecycle-v1
v2_ref=${registry_host}/${repository}:lifecycle-v2

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required" >&2; exit 1; }
[[ ${wait_attempts} =~ ^[0-9]+$ && ${wait_attempts} -gt 0 ]] || { echo "VM_WAIT_ATTEMPTS must be a positive integer" >&2; exit 2; }
[[ ${registry_host} =~ ^[[:alnum:].:-]+$ ]] || { echo "VM_REGISTRY_HOST contains invalid characters" >&2; exit 2; }
[[ ${repository} =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || { echo "VM_UPDATE_REPOSITORY is invalid" >&2; exit 2; }
[[ -f ${admin_identity} ]] || { echo "run make vm-init-worker first" >&2; exit 1; }
"${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1 || { echo "VM is not running" >&2; exit 1; }

admin_ssh=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=3
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "${ssh_port}"
    -i "${admin_identity}"
    root@127.0.0.1
)

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

assert_deployment() {
    local expected_version=$1
    local expected_ref=$2
    local marker=$3
    "${admin_ssh[@]}" bash -Eeuo pipefail -s -- "${expected_version}" "${expected_ref}" "${marker}" <<'REMOTE'
expected_version=$1
expected_ref=$2
expected_marker=$3
[[ $(cat /usr/lib/coolify-aws/image-version) == "${expected_version}" ]]
bootc status --booted --format json | grep -Fq "${expected_ref}"
volume_path=$(docker volume inspect --format '{{ .Mountpoint }}' coolify-update-rollback-test)
[[ $(cat "${volume_path}/marker") == "${expected_marker}" ]]
[[ $(getenforce) == Enforcing ]]
systemctl is-active --quiet docker.service
REMOTE
}

marker="coolify-worker-update-rollback-$(date -u +%s)"
"${admin_ssh[@]}" bash -Eeuo pipefail -s -- "${marker}" <<'REMOTE'
marker=$1
systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
# Keep the controlled rollback deterministic across reboots. The mask is
# removed after validation, and the image's enabled policy is unchanged.
systemctl mask --now bootc-fetch-apply-updates.timer
docker volume create coolify-update-rollback-test >/dev/null
volume_path=$(docker volume inspect --format '{{ .Mountpoint }}' coolify-update-rollback-test)
printf '%s\n' "${marker}" > "${volume_path}/marker"
REMOTE

"${admin_ssh[@]}" bootc switch --transport registry --retain "${v1_ref}"
reboot_and_wait
assert_deployment lifecycle-v1 "${v1_ref}" "${marker}"

"${admin_ssh[@]}" bootc upgrade --tag lifecycle-v2
reboot_and_wait
assert_deployment lifecycle-v2 "${v2_ref}" "${marker}"

"${admin_ssh[@]}" bootc rollback
reboot_and_wait
assert_deployment lifecycle-v1 "${v1_ref}" "${marker}"
"${admin_ssh[@]}" systemctl unmask bootc-fetch-apply-updates.timer
"${admin_ssh[@]}" systemctl start bootc-fetch-apply-updates.timer

echo "VM update/rollback validation passed: v1 -> v2 -> v1 with Docker data and enforcing SELinux preserved"
