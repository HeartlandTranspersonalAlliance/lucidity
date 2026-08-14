#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root

role=${1:-worker}
[[ ${role} == worker ]] || { echo "unsupported VM role: ${role}" >&2; exit 2; }

base_disk=${VM_BASE_DISK:-${repo_root}/image-output/worker/coolify-worker-qcow2.qcow2}
vm_dir=${VM_DIR:-${repo_root}/image-output/vm}
vm_disk=${vm_dir}/coolify-worker-test.qcow2

for command in qemu-img ssh-keygen xorriso; do
    command -v "${command}" >/dev/null 2>&1 || { echo "${command} is required" >&2; exit 1; }
done
[[ -f ${base_disk} ]] || { echo "base disk not found: ${base_disk}" >&2; exit 1; }
[[ ! -e ${vm_disk} ]] || {
    echo "test VM already exists: ${vm_disk}; run make vm-clean-worker first" >&2
    exit 1
}

mkdir -p "${vm_dir}"
for identity in admin coolify; do
    if [[ ! -f ${vm_dir}/${identity} ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "coolify-local-${identity}" -f "${vm_dir}/${identity}"
    fi
done

admin_key=$(<"${vm_dir}/admin.pub")
coolify_key=$(<"${vm_dir}/coolify.pub")

cat > "${vm_dir}/user-data" <<EOF
#cloud-config
hostname: coolify-worker-test
manage_etc_hosts: true
disable_root: false
ssh_pwauth: false
# bootc owns root filesystem growth; cloud-init cannot resize composefs.
resize_rootfs: false
users:
  - default
  - name: root
    lock_passwd: true
    ssh_authorized_keys:
      - ${admin_key}
write_files:
  - path: /etc/coolify-worker/authorized_keys
    owner: root:root
    permissions: '0600'
    content: |
      ${coolify_key}
EOF

cat > "${vm_dir}/meta-data" <<EOF
instance-id: coolify-worker-local-1
local-hostname: coolify-worker-test
EOF

(
    cd "${vm_dir}"
    xorriso -as mkisofs -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
)

relative_base=$(realpath --relative-to="${vm_dir}" "${base_disk}")
(
    cd "${vm_dir}"
    qemu-img create -q -f qcow2 -F qcow2 -b "${relative_base}" "$(basename "${vm_disk}")"
)

echo "Local worker VM initialized in ${vm_dir}"
echo "Admin identity: ${vm_dir}/admin"
echo "Coolify identity: ${vm_dir}/coolify"
