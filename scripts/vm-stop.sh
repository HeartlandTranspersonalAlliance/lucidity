#!/usr/bin/env bash
set -Eeuo pipefail

role=${1:-worker}
case "${role}" in
    controller|worker) ;;
    *) echo "unsupported VM role '${role}'; expected controller or worker" >&2; exit 2 ;;
esac

vm_name=${VM_NAME:-coolify-${role}-vm}
container_engine=${CONTAINER_ENGINE:-podman}

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
if "${container_engine}" container inspect "${vm_name}" >/dev/null 2>&1; then
    "${container_engine}" stop --timeout 30 "${vm_name}"
else
    echo "VM is not running: ${vm_name}"
fi
