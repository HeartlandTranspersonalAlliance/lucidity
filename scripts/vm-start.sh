#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
# shellcheck disable=SC1091
source "${repo_root}/image/image-builder.env"

vm_dir=${VM_DIR:-${repo_root}/image-output/vm}
output_root=$(dirname "${vm_dir}")
vm_name=${VM_NAME:-coolify-worker-vm}
ssh_port=${VM_SSH_PORT:-2222}
cpus=${VM_CPUS:-2}
memory_mb=${VM_MEMORY_MB:-4096}

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }
[[ -e /dev/kvm ]] || { echo "/dev/kvm is required" >&2; exit 1; }
[[ -f ${vm_dir}/coolify-worker-test.qcow2 ]] || { echo "run make vm-init-worker first" >&2; exit 1; }
[[ -f ${vm_dir}/seed.iso ]] || { echo "cloud-init seed is missing" >&2; exit 1; }
[[ ${ssh_port} =~ ^[0-9]+$ ]] || { echo "VM_SSH_PORT must be numeric" >&2; exit 2; }

if podman container exists "${vm_name}"; then
    echo "VM container already exists: ${vm_name}" >&2
    exit 1
fi

podman run --detach --rm \
    --name "${vm_name}" \
    --network host \
    --device /dev/kvm \
    --security-opt label=disable \
    --volume "${output_root}:/images" \
    --env "VM_SSH_PORT=${ssh_port}" \
    --env "VM_CPUS=${cpus}" \
    --env "VM_MEMORY_MB=${memory_mb}" \
    --entrypoint /bin/bash \
    "${IMAGE_BUILDER_IMAGE}" \
    -Eeuo pipefail -c '
        vars=/images/vm/OVMF_VARS.fd
        if [[ ! -f ${vars} ]]; then
            cp /usr/share/edk2/ovmf/OVMF_VARS.fd "${vars}"
        fi
        exec qemu-system-x86_64 \
            -name coolify-worker-test \
            -machine q35,accel=kvm \
            -cpu host \
            -smp "${VM_CPUS}" \
            -m "${VM_MEMORY_MB}" \
            -nodefaults \
            -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
            -drive if=pflash,format=raw,file="${vars}" \
            -drive if=virtio,format=qcow2,file=/images/vm/coolify-worker-test.qcow2 \
            -drive if=virtio,media=cdrom,readonly=on,file=/images/vm/seed.iso \
            -device virtio-net-pci,netdev=net0 \
            -netdev user,id=net0,hostfwd=tcp:127.0.0.1:"${VM_SSH_PORT}"-:22 \
            -device virtio-rng-pci \
            -display none \
            -monitor none \
            -serial stdio
    '

echo "VM started as ${vm_name}; SSH will become available on 127.0.0.1:${ssh_port}"
echo "Console: podman logs -f ${vm_name}"
