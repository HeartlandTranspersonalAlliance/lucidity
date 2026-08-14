#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
# shellcheck disable=SC1091
source "${repo_root}/image/image-builder.env"

role=${1:-worker}
[[ ${role} == worker ]] || { echo "unsupported VM role: ${role}" >&2; exit 2; }

base_disk=${VM_BASE_DISK:-${repo_root}/image-output/worker/coolify-worker-qcow2.qcow2}
vm_dir=${VM_DIR:-${repo_root}/image-output/vm}
vm_disk=${vm_dir}/coolify-worker-test.qcow2
output_root=$(dirname "${vm_dir}")
container_engine=${CONTAINER_ENGINE:-}
tool_image=${VM_TOOL_IMAGE:-${IMAGE_BUILDER_IMAGE}}

command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required" >&2; exit 1; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v xorriso >/dev/null 2>&1; then
    [[ -n ${container_engine} ]] || { echo "qemu-img and xorriso are required, or set CONTAINER_ENGINE" >&2; exit 1; }
    command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
fi
[[ -f ${base_disk} ]] || { echo "base disk not found: ${base_disk}" >&2; exit 1; }
[[ ! -e ${vm_disk} ]] || {
    echo "test VM already exists: ${vm_disk}; run make vm-clean-worker first" >&2
    exit 1
}

mkdir -p "${vm_dir}"
output_root=$(realpath "${output_root}")
vm_dir=$(realpath "${vm_dir}")
vm_subdir=$(realpath --relative-to="${output_root}" "${vm_dir}")
[[ ${vm_subdir} != ../* ]] || { echo "VM_DIR must be inside ${output_root}" >&2; exit 2; }

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

if command -v xorriso >/dev/null 2>&1; then
    (
        cd "${vm_dir}"
        xorriso -as mkisofs -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data
    )
else
    # VM_SUBDIR is expanded inside the tooling container.
    # shellcheck disable=SC2016
    "${container_engine}" run --rm \
        --volume "${output_root}:/images" \
        --env "VM_SUBDIR=${vm_subdir}" \
        --entrypoint /bin/bash \
        "${tool_image}" \
        -Eeuo pipefail -c 'cd "/images/${VM_SUBDIR}"; xorriso -as mkisofs -quiet -output seed.iso -volid cidata -joliet -rock user-data meta-data'
fi

relative_base=$(realpath --relative-to="${vm_dir}" "${base_disk}")
if command -v qemu-img >/dev/null 2>&1; then
    (
        cd "${vm_dir}"
        qemu-img create -q -f qcow2 -F qcow2 -b "${relative_base}" "$(basename "${vm_disk}")"
    )
else
    base_from_output=$(realpath --relative-to="${output_root}" "${base_disk}")
    [[ ${base_from_output} != ../* ]] || { echo "VM_BASE_DISK must be inside ${output_root} for containerized tools" >&2; exit 2; }
    # VM_SUBDIR and RELATIVE_BASE are expanded inside the tooling container.
    # shellcheck disable=SC2016
    "${container_engine}" run --rm \
        --volume "${output_root}:/images" \
        --env "VM_SUBDIR=${vm_subdir}" \
        --env "RELATIVE_BASE=${relative_base}" \
        --entrypoint /bin/bash \
        "${tool_image}" \
        -Eeuo pipefail -c 'cd "/images/${VM_SUBDIR}"; qemu-img create -q -f qcow2 -F qcow2 -b "${RELATIVE_BASE}" coolify-worker-test.qcow2'
fi

echo "Local worker VM initialized in ${vm_dir}"
echo "Admin identity: ${vm_dir}/admin"
echo "Coolify identity: ${vm_dir}/coolify"
