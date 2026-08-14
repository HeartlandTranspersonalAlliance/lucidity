#!/usr/bin/env bash
set -Eeuo pipefail

image=${1:-${IMAGE_NAME:-localhost/coolify-bootc-worker:dev}}

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

role=$("${engine}" image inspect --format '{{ index .Config.Labels "io.coolify-aws.role" }}' "${image}")
case "${role}" in
    controller|worker) ;;
    *) echo "unexpected image role: ${role:-<unset>}" >&2; exit 1 ;;
esac

"${engine}" run --rm "${image}" bootc container lint
"${engine}" run --rm --entrypoint /bin/bash "${image}" -Eeuo pipefail -c '
    docker --version
    docker compose version
    rpm -q bootc rpm-ostree openssh-server container-selinux cloud-init NetworkManager
    jq -e '\''.["data-root"] == "/var/lib/docker"'\'' /etc/docker/daemon.json >/dev/null
    ssh-keygen -A
    sshd -t
'

if [[ ${role} == controller ]]; then
    "${engine}" run --rm --entrypoint /bin/bash "${image}" -Eeuo pipefail -c '
        systemctl is-enabled --quiet nix.mount
        test -d /nix
        grep -Fq "What=/var/lib/nix" /usr/lib/systemd/system/nix.mount
        grep -Fq "Where=/nix" /usr/lib/systemd/system/nix.mount
        grep -Fq "Before=nix.mount" /usr/lib/systemd/system/nix-storage.service
    '
fi

echo "image validation passed: ${image}"
