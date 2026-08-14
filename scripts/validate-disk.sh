#!/usr/bin/env bash
set -Eeuo pipefail

artifact=${1:-}
[[ -n ${artifact} ]] || { echo "usage: validate-disk.sh ARTIFACT" >&2; exit 2; }
[[ -f ${artifact} ]] || { echo "artifact not found: ${artifact}" >&2; exit 1; }
command -v qemu-img >/dev/null 2>&1 || { echo "qemu-img is required" >&2; exit 1; }

case "${artifact}" in
    *.qcow2) expected_format=qcow2 ;;
    *.ami|*.raw) expected_format=raw ;;
    *) echo "unrecognized disk artifact extension: ${artifact}" >&2; exit 2 ;;
esac

info=$(qemu-img info --output=json "${artifact}")
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

qemu-img check "${artifact}"
echo "disk validation passed: ${artifact} (${format}, ${virtual_size} bytes virtual)"
