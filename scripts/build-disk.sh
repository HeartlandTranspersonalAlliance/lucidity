#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
# The path is derived from this script's canonical repository location.
# shellcheck disable=SC1091
source "${repo_root}/image/image-builder.env"

role=${1:-worker}
image_type=${2:-qcow2}

case "${role}" in
    worker) ;;
    *) echo "unsupported role '${role}'; controller image is not implemented" >&2; exit 2 ;;
esac

case "${image_type}" in
    qcow2|ami) ;;
    *) echo "unsupported image type '${image_type}'; expected qcow2 or ami" >&2; exit 2 ;;
esac

command -v podman >/dev/null 2>&1 || { echo "podman is required" >&2; exit 1; }

if [[ $(id -u) -eq 0 ]]; then
    privileged_engine=(podman)
elif command -v run0 >/dev/null 2>&1; then
    privileged_engine=(run0 podman)
else
    echo "run0 is required for privileged image builds (or run this script as root)" >&2
    exit 1
fi

source_image=${IMAGE_NAME:-localhost/coolify-bootc-${role}:dev}
output_dir=${IMAGE_OUTPUT_DIR:-${repo_root}/image-output/${role}}
output_name=${IMAGE_OUTPUT_NAME:-coolify-${role}-${image_type}}

podman image exists "${source_image}" || {
    echo "source image not found: ${source_image}; run make build-${role} first" >&2
    exit 1
}

source_id=$(podman image inspect --format '{{.Id}}' "${source_image}")
source_arch=$(podman image inspect --format '{{.Architecture}}' "${source_image}")
case "${source_arch}" in
    amd64) builder_arch=x86_64 ;;
    arm64) builder_arch=aarch64 ;;
    *) echo "unsupported source image architecture: ${source_arch}" >&2; exit 2 ;;
esac

privileged_id=""
if "${privileged_engine[@]}" image exists "${source_image}"; then
    privileged_id=$("${privileged_engine[@]}" image inspect --format '{{.Id}}' "${source_image}")
fi

if [[ ${source_id} != "${privileged_id}" ]]; then
    echo "Copying ${source_image} into privileged Podman storage"
    podman save "${source_image}" | "${privileged_engine[@]}" load
fi

mkdir -p "${output_dir}"
output_dir=$(realpath "${output_dir}")

echo "Building ${image_type} artifact from ${source_image} (${source_arch})"
"${privileged_engine[@]}" run \
    --rm \
    --privileged \
    --security-opt label=disable \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    --volume "${output_dir}:/output" \
    "${IMAGE_BUILDER_IMAGE}" \
    --output-dir /output \
    build \
    --arch "${builder_arch}" \
    --bootc-ref "${source_image}" \
    --bootc-default-fs "${IMAGE_ROOT_FS}" \
    --image-size "${IMAGE_SIZE_GIB} GiB" \
    --output-name "${output_name}" \
    --progress verbose \
    --with-buildlog \
    --with-manifest \
    --with-sbom \
    "${image_type}"

echo "Disk image artifacts written to ${output_dir}"
