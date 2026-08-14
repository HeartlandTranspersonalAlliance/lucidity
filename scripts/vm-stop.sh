#!/usr/bin/env bash
set -Eeuo pipefail

vm_name=${VM_NAME:-coolify-worker-vm}

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }
if podman container exists "${vm_name}"; then
    podman stop --time 30 "${vm_name}"
else
    echo "VM is not running: ${vm_name}"
fi
