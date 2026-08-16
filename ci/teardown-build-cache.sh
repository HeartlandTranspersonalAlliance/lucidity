#!/usr/bin/env bash
set -Eeuo pipefail

case "${BUILD_CACHE_ENGINE:-docker}" in
    docker)
        docker logout ghcr.io || true
        docker buildx rm "${BUILDX_BUILDER_NAME:-lucidity-ci}" || true
        ;;
    podman)
        if [[ -n ${REGISTRY_AUTH_FILE:-} ]]; then
            sudo podman logout --authfile "${REGISTRY_AUTH_FILE}" ghcr.io || true
            if [[ -n ${RUNNER_TEMP:-} && ${REGISTRY_AUTH_FILE} == "${RUNNER_TEMP%/}/"* ]]; then
                sudo rm -f -- "${REGISTRY_AUTH_FILE}"
            fi
        fi
        ;;
    *)
        echo "unknown build cache engine: ${BUILD_CACHE_ENGINE}" >&2
        exit 2
        ;;
esac
