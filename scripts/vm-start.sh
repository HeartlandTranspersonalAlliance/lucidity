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
        default_ssh_port=2223
        ;;
    worker)
        default_vm_dir=${repo_root}/image-output/vm
        default_ssh_port=2222
        ;;
    *) echo "unsupported VM role '${role}'; expected controller or worker" >&2; exit 2 ;;
esac

vm_dir=${VM_DIR:-${default_vm_dir}}
output_root=$(realpath "$(dirname "${vm_dir}")")
vm_dir=$(realpath "${vm_dir}")
vm_subdir=$(realpath --relative-to="${output_root}" "${vm_dir}")
vm_name=${VM_NAME:-coolify-${role}-vm}
ssh_port=${VM_SSH_PORT:-${default_ssh_port}}
host_forward_port=${VM_HOST_FORWARD_PORT:-0}
guest_forward_port=${VM_GUEST_FORWARD_PORT:-0}
cpus=${VM_CPUS:-2}
memory_mb=${VM_MEMORY_MB:-4096}
container_engine=${CONTAINER_ENGINE:-podman}
tool_image=${VM_TOOL_IMAGE:-${IMAGE_BUILDER_IMAGE}}

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
[[ -f ${vm_dir}/coolify-${role}-test.qcow2 ]] || { echo "run make vm-init-${role} first" >&2; exit 1; }
[[ -f ${vm_dir}/seed.iso ]] || { echo "cloud-init seed is missing" >&2; exit 1; }
for port_name in ssh_port host_forward_port guest_forward_port; do
    port_value=${!port_name}
    [[ ${port_value} =~ ^[0-9]+$ && ${port_value} -le 65535 ]] || {
        echo "${port_name^^} must be an integer from 0 through 65535" >&2
        exit 2
    }
done
[[ ${ssh_port} -gt 0 ]] || { echo "VM_SSH_PORT must be greater than zero" >&2; exit 2; }
if [[ ${host_forward_port} -eq 0 || ${guest_forward_port} -eq 0 ]]; then
    [[ ${host_forward_port} -eq 0 && ${guest_forward_port} -eq 0 ]] || {
        echo "VM_HOST_FORWARD_PORT and VM_GUEST_FORWARD_PORT must both be set" >&2
        exit 2
    }
fi
[[ ${vm_subdir} != ../* ]] || { echo "VM_DIR must be inside ${output_root}" >&2; exit 2; }

if "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
    echo "VM container already exists: ${vm_name}" >&2
    exit 1
fi

run_options=(
    --detach
    --rm
    --name "${vm_name}"
    --network host
    --volume "${output_root}:/images"
)

accel=${VM_ACCEL:-auto}
if [[ ${accel} == auto ]]; then
    if [[ -r /dev/kvm && -w /dev/kvm ]]; then
        accel=kvm
    else
        accel=tcg
    fi
fi
case "${accel}" in
    kvm)
        [[ -r /dev/kvm && -w /dev/kvm ]] || { echo "/dev/kvm is not accessible" >&2; exit 1; }
        run_options+=(--device /dev/kvm)
        cpu_model=host
        ;;
    tcg) cpu_model=max ;;
    *) echo "VM_ACCEL must be auto, kvm, or tcg" >&2; exit 2 ;;
esac

if command -v getenforce >/dev/null 2>&1 && [[ $(getenforce) != Disabled ]]; then
    run_options+=(--security-opt label=disable)
fi

# The quoted script expands the explicitly passed VM environment inside the tooling container.
# shellcheck disable=SC2016
"${container_engine}" run "${run_options[@]}" \
    --env "VM_SSH_PORT=${ssh_port}" \
    --env "VM_HOST_FORWARD_PORT=${host_forward_port}" \
    --env "VM_GUEST_FORWARD_PORT=${guest_forward_port}" \
    --env "VM_CPUS=${cpus}" \
    --env "VM_MEMORY_MB=${memory_mb}" \
    --env "VM_ACCEL=${accel}" \
    --env "VM_CPU_MODEL=${cpu_model}" \
    --env "VM_SUBDIR=${vm_subdir}" \
    --env "VM_ROLE=${role}" \
    --entrypoint /bin/bash \
    "${tool_image}" \
    -Eeuo pipefail -c '
        vm_root=/images/${VM_SUBDIR}
        vars=${vm_root}/OVMF_VARS.fd
        netdev=user,id=net0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22
        if ((VM_HOST_FORWARD_PORT > 0)); then
            netdev+=,hostfwd=tcp:127.0.0.1:${VM_HOST_FORWARD_PORT}-:${VM_GUEST_FORWARD_PORT}
        fi
        if [[ ! -f ${vars} ]]; then
            cp /usr/share/edk2/ovmf/OVMF_VARS.fd "${vars}"
        fi
        exec qemu-system-x86_64 \
            -name "coolify-${VM_ROLE}-test" \
            -machine q35,accel="${VM_ACCEL}" \
            -cpu "${VM_CPU_MODEL}" \
            -smp "${VM_CPUS}" \
            -m "${VM_MEMORY_MB}" \
            -nodefaults \
            -drive if=pflash,format=raw,readonly=on,file=/usr/share/edk2/ovmf/OVMF_CODE.fd \
            -drive if=pflash,format=raw,file="${vars}" \
            -drive if=virtio,format=qcow2,file="${vm_root}/coolify-${VM_ROLE}-test.qcow2" \
            -drive if=virtio,media=cdrom,readonly=on,file="${vm_root}/seed.iso" \
            -device virtio-net-pci,netdev=net0 \
            -netdev "${netdev}" \
            -device virtio-rng-pci \
            -display none \
            -monitor none \
            -serial stdio
    '

echo "VM started as ${vm_name} with ${accel}; SSH will become available on 127.0.0.1:${ssh_port}"
if ((host_forward_port > 0)); then
    echo "Guest TCP ${guest_forward_port} will be available on 127.0.0.1:${host_forward_port}"
fi
echo "Console: ${container_engine} logs -f ${vm_name}"
