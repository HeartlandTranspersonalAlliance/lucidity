#!/usr/bin/env bash
set -Eeuo pipefail

role=${1:-worker}
case "${role}" in
    benchmark-base|controller|worker) ;;
    *)
        echo "unsupported role '${role}'; expected benchmark-base, controller, or worker" >&2
        exit 2
        ;;
esac

if [[ -n ${CONTAINER_ENGINE:-} ]]; then
    engine=${CONTAINER_ENGINE}
elif command -v podman >/dev/null 2>&1; then
    engine=podman
elif command -v docker >/dev/null 2>&1; then
    engine=docker
else
    echo "podman or docker is required" >&2
    exit 1
fi

case "${ARCH:-$(uname -m)}" in
    aarch64|arm64) arch=arm64 ;;
    x86_64|amd64) arch=amd64 ;;
    *) echo "unsupported architecture: ${ARCH:-$(uname -m)}" >&2; exit 2 ;;
esac

base_image=${BASE_IMAGE:-quay.io/almalinuxorg/almalinux-bootc:10}
image_name=${IMAGE_NAME:-localhost/coolify-bootc-${role}:dev}
image_version=${IMAGE_VERSION:-dev}

exec "${engine}" build \
    --pull \
    --platform "linux/${arch}" \
    --target "${role}" \
    --build-arg "BASE_IMAGE=${base_image}" \
    --build-arg "IMAGE_VERSION=${image_version}" \
    --tag "${image_name}" \
    --file Containerfile \
    .
