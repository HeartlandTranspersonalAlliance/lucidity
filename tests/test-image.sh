#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

required_files=(
    Containerfile
    AGENTS.md
    ci/Containerfile
    ci/images.env
    ci/worker-changes.sh
    roles/common/etc/docker/daemon.json
    roles/common/etc/ssh/sshd_config.d/40-coolify-aws.conf
    roles/common/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-coolify-aws.conf
    roles/controller/usr/lib/systemd/system/nix-storage.service
    roles/controller/usr/lib/systemd/system/nix.mount
    roles/worker/usr/lib/systemd/system/coolify-worker-authorized-keys.service
    scripts/build.sh
    scripts/build-disk.sh
    scripts/validate-disk.sh
    scripts/validate-ami-import.sh
    scripts/validate-image.sh
    scripts/vm-init.sh
    scripts/vm-start.sh
    scripts/vm-validate.sh
    scripts/vm-registry.sh
    scripts/vm-validate-update.sh
    scripts/vm-stop.sh
    image/image-builder.env
    tofu/modules/ami-import-validation/main.tf
    tofu/modules/ami-import-validation/outputs.tf
    tofu/modules/ami-import-validation/variables.tf
    tofu/modules/ami-import-validation/versions.tf
    tofu/modules/network/main.tf
    tofu/modules/network/outputs.tf
    tofu/modules/network/variables.tf
    tofu/modules/network/versions.tf
    tofu/modules/runtime-secrets/main.tf
    tofu/modules/runtime-secrets/outputs.tf
    tofu/modules/runtime-secrets/variables.tf
    tofu/modules/runtime-secrets/versions.tf
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
grep -Fq 'WantedBy=cloud-init.target' roles/worker/usr/lib/systemd/system/coolify-worker-authorized-keys.service
grep -Fq 'enable bootc-fetch-apply-updates.timer' roles/common/usr/lib/systemd/system-preset/80-coolify-aws.preset
grep -Fq 'OnCalendar=*-*-* 11:00:00 UTC' roles/common/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-coolify-aws.conf
grep -Fq 'install -d -m 0755 /nix' Containerfile
grep -Fq 'What=/var/lib/nix' roles/controller/usr/lib/systemd/system/nix.mount
grep -Fq 'Where=/nix' roles/controller/usr/lib/systemd/system/nix.mount
grep -Fq 'WantedBy=local-fs.target' roles/controller/usr/lib/systemd/system/nix.mount
grep -Fq 'Before=nix.mount' roles/controller/usr/lib/systemd/system/nix-storage.service
if grep -R -n -E 'nix\.mount|/var/lib/nix' roles/common roles/worker; then
    echo "controller-only Nix storage leaked into the common or worker role" >&2
    exit 1
fi
grep -Eq '^IMAGE_BUILDER_IMAGE=.+@sha256:[0-9a-f]{64}$' image/image-builder.env
grep -Eq '^SHELLCHECK_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Eq '^ACTIONLINT_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Eq '^REGISTRY_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Fq 'IMAGE_VERSION' scripts/build.sh
grep -Fq '/usr/lib/coolify-aws/image-version' Containerfile
grep -Fq '=~ ^[[:alnum:].:-]+$' scripts/vm-init.sh
grep -Fq '=~ ^[[:alnum:].:-]+$' scripts/vm-validate-update.sh
grep -Fq 'CONTAINER_ENGINE' scripts/build-disk.sh
grep -Fq "if [[ \${format} == qcow2 ]]" scripts/validate-disk.sh
grep -Fq -- '--usage-operation RunInstances' scripts/validate-ami-import.sh
grep -Fq -- '--architecture x86_64' scripts/validate-ami-import.sh
grep -Fq 'trap cleanup EXIT' scripts/validate-ami-import.sh
grep -Fq 'image-output/worker/coolify-worker-ami.raw' .github/workflows/ami.yml
if grep -Fq 'image-output/worker/coolify-worker-ami.ami' .github/workflows/ami.yml; then
    echo "AMI workflow must use the raw artifact emitted by build-disk.sh" >&2
    exit 1
fi
grep -Fq 'resource "aws_nat_gateway" "this"' tofu/modules/network/main.tf
grep -Fq 'default     = false' tofu/modules/network/variables.tf
grep -Fq 'image_tag_mutability = length(var.mutable_channel_tags) > 0 ? "IMMUTABLE_WITH_EXCLUSION" : "IMMUTABLE"' tofu/modules/ecr/main.tf
grep -Fq 'resource "aws_flow_log" "this"' tofu/modules/network/main.tf
grep -Fq 'resource "aws_s3_bucket" "this"' tofu/modules/ami-import-validation/main.tf
grep -Fq 'identifiers = ["vmie.amazonaws.com"]' tofu/modules/ami-import-validation/main.tf
grep -Fq 'variable = "iam:PassedToService"' tofu/modules/ami-import-validation/main.tf
grep -Fq 'resource "aws_secretsmanager_secret" "controller_runtime"' tofu/modules/runtime-secrets/main.tf
grep -Fq 'enable_key_rotation     = true' tofu/modules/runtime-secrets/main.tf
grep -Fq 'variable = "kms:ViaService"' tofu/modules/runtime-secrets/main.tf
grep -Fq '{{resolve:secretsmanager:' tofu/modules/runtime-secrets/outputs.tf
grep -Fq 'default     = "amd64"' tofu/environments/aws/variables.tf
grep -Fq 'default     = "t3a.small"' tofu/environments/aws/variables.tf
grep -Fq 'default     = "t3a.large"' tofu/environments/aws/variables.tf
if grep -R -n -E '0\.0\.0\.0/0.*(22|8000)|(22|8000).*0\.0\.0\.0/0' tofu; then
    echo "SSH and the Coolify bootstrap port must not be globally accessible" >&2
    exit 1
fi
if rg -n --glob '*.tf' 'aws_secretsmanager_secret_version|secret_string\s*=' tofu; then
    echo "OpenTofu must provision secret containers and references, never secret values" >&2
    exit 1
fi
[[ $(printf '%s\n' README.md tofu/environments/aws/main.tf roles/controller/usr/example | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' README.md roles/worker/usr/example | ci/worker-changes.sh) == true ]]
[[ $(printf '%s\n' .github/workflows/validate.yml | ci/worker-changes.sh) == true ]]
unexpected_sudo=$(grep -R -n -E '(^|[[:space:]])sudo[[:space:]]' .github/workflows | \
    grep -Ev 'sudo (tee /etc/udev/rules.d/99-kvm4all.rules|udevadm control --reload-rules|udevadm trigger --name-match=kvm)$' || true)
if [[ -n ${unexpected_sudo} ]]; then
    echo "GitHub Actions may use host sudo only for the documented KVM udev rule" >&2
    printf '%s\n' "${unexpected_sudo}" >&2
    exit 1
fi
[[ $(grep -R -h -E '(^|[[:space:]])sudo[[:space:]]' .github/workflows | wc -l) == 3 ]] || {
    echo "the KVM setup must contain exactly three narrowly scoped sudo commands" >&2
    exit 1
}
if grep -Eq '^IMAGE_BUILDER_IMAGE=.+:(latest|main)$' image/image-builder.env; then
    echo "image-builder must be pinned by digest" >&2
    exit 1
fi

echo "static image assertions passed"
