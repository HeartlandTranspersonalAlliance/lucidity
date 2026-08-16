#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly repo_root
# shellcheck disable=SC1091
source "${repo_root}/ci/images.env"

action=${1:-}
role=${2:-worker}
case "${role}" in
    controller) default_registry_port=5001 ;;
    worker) default_registry_port=5000 ;;
    *) echo "unsupported VM role '${role}'; expected controller or worker" >&2; exit 2 ;;
esac
container_engine=${CONTAINER_ENGINE:-podman}
registry_name=${VM_REGISTRY_NAME:-coolify-${role}-registry}
registry_port=${VM_REGISTRY_PORT:-${default_registry_port}}
base_image=${VM_BASE_IMAGE:-localhost/coolify-bootc-${role}:lifecycle-v1}
update_image=${VM_UPDATE_IMAGE:-localhost/coolify-bootc-${role}:lifecycle-v2}
repository=${VM_UPDATE_REPOSITORY:-coolify-bootc-${role}}
registry_ref=localhost:${registry_port}/${repository}

command -v "${container_engine}" >/dev/null 2>&1 || { echo "${container_engine} is required" >&2; exit 1; }
[[ ${registry_port} =~ ^[0-9]+$ ]] || { echo "VM_REGISTRY_PORT must be numeric" >&2; exit 2; }
[[ ${repository} =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || { echo "VM_UPDATE_REPOSITORY is invalid" >&2; exit 2; }

case "${action}" in
    start)
        for image in "${base_image}" "${update_image}"; do
            "${container_engine}" image inspect "${image}" >/dev/null 2>&1 || {
                echo "lifecycle image not found: ${image}" >&2
                exit 1
            }
        done
        if "${container_engine}" container inspect "${registry_name}" >/dev/null 2>&1; then
            echo "test registry already exists: ${registry_name}" >&2
            exit 1
        fi
        "${container_engine}" run --detach --rm \
            --name "${registry_name}" \
            --network host \
            --env "REGISTRY_HTTP_ADDR=127.0.0.1:${registry_port}" \
            "${REGISTRY_IMAGE}" >/dev/null

        ready=false
        for _attempt in {1..50}; do
            if (exec 3<>"/dev/tcp/127.0.0.1/${registry_port}") 2>/dev/null; then
                exec 3>&-
                exec 3<&-
                ready=true
                break
            fi
            sleep 0.1
        done
        [[ ${ready} == true ]] || { echo "test registry did not become ready" >&2; exit 1; }

        for version in v1 v2; do
            if [[ ${version} == v1 ]]; then
                image=${base_image}
            else
                image=${update_image}
            fi
            "${container_engine}" tag "${image}" "${registry_ref}:lifecycle-${version}"
            if [[ ${container_engine} == podman ]]; then
                "${container_engine}" push --tls-verify=false "${registry_ref}:lifecycle-${version}"
            else
                "${container_engine}" push "${registry_ref}:lifecycle-${version}"
            fi
        done
        echo "Lifecycle images published to ${registry_ref}"
        ;;
    stop)
        if "${container_engine}" container inspect "${registry_name}" >/dev/null 2>&1; then
            "${container_engine}" stop --timeout 10 "${registry_name}"
        else
            echo "Test registry is not running: ${registry_name}"
        fi
        ;;
    *)
        echo "usage: $0 start|stop [controller|worker]" >&2
        exit 2
        ;;
esac
