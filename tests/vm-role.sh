#!/usr/bin/env bash
set -Eeuo pipefail

role=${1:-}
[[ $role == controller || $role == worker ]] || {
    echo "usage: vm-role.sh controller|worker" >&2
    exit 2
}

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
image=${IMAGE_NAME:-localhost/lucidity-${role}:vm-test}
engine=${CONTAINER_ENGINE:-podman}
export IMAGE_NAME=$image

command -v "$engine" >/dev/null 2>&1 || {
    echo "container engine is not available: $engine" >&2
    exit 1
}

nix run "$repo_root#lucidity" -- build "$role"

"$engine" image inspect "$image" >/dev/null
"$engine" run --rm --privileged --entrypoint bootc "$image" container lint

echo "The generated ${role} bootc image passed container validation."
echo "Set LUCIDITY_FULL_GUEST_TEST=1 to run the disk and KVM lifecycle gate in CI."
if [[ ${LUCIDITY_FULL_GUEST_TEST:-0} == 1 ]]; then
    IMAGE_NAME=$image "$repo_root/scripts/build-disk.sh" "$role" qcow2
    VM_BASE_DISK="$repo_root/image-output/$role/coolify-$role-qcow2.qcow2" \
        "$repo_root/scripts/vm-init.sh" "$role"
    "$repo_root/scripts/vm-start.sh" "$role"
    trap '"$repo_root/scripts/vm-stop.sh" "$role" || true' EXIT
    "$repo_root/scripts/vm-validate.sh" "$role"
fi
