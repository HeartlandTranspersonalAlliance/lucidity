#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=${LUCIDITY_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly repo_root
# shellcheck disable=SC1091
source "${repo_root}/image/image-builder.env"

artifact=${1:-}
[[ -n ${artifact} ]] || { echo "usage: validate-disk.sh ARTIFACT" >&2; exit 2; }
[[ -f ${artifact} ]] || { echo "artifact not found: ${artifact}" >&2; exit 1; }

container_engine=${CONTAINER_ENGINE:-}
tool_image=${VM_TOOL_IMAGE:-${IMAGE_BUILDER_IMAGE}}

qemu_img() {
    if command -v qemu-img >/dev/null 2>&1; then
        qemu-img "$@" "${artifact}"
        return
    fi
    [[ -n ${container_engine} ]] || { echo "qemu-img or CONTAINER_ENGINE is required" >&2; exit 1; }
    command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
    local artifact_dir artifact_name
    artifact_dir=$(dirname "$(realpath "${artifact}")")
    artifact_name=$(basename "${artifact}")
    "${container_engine}" run --rm \
        --volume "${artifact_dir}:/artifacts" \
        --entrypoint /usr/bin/qemu-img \
        "${tool_image}" "$@" "/artifacts/${artifact_name}"
}

case "${artifact}" in
    *.qcow2) expected_format=qcow2 ;;
    *.ami|*.raw) expected_format=raw ;;
    *) echo "unrecognized disk artifact extension: ${artifact}" >&2; exit 2 ;;
esac

info=$(qemu_img info --output=json)
format=$(jq -r '.format' <<< "${info}")
virtual_size=$(jq -r '.["virtual-size"]' <<< "${info}")

[[ ${format} == "${expected_format}" ]] || {
    echo "expected ${expected_format} but qemu-img detected ${format}" >&2
    exit 1
}
((virtual_size >= 8 * 1024 * 1024 * 1024)) || {
    echo "virtual disk is unexpectedly small: ${virtual_size} bytes" >&2
    exit 1
}

if [[ ${format} == qcow2 ]]; then
    qemu_img check
else
    echo "qemu-img consistency checks are unsupported for raw images; format and size checks passed"
fi
echo "disk validation passed: ${artifact} (${format}, ${virtual_size} bytes virtual)"
