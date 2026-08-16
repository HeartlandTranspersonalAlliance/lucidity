#!/usr/bin/env bash
set -Eeuo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "${repo_root}"

required_files=(
    VERSION
    .github/syft.yaml
    .github/workflows/release.yml
    Containerfile
    AGENTS.md
    ci/Containerfile
    ci/images.env
    ci/setup-build-cache.sh
    ci/teardown-build-cache.sh
    ci/controller-changes.sh
    ci/worker-changes.sh
    .github/workflows/publish.yml
    .github/workflows/validate-deployment.yml
    .github/workflows/ami-switch-benchmark.yml
    roles/common/etc/docker/daemon.json
    roles/common/etc/selinux/config
    roles/common/etc/ssh/sshd_config.d/40-coolify-aws.conf
    roles/common/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-coolify-aws.conf
    roles/common/usr/lib/systemd/system/coolify-bootc-ecr-auth.service
    roles/common/usr/lib/systemd/system/determinate-nix-install.service
    roles/common/usr/libexec/coolify-aws/configure-bootc-ecr-auth
    roles/common/usr/libexec/coolify-aws/install-determinate-nix
    nix/smoke/flake.nix
    nix/smoke/flake.lock
    roles/controller/etc/coolify-controller/runtime-secrets.env.example
    roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
    roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-token.service
    roles/controller/usr/lib/systemd/system/coolify-controller-bootstrap.service
    roles/controller/usr/lib/systemd/system/coolify-controller-storage.service
    roles/controller/usr/lib/sysusers.d/coolify-controller.conf
    roles/controller/usr/lib/tmpfiles.d/coolify-controller.conf
    roles/controller/usr/libexec/coolify-aws/bootstrap-controller-with-secrets
    roles/controller/usr/libexec/coolify-aws/prepare-controller-storage
    roles/controller/usr/libexec/coolify-aws/workload-credentials-provider-token
    scripts/bootstrap-controller.sh
    roles/worker/usr/lib/systemd/system/coolify-worker-authorized-keys.service
    scripts/build.sh
    scripts/build-disk.sh
    scripts/validate-disk.sh
    scripts/validate-ami-import.sh
    scripts/validate-deployment.sh
    scripts/validate-image.sh
    scripts/vm-init.sh
    scripts/vm-start.sh
    scripts/vm-validate.sh
    scripts/vm-registry.sh
    scripts/vm-validate-update.sh
    scripts/vm-stop.sh
    tests/fixtures/aws
    tests/fixtures/aws-deployment-validation
    tests/fixtures/deployment-curl
    tests/fixtures/bootc
    tests/fixtures/coldsnap
    tests/fixtures/controller-asm-exec
    tests/fixtures/controller-bootstrap-probe
    tests/fixtures/controller-curl
    tests/fixtures/controller-docker
    tests/fixtures/controller-openssl
    tests/fixtures/controller-restorecon
    tests/test-ami-import.sh
    tests/test-deployment-validation.sh
    image/image-builder.env
    tofu/modules/ami-import-validation/main.tf
    tofu/modules/ami-import-validation/outputs.tf
    tofu/modules/ami-import-validation/variables.tf
    tofu/modules/ami-import-validation/versions.tf
    tofu/modules/deployment-validation/main.tf
    tofu/modules/deployment-validation/outputs.tf
    tofu/modules/deployment-validation/variables.tf
    tofu/modules/deployment-validation/versions.tf
    tofu/modules/instance-management/main.tf
    tofu/modules/instance-management/outputs.tf
    tofu/modules/instance-management/variables.tf
    tofu/modules/instance-management/versions.tf
    tofu/modules/ec2-launch-templates/main.tf
    tofu/modules/ec2-launch-templates/outputs.tf
    tofu/modules/ec2-launch-templates/variables.tf
    tofu/modules/ec2-launch-templates/versions.tf
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
grep -Fq 'WantedBy=cloud-init.target' roles/controller/usr/lib/systemd/system/coolify-controller-bootstrap.service
grep -Fq 'cloud-final.service' roles/controller/usr/lib/systemd/system/coolify-controller-bootstrap.service
grep -Fq 'WantedBy=cloud-init.target' roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
grep -Fq 'cloud-final.service' roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
grep -Fq 'ConditionPathExists=/etc/coolify-controller/runtime-secrets.env' roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
grep -Fq 'enable bootc-fetch-apply-updates.timer' roles/common/usr/lib/systemd/system-preset/80-coolify-aws.preset
grep -Fq 'OnCalendar=*-*-* 11:00:00 UTC' roles/common/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-coolify-aws.conf
grep -Fq 'install -d -m 0755 /nix' Containerfile
grep -Fq 'NIX_INSTALLER_VERSION=3.21.0' Containerfile
grep -Fq 'NIX_INSTALLER_COMMIT=9a5e37a9ad25e62337dda5be777007c70c470bfc' Containerfile
grep -Fq 'NIX_INSTALLER_SHA256=b9911496659f0c35c642353d592926c024c205b597e8094bf73a42908a75e462' Containerfile
grep -Fq 'NIX_INSTALLER_LICENSE_SHA256=36b6d3fa47916943fd5fec313c584784946047ec1337a78b440e5992cb595f89' Containerfile
grep -Fq 'WCP_VERSION=3.1.1' Containerfile
grep -Fq 'WCP_SOURCE_SHA256=71019369b95c028e09f6b6ed65cc0237b8ba8a4b86a8e5bce4c31f518f8c698e' Containerfile
grep -Fq 'ASM_EXEC_COMMIT=957cf377ea1dffccf1f8a54ded2be8666b6db41c' Containerfile
grep -Fq 'ASM_EXEC_LICENSE_SHA256=09e8a9bcec8067104652c168685ab0931e7868f9c8284b66f5ae6edae5f1130b' Containerfile
grep -Fq "semanage fcontext -a -t container_file_t '/data/coolify(/.*)?'" Containerfile
grep -Fq 'EnvironmentFile=-/etc/coolify-controller/runtime-secrets.env' roles/controller/usr/lib/systemd/system/coolify-controller-bootstrap.service
grep -Fq 'After=aws-workload-credentials-provider-token.service network-online.target' roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
grep -Fq 'http://127.0.0.1:2773/ping' roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
grep -Fq 'AWS_TOKEN=file:///run/awssmatoken' roles/controller/usr/lib/systemd/system/aws-workload-credentials-provider-sm.service
# This is a literal shell expression in the implementation under test.
# shellcheck disable=SC2016
grep -Fq 'mount --bind "${source_path}" "${target_path}"' roles/controller/usr/libexec/coolify-aws/prepare-controller-storage
grep -Fq '{{resolve:secretsmanager:' roles/controller/etc/coolify-controller/runtime-secrets.env.example
if rg -n '=(plaintext|password|secret)$' roles/controller/etc/coolify-controller; then
    echo "controller configuration must contain references, never secret values" >&2
    exit 1
fi
grep -Fxq 'SELINUX=enforcing' roles/common/etc/selinux/config
grep -Fxq 'SELINUXTYPE=targeted' roles/common/etc/selinux/config
if find roles -type f -name 'nix.mount' -print -quit | grep -q .; then
    echo "Determinate's OSTree planner, not the bootc image, must supply nix.mount" >&2
    exit 1
fi
grep -Fq 'install ostree' roles/common/usr/libexec/coolify-aws/install-determinate-nix
grep -Fq -- '--persistence /var/lib/nix' roles/common/usr/libexec/coolify-aws/install-determinate-nix
grep -Fq -- '--determinate' roles/common/usr/libexec/coolify-aws/install-determinate-nix
grep -Fq -- '--diagnostic-endpoint ""' roles/common/usr/libexec/coolify-aws/install-determinate-nix
grep -Fq 'ln -s ../var/usrlocal /usr/local' Containerfile
grep -Fxq 'd /var/usrlocal 0755 root root -' roles/common/usr/lib/tmpfiles.d/coolify-aws.conf
grep -Fxq 'd /var/usrlocal/bin 0755 root root -' roles/common/usr/lib/tmpfiles.d/coolify-aws.conf
grep -Fq 'Recovering an interrupted Determinate Nix installation' roles/common/usr/libexec/coolify-aws/install-determinate-nix
# This is a literal shell expression in the implementation under test.
# shellcheck disable=SC2016
grep -Fq '"${recovery_installer}" uninstall --no-confirm' roles/common/usr/libexec/coolify-aws/install-determinate-nix
# This is a literal shell expression in the implementation under test.
# shellcheck disable=SC2016
grep -Fq '[[ $(getenforce) == Enforcing ]]' roles/common/usr/libexec/coolify-aws/install-determinate-nix
if grep -Eq '^(After|Before)=.*cloud-final\.service' roles/common/usr/lib/systemd/system/determinate-nix-install.service; then
    echo "Determinate Nix installation must not order against cloud-final.service" >&2
    exit 1
fi
if grep -Eq '^Before=.*coolify-(controller|worker)' roles/common/usr/lib/systemd/system/determinate-nix-install.service; then
    echo "Determinate Nix installation must not order the role boot services" >&2
    exit 1
fi
grep -Fq 'Determinate Nix installation failed' scripts/vm-validate.sh
grep -Fq '_AUDIT_TYPE_NAME=AVC' scripts/vm-validate.sh
grep -Fq 'systemctl is-active --quiet nix-daemon.service' scripts/vm-validate.sh
grep -Fq "stat -c '%d:%i' /var/lib/nix" scripts/vm-validate.sh
grep -Fq '/var/lib/coolify-aws/nix-smoke-result' scripts/vm-validate-update.sh
grep -Fq 'systemctl start determinate-nix-install.service' scripts/validate-deployment.sh
grep -Fq 'systemctl is-active --quiet nix-daemon.service' scripts/validate-deployment.sh
grep -Fq '/var/lib/coolify-aws/nix-smoke-result' scripts/validate-deployment.sh
grep -Eq '^IMAGE_BUILDER_IMAGE=.+@sha256:[0-9a-f]{64}$' image/image-builder.env
grep -Eq '^SHELLCHECK_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Eq '^ACTIONLINT_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Eq '^REGISTRY_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Fq 'IMAGE_VERSION' scripts/build.sh
grep -Fq 'benchmark-base|controller|worker' scripts/build.sh
grep -Fq 'docker buildx build --load' scripts/build.sh
# These are literal shell expressions in the implementation under test.
# shellcheck disable=SC2016
grep -Fq 'type=registry,ref=${BUILD_CACHE_FROM}' scripts/build.sh
grep -Fq 'mode=max,image-manifest=true,oci-mediatypes=true' scripts/build.sh
grep -Fq 'podman build --layers' scripts/build.sh
grep -Fq -- '--cache-ttl 168h' scripts/build.sh
# shellcheck disable=SC2016
grep -Fq 'cache_repository=${GITHUB_REPOSITORY,,}-build-cache' ci/setup-build-cache.sh
# shellcheck disable=SC2016
grep -Fq 'docker login "${cache_registry}" --username "${GITHUB_ACTOR}" --password-stdin' ci/setup-build-cache.sh
grep -Fq 'sudo podman login' ci/setup-build-cache.sh
grep -Fq 'sudo skopeo list-tags' ci/setup-build-cache.sh
grep -Fq 'BUILD_CACHE_TO=' ci/setup-build-cache.sh
grep -Fq 'sudo podman logout' ci/teardown-build-cache.sh
grep -Fq 'benchmark-base|controller|worker' scripts/validate-image.sh
grep -Fq 'FROM common AS benchmark-base' Containerfile
grep -Fq '/usr/lib/coolify-aws/image-version' Containerfile
controller_setup_line=$(grep -n '^RUN dnf -y install policycoreutils-python-utils python3' Containerfile | cut -d: -f1)
controller_version_line=$(awk '
    /^FROM common AS controller$/ { in_controller = 1; next }
    /^FROM / && in_controller { exit }
    in_controller && /^ARG IMAGE_VERSION=/ { print NR; exit }
' Containerfile)
worker_setup_line=$(grep -n '^RUN chmod 0755 /usr/libexec/coolify-aws/bootstrap-worker' Containerfile | cut -d: -f1)
worker_version_line=$(awk '
    /^FROM common AS worker$/ { in_worker = 1; next }
    /^FROM / && in_worker { exit }
    in_worker && /^ARG IMAGE_VERSION=/ { print NR; exit }
' Containerfile)
[[ -n ${controller_setup_line} && -n ${controller_version_line} && ${controller_setup_line} -lt ${controller_version_line} ]] || {
    echo "controller release metadata must follow the expensive stable setup layer" >&2
    exit 1
}
[[ -n ${worker_setup_line} && -n ${worker_version_line} && ${worker_setup_line} -lt ${worker_version_line} ]] || {
    echo "worker release metadata must follow the stable role setup layer" >&2
    exit 1
}
grep -Fq '=~ ^[[:alnum:].:-]+$' scripts/vm-init.sh
grep -Fq '=~ ^[[:alnum:].:-]+$' scripts/vm-validate-update.sh
grep -Fq 'CONTAINER_ENGINE' scripts/build-disk.sh
grep -Fq 'controller|worker' scripts/build-disk.sh
# These are literal shell expressions in the implementation under test.
# shellcheck disable=SC2016
grep -Fq 'coolify-${role}-qcow2.qcow2' scripts/vm-init.sh
# shellcheck disable=SC2016
grep -Fq 'coolify-${role}-test.qcow2' scripts/vm-start.sh
# shellcheck disable=SC2016
grep -Fq 'coolify-bootc-${role}' scripts/vm-registry.sh
grep -Fq 'Worker VM initial validation passed' scripts/vm-validate.sh
grep -Fq 'Controller VM initial validation passed' scripts/vm-validate.sh
# shellcheck disable=SC2016
grep -Fq 'compose+=(up -d --wait --wait-timeout 600 --pull "${pull_policy}" --remove-orphans)' scripts/bootstrap-controller.sh
grep -Fq '/data/coolify/.update-rollback-marker' scripts/vm-validate-update.sh
grep -Fq 'timed out waiting for Docker and the Coolify worker SSH identity' scripts/vm-validate-update.sh
grep -Fq 'deployment assertion failed while checking' scripts/vm-validate-update.sh
# shellcheck disable=SC2016
worker_branch_line=$(grep -n 'if \[\[ ${role} == worker \]\]; then' scripts/vm-validate-update.sh | head -n 2 | tail -n 1 | cut -d: -f1)
# shellcheck disable=SC2016
controller_hash_line=$(grep -n '^expected_env_hash=\$5$' scripts/vm-validate-update.sh | cut -d: -f1)
[[ ${worker_branch_line} -lt ${controller_hash_line} ]] || {
    echo "worker deployment assertions must branch before reading controller-only arguments" >&2
    exit 1
}
grep -Fq 'vm-update-rollback-controller' Makefile
grep -Fq 'Build and validate controller QCOW2' .github/workflows/validate.yml
grep -Fq 'amazon-ssm-agent' Containerfile
grep -Fq '/3.3.5068.0/linux_amd64/amazon-ssm-agent.rpm' Containerfile
if grep -Fq '/latest/linux_amd64/amazon-ssm-agent.rpm' Containerfile; then
    echo "SSM Agent RPM must be version-pinned" >&2
    exit 1
fi
grep -Fq 'systemctl is-enabled --quiet amazon-ssm-agent.service' scripts/validate-image.sh
grep -Fq 'systemctl is-enabled --quiet coolify-bootc-ecr-auth.service' scripts/validate-image.sh
grep -Fq 'docker-credential-ecr-login' Containerfile
grep -Fq 'c874cc88850330fd7a93452c7c654737fa37f06916153cf818e49088197a5e4c' Containerfile
grep -Fq '/run/ostree' roles/common/usr/libexec/coolify-aws/configure-bootc-ecr-auth
grep -Fq 'credHelpers' roles/common/usr/libexec/coolify-aws/configure-bootc-ecr-auth
grep -Fq 'Before=bootc-fetch-apply-updates.service' roles/common/usr/lib/systemd/system/coolify-bootc-ecr-auth.service
grep -Fq 'grep -Eq "^SELINUX=enforcing$" /etc/selinux/config' scripts/validate-image.sh
grep -Fq 'getenforce) == Enforcing' scripts/vm-validate.sh
grep -Fq "if [[ \${format} == qcow2 ]]" scripts/validate-disk.sh
grep -Fq 'coldsnap_command' scripts/validate-ami-import.sh
grep -Fq -- '--kms-key-id' scripts/validate-ami-import.sh
grep -Fq 'aws ec2 register-image' scripts/validate-ami-import.sh
grep -Fq -- '--architecture x86_64' scripts/validate-ami-import.sh
grep -Fq -- '--boot-mode uefi' scripts/validate-ami-import.sh
grep -Fq -- '--imds-support v2.0' scripts/validate-ami-import.sh
grep -Fq 'aws ec2 run-instances' scripts/validate-ami-import.sh
grep -Fq -- '--credit-specification CpuCredits=standard' scripts/validate-ami-import.sh
grep -Fq 'HttpEndpoint=enabled,HttpTokens=required,HttpPutResponseHopLimit=2' scripts/validate-ami-import.sh
grep -Fq 'aws ssm send-command' scripts/validate-ami-import.sh
grep -Fq 'base64 --decode > /run/ostree/auth.json' scripts/validate-ami-import.sh
# These are literal guest-shell snippets embedded in the jq command document.
# shellcheck disable=SC2016
grep -Fq 'test \"$(getenforce)\" = Enforcing' scripts/validate-ami-import.sh
# shellcheck disable=SC2016
grep -Fq 'test \"${imds_code}\" = 401' scripts/validate-ami-import.sh
if grep -Eq -- '--key-name|KeyName=' scripts/validate-ami-import.sh; then
    echo "disposable AMI boot validation must not create or attach an SSH key pair" >&2
    exit 1
fi
if grep -Fq 'aws ec2 import-image' scripts/validate-ami-import.sh; then
    echo "AMI workflow must not use OS-detecting import-image for AlmaLinux" >&2
    exit 1
fi
grep -Fq 'trap cleanup EXIT' scripts/validate-ami-import.sh
# This is a literal workflow shell expression.
# shellcheck disable=SC2016
grep -Fq 'AMI_ARTIFACT=image-output/${AMI_ROLE}/coolify-${AMI_ROLE}-ami.raw' .github/workflows/ami.yml
if grep -Fq 'image-output/worker/coolify-worker-ami.ami' .github/workflows/ami.yml; then
    echo "AMI workflow must use the raw artifact emitted by build-disk.sh" >&2
    exit 1
fi
grep -Fq 'resource "aws_nat_gateway" "this"' tofu/modules/network/main.tf
grep -Fq 'default     = false' tofu/modules/network/variables.tf
grep -Fq 'image_tag_mutability = length(var.mutable_channel_tags) > 0 ? "IMMUTABLE_WITH_EXCLUSION" : "IMMUTABLE"' tofu/modules/ecr/main.tf
grep -Fq 'Expire untagged images while retaining immutable release tags' tofu/modules/ecr/main.tf
if grep -Fq 'tagStatus   = "any"' tofu/modules/ecr/main.tf; then
    echo "ECR lifecycle policy must not expire immutable tagged releases" >&2
    exit 1
fi
grep -Fq 'resource "aws_flow_log" "this"' tofu/modules/network/main.tf
grep -Fq 'backend "s3" {}' tofu/environments/aws/versions.tf
grep -Fq 'bucket_namespace = "account-regional"' tofu/bootstrap/state/main.tf
grep -Fq 'blocked_encryption_types = ["SSE-C"]' tofu/bootstrap/state/main.tf
grep -Fq 'sid     = "DenyInsecureTransport"' tofu/bootstrap/state/main.tf
grep -Fq 'resource "aws_s3_bucket_logging" "state"' tofu/bootstrap/state/main.tf
grep -Fq 'use_lockfile = true' tofu/environments/aws/backend.s3.tfbackend.example
if rg -n 'dynamodb_table|aws_dynamodb' tofu/bootstrap/state tofu/environments/aws/backend.s3.tfbackend.example; then
    echo "native S3 state locking must not add a DynamoDB dependency" >&2
    exit 1
fi
grep -Fq 'AmazonSSMManagedInstanceCore' tofu/modules/instance-management/main.tf
grep -Fq 'resource "aws_iam_role_policy" "ecr_pull"' tofu/modules/instance-management/main.tf
grep -Fq 'resource "aws_iam_instance_profile" "node"' tofu/modules/instance-management/main.tf
grep -Fq 'resource "aws_kms_key" "ami_snapshot"' tofu/modules/ami-import-validation/main.tf
grep -Fq 'ebs:StartSnapshot' tofu/modules/ami-import-validation/main.tf
grep -Fq 'ebs:PutSnapshotBlock' tofu/modules/ami-import-validation/main.tf
grep -Fq 'ebs:CompleteSnapshot' tofu/modules/ami-import-validation/main.tf
grep -Fq 'kms:GenerateDataKey' tofu/modules/ami-import-validation/main.tf
grep -Fq 'kms:GenerateDataKeyWithoutPlaintext' tofu/modules/ami-import-validation/main.tf
grep -Fq 'kms:GrantIsForAWSResource' tofu/modules/ami-import-validation/main.tf
grep -Fq 'values   = ["ami-release", "ami-validation"]' tofu/modules/ami-import-validation/main.tf
grep -Fq 'ecr:GetAuthorizationToken' tofu/modules/ami-import-validation/main.tf
grep -Fq 'ecr:GetDownloadUrlForLayer' tofu/modules/ami-import-validation/main.tf
grep -Fq 'sid     = "CreateTaggedValidationInstance"' tofu/modules/ami-import-validation/main.tf
grep -Fq 'variable = "ec2:MetadataHttpTokens"' tofu/modules/ami-import-validation/main.tf
grep -Fq 'values   = ["required"]' tofu/modules/ami-import-validation/main.tf
grep -Fq 'sid       = "PassValidationInstanceRole"' tofu/modules/ami-import-validation/main.tf
grep -Fq 'document/AWS-RunShellScript' tofu/modules/ami-import-validation/main.tf
# These are literal OpenTofu interpolation strings.
# shellcheck disable=SC2016
grep -Fq 'ec2:${var.aws_region}::image/*' tofu/modules/ami-import-validation/main.tf
# shellcheck disable=SC2016
grep -Fq 'ec2:${var.aws_region}::snapshot/*' tofu/modules/ami-import-validation/main.tf
if rg -n 'ec2:\$\{var\.aws_region\}:\$\{local\.account_id\}:(image|snapshot)/\*' tofu/modules/ami-import-validation/main.tf; then
    echo "EC2 image and snapshot IAM ARNs must use an empty account field" >&2
    exit 1
fi
grep -Fq 'allowed-account-ids: 467590374785' .github/workflows/ami.yml
# This is a literal workflow shell expression.
# shellcheck disable=SC2016
grep -Fq 'ci/setup-build-cache.sh "${AMI_ROLE}"' .github/workflows/ami.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
[[ $(grep -Fc "GHCR_CACHE_WRITE: \${{ github.event_name != 'pull_request' }}" .github/workflows/ami.yml) == 1 ]]
ami_pr_paths=$(sed -n '/^  pull_request:/,/^  workflow_call:/p' .github/workflows/ami.yml)
grep -Fq -- '- scripts/build-disk.sh' <<< "${ami_pr_paths}"
grep -Fq -- '- scripts/validate-disk.sh' <<< "${ami_pr_paths}"
if grep -Eq -- '- (Containerfile|roles/\*\*|scripts/build\.sh)' <<< "${ami_pr_paths}"; then
    echo "AMI pull-request validation must not duplicate the normal role image build" >&2
    exit 1
fi
grep -Fq "github.ref == 'refs/heads/main'" .github/workflows/publish.yml
grep -Fq 'id-token: write' .github/workflows/publish.yml
grep -Fq 'packages: write' .github/workflows/publish.yml
grep -Fq 'max-parallel: 4' .github/workflows/publish.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'ci/setup-build-cache.sh "${{ matrix.role }}"' .github/workflows/publish.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'workflow_call:' .github/workflows/publish.yml
grep -Fq 'source_sha:' .github/workflows/publish.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'IMAGE_TAG: sha-${{ inputs.source_sha || github.sha }}' .github/workflows/publish.yml
grep -Fq 'allowed-account-ids: 467590374785' .github/workflows/publish.yml
grep -Fq 'aws ecr get-login-password' .github/workflows/publish.yml
grep -Fq 'aws ecr batch-get-image' .github/workflows/publish.yml
grep -Fq 'docker manifest inspect --verbose' .github/workflows/publish.yml
grep -Fq '.Descriptor.platform.architecture == "amd64"' .github/workflows/publish.yml
if grep -Fq 'pull_request:' .github/workflows/publish.yml; then
    echo "ECR publishing must never receive credentials on pull requests" >&2
    exit 1
fi
if rg -n 'AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|secrets\.' .github/workflows/publish.yml; then
    echo "ECR publishing must use GitHub OIDC without stored AWS credentials" >&2
    exit 1
fi
if rg -n '(^|[^[:alnum:]])(latest|stable)([^[:alnum:]]|$)' .github/workflows/publish.yml; then
    echo "candidate publication must not write mutable latest or stable tags" >&2
    exit 1
fi
grep -Fq 'resource "aws_secretsmanager_secret" "controller_runtime"' tofu/modules/runtime-secrets/main.tf
grep -Fq 'kms_key_id              = "alias/aws/secretsmanager"' tofu/modules/runtime-secrets/main.tf
if rg -n 'resource "aws_kms_(key|alias)"' tofu/modules/runtime-secrets; then
    echo "runtime secrets must use the AWS managed Secrets Manager key without a billed customer key" >&2
    exit 1
fi
grep -Fq '{{resolve:secretsmanager:' tofu/modules/runtime-secrets/outputs.tf
grep -Fq 'default     = "amd64"' tofu/environments/aws/variables.tf
grep -Fq 'default     = "t3a.small"' tofu/environments/aws/variables.tf
grep -Fq 'default     = "t3a.medium"' tofu/environments/aws/variables.tf
grep -Fq 'enable_ami_launch_validation' tofu/environments/aws/variables.tf
grep -Fq 'run_aws_launch:' .github/workflows/ami.yml
grep -Fq 'run_aws_validation:' .github/workflows/ami.yml
grep -Fq 'ami_lifecycle:' .github/workflows/ami.yml
grep -Fq 'workflow_call:' .github/workflows/ami.yml
grep -Fq 'ami_role:' .github/workflows/ami.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq "AMI_LIFECYCLE: \${{ inputs.ami_lifecycle || 'disposable' }}" .github/workflows/ami.yml
# This is a literal workflow shell expression.
# shellcheck disable=SC2016
grep -Fq 'sudo podman pull "${IMAGE_REF}"' .github/workflows/ami.yml
# This is a literal GitHub Actions shell expression.
# shellcheck disable=SC2016
grep -Fq 'sudo env CONTAINER_ENGINE=podman ./scripts/validate-image.sh "${IMAGE_REF}"' .github/workflows/ami.yml
grep -Fq 'sudo podman build' .github/workflows/ami.yml
grep -Fq 'CONTAINER_ENGINE=docker' .github/workflows/ami.yml
grep -Fq 'GHCR_CACHE_ENGINE: podman' .github/workflows/ami-switch-benchmark.yml
grep -Fq 'AWS_ECR_CONTROLLER_REPOSITORY_URL' .github/workflows/ami.yml
grep -Fq 'AWS_ECR_WORKER_REPOSITORY_URL' .github/workflows/ami.yml
# These are literal workflow shell expressions.
# shellcheck disable=SC2016
grep -Fq 'image_ref="${ecr_repository_url}:${RELEASE_VERSION}"' .github/workflows/ami.yml
# shellcheck disable=SC2016
grep -Fq 'image_ref="${ecr_repository_url}:sha-${GITHUB_SHA}"' .github/workflows/ami.yml
grep -Fq 'retained AMIs require the EC2 launch gate' scripts/validate-ami-import.sh
grep -Fq 'artifact_purpose=ami-release' scripts/validate-ami-import.sh
grep -Fq 'completed_successfully=true' scripts/validate-ami-import.sh
grep -Fq 'AMI_SWITCH_TARGET_REF' scripts/validate-ami-import.sh
grep -Fq 'coolify-controller-bootstrap.service' scripts/validate-ami-import.sh
grep -Fq 'CENTOS_BOOTC_IMAGE: quay.io/centos-bootc/centos-bootc:stream10@sha256:' .github/workflows/ami-switch-benchmark.yml
grep -Fq './scripts/build.sh benchmark-base' .github/workflows/ami-switch-benchmark.yml
grep -Fq 'ci/setup-build-cache.sh benchmark-base' .github/workflows/ami-switch-benchmark.yml
# These are literal workflow shell expressions.
# shellcheck disable=SC2016
grep -Fq 'image_without_tag=${WORKER_IMAGE_REF%:*}' .github/workflows/ami-switch-benchmark.yml
# shellcheck disable=SC2016
grep -Fq 'repository_name=${image_without_tag#*/}' .github/workflows/ami-switch-benchmark.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'TARGET_REVISION: ${{ inputs.worker_revision || github.sha }}' .github/workflows/ami-switch-benchmark.yml
grep -Fq 'worker_revision must be a full lowercase Git commit SHA' .github/workflows/ami-switch-benchmark.yml
# This is a literal workflow shell variable.
# shellcheck disable=SC2016
grep -Fq './scripts/validate-image.sh "${BOOTSTRAP_IMAGE}"' .github/workflows/ami-switch-benchmark.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'AMI_SWITCH_TARGET_REF: ${{ env.WORKER_IMAGE_REF }}' .github/workflows/ami-switch-benchmark.yml
grep -Fq 'nix build --no-link --print-out-paths .#coldsnap' .github/workflows/ami.yml
grep -Fq 'coldsnap = pkgs.coldsnap;' flake.nix
grep -Fq 'syft = pkgs.syft;' flake.nix
grep -Fxq '0.1.0' VERSION
grep -Fq 'name: Release bootc appliance' .github/workflows/release.yml
# This is a literal workflow shell variable.
# shellcheck disable=SC2016
grep -Fq 'git rev-parse --verify --quiet "refs/tags/${tag}^{commit}"' .github/workflows/release.yml
missing_release_tag_commit=$(git rev-parse --verify --quiet 'refs/tags/v999999.999999.999999^{commit}' || true)
[[ -z ${missing_release_tag_commit} ]] || {
    echo "a missing release tag must resolve to an empty commit" >&2
    exit 1
}
grep -Fq 'uses: ./.github/workflows/publish.yml' .github/workflows/release.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'source_sha: ${{ needs.prepare.outputs.source_sha }}' .github/workflows/release.yml
if rg -n 'gh workflow run publish.yml|gh run (list|watch).*publish.yml|actions: write' .github/workflows/release.yml; then
    echo "release must call the immutable publication workflow directly without workflow-dispatch polling" >&2
    exit 1
fi
grep -Fq 'cron: "41 7 * * *"' .github/workflows/audit-ami-resources.yml
grep -Fq 'AMI_VALIDATION_MAX_AGE_HOURS: 12' .github/workflows/audit-ami-resources.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'role-to-assume: ${{ vars.AWS_AMI_AUDIT_ROLE_ARN }}' .github/workflows/audit-ami-resources.yml
if grep -Fq 'AWS_AMI_IMPORT_ROLE_ARN' .github/workflows/audit-ami-resources.yml; then
    echo "scheduled AMI resource audits must not assume the mutation-capable import role" >&2
    exit 1
fi
grep -Fq 'aws ecr put-image' .github/workflows/release.yml
grep -Fq 'nix build .#syft --no-link --print-out-paths' .github/workflows/release.yml
grep -Fq 'predicate-type: https://spdx.dev/Document/v2.3' .github/workflows/release.yml
[[ $(grep -Fc 'uses: ./.github/workflows/ami.yml' .github/workflows/release.yml) -eq 2 ]]
grep -Fq 'ami_role: controller' .github/workflows/release.yml
grep -Fq 'ami_role: worker' .github/workflows/release.yml
grep -Fq '.aws.amis | keys | sort == ["controller","worker"]' .github/workflows/release.yml
if grep -Fq 'gh workflow run ami.yml' .github/workflows/release.yml; then
    echo "the release must call the AMI workflow directly instead of dispatching and polling it" >&2
    exit 1
fi
# These are literal shell and GitHub Actions expressions in the workflows under test.
# shellcheck disable=SC2016
grep -Fq 'gh release create "${RELEASE_TAG}"' .github/workflows/release.yml
# shellcheck disable=SC2016
grep -Fq 'gh release edit "${RELEASE_TAG}" --draft=false' .github/workflows/release.yml
# shellcheck disable=SC2016
grep -Fq 'AMI_RELEASE_VERSION: ${{ inputs.release_version }}' .github/workflows/ami.yml
# shellcheck disable=SC2016
grep -Fq 'AMI_SOURCE_IMAGE_DIGEST: ${{ inputs.source_image_digest }}' .github/workflows/ami.yml
# shellcheck disable=SC2016
grep -Fq 'AMI_SBOM_SHA256: ${{ inputs.sbom_sha256 }}' .github/workflows/ami.yml
grep -Fq 'Key=SourceImageDigest' scripts/validate-ami-import.sh
grep -Fq 'Key=SbomSha256' scripts/validate-ami-import.sh
if rg -n 'AWS_ACCESS_KEY_ID|AWS_SECRET_ACCESS_KEY|secrets\.' .github/workflows/release.yml; then
    echo "immutable releases must use GitHub OIDC without stored AWS credentials" >&2
    exit 1
fi
if rg -n -i 'vmimport|vm import|import-snapshot|AMI_IMPORT_BUCKET|VMIMPORT_ROLE_NAME|snapshot_upload_mode' \
    .github/workflows/ami.yml scripts/validate-ami-import.sh tofu/modules/ami-import-validation; then
    echo "legacy VM Import must not remain in the EBS Direct AMI delivery path" >&2
    exit 1
fi
if rg -n --glob '*.tf' '0\.0\.0\.0/0.*(22|8000)|(22|8000).*0\.0\.0\.0/0' tofu; then
    echo "SSH and the Coolify bootstrap port must not be globally accessible" >&2
    exit 1
fi
if rg -n 'controller_bootstrap|administrator_ssh|security_group" "ssh"|ip_protocol\s*=\s*"-1"' tofu/modules/network; then
    echo "Public management ingress and unrestricted security-group egress are forbidden" >&2
    exit 1
fi
if rg -n --glob '*.tf' 'aws_secretsmanager_secret_version|secret_string\s*=' tofu; then
    echo "OpenTofu must provision secret containers and references, never secret values" >&2
    exit 1
fi

auth_test_dir=$(mktemp -d)
trap 'rm -rf "${auth_test_dir}"' EXIT
BOOTC_AUTH_DIR="${auth_test_dir}" \
MOCK_BOOTC_IMAGE=467590374785.dkr.ecr.us-east-2.amazonaws.com/lucidity/bootc/worker:sha-0123456789abcdef0123456789abcdef01234567 \
PATH="${repo_root}/tests/fixtures:${PATH}" \
    roles/common/usr/libexec/coolify-aws/configure-bootc-ecr-auth
jq -e '.auths["467590374785.dkr.ecr.us-east-2.amazonaws.com"] == {}' "${auth_test_dir}/auth.json" >/dev/null
jq -e '.credHelpers["467590374785.dkr.ecr.us-east-2.amazonaws.com"] == "ecr-login"' "${auth_test_dir}/auth.json" >/dev/null
[[ $(stat -c '%a' "${auth_test_dir}/auth.json") == 600 ]]
BOOTC_AUTH_DIR="${auth_test_dir}" \
MOCK_BOOTC_IMAGE=localhost/coolify-bootc-worker:test \
PATH="${repo_root}/tests/fixtures:${PATH}" \
    roles/common/usr/libexec/coolify-aws/configure-bootc-ecr-auth
[[ ! -e ${auth_test_dir}/auth.json ]]
grep -Fq 'resource "aws_launch_template" "node"' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'owners = ["self"]' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'http_tokens                 = "required"' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'http_put_response_hop_limit = 2' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'cpu_credits = "standard"' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'volume_type           = "gp3"' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'update_default_version = false' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'user_data = each.key == "controller" ? base64encode(local.controller_user_data) : null' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'document/AWS-RunShellScript' tofu/modules/deployment-validation/main.tf
grep -Fq 'variable = "ssm:resourceTag/Project"' tofu/modules/deployment-validation/main.tf
grep -Fq 'variable = "ssm:resourceTag/Environment"' tofu/modules/deployment-validation/main.tf
grep -Fq 'variable = "ssm:resourceTag/Role"' tofu/modules/deployment-validation/main.tf
grep -Fq 'values   = ["controller", "worker"]' tofu/modules/deployment-validation/main.tf
grep -Fq 'path        = "/etc/coolify-controller/runtime-secrets.env"' tofu/modules/ec2-launch-templates/main.tf
grep -Fq 'permissions = "0600"' tofu/modules/ec2-launch-templates/main.tf
# These are literal OpenTofu interpolation expressions.
# shellcheck disable=SC2016
grep -Fq '{{resolve:secretsmanager:${var.controller_runtime_secret_name}:SecretString:${json_key}}}' tofu/modules/ec2-launch-templates/main.tf
for secret_variable in \
    COOLIFY_APP_ID \
    COOLIFY_APP_KEY \
    COOLIFY_DB_PASSWORD \
    COOLIFY_REDIS_PASSWORD \
    COOLIFY_PUSHER_APP_ID \
    COOLIFY_PUSHER_APP_KEY \
    COOLIFY_PUSHER_APP_SECRET; do
    grep -Fq "${secret_variable}" tofu/modules/ec2-launch-templates/main.tf
done
if rg -n 'key_name|associate_public_ip_address' tofu/modules/ec2-launch-templates; then
    echo "launch templates must not embed key pairs or networking placement" >&2
    exit 1
fi
[[ $(printf '%s\n' README.md tofu/environments/aws/main.tf roles/controller/usr/example | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' ci/controller-changes.sh ci/worker-changes.sh | ci/worker-changes.sh) == true ]]
[[ $(printf '%s\n' tests/test-image.sh tests/test-ami-import.sh tests/fixtures/aws tests/fixtures/coldsnap | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' README.md roles/worker/usr/example | ci/worker-changes.sh) == true ]]
[[ $(printf '%s\n' scripts/bootstrap-controller.sh tests/test-controller.sh | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' mk/quality.mk scripts/check-text-style.sh tests/test-text-style.sh | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' .github/workflows/validate-deployment.yml scripts/validate-deployment.sh tests/test-deployment-validation.sh tests/fixtures/aws-deployment-validation | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' .github/workflows/ami-switch-benchmark.yml scripts/validate-ami-import.sh tests/test-ami-import.sh | ci/worker-changes.sh) == false ]]
[[ $(printf '%s\n' Makefile | ci/worker-changes.sh) == true ]]
[[ $(printf '%s\n' .github/workflows/validate.yml | ci/worker-changes.sh) == true ]]
[[ $(printf '%s\n' README.md tofu/environments/aws/main.tf roles/worker/usr/example | ci/controller-changes.sh) == false ]]
[[ $(printf '%s\n' ci/controller-changes.sh ci/worker-changes.sh | ci/controller-changes.sh) == true ]]
[[ $(printf '%s\n' tests/test-image.sh tests/test-ami-import.sh tests/fixtures/aws tests/fixtures/coldsnap | ci/controller-changes.sh) == false ]]
[[ $(printf '%s\n' README.md roles/controller/usr/example | ci/controller-changes.sh) == true ]]
[[ $(printf '%s\n' scripts/bootstrap-worker.sh tests/test-worker.sh | ci/controller-changes.sh) == false ]]
[[ $(printf '%s\n' mk/quality.mk scripts/check-text-style.sh tests/test-text-style.sh | ci/controller-changes.sh) == false ]]
[[ $(printf '%s\n' .github/workflows/validate-deployment.yml scripts/validate-deployment.sh tests/test-deployment-validation.sh tests/fixtures/aws-deployment-validation | ci/controller-changes.sh) == false ]]
[[ $(printf '%s\n' .github/workflows/ami-switch-benchmark.yml scripts/validate-ami-import.sh tests/test-ami-import.sh | ci/controller-changes.sh) == false ]]
[[ $(printf '%s\n' Makefile | ci/controller-changes.sh) == true ]]
[[ $(printf '%s\n' .github/workflows/validate.yml | ci/controller-changes.sh) == true ]]
grep -Fq 'merge_group:' .github/workflows/validate.yml
# These are literal GitHub Actions expressions in the workflow under test.
# shellcheck disable=SC2016
grep -Fq 'MERGE_GROUP_BASE_SHA: ${{ github.event.merge_group.base_sha }}' .github/workflows/validate.yml
# shellcheck disable=SC2016
grep -Fq 'MERGE_GROUP_HEAD_SHA: ${{ github.event.merge_group.head_sha }}' .github/workflows/validate.yml
grep -Fq 'schedule|workflow_dispatch)' .github/workflows/validate.yml
grep -Fq 'cron: "17 5 * * 1"' .github/workflows/validate.yml
if grep -Fq 'push:' .github/workflows/validate.yml; then
    echo "validate.yml must not repeat the merge queue's full lifecycle after main updates" >&2
    exit 1
fi
# Pull requests build and validate disks; the serial merge queue owns guest lifecycle validation.
grep -Fq "FULL_LIFECYCLE: \${{ github.event_name != 'pull_request' }}" .github/workflows/validate.yml
[[ $(grep -Fc "if: env.FULL_LIFECYCLE == 'true'" .github/workflows/validate.yml) == 4 ]]
[[ $(grep -Fc 'make vm-validate-' .github/workflows/validate.yml) == 2 ]]
# This is a literal shell expression in the workflow under test.
# shellcheck disable=SC2016
[[ $(grep -Fc 'if [[ ${FULL_LIFECYCLE} == true ]]; then' .github/workflows/validate.yml) == 2 ]]
[[ $(grep -Fc 'make vm-update-rollback-' .github/workflows/validate.yml) == 2 ]]
unexpected_sudo=$(grep -R -n -E '(^|[[:space:]])sudo[[:space:]]' .github/workflows | \
    grep -Ev 'sudo (tee /etc/udev/rules.d/99-kvm4all.rules|udevadm control --reload-rules|udevadm trigger --name-match=kvm)$' | \
    grep -Ev '^\.github/workflows/(ami|ami-switch-benchmark)\.yml:.*sudo (podman (system df|login|pull|image inspect|build|logout)|env (\\|CONTAINER_ENGINE=podman))' || true)
if [[ -n ${unexpected_sudo} ]]; then
    echo "GitHub Actions may use host sudo only for KVM setup and the documented root-Podman osbuild path" >&2
    printf '%s\n' "${unexpected_sudo}" >&2
    exit 1
fi
[[ $(grep -R -h -E 'sudo (tee /etc/udev/rules.d/99-kvm4all.rules|udevadm control --reload-rules|udevadm trigger --name-match=kvm)$' .github/workflows | wc -l) == 6 ]] || {
    echo "the two KVM lifecycle jobs must each contain exactly three narrowly scoped sudo commands" >&2
    exit 1
}
if grep -Eq '^IMAGE_BUILDER_IMAGE=.+:(latest|main)$' image/image-builder.env; then
    echo "image-builder must be pinned by digest" >&2
    exit 1
fi

echo "static image assertions passed"
