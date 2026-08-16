#!/usr/bin/env bash
set -Eeuo pipefail

cache_scope=${1:-}
if [[ ! ${cache_scope} =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
    echo "cache scope must contain only lowercase letters, digits, dots, underscores, and hyphens" >&2
    exit 2
fi

: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_ACTOR:?GITHUB_ACTOR is required}"
: "${GITHUB_TOKEN:?GITHUB_TOKEN is required}"
: "${GITHUB_ENV:?GITHUB_ENV is required}"

cache_registry=${GHCR_CACHE_REGISTRY:-ghcr.io}
cache_engine=${GHCR_CACHE_ENGINE:-docker}
cache_repository=${GITHUB_REPOSITORY,,}-build-cache
cache_from=""
cache_to=""
builder_name=""
registry_auth_file=""

case "${cache_engine}" in
    docker)
        cache_ref=${cache_registry}/${cache_repository}:${cache_scope}
        builder_name=${BUILDX_BUILDER_NAME:-lucidity-ci}
        printf '%s' "${GITHUB_TOKEN}" | \
            docker login "${cache_registry}" --username "${GITHUB_ACTOR}" --password-stdin
        if ! docker buildx inspect "${builder_name}" >/dev/null 2>&1; then
            docker buildx create \
                --driver docker-container \
                --name "${builder_name}" \
                --use >/dev/null
        else
            docker buildx use "${builder_name}"
        fi
        docker buildx inspect --bootstrap "${builder_name}" >/dev/null
        cache_from=${cache_ref}
        ;;
    podman)
        : "${RUNNER_TEMP:?RUNNER_TEMP is required for Podman registry authentication}"
        cache_ref=${cache_registry}/${cache_repository}-${cache_scope}
        registry_auth_file=${RUNNER_TEMP%/}/ghcr-${cache_scope}-auth.json
        printf '%s' "${GITHUB_TOKEN}" | \
            sudo podman login \
                --authfile "${registry_auth_file}" \
                "${cache_registry}" \
                --username "${GITHUB_ACTOR}" \
                --password-stdin
        if sudo skopeo list-tags \
            --authfile "${registry_auth_file}" \
            "docker://${cache_ref}" >/dev/null 2>&1; then
            cache_from=${cache_ref}
        else
            echo "No existing ${cache_scope} Podman cache; this run will seed it"
        fi
        ;;
    *)
        echo "unsupported GHCR_CACHE_ENGINE '${cache_engine}'; expected docker or podman" >&2
        exit 2
        ;;
esac

if [[ ${GHCR_CACHE_WRITE:-false} == true ]]; then
    cache_to=${cache_ref}
fi

{
    printf 'BUILD_CACHE_ENGINE=%s\n' "${cache_engine}"
    printf 'BUILDX_BUILDER_NAME=%s\n' "${builder_name}"
    printf 'BUILD_CACHE_FROM=%s\n' "${cache_from}"
    printf 'BUILD_CACHE_TO=%s\n' "${cache_to}"
    printf 'GHCR_CACHE_REF=%s\n' "${cache_ref}"
    printf 'REGISTRY_AUTH_FILE=%s\n' "${registry_auth_file}"
} >> "${GITHUB_ENV}"

echo "Configured ${cache_ref} as the ${cache_scope} registry build cache"
