#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

required_files=(
    Containerfile
    roles/common/etc/docker/daemon.json
    roles/common/etc/ssh/sshd_config.d/40-coolify-aws.conf
    roles/worker/usr/lib/systemd/system/coolify-worker-authorized-keys.service
    scripts/build.sh
    scripts/build-disk.sh
    scripts/validate-disk.sh
    scripts/validate-image.sh
    image/image-builder.env
)

for file in "${required_files[@]}"; do
    [[ -f ${file} ]] || { echo "missing required file: ${file}" >&2; exit 1; }
done

jq -e '."data-root" == "/var/lib/docker" and ."live-restore" == true' \
    roles/common/etc/docker/daemon.json >/dev/null
grep -Fq 'quay.io/almalinuxorg/almalinux-bootc:10' Containerfile
grep -Fq 'bootc container lint' Containerfile
grep -Fq 'PermitRootLogin prohibit-password' roles/common/etc/ssh/sshd_config.d/40-coolify-aws.conf
grep -Fq 'PasswordAuthentication no' roles/common/etc/ssh/sshd_config.d/40-coolify-aws.conf
grep -Eq '^IMAGE_BUILDER_IMAGE=.+@sha256:[0-9a-f]{64}$' image/image-builder.env
if grep -Eq '^IMAGE_BUILDER_IMAGE=.+:(latest|main)$' image/image-builder.env; then
    echo "image-builder must be pinned by digest" >&2
    exit 1
fi

echo "static image assertions passed"
