#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=${LUCIDITY_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly repo_root
# shellcheck disable=SC1091
source "${repo_root}/image/image-builder.env"

role=${1:-worker}
case "${role}" in
    controller)
        default_vm_dir=${repo_root}/image-output/vm-controller
        default_registry_port=5001
        ;;
    worker)
        default_vm_dir=${repo_root}/image-output/vm
        default_registry_port=5000
        ;;
    *) echo "unsupported VM role '${role}'; expected controller or worker" >&2; exit 2 ;;
esac

base_disk=${VM_BASE_DISK:-${repo_root}/image-output/${role}/coolify-${role}-qcow2.qcow2}
vm_dir=${VM_DIR:-${default_vm_dir}}
vm_disk=${vm_dir}/coolify-${role}-test.qcow2
output_root=$(dirname "${vm_dir}")
container_engine=${CONTAINER_ENGINE:-}
tool_image=${VM_TOOL_IMAGE:-${IMAGE_BUILDER_IMAGE}}
registry_host=${VM_REGISTRY_HOST:-10.0.2.2:${default_registry_port}}

command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is required" >&2; exit 1; }
if ! command -v qemu-img >/dev/null 2>&1 || ! command -v xorriso >/dev/null 2>&1; then
    [[ -n ${container_engine} ]] || { echo "qemu-img and xorriso are required, or set CONTAINER_ENGINE" >&2; exit 1; }
    command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
fi
[[ -f ${base_disk} ]] || { echo "base disk not found: ${base_disk}" >&2; exit 1; }
[[ ${registry_host} =~ ^[[:alnum:].:-]+$ ]] || { echo "VM_REGISTRY_HOST contains invalid characters" >&2; exit 2; }
[[ ! -e ${vm_disk} ]] || {
    echo "test VM already exists: ${vm_disk}; run make vm-clean-${role} first" >&2
    exit 1
}

mkdir -p "${vm_dir}"
output_root=$(realpath "${output_root}")
vm_dir=$(realpath "${vm_dir}")
vm_subdir=$(realpath --relative-to="${output_root}" "${vm_dir}")
[[ ${vm_subdir} != ../* ]] || { echo "VM_DIR must be inside ${output_root}" >&2; exit 2; }

identities=(admin)
if [[ ${role} == worker ]]; then
    identities+=(coolify)
fi
for identity in "${identities[@]}"; do
    if [[ ! -f ${vm_dir}/${identity} ]]; then
        ssh-keygen -q -t ed25519 -N '' -C "coolify-local-${identity}" -f "${vm_dir}/${identity}"
    fi
done

admin_key=$(<"${vm_dir}/admin.pub")
if [[ ${role} == worker ]]; then
    coolify_key=$(<"${vm_dir}/coolify.pub")
fi

cloud_init_package=$(nix build --no-link --print-out-paths "${repo_root}#cloud-init-${role}")
cloud_init_generator=${cloud_init_package}/bin/lucidity-cloud-init-${role}
if [[ ${role} == controller ]]; then
    ADMIN_SSH_PUBLIC_KEY=${admin_key} \
        "${cloud_init_generator}" user-data "${registry_host}" >"${vm_dir}/user-data"
else
    ADMIN_SSH_PUBLIC_KEY=${admin_key} \
        COOLIFY_WORKER_SSH_PUBLIC_KEY=${coolify_key} \
        "${cloud_init_generator}" user-data "${registry_host}" >"${vm_dir}/user-data"
fi
chmod 0600 "${vm_dir}/user-data"
"${cloud_init_generator}" meta-data >"${vm_dir}/meta-data"

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
        --env "VM_DISK=coolify-${role}-test.qcow2" \
        --entrypoint /bin/bash \
        "${tool_image}" \
        -Eeuo pipefail -c 'cd "/images/${VM_SUBDIR}"; qemu-img create -q -f qcow2 -F qcow2 -b "${RELATIVE_BASE}" "${VM_DISK}"'
fi

echo "Local ${role} VM initialized in ${vm_dir}"
echo "Admin identity: ${vm_dir}/admin"
if [[ ${role} == worker ]]; then
    echo "Coolify identity: ${vm_dir}/coolify"
fi
