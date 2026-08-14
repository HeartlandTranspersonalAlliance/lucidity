#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root

vm_dir=${VM_DIR:-${repo_root}/image-output/vm}
vm_name=${VM_NAME:-coolify-worker-vm}
ssh_port=${VM_SSH_PORT:-2222}
admin_identity=${vm_dir}/admin
coolify_identity=${vm_dir}/coolify

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }
command -v ssh >/dev/null 2>&1 || { echo "ssh is required" >&2; exit 1; }
[[ -f ${admin_identity} && -f ${coolify_identity} ]] || { echo "run make vm-init-worker first" >&2; exit 1; }
podman container exists "${vm_name}" || { echo "VM is not running; run make vm-start-worker" >&2; exit 1; }

ssh_base=(
    ssh
    -o BatchMode=yes
    -o ConnectTimeout=3
    -o IdentitiesOnly=yes
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -p "${ssh_port}"
)

wait_for_ssh() {
    local identity=$1
    for _ in {1..120}; do
        if "${ssh_base[@]}" -i "${identity}" root@127.0.0.1 true >/dev/null 2>&1; then
            return 0
        fi
        if ! podman container exists "${vm_name}"; then
            echo "VM exited before SSH became available" >&2
            podman logs "${vm_name}" >&2 || true
            return 1
        fi
        sleep 2
    done
    echo "timed out waiting for VM SSH" >&2
    return 1
}

admin_ssh=("${ssh_base[@]}" -i "${admin_identity}" root@127.0.0.1)
coolify_ssh=("${ssh_base[@]}" -i "${coolify_identity}" root@127.0.0.1)

wait_for_ssh "${admin_identity}"
if ! cloud_status=$("${admin_ssh[@]}" cloud-init status --wait); then
    printf '%s\n' "${cloud_status}" >&2
    "${admin_ssh[@]}" cloud-init status --long >&2 || true
    exit 1
fi
printf '%s\n' "${cloud_status}"
"${coolify_ssh[@]}" true

"${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
systemctl is-active --quiet docker.service
systemctl is-active --quiet sshd.service
systemctl is-active --quiet coolify-worker-authorized-keys.service
systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
[[ $(getenforce) == Enforcing ]]
docker info --format '{{json .ServerVersion}}' >/dev/null
docker compose version >/dev/null
bootc status >/dev/null
REMOTE

marker="coolify-worker-persistence-$(date -u +%s)"
"${admin_ssh[@]}" bash -Eeuo pipefail -s -- "${marker}" <<'REMOTE'
marker=$1
docker volume create coolify-lifecycle-test >/dev/null
volume_path=$(docker volume inspect --format '{{ .Mountpoint }}' coolify-lifecycle-test)
printf '%s\n' "${marker}" > "${volume_path}/marker"
REMOTE

old_boot_id=$("${admin_ssh[@]}" cat /proc/sys/kernel/random/boot_id)
"${admin_ssh[@]}" systemctl reboot >/dev/null 2>&1 || true

new_boot_id=""
for _ in {1..120}; do
    candidate=$("${admin_ssh[@]}" cat /proc/sys/kernel/random/boot_id 2>/dev/null || true)
    if [[ -n ${candidate} && ${candidate} != "${old_boot_id}" ]]; then
        new_boot_id=${candidate}
        break
    fi
    if ! podman container exists "${vm_name}"; then
        echo "VM exited during reboot" >&2
        break
    fi
    sleep 2
done
[[ -n ${new_boot_id} ]] || { echo "VM did not return after reboot" >&2; exit 1; }

persisted=$("${admin_ssh[@]}" bash -Eeuo pipefail -s <<'REMOTE'
volume_path=$(docker volume inspect --format '{{ .Mountpoint }}' coolify-lifecycle-test)
cat "${volume_path}/marker"
REMOTE
)
[[ ${persisted} == "${marker}" ]] || { echo "Docker volume marker did not survive reboot" >&2; exit 1; }
"${admin_ssh[@]}" systemctl is-active --quiet docker.service
"${admin_ssh[@]}" systemctl is-enabled --quiet bootc-fetch-apply-updates.timer
"${coolify_ssh[@]}" true

echo "VM validation passed: cloud-init, both SSH identities, Docker, Compose, bootc, SELinux, unattended-update timer, and Docker volume persistence across reboot"
