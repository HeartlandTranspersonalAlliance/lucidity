{lib, ...}: {
  perSystem = {
    config,
    lucidityProject,
    pkgs,
    ...
  }: let
    inherit
      (lucidityProject)
      awsConfig
      awsProductionVars
      lucidity
      lucidityRelease
      mkPatchedSource
      mkShellTest
      mkSource
      rolePackages
      source
      ;
    infrastructureTestSource = mkSource "infrastructure-tests" [../infra/tests];
    secretspecSource = mkSource "secretspec" [../../secretspec.toml];
    runtimeToolsSource = mkSource "runtime-tools-policy" [
      ../../scripts
      ../../.github/workflows/validate.yml
    ];
    toolingBuildSource = mkSource "tooling-build" [
      ../../flake.nix
      ../../ci
      ../../image/image-builder.env
    ];
    controllerTestSource = mkPatchedSource "controller-test" [
      ../den/aspects/controller/tests
    ];
    workerTestSource = mkPatchedSource "worker-test" [
      ../den/aspects/worker/tests
    ];
    policyTestSource = mkPatchedSource "repository-test-policy" [
      ../../scripts
      ../../tests
      ../den/aspects
    ];
    manifestsCheck = pkgs.runCommand "lucidity-manifest-check" {} ''
      ${pkgs.jq}/bin/jq -e '.role == "controller" and .overlayIPv4 == "100.96.0.1"' ${rolePackages.host-manifest-controller} >/dev/null
      ${pkgs.jq}/bin/jq -e '.role == "worker" and .overlayIPv4 == "100.96.0.2"' ${rolePackages.host-manifest-worker} >/dev/null
      touch "$out"
    '';
    cloudInitCheck =
      pkgs.runCommand "lucidity-cloud-init-check" {
        nativeBuildInputs = [pkgs.jq pkgs.openssh];
      } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        ssh-keygen -q -t ed25519 -N "" -f fixture-key
        admin_key=$(< fixture-key.pub)
        ADMIN_SSH_PUBLIC_KEY="$admin_key" \
          ${rolePackages.cloud-init-controller}/bin/lucidity-cloud-init-controller user-data 10.0.2.2:5001 > controller.yml
        ADMIN_SSH_PUBLIC_KEY="$admin_key" \
          COOLIFY_WORKER_SSH_PUBLIC_KEY="$admin_key" \
          ${rolePackages.cloud-init-worker}/bin/lucidity-cloud-init-worker user-data 10.0.2.2:5000 > worker.yml
        ${rolePackages.cloud-init-controller}/bin/lucidity-cloud-init-controller meta-data > controller-meta.json
        ${rolePackages.cloud-init-worker}/bin/lucidity-cloud-init-worker meta-data > worker-meta.json
        tail -n +2 controller.yml > controller.json
        tail -n +2 worker.yml > worker.json
        jq -e '
          .hostname == "coolify-controller-test" and
          (.users[1].ssh_authorized_keys | length) == 1 and
          any(.write_files[]; .path == "/etc/lucidity/admin-authorized-key") and
          any(.write_files[]; .path == "/etc/systemd/system/openbao.service.d/99-lucidity-vm-fixture.conf")
        ' controller.json >/dev/null
        jq -e '
          .hostname == "coolify-worker-test" and
          any(.write_files[]; .path == "/etc/coolify-worker/authorized_keys")
        ' worker.json >/dev/null
        jq -e '
          ."instance-id" == "coolify-controller-local-1" and
          ."local-hostname" == "coolify-controller-test"
        ' controller-meta.json >/dev/null
        jq -e '
          ."instance-id" == "coolify-worker-local-1" and
          ."local-hostname" == "coolify-worker-test"
        ' worker-meta.json >/dev/null
        ! grep -R -F "$admin_key" ${rolePackages.cloud-init-controller} ${rolePackages.cloud-init-worker}
        touch "$out"
      '';
    policyCheck = pkgs.runCommand "lucidity-policy-check" {} ''
      grep -Fq 'PermitRootLogin no' ${rolePackages.bootc-context-controller}/rootfs/etc/ssh/sshd_config.d/40-lucidity.conf
      grep -Fq 'PermitRootLogin prohibit-password' ${rolePackages.bootc-context-worker}/rootfs/etc/ssh/sshd_config.d/40-lucidity.conf
      grep -Fq 'nix-store --load-db' ${rolePackages.bootc-context-controller}/rootfs/usr/libexec/lucidity/activate-nix-profile
      grep -Fq '[[ -e $destination ]] || cp -a' ${rolePackages.bootc-context-controller}/rootfs/usr/libexec/lucidity/activate-nix-profile
      grep -Fq 'install -d -m 0755 /nix ' ${rolePackages.bootc-context-controller}/Containerfile
      grep -Fq 'lucidity-admin-authorized-key.service' ${rolePackages.bootc-context-worker}/Containerfile
      test -f ${rolePackages.bootc-context-controller}/rootfs/usr/share/lucidity/nix-smoke/flake.nix
      test -f ${rolePackages.bootc-context-controller}/rootfs/usr/share/lucidity/nix-smoke/flake.lock
      test -f ${rolePackages.bootc-context-worker}/rootfs/usr/share/lucidity/nix-smoke/flake.nix
      test -f ${rolePackages.bootc-context-worker}/rootfs/usr/share/lucidity/nix-smoke/flake.lock
      grep -Fq 'Environment=COOLIFY_CURL_BIN=/usr/bin/curl' ${rolePackages.bootc-context-controller}/rootfs/usr/lib/systemd/system/coolify-controller-bootstrap.service
      ! grep -Fq 'Requires=lucidity-nix-profile.service' ${rolePackages.bootc-context-worker}/rootfs/usr/lib/systemd/system/lucidity-admin-authorized-key.service
      grep -Fq '100.96.0.1' ${rolePackages.bootc-context-worker}/rootfs/etc/nebula/config.yml.in
      grep -Fq 'address = "127.0.0.1:8200"' ${rolePackages.bootc-context-controller}/rootfs/etc/openbao/openbao.hcl.in
      test -f ${rolePackages.bootc-context-controller}/rootfs/usr/lib/systemd/system/lucidity-backup.service
      test -f ${rolePackages.bootc-context-controller}/rootfs/usr/lib/systemd/system/lucidity-backup.timer
      test -f ${rolePackages.bootc-context-worker}/rootfs/usr/lib/systemd/system/lucidity-backup.service
      test -f ${rolePackages.bootc-context-worker}/rootfs/usr/lib/systemd/system/lucidity-backup.timer
      grep -Fq 'Requires=openbao.service' ${rolePackages.bootc-context-controller}/rootfs/usr/lib/systemd/system/lucidity-backup.service
      ! grep -Fq 'openbao.service' ${rolePackages.bootc-context-worker}/rootfs/usr/lib/systemd/system/lucidity-backup.service
      ! grep -R -E 'GetSecretValue|BatchGetSecretValue' ${rolePackages.bootc-context-controller}/rootfs/usr/libexec
      touch "$out"
    '';
    infrastructureCheck =
      pkgs.runCommand "lucidity-infrastructure-check" {
        nativeBuildInputs = [
          pkgs.jq
          (pkgs.opentofu.withPlugins (plugins: [
            plugins.hashicorp_aws
            plugins.cloudflare_cloudflare
          ]))
        ];
      } ''
        aws=${awsConfig}
        production_vars=${awsProductionVars}
        state=${config.terranix.terranixConfigurations.state.result.terraformConfiguration}
        ${pkgs.jq}/bin/jq -e '
          . as $root |
          ([
            "account_cost_budget_notification_email",
            "node_alarm_notification_email",
            "controller_ami_id",
            "worker_ami_id",
            "cloudflare_zone_id",
            "github_oidc_provider_arn",
            "root_volume_kms_key_arn"
          ] | all(.[]; . as $name | ($root.variable[$name] | has("default") and .default == null))) and
          .variable.account_annual_cost_limit_usd.default == 1100 and
          .variable.controller_instance_type.default == "t3a.small" and
          .variable.worker_instance_type.default == "t3a.medium" and
          .variable.ec2_node_availability_zone_indices.default.controller == 0 and
          .variable.ec2_node_availability_zone_indices.default.worker == 0 and
          .module.network.nebula_udp_port == 4242 and
          .variable.cloudflare_dns_records.default.mesh.proxied == false and
          .output.ses_pricing_plan.value == "NONE" and
          (.resource.aws_iam_policy.openbao_unseal.policy | contains("kms:Encrypt")) and
          (.resource.aws_iam_policy.openbao_unseal.policy | contains("kms:Decrypt")) and
          (.resource.aws_iam_policy.openbao_unseal.policy | contains("kms:DescribeKey"))
        ' "$aws" >/dev/null
        ${pkgs.jq}/bin/jq -e '
          .enable_account_security_baseline and
          .enable_ami_launch_validation and
          .enable_instance_management and
          .enable_network and
          .enable_openbao and
          .enable_runtime_secrets and
          .flow_log_retention_days == 90 and
          (keys | length == 7)
        ' "$production_vars" >/dev/null
        network=$(${pkgs.jq}/bin/jq -r '.module.network.source' "$aws")
        ${pkgs.gnugrep}/bin/grep -Rq 'from_port[[:space:]]*=[[:space:]]*var.nebula_udp_port' "$network"
        ${pkgs.gnugrep}/bin/grep -Fq 'resource "aws_flow_log" "rejected"' "$network/main.tf"
        ${pkgs.gnugrep}/bin/grep -Fq 'traffic_type = "ALL"' "$network/main.tf"
        ! ${pkgs.gnugrep}/bin/grep -R -E 'from_port[[:space:]]*=[[:space:]]*22|to_port[[:space:]]*=[[:space:]]*22' "$network"
        security=$(${pkgs.jq}/bin/jq -r '.module.account_security_baseline.source' "$aws")
        ${pkgs.gnugrep}/bin/grep -Fq 'resource "aws_cloudtrail" "account"' "$security/main.tf"
        ${pkgs.gnugrep}/bin/grep -Fq 'resource "aws_securityhub_account_v2" "account"' "$security/main.tf"
        ${pkgs.gnugrep}/bin/grep -Fq 'state = "block-all-sharing"' "$security/main.tf"
        instance_management=$(${pkgs.jq}/bin/jq -r '.module.instance_management.source' "$aws")
        ${pkgs.gnugrep}/bin/grep -Fq 'for_each = var.controller_policies' "$instance_management/main.tf"
        ${pkgs.jq}/bin/jq -e '
          .module.instance_management.controller_policies |
          contains("runtime_secrets") and contains("openbao_unseal")
        ' "$aws" >/dev/null
        mkdir generated-aws
        ${pkgs.jq}/bin/jq 'del(.terraform.backend)' "$aws" >generated-aws/main.tf.json
        mkdir generated-aws/tests
        cp ${infrastructureTestSource}/nix/infra/tests/aws.tftest.hcl generated-aws/tests/aws.tftest.hcl
        tofu -chdir=generated-aws init -backend=false -input=false >/dev/null
        tofu -chdir=generated-aws validate
        tofu -chdir=generated-aws test
        ${pkgs.jq}/bin/jq -e '
          .terraform.backend.s3 == {} and
          (.moved | length) == 13 and
          .moved[0].from == "aws_s3_bucket.state" and
          .moved[0].to == "module.bootstrap.aws_s3_bucket.state"
        ' "$state" >/dev/null
        mkdir generated-state
        ${pkgs.jq}/bin/jq 'del(.terraform.backend)' "$state" >generated-state/main.tf.json
        mkdir generated-state/tests
        cp ${infrastructureTestSource}/nix/infra/tests/state.tftest.hcl generated-state/tests/state.tftest.hcl
        tofu -chdir=generated-state init -backend=false -input=false >/dev/null
        tofu -chdir=generated-state validate
        tofu -chdir=generated-state test
        touch "$out"
      '';
    secretspecCheck = pkgs.runCommand "lucidity-secretspec-schema-check" {} ''
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${secretspecSource}/secretspec.toml --profile operator --output schema.json
      ${pkgs.jq}/bin/jq -e '
        (.required | sort) == ["ADMIN_SSH_PUBLIC_KEY", "NEBULA_CA_PASSPHRASE"]
      ' schema.json >/dev/null
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${secretspecSource}/secretspec.toml --profile coolify --output coolify-schema.json
      ${pkgs.jq}/bin/jq -e '
        .required == ["COOLIFY_API_TOKEN"]
      ' coolify-schema.json >/dev/null
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${secretspecSource}/secretspec.toml --profile vm-worker --output vm-worker-schema.json
      ${pkgs.jq}/bin/jq -e '
        (.required | sort) == ["ADMIN_SSH_PUBLIC_KEY", "COOLIFY_WORKER_SSH_PUBLIC_KEY"]
      ' vm-worker-schema.json >/dev/null
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${secretspecSource}/secretspec.toml --profile backup-controller-aws --output backup-controller-schema.json
      ${pkgs.jq}/bin/jq -e '
        .required == ["RESTIC_PASSWORD_FILE"]
      ' backup-controller-schema.json >/dev/null
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${secretspecSource}/secretspec.toml --profile backup-worker-s3 --output backup-worker-schema.json
      ${pkgs.jq}/bin/jq -e '
        (.required | sort) == ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "RESTIC_PASSWORD_FILE"]
      ' backup-worker-schema.json >/dev/null
      touch "$out"
    '';
    repositoryCheck =
      pkgs.runCommand "lucidity-repository-policy-check" {
        nativeBuildInputs = [pkgs.ripgrep];
      } ''
        cd ${source}

        version=$(<VERSION)
        [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
        rg -Fq "## [$version] - " CHANGELOG.md
        rg -Fq "Current version: **$version**" README.md

        help=$(${lucidity}/bin/lucidity --help)
        for interface in generate check build vm infra state secrets mesh release; do
          grep -Eq "(^|[[:space:]])$interface([[:space:]]|$)" <<<"$help"
        done
        grep -Fq 'secrets initialize-controller-runtime' <<<"$help"

        if rg -n 'secretsmanager[[:space:]]+(get-secret-value|batch-get-secret-value)' nix scripts tests; then
          echo "direct Secrets Manager value retrieval is prohibited; use asm-exec" >&2
          exit 1
        fi
        rg -q 'secretsmanager put-secret-value.*--region' nix/pkgs/lucidity.sh
        rg -q 'list-secret-version-ids' nix/pkgs/lucidity.sh
        rg -q -- '--secret-string "file://\$secret_file"' nix/pkgs/lucidity.sh
        if rg -n '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)' nix secretspec.toml; then
          echo "SSH public key material must be resolved from SecretSpec, not committed" >&2
          exit 1
        fi
        if rg -n '^#!/usr/bin/env' \
          ${policyTestSource}/scripts \
          ${policyTestSource}/tests \
          ${policyTestSource}/nix/den/aspects; then
          echo "copied test executables must use patchShebangs-resolved Nix-store interpreters" >&2
          exit 1
        fi

        rg -q '^\[profiles\.coolify\]$' secretspec.toml
        rg -q '^aws-production = "awssm://us-east-2?' secretspec.toml
        rg -q '^COOLIFY_API_TOKEN = \{ required = true \}$' secretspec.toml
        rg -Fq 'RESTIC_PASSWORD_FILE = { description = "Restic repository encryption password materialized as a private temporary file", required = false, as_path = true }' secretspec.toml
        rg -q '^\[scopes\.backup-aws\]$' secretspec.toml
        rg -q '^\[scopes\.backup-s3\]$' secretspec.toml
        rg -q 'coolify-worker-storage.service' nix/den/classes/bootc/image.nix
        rg -q 'Environment=COOLIFY_CURL_BIN=/usr/bin/curl' nix/den/classes/bootc/image.nix
        rg -q 'lucidity-admin-authorized-key.service' nix/den/classes/bootc/image.nix
        rg -Fq 'secretspec run' nix/pkgs/cloud-init-fixture.nix
        rg -Fq 'nix flake check --show-trace --print-build-logs' .github/workflows/validate.yml
        ! rg -q 'checks\.x86_64-linux|make |\./scripts/' .github/workflows/validate.yml
        rg -Fq 'run: nix run .#audit-ami-resources' .github/workflows/audit-ami-resources.yml
        ! rg -q 'run: \./scripts/' .github/workflows/audit-ami-resources.yml
        rg -Fq 'run: nix run .#validate-deployment' .github/workflows/validate-deployment.yml
        ! rg -q 'run: \./scripts/' .github/workflows/validate-deployment.yml
        if rg -n 'make |\./scripts/' .github/workflows; then
          echo "GitHub workflows must invoke flake apps instead of Make or repository scripts" >&2
          exit 1
        fi
        rg -Fq 'run: nix run .#release -- prepare' .github/workflows/release.yml
        rg -Fq 'source_sha:' .github/workflows/release.yml
        rg -Fq 'tooling_sha: ''${{ steps.version.outputs.tooling_sha }}' .github/workflows/release.yml
        test "$(rg -F 'ref: ''${{ needs.prepare.outputs.tooling_sha }}' .github/workflows/release.yml | wc -l)" -eq 3
        ! rg -Fq 'ref: ''${{ needs.prepare.outputs.source_sha }}' .github/workflows/release.yml
        rg -Fq 'run: nix run .#release -- image' .github/workflows/release.yml
        rg -Fq 'run: nix run .#release -- manifest' .github/workflows/release.yml
        rg -Fq 'run: nix run .#ci -- ecr pin-local' .github/workflows/release.yml
        rg -Fq 'IMAGE_NAME: ''${{ env.VERIFIED_IMAGE_REF }}' .github/workflows/release.yml
        rg -Fq 'docker_run_args+=(--volume "''${docker_config}:/root/.docker/config.json:ro")' scripts/build-disk.sh
        ! rg -q 'cat .*docker_config|cp .*docker_config' scripts/build-disk.sh
        rg -Fq 'nix/pkgs/lucidity.sh | scripts/build-disk.sh)' nix/pkgs/lucidity.sh
        rg -Fq 'run: nix run .#ci -- timing summarize' .github/workflows/release.yml
        ! rg -Fq 'uses: ./.github/workflows/ami.yml' .github/workflows/release.yml
        ! rg -Fq 'uses: ./.github/workflows/publish.yml' .github/workflows/release.yml
        ! rg -q '^        run: \|' .github/workflows/release.yml
        rg -Fq 'run: nix run .#ci -- ecr resolve' .github/workflows/publish.yml
        ! rg -q '^        run: \|' .github/workflows/publish.yml
        rg -Fq 'run: nix run .#ci -- ami resolve' .github/workflows/ami.yml
        rg -Fq 'run: nix run .#ci -- ami pull' .github/workflows/ami.yml
        rg -Fq 'run: nix run .#ci -- ami validate-inputs' .github/workflows/ami.yml
        rg -Fq 'run: nix run .#ci -- benchmark resolve' .github/workflows/ami-switch-benchmark.yml
        rg -Fq 'run: nix run .#ci -- benchmark verify-target' .github/workflows/ami-switch-benchmark.yml
        if rg -n '^\s+(aws (ecr|ec2|ssm|secretsmanager)|podman pull)' .github/workflows; then
          echo "AWS and image policy must live behind flake-owned CI commands" >&2
          exit 1
        fi

        rg -Fq 'extra-substituters = ["https://lucidity.cachix.org"]' flake.nix
        rg -Fq 'lucidity.cachix.org-1:EiVuaCjci+zOjSGxHE3nOXVNPVCfXfwfCFzba1vnirA=' flake.nix
        cache_action='cachix/cachix-action@5f2d7c5294214f71b873db4b969586b980625e71'
        trusted_events="github.event_name == 'merge_group' || github.event_name == 'release' || github.event_name == 'schedule' || github.event_name == 'workflow_call' || github.event_name == 'workflow_dispatch' || (github.event_name == 'push' && github.ref == 'refs/heads/main')"
        mapfile -t cache_workflows < <(rg -l -F 'run: nix ' .github/workflows | sort)
        test "''${#cache_workflows[@]}" -eq 9
        for workflow in "''${cache_workflows[@]}"; do
          rg -Fq "$trusted_events" "$workflow"
          rg -Fq "$cache_action" "$workflow"
          rg -Fq "env.NIX_CACHE_WRITE == 'true' && secrets.CACHIX_AUTH_TOKEN" "$workflow"
          rg -Fq "env.NIX_CACHE_WRITE != 'true'" "$workflow"
          rg -Fq 'pushFilter: lucidity-(controller|worker)-bootc-context' "$workflow"
          rg -Fq 'CACHIX_AUTH_TOKEN is required for trusted cache-writing events' "$workflow"

          mapfile -t installers < <(rg -n -F 'DeterminateSystems/determinate-nix-action@' "$workflow" | cut -d: -f1)
          mapfile -t caches < <(rg -n -F "$cache_action" "$workflow" | cut -d: -f1)
          test "''${#installers[@]}" -eq "''${#caches[@]}"
          for index in "''${!installers[@]}"; do
            test "''${caches[$index]}" -gt "''${installers[$index]}"
          done
        done
        test "$(rg -F "$cache_action" .github/workflows | wc -l)" -eq 14
        test "$(rg -F 'pushFilter: lucidity-(controller|worker)-bootc-context' .github/workflows | wc -l)" -eq 14
        test "$(rg -F 'kvm: true' .github/workflows | wc -l)" -eq 15
        ! rg -q '99-kvm4all|udevadm.*kvm' .github/workflows
        ! rg -q 'pathsToPush:.*(qcow2|raw|ami|bootc-context)' .github/workflows
        test "$(rg -F 'cache configure ci-tools' .github/workflows | wc -l)" -eq 4
        rg -Fq 'BUILD_CACHE_FROM="''${BUILD_CACHE_FROM}"' .github/workflows/ami.yml
        rg -Fq 'BUILD_CACHE_TO="''${BUILD_CACHE_TO}"' .github/workflows/ami.yml
        ! rg -q 'tests/run\.sh|tests/vm-(role|mesh)\.sh|ci/run-with-progress\.sh' \
          nix .github/workflows README.md
        test ! -e Containerfile
        test ! -e Makefile
        test ! -e roles
        test ! -e tofu/environments/aws
        touch "$out"
      '';
    runtimeToolsCheck = pkgs.runCommand "lucidity-runtime-tools-check" {} ''
      grep -Fq ${lib.escapeShellArg "${pkgs.qemu-utils}/bin"} ${lib.getExe lucidity}
      grep -Fq ${lib.escapeShellArg "${pkgs.xorriso}/bin"} ${lib.getExe lucidity}
      grep -Fq 'base_image=''${VM_BASE_IMAGE:-localhost/coolify-bootc-$role:lifecycle-v1}' ${lib.getExe lucidity}
      grep -Fq 'update_image=''${VM_UPDATE_IMAGE:-localhost/coolify-bootc-$role:lifecycle-v2}' ${lib.getExe lucidity}
      grep -Fq 'IMAGE_NAME=$update_image IMAGE_VERSION=lifecycle-v2 build_role "$role"' ${lib.getExe lucidity}
      grep -Fq 'VM_BASE_IMAGE=$base_image VM_UPDATE_IMAGE=$update_image' ${lib.getExe lucidity}
      grep -Fq 'trap "vm_test_cleanup $role" EXIT' ${lib.getExe lucidity}
      grep -Fq 'vm_test_cleanup "$role"' ${lib.getExe lucidity}
      grep -Fq 'admin@127.0.0.1' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      grep -Fq 'admin_login[@]}" sudo -n' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      ! grep -Fq 'admin_identity}" root@127.0.0.1' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      grep -Fq 'bootc status --booted --format json | grep -Fq "''${expected_ref}"' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      ! grep -Fq '/usr/lib/coolify-aws/image-version' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      grep -Fq '/nix/var/nix/profiles/default/bin/nix build' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      grep -Fq '/usr/share/lucidity/nix-smoke' \
        ${lucidity.runtimeScripts}/libexec/lucidity/vm-validate-update.sh
      ! grep -R -Fq '/usr/share/coolify-aws/nix-smoke' \
        ${lucidity.runtimeScripts}/libexec/lucidity
      ! grep -Fq 'IMAGE_NAME: localhost/lucidity-' ${runtimeToolsSource}/.github/workflows/validate.yml
      for script in \
        audit-ami-validation-resources.sh build-disk.sh check-text-style.sh \
        validate-ami-import.sh validate-deployment.sh validate-disk.sh \
        vm-init.sh vm-integration.sh vm-registry.sh vm-start.sh vm-stop.sh \
        vm-validate-update.sh vm-validate.sh; do
        test -x "${lucidity.runtimeScripts}/libexec/lucidity/$script"
        head -n 1 "${lucidity.runtimeScripts}/libexec/lucidity/$script" | \
          grep -Fq '/nix/store/'
      done
      source_count=$(find ${runtimeToolsSource}/scripts -maxdepth 1 -type f -name '*.sh' | wc -l)
      packaged_count=$(find ${lucidity.runtimeScripts}/libexec/lucidity -maxdepth 1 -type f -name '*.sh' | wc -l)
      test "$source_count" -eq "$packaged_count"
      while IFS= read -r source_script; do
        test -x "${lucidity.runtimeScripts}/libexec/lucidity/$(basename "$source_script")"
      done < <(find ${runtimeToolsSource}/scripts -maxdepth 1 -type f -name '*.sh' -print)
      ! grep -Fq '$root/scripts/' ${lib.getExe lucidity}
      grep -Fq 'syft.yaml' ${lib.getExe lucidity}
      touch "$out"
    '';
    yamlPolicyCheck =
      pkgs.runCommand "lucidity-yaml-policy-check" {
        nativeBuildInputs = [pkgs.findutils pkgs.ripgrep pkgs.yq-go];
      } ''
        cd ${source}
        while IFS= read -r file; do
          yq eval '.' "$file" >/dev/null
        done < <(find .github -type f \( -name '*.yml' -o -name '*.yaml' \) -print | sort)

        yq -e '.version == 2 and (.updates | length > 0)' .github/dependabot.yml >/dev/null
        yq -e '.check-for-app-update == false and (.default-catalogers | length > 0)' \
          .github/syft.yaml >/dev/null
        if rg -n -P '^\s*uses:\s*(?!\./)[^@\s]+@(?![0-9a-f]{40}(?:\s|$))' \
          .github/workflows; then
          echo 'external GitHub Actions must be pinned to full commit SHAs' >&2
          exit 1
        fi
        touch "$out"
      '';
    cacheDocker = pkgs.writeShellScriptBin "docker" ''
      set -Eeuo pipefail
      if [[ -n ''${MOCK_DOCKER_LOG:-} ]]; then
        printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"
      fi
      if [[ $1 == login ]]; then
        cat >/dev/null
        exit 0
      fi
      if [[ $1 == buildx && $2 == imagetools && $3 == inspect ]]; then
        [[ ''${MOCK_CACHE_HIT:-false} == true ]]
        exit
      fi
      exit 0
    '';
    lifecycleDocker = pkgs.writeShellScriptBin "docker" ''
      set -Eeuo pipefail
      printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"
      if [[ $1 == image && $2 == inspect && ''${3:-} == --format ]]; then
        printf '%s\n' "$MOCK_ROLE"
      fi
    '';
    ecrPinDocker = pkgs.writeShellScriptBin "docker" ''
      set -Eeuo pipefail
      printf '%s\n' "$*" >>"$MOCK_DOCKER_LOG"
      if [[ $1 == image && $2 == inspect ]]; then
        printf 'linux/amd64\n'
      fi
    '';
    lifecycleNix = pkgs.writeShellScriptBin "nix" ''
      set -Eeuo pipefail
      [[ $1 == build ]]
      printf '%s\n' "$MOCK_BOOTC_CONTEXT"
    '';
    lifecycleCommandSource = mkSource "lifecycle-command" [
      ../../flake.nix
      ../pkgs/lucidity.sh
    ];
    lifecycleScopeCheck =
      pkgs.runCommand "lucidity-lifecycle-scope-check" {
        nativeBuildInputs = [
          lifecycleDocker
          lifecycleNix
          pkgs.bash
          pkgs.coreutils
          pkgs.gnugrep
        ];
      } ''
        mkdir context
        export MOCK_BOOTC_CONTEXT="$PWD/context"
        export MOCK_DOCKER_LOG="$PWD/docker.log"
        export CONTAINER_ENGINE=docker

        for role in controller worker; do
          : >"$MOCK_DOCKER_LOG"
          export MOCK_ROLE="$role"
          LUCIDITY_REPOSITORY_ROOT=${lifecycleCommandSource} \
            bash ${lifecycleCommandSource}/nix/pkgs/lucidity.sh vm test "$role"

          lifecycle_image="localhost/coolify-bootc-$role:lifecycle-v1"
          grep -Fxq "image inspect $lifecycle_image" "$MOCK_DOCKER_LOG"
          ! grep -Fq 'image inspect quay.io/almalinuxorg/almalinux-bootc:10' "$MOCK_DOCKER_LOG"
        done
        touch "$out"
      '';
    cacheUnitCheck =
      pkgs.runCommand "lucidity-cache-unit-check" {
        nativeBuildInputs = [cacheDocker pkgs.gnugrep];
      } ''
        export GITHUB_ACTOR=lucidity-ci
        export GITHUB_REPOSITORY=example/lucidity
        export GITHUB_TOKEN=not-a-real-token
        export GHCR_CACHE_WRITE=true
        export DOCKER_COMMAND=${cacheDocker}/bin/docker

        GITHUB_ENV=$PWD/hit.env GITHUB_OUTPUT=$PWD/hit.out MOCK_CACHE_HIT=true \
          ${lucidity}/bin/lucidity ci cache configure controller
        grep -Fxq 'BUILD_CACHE_FROM=ghcr.io/example/lucidity-build-cache:controller' hit.env
        grep -Fxq 'BUILD_CACHE_TO=ghcr.io/example/lucidity-build-cache:controller' hit.env
        grep -Fxq 'GHCR_CACHE_HIT=true' hit.env
        grep -Fxq 'hit=true' hit.out

        GITHUB_ENV=$PWD/miss.env GITHUB_OUTPUT=$PWD/miss.out MOCK_CACHE_HIT=false \
          ${lucidity}/bin/lucidity ci cache configure worker
        grep -Fxq 'BUILD_CACHE_FROM=' miss.env
        grep -Fxq 'BUILD_CACHE_TO=ghcr.io/example/lucidity-build-cache:worker' miss.env
        grep -Fxq 'GHCR_CACHE_HIT=false' miss.env
        grep -Fxq 'hit=false' miss.out

        GITHUB_ENV=$PWD/tools.env GITHUB_OUTPUT=$PWD/tools.out MOCK_CACHE_HIT=true \
          ${lucidity}/bin/lucidity ci cache configure ci-tools
        grep -Fxq 'BUILD_CACHE_FROM=ghcr.io/example/lucidity-build-cache:ci-tools' tools.env
        grep -Fxq 'BUILD_CACHE_TO=ghcr.io/example/lucidity-build-cache:ci-tools' tools.env

        export MOCK_DOCKER_LOG=$PWD/docker.log
        LUCIDITY_REPOSITORY_ROOT=${toolingBuildSource} \
          CI_TOOLS_IMAGE=localhost/lucidity-ci-tools:test \
          BUILD_CACHE_FROM=ghcr.io/example/lucidity-build-cache:ci-tools \
          BUILD_CACHE_TO=ghcr.io/example/lucidity-build-cache:ci-tools \
          BUILDX_BUILDER_NAME=lucidity-ci \
          ${lucidity}/bin/lucidity ci build-tools-image
        grep -Fq 'buildx build --load --builder lucidity-ci --cache-from type=registry,ref=ghcr.io/example/lucidity-build-cache:ci-tools' docker.log
        grep -Fq -- '--cache-to type=registry,ref=ghcr.io/example/lucidity-build-cache:ci-tools,mode=max,image-manifest=true,oci-mediatypes=true' docker.log

        BUILD_CACHE_ENGINE=docker BUILDX_BUILDER_NAME=lucidity-ci \
          ${lucidity}/bin/lucidity ci cache cleanup
        touch "$out"
      '';
    ciWorkflowUnitCheck =
      pkgs.runCommand "lucidity-ci-workflow-unit-check" {
        nativeBuildInputs = [ecrPinDocker pkgs.gnugrep];
      } ''
        touch github.env
        AMI_ROLE=worker \
          AMI_LIFECYCLE=disposable \
          IMAGE=localhost/lucidity-worker:test \
          GITHUB_ENV=$PWD/github.env \
          ${lucidity}/bin/lucidity ci ami resolve
        grep -Fxq 'AMI_ARTIFACT=image-output/worker/coolify-worker-ami.raw' github.env
        grep -Fxq 'IMAGE_REF=localhost/lucidity-worker:test' github.env

        RUN_AWS_VALIDATION=false \
          RUN_AWS_LAUNCH=false \
          AMI_LIFECYCLE=disposable \
          ${lucidity}/bin/lucidity ci ami validate-inputs
        if RUN_AWS_VALIDATION=false RUN_AWS_LAUNCH=true AMI_LIFECYCLE=disposable \
          ${lucidity}/bin/lucidity ci ami validate-inputs 2>/dev/null; then
          echo 'AMI input policy accepted launch without AWS validation' >&2
          exit 1
        fi

        : >github.env
        AMI_ROLE_ARN=arn:aws:iam::123456789012:role/import \
          SNAPSHOT_KMS_KEY_ARN=arn:aws:kms:us-east-2:123456789012:key/example \
          TEST_INSTANCE_PROFILE=worker \
          TEST_SECURITY_GROUP=sg-12345678 \
          TEST_SUBNET=subnet-12345678 \
          WORKER_REPOSITORY_URL=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity-worker \
          TARGET_REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
          GITHUB_ENV=$PWD/github.env \
          ${lucidity}/bin/lucidity ci benchmark resolve
        grep -Fxq 'WORKER_IMAGE_REF=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity-worker:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' github.env

        : >github.env
        export MOCK_DOCKER_LOG=$PWD/docker.log
        GITHUB_ENV=$PWD/github.env \
          ${lucidity}/bin/lucidity ci ecr pin-local \
            123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/worker:sha-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
            sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        immutable_ref=123456789012.dkr.ecr.us-east-2.amazonaws.com/lucidity/worker@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        grep -Fxq "pull $immutable_ref" docker.log
        grep -Fxq "VERIFIED_IMAGE_REF=$immutable_ref" github.env

        GITHUB_STEP_SUMMARY=$PWD/summary \
          ${lucidity}/bin/lucidity ci timing summarize 'release path' "$(date +%s)" 611
        grep -Fq '### release path performance' summary
        grep -Fq -- '- Baseline: 611s' summary
        touch "$out"
      '';
    releaseUnitCheck =
      pkgs.runCommand "lucidity-release-unit-check" {
        nativeBuildInputs = [pkgs.git pkgs.jq];
      } ''
        mkdir release
        for role in controller worker; do
          jq -n \
            --arg role "$role" \
            --arg release_tag v1.2.3 \
            --arg digest sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
            --arg sbom_sha256 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
            '{role:$role,release_tag:$release_tag,digest:$digest,sbom_sha256:$sbom_sha256}' \
            >"release/$role.metadata.json"
        done
        GITHUB_OUTPUT="$PWD/outputs" ${lib.getExe lucidityRelease} release inventory v1.2.3
        grep -Fxq 'controller_digest=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' outputs
        grep -Fxq 'worker_sbom_sha256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' outputs

        mkdir resume-repository
        cd resume-repository
        git init -q
        git config user.email release-test@lucidity.invalid
        git config user.name 'Lucidity release test'
        mkdir -p .github/workflows docs/reference nix/flake nix/pkgs scripts
        touch flake.nix
        printf '0.2.0\n' >VERSION
        printf 'Current version: **0.2.0**\n' >README.md
        printf '## [0.2.0] - 2026-08-18\n' >CHANGELOG.md
        git add .
        git commit -qm 'docs: prepare v0.2.0'
        source_sha=$(git rev-parse HEAD)
        printf 'release tooling\n' >.github/workflows/release.yml
        printf 'release helper\n' >nix/pkgs/lucidity.sh
        printf 'disk builder fix\n' >scripts/build-disk.sh
        git add .
        git commit -qm 'fix: resume immutable release'
        tooling_sha=$(git rev-parse HEAD)
        : >outputs
        GITHUB_REF=refs/heads/main \
          GITHUB_SHA="$tooling_sha" \
          GITHUB_OUTPUT=$PWD/outputs \
          LUCIDITY_REPOSITORY_ROOT=$PWD \
          ${lib.getExe lucidityRelease} release prepare minor "$source_sha"
        grep -Fxq "source_sha=$source_sha" outputs
        grep -Fxq "tooling_sha=$tooling_sha" outputs
        grep -Fxq 'tag=v0.2.0' outputs
        grep -Fxq 'version=0.2.0' outputs

        mkdir -p nix/den
        printf 'image input\n' >nix/den/disallowed.nix
        git add .
        git commit -qm 'feat: change appliance input'
        if GITHUB_REF=refs/heads/main \
          GITHUB_SHA=$(git rev-parse HEAD) \
          LUCIDITY_REPOSITORY_ROOT=$PWD \
          ${lib.getExe lucidityRelease} release prepare minor "$source_sha" 2>/dev/null; then
          echo 'release resume accepted a non-tooling change' >&2
          exit 1
        fi
        touch "$out"
      '';
    controllerUnitCheck =
      pkgs.runCommand "lucidity-controller-unit-check" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.gnused pkgs.openssh];
      } ''
        export HOME="$TMPDIR/home"
        cp -R ${rolePackages.bootc-context-controller}/rootfs "$TMPDIR/controller-root"
        chmod -R u+w "$TMPDIR/controller-root"
        patchShebangs "$TMPDIR/controller-root/usr/libexec"
        export LUCIDITY_CONTROLLER_ROOT="$TMPDIR/controller-root"
        export LUCIDITY_CONTROLLER_TEST_FIXTURES=${controllerTestSource}/nix/den/aspects/controller/tests/fixtures
        mkdir -p "$HOME"
        bash ${controllerTestSource}/nix/den/aspects/controller/tests/bootstrap.sh
        touch "$out"
      '';
    workerUnitCheck =
      pkgs.runCommand "lucidity-worker-unit-check" {
        nativeBuildInputs = [pkgs.bash pkgs.coreutils pkgs.gnugrep pkgs.openssh];
      } ''
        export HOME="$TMPDIR/home"
        cp -R ${rolePackages.bootc-context-worker}/rootfs "$TMPDIR/worker-root"
        chmod -R u+w "$TMPDIR/worker-root"
        patchShebangs "$TMPDIR/worker-root/usr/libexec"
        export LUCIDITY_WORKER_ROOT="$TMPDIR/worker-root"
        mkdir -p "$HOME"
        bash ${workerTestSource}/nix/den/aspects/worker/tests/bootstrap.sh
        touch "$out"
      '';
    amiImportUnitCheck = mkShellTest {
      name = "ami-import-unit";
      script = "tests/test-ami-import.sh";
      files = [
        ../../tests/test-ami-import.sh
        ../../tests/fixtures/aws
        ../../tests/fixtures/bootc
        ../../tests/fixtures/coldsnap
        ../../scripts/validate-ami-import.sh
      ];
      nativeBuildInputs = [pkgs.gawk pkgs.jq pkgs.gnused];
    };
    amiAuditUnitCheck = mkShellTest {
      name = "ami-audit-unit";
      script = "tests/test-ami-resource-audit.sh";
      files = [
        ../../tests/test-ami-resource-audit.sh
        ../../tests/fixtures/aws-ami-audit
        ../../scripts/audit-ami-validation-resources.sh
      ];
      nativeBuildInputs = [pkgs.jq];
    };
    deploymentUnitCheck = mkShellTest {
      name = "deployment-unit";
      script = "tests/test-deployment-validation.sh";
      files = [
        ../../tests/test-deployment-validation.sh
        ../../tests/fixtures/aws-deployment-validation
        ../../tests/fixtures/deployment-curl
        ../../scripts/validate-deployment.sh
      ];
      nativeBuildInputs = [pkgs.jq];
    };
    backupUnitCheck = mkShellTest {
      name = "backup-unit";
      script = "tests/test-backup.sh";
      files = [
        ../../tests/test-backup.sh
        ../den/aspects/common/files/backup.sh
        ../../secretspec.toml
      ];
      nativeBuildInputs = [pkgs.findutils pkgs.gnused pkgs.util-linux];
    };
    textStyleUnitCheck = mkShellTest {
      name = "text-style-unit";
      script = "tests/test-text-style.sh";
      files = [
        ../../tests/test-text-style.sh
        ../../scripts/check-text-style.sh
      ];
      nativeBuildInputs = [pkgs.gitMinimal];
    };
    staticChecks = [
      manifestsCheck
      cloudInitCheck
      policyCheck
      infrastructureCheck
      secretspecCheck
      repositoryCheck
      runtimeToolsCheck
      lifecycleScopeCheck
      cacheUnitCheck
      ciWorkflowUnitCheck
      releaseUnitCheck
      controllerUnitCheck
      workerUnitCheck
      amiImportUnitCheck
      amiAuditUnitCheck
      deploymentUnitCheck
      backupUnitCheck
      textStyleUnitCheck
      yamlPolicyCheck
    ];
    staticCheck = pkgs.runCommand "lucidity-static-checks" {} ''
      for check in ${lib.escapeShellArgs (map toString staticChecks)}; do
        test -e "$check"
      done
      touch "$out"
    '';
  in {
    checks = {
      backup-unit = backupUnitCheck;
      ami-audit-unit = amiAuditUnitCheck;
      ami-import-unit = amiImportUnitCheck;
      cache-unit = cacheUnitCheck;
      ci-workflow-unit = ciWorkflowUnitCheck;
      cloud-init = cloudInitCheck;
      controller-unit = controllerUnitCheck;
      deployment-unit = deploymentUnitCheck;
      infrastructure = infrastructureCheck;
      lifecycle-scope = lifecycleScopeCheck;
      manifests = manifestsCheck;
      mesh-vm = import ../den/classes/bootc/tests/mesh.nix {inherit pkgs;};
      policy = policyCheck;
      repository = repositoryCheck;
      runtime-tools = runtimeToolsCheck;
      release-unit = releaseUnitCheck;
      secretspec = secretspecCheck;
      static = staticCheck;
      text-style-unit = textStyleUnitCheck;
      worker-unit = workerUnitCheck;
      yaml-policy = yamlPolicyCheck;
    };
  };
}
