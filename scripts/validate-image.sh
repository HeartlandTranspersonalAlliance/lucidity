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
    benchmark-base|controller|worker) ;;
    *) echo "unexpected image role: ${role:-<unset>}" >&2; exit 1 ;;
esac

"${engine}" run --rm "${image}" bootc container lint
"${engine}" run --rm --entrypoint /bin/bash "${image}" -Eeuo pipefail -c '
    docker --version
    docker compose version
    docker-credential-ecr-login -v | grep -Eq "^Version:[[:space:]]+0.12.0$"
    rpm -q amazon-ssm-agent bootc rpm-ostree openssh-server container-selinux cloud-init NetworkManager policycoreutils selinux-policy-targeted
    systemctl is-enabled --quiet amazon-ssm-agent.service
    systemctl is-enabled --quiet coolify-bootc-ecr-auth.service
    grep -Eq "^SELINUX=enforcing$" /etc/selinux/config
    grep -Eq "^SELINUXTYPE=targeted$" /etc/selinux/config
    test -d /nix
    jq -e '\''.["data-root"] == "/var/lib/docker"'\'' /etc/docker/daemon.json >/dev/null
    ssh-keygen -A
    sshd -t
'

if [[ ${role} == controller ]]; then
    "${engine}" run --rm --entrypoint /bin/bash "${image}" -Eeuo pipefail -c '
        test -x /usr/bin/asm-exec
        test -x /usr/libexec/coolify-aws/aws-workload-credentials-provider
        test -x /usr/libexec/coolify-aws/bootstrap-controller
        test -s /usr/share/licenses/asm-exec/LICENSE
        test -s /usr/share/licenses/aws-workload-credentials-provider/LICENSE
        test -s /usr/share/licenses/aws-workload-credentials-provider/NOTICE
        systemctl is-enabled --quiet aws-workload-credentials-provider-token.service
        systemctl is-enabled --quiet aws-workload-credentials-provider-sm.service
        systemctl is-enabled --quiet coolify-controller-storage.service
        systemctl is-enabled --quiet coolify-controller-bootstrap.service
        systemd-analyze verify \
            /usr/lib/systemd/system/aws-workload-credentials-provider-token.service \
            /usr/lib/systemd/system/aws-workload-credentials-provider-sm.service \
            /usr/lib/systemd/system/coolify-controller-storage.service \
            /usr/lib/systemd/system/coolify-controller-bootstrap.service
        semanage fcontext --list | grep -E "^/data/coolify\(/\.\*\)\?.*container_file_t" >/dev/null
        grep -Fq "EnvironmentFile=-/etc/coolify-controller/runtime-secrets.env" \
            /usr/lib/systemd/system/coolify-controller-bootstrap.service
    '
fi

echo "image validation passed: ${image}"
