#!/usr/bin/env bash
set -Eeuo pipefail

vm_name=${VM_NAME:-coolify-worker-vm}
container_engine=${CONTAINER_ENGINE:-podman}

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
if "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
    "${container_engine}" stop --time 30 "${vm_name}"
else
    echo "VM is not running: ${vm_name}"
fi
