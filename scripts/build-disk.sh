#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=${LUCIDITY_REPOSITORY_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}
readonly repo_root
# The path is derived from this script's canonical repository location.
# shellcheck disable=SC1091
source "${repo_root}/image/image-builder.env"

role=${1:-worker}
image_type=${2:-qcow2}

case "${role}" in
    controller|worker) ;;
    *) echo "unsupported role '${role}'; expected controller or worker" >&2; exit 2 ;;
esac

case "${image_type}" in
    qcow2|ami) ;;
    *) echo "unsupported image type '${image_type}'; expected qcow2 or ami" >&2; exit 2 ;;
esac

container_engine=${CONTAINER_ENGINE:-podman}
source_image=${IMAGE_NAME:-localhost/coolify-bootc-${role}:dev}
output_dir=${IMAGE_OUTPUT_DIR:-${repo_root}/image-output/${role}}
output_name=${IMAGE_OUTPUT_NAME:-coolify-${role}-${image_type}}
tool_image=${VM_TOOL_IMAGE:-${IMAGE_BUILDER_IMAGE}}

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
"${container_engine}" image inspect "${source_image}" >/dev/null 2>&1 || {
    echo "source image not found: ${source_image}; run make build-${role} first" >&2
    exit 1
}

source_arch=$("${container_engine}" image inspect --format '{{.Architecture}}' "${source_image}")
case "${source_arch}" in
    amd64) builder_arch=x86_64 ;;
    arm64) builder_arch=aarch64 ;;
    *) echo "unsupported source image architecture: ${source_arch}" >&2; exit 2 ;;
esac

mkdir -p "${output_dir}"
output_dir=$(realpath "${output_dir}")

if [[ ${container_engine} == docker ]]; then
    echo "Building ${image_type} artifact from ${source_image} (${source_arch}) in a privileged tooling container"
    docker_config=${DOCKER_CONFIG:-${HOME}/.docker}/config.json
    docker_run_args=(
        --rm
        --interactive
        --privileged
        --volume "${output_dir}:/output"
        --env "SOURCE_IMAGE=${source_image}"
        --env "BUILDER_ARCH=${builder_arch}"
        --env "IMAGE_TYPE=${image_type}"
        --env "IMAGE_ROOT_FS=${IMAGE_ROOT_FS}"
        --env "IMAGE_SIZE_GIB=${IMAGE_SIZE_GIB}"
        --env "OUTPUT_NAME=${output_name}"
        --entrypoint /bin/bash
    )
    if [[ -f ${docker_config} ]]; then
        # The pinned builder may need to resolve a private digest after loading it.
        # Mount Docker's short-lived auth file read-only; never copy or print it.
        docker_run_args+=(--volume "${docker_config}:/root/.docker/config.json:ro")
    fi
    # The quoted script expands the explicitly passed environment inside the tooling container.
    # shellcheck disable=SC2016
    "${container_engine}" save "${source_image}" | "${container_engine}" run \
        "${docker_run_args[@]}" \
        "${tool_image}" \
        -Eeuo pipefail -c '
            podman load
            image-builder --output-dir /output build \
                --arch "${BUILDER_ARCH}" \
                --bootc-ref "${SOURCE_IMAGE}" \
                --bootc-default-fs "${IMAGE_ROOT_FS}" \
                --image-size "${IMAGE_SIZE_GIB} GiB" \
                --output-name "${OUTPUT_NAME}" \
                --progress verbose \
                --with-buildlog \
                --with-manifest \
                --with-sbom \
                "${IMAGE_TYPE}"
        '
    echo "Disk image artifacts written to ${output_dir}"
    exit 0
fi

[[ ${container_engine} == podman ]] || { echo "unsupported container engine: ${container_engine}" >&2; exit 2; }
if [[ $(id -u) -eq 0 ]]; then
    privileged_engine=(podman)
elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
    privileged_engine=(sudo -n podman)
elif command -v run0 >/dev/null 2>&1; then
    privileged_engine=(run0 podman)
else
    echo "passwordless sudo or run0 is required for privileged image builds" >&2
    exit 1
fi

source_id=$(podman image inspect --format '{{.Id}}' "${source_image}")
privileged_id=""
if "${privileged_engine[@]}" image exists "${source_image}"; then
    privileged_id=$("${privileged_engine[@]}" image inspect --format '{{.Id}}' "${source_image}")
fi

if [[ ${source_id} != "${privileged_id}" ]]; then
    echo "Copying ${source_image} into privileged Podman storage"
    podman save "${source_image}" | "${privileged_engine[@]}" load
fi

echo "Building ${image_type} artifact from ${source_image} (${source_arch})"
"${privileged_engine[@]}" run \
    --rm \
    --privileged \
    --security-opt label=disable \
    --volume /var/lib/containers/storage:/var/lib/containers/storage \
    --volume "${output_dir}:/output" \
    "${tool_image}" \
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
