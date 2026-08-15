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
    .github/workflows/publish.yml
    .github/workflows/ami-switch-benchmark.yml
    roles/common/etc/docker/daemon.json
    roles/common/etc/selinux/config
    roles/common/etc/ssh/sshd_config.d/40-coolify-aws.conf
    roles/common/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-coolify-aws.conf
    roles/common/usr/lib/systemd/system/coolify-bootc-ecr-auth.service
    roles/common/usr/libexec/coolify-aws/configure-bootc-ecr-auth
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
    tests/fixtures/aws
    tests/fixtures/bootc
    tests/fixtures/coldsnap
    tests/test-ami-import.sh
    image/image-builder.env
    tofu/modules/ami-import-validation/main.tf
    tofu/modules/ami-import-validation/outputs.tf
    tofu/modules/ami-import-validation/variables.tf
    tofu/modules/ami-import-validation/versions.tf
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
grep -Fq 'enable bootc-fetch-apply-updates.timer' roles/common/usr/lib/systemd/system-preset/80-coolify-aws.preset
grep -Fq 'OnCalendar=*-*-* 11:00:00 UTC' roles/common/usr/lib/systemd/system/bootc-fetch-apply-updates.timer.d/10-coolify-aws.conf
grep -Fq 'install -d -m 0755 /nix' Containerfile
grep -Fxq 'SELINUX=enforcing' roles/common/etc/selinux/config
grep -Fxq 'SELINUXTYPE=targeted' roles/common/etc/selinux/config
if rg -n 'nix\.mount|nix-storage|/var/lib/nix' roles Containerfile; then
    echo "Determinate's OSTree planner, not the bootc image, must own Nix mount units" >&2
    exit 1
fi
grep -Eq '^IMAGE_BUILDER_IMAGE=.+@sha256:[0-9a-f]{64}$' image/image-builder.env
grep -Eq '^SHELLCHECK_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Eq '^ACTIONLINT_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Eq '^REGISTRY_IMAGE=.+@sha256:[0-9a-f]{64}$' ci/images.env
grep -Fq 'IMAGE_VERSION' scripts/build.sh
grep -Fq 'benchmark-base|controller|worker' scripts/build.sh
grep -Fq 'benchmark-base|controller|worker' scripts/validate-image.sh
grep -Fq 'FROM common AS benchmark-base' Containerfile
grep -Fq '/usr/lib/coolify-aws/image-version' Containerfile
grep -Fq '=~ ^[[:alnum:].:-]+$' scripts/vm-init.sh
grep -Fq '=~ ^[[:alnum:].:-]+$' scripts/vm-validate-update.sh
grep -Fq 'CONTAINER_ENGINE' scripts/build-disk.sh
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
grep -Fq 'image-output/worker/coolify-worker-ami.raw' .github/workflows/ami.yml
if grep -Fq 'image-output/worker/coolify-worker-ami.ami' .github/workflows/ami.yml; then
    echo "AMI workflow must use the raw artifact emitted by build-disk.sh" >&2
    exit 1
fi
grep -Fq 'resource "aws_nat_gateway" "this"' tofu/modules/network/main.tf
grep -Fq 'default     = false' tofu/modules/network/variables.tf
grep -Fq 'image_tag_mutability = length(var.mutable_channel_tags) > 0 ? "IMMUTABLE_WITH_EXCLUSION" : "IMMUTABLE"' tofu/modules/ecr/main.tf
grep -Fq 'resource "aws_flow_log" "this"' tofu/modules/network/main.tf
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
grep -Fq "github.ref == 'refs/heads/main'" .github/workflows/publish.yml
grep -Fq 'id-token: write' .github/workflows/publish.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'IMAGE_TAG: sha-${{ github.sha }}' .github/workflows/publish.yml
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
grep -Fq 'enable_key_rotation     = true' tofu/modules/runtime-secrets/main.tf
grep -Fq 'variable = "kms:ViaService"' tofu/modules/runtime-secrets/main.tf
grep -Fq '{{resolve:secretsmanager:' tofu/modules/runtime-secrets/outputs.tf
grep -Fq 'default     = "amd64"' tofu/environments/aws/variables.tf
grep -Fq 'default     = "t3a.small"' tofu/environments/aws/variables.tf
grep -Fq 'default     = "t3a.large"' tofu/environments/aws/variables.tf
grep -Fq 'enable_ami_launch_validation' tofu/environments/aws/variables.tf
grep -Fq 'run_aws_launch:' .github/workflows/ami.yml
grep -Fq 'run_aws_validation:' .github/workflows/ami.yml
grep -Fq 'ami_lifecycle:' .github/workflows/ami.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'AMI_LIFECYCLE: ${{ inputs.ami_lifecycle }}' .github/workflows/ami.yml
grep -Fq "docker pull \"\${WORKER_IMAGE_REF}\"" .github/workflows/ami.yml
# This is a literal GitHub Actions shell expression.
# shellcheck disable=SC2016
grep -Fq 'CONTAINER_ENGINE=docker ./scripts/validate-image.sh "${WORKER_IMAGE_REF}"' .github/workflows/ami.yml
grep -Fq 'AWS_ECR_WORKER_REPOSITORY_URL' .github/workflows/ami.yml
grep -Fq "worker_image_ref=\"\${ECR_REPOSITORY_URL}:sha-\${GITHUB_SHA}\"" .github/workflows/ami.yml
grep -Fq 'retained AMIs require the disposable EC2 launch gate' scripts/validate-ami-import.sh
grep -Fq 'artifact_purpose=ami-release' scripts/validate-ami-import.sh
grep -Fq 'completed_successfully=true' scripts/validate-ami-import.sh
grep -Fq 'AMI_SWITCH_TARGET_REF' scripts/validate-ami-import.sh
grep -Fq 'CENTOS_BOOTC_IMAGE: quay.io/centos-bootc/centos-bootc:stream10@sha256:' .github/workflows/ami-switch-benchmark.yml
grep -Fq './scripts/build.sh benchmark-base' .github/workflows/ami-switch-benchmark.yml
# This is a literal workflow shell variable.
# shellcheck disable=SC2016
grep -Fq './scripts/validate-image.sh "${BOOTSTRAP_IMAGE}"' .github/workflows/ami-switch-benchmark.yml
# This is a literal GitHub Actions expression.
# shellcheck disable=SC2016
grep -Fq 'AMI_SWITCH_TARGET_REF: ${{ env.WORKER_IMAGE_REF }}' .github/workflows/ami-switch-benchmark.yml
grep -Fq 'nix build --no-link --print-out-paths .#coldsnap' .github/workflows/ami.yml
grep -Fq 'coldsnap = pkgs.coldsnap;' flake.nix
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
if rg -n 'key_name|associate_public_ip_address|user_data' tofu/modules/ec2-launch-templates; then
    echo "launch templates must not embed key pairs, networking placement, or user data" >&2
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
