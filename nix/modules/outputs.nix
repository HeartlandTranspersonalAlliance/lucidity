{
  config,
  inputs,
  lib,
  ...
}: let
  flakeConfig = config;
  roles = [
    "controller"
    "worker"
  ];
in {
  flake.homeConfigurations = lib.genAttrs roles (
    role:
      inputs.home-manager.lib.homeManagerConfiguration {
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
        extraSpecialArgs = {inherit role;};
        modules = [../home/admin.nix];
      }
  );

  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: let
    lucidity = import ../pkgs/lucidity.nix {inherit pkgs;};
    asmExec = pkgs.callPackage ../pkgs/asm-exec.nix {};
    awsWorkloadCredentialsProvider =
      pkgs.callPackage ../pkgs/aws-workload-credentials-provider.nix {};
    openbaoKmsPlugin = pkgs.callPackage ../pkgs/openbao-kms-aws.nix {
      openbaoPluginsSrc = inputs.openbao-plugins;
    };
    awsConfig =
      pkgs.runCommand "lucidity-aws-config.tf.json" {
        nativeBuildInputs = [pkgs.jq];
      } ''
        jq '
          .variable.account_cost_budget_notification_email.default = null |
          .variable.node_alarm_notification_email.default = null |
          .variable.controller_ami_id.default = null |
          .variable.worker_ami_id.default = null |
          .variable.cloudflare_zone_id.default = null |
          .variable.github_oidc_provider_arn.default = null |
          .variable.root_volume_kms_key_arn.default = null
        ' ${config.terranix.terranixConfigurations.aws.result.terraformConfiguration} > "$out"
      '';
    mkRoleOutputs = role: let
      evaluated = flakeConfig.flake.denConfigurations.${role};
      profileConfig = evaluated.config;
      cloudInitFixture = pkgs.callPackage ../pkgs/cloud-init-fixture.nix {
        inherit role;
        secretspecManifest = ../../secretspec.toml;
      };
      systemProfile = pkgs.buildEnv {
        name = "lucidity-${role}-system-profile";
        paths =
          profileConfig.lucidity.packages
          ++ [lucidity]
          ++ lib.optionals (role == "controller") [
            asmExec
            awsWorkloadCredentialsProvider
          ];
        pathsToLink = [
          "/bin"
          "/share"
        ];
      };
      homeActivation = flakeConfig.flake.homeConfigurations.${role}.activationPackage;
      context = import ../lib/mk-bootc-context.nix {
        inherit
          lib
          pkgs
          profileConfig
          systemProfile
          homeActivation
          openbaoKmsPlugin
          asmExec
          awsWorkloadCredentialsProvider
          ;
      };
      manifest = pkgs.writeText "lucidity-${role}-manifest.json" (
        builtins.toJSON {
          schemaVersion = 1;
          inherit role system;
          hostName = profileConfig.lucidity.hostName;
          overlayIPv4 = profileConfig.lucidity.overlayIPv4;
          nebulaGroups = profileConfig.lucidity.nebulaGroups;
          persistentPaths = profileConfig.lucidity.persistentPaths;
          admin = {
            name = profileConfig.lucidity.admin.name;
            sshPublicKeySecret = profileConfig.lucidity.admin.sshPublicKeySecret;
            sshFingerprint = profileConfig.lucidity.admin.sshFingerprint;
            passwordLocked = true;
            passwordlessSudo = true;
          };
        }
      );
    in {
      "system-profile-${role}" = systemProfile;
      "home-activation-${role}" = homeActivation;
      "bootc-context-${role}" = context;
      "cloud-init-${role}" = cloudInitFixture;
      "host-manifest-${role}" = manifest;
    };
    rolePackages = lib.foldl' lib.recursiveUpdate {} (map mkRoleOutputs roles);
    source = ../..;
    testSource = pkgs.runCommand "lucidity-test-source" {} ''
      cp -R ${source} "$out"
      chmod -R u+w "$out"
      patchShebangs "$out/scripts" "$out/tests" "$out/roles"
    '';
    mkShellTest = {
      name,
      script,
      nativeBuildInputs ? [],
    }:
      pkgs.runCommandLocal "lucidity-${name}-check" {
        nativeBuildInputs =
          [pkgs.bash pkgs.coreutils pkgs.gnugrep]
          ++ nativeBuildInputs;
      } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        bash ${testSource}/${script}
        touch "$out"
      '';
    manifestsCheck = pkgs.runCommand "lucidity-manifest-check" {} ''
      ${pkgs.jq}/bin/jq -e '.role == "controller" and .overlayIPv4 == "100.96.0.1"' ${rolePackages.host-manifest-controller} >/dev/null
      ${pkgs.jq}/bin/jq -e '.role == "worker" and .overlayIPv4 == "100.96.0.2"' ${rolePackages.host-manifest-worker} >/dev/null
      touch "$out"
    '';
    cloudInitCheck =
      pkgs.runCommand "lucidity-cloud-init-check" {
        nativeBuildInputs = [pkgs.jq pkgs.openssh];
      } ''
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
      grep -Fq 'Environment=COOLIFY_CURL_BIN=/usr/bin/curl' ${rolePackages.bootc-context-controller}/rootfs/usr/lib/systemd/system/coolify-controller-bootstrap.service
      ! grep -Fq 'Requires=lucidity-nix-profile.service' ${rolePackages.bootc-context-worker}/rootfs/usr/lib/systemd/system/lucidity-admin-authorized-key.service
      grep -Fq '100.96.0.1' ${rolePackages.bootc-context-worker}/rootfs/etc/nebula/config.yml.in
      grep -Fq 'address = "127.0.0.1:8200"' ${rolePackages.bootc-context-controller}/rootfs/etc/openbao/openbao.hcl.in
      ! grep -R -E 'GetSecretValue|BatchGetSecretValue' ${rolePackages.bootc-context-controller}/rootfs/usr/libexec
      touch "$out"
    '';
    infrastructureCheck = pkgs.runCommand "lucidity-infrastructure-check" {} ''
      aws=${awsConfig}
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
      network=$(${pkgs.jq}/bin/jq -r '.module.network.source' "$aws")
      ${pkgs.gnugrep}/bin/grep -Rq 'from_port[[:space:]]*=[[:space:]]*var.nebula_udp_port' "$network"
      ${pkgs.gnugrep}/bin/grep -Fq 'resource "aws_flow_log" "rejected"' "$network/main.tf"
      ${pkgs.gnugrep}/bin/grep -Fq 'traffic_type = "ALL"' "$network/main.tf"
      ! ${pkgs.gnugrep}/bin/grep -R -E 'from_port[[:space:]]*=[[:space:]]*22|to_port[[:space:]]*=[[:space:]]*22' "$network"
      ${pkgs.jq}/bin/jq -e '
        .terraform.backend.s3 == {} and
        (.moved | length) == 13 and
        .moved[0].from == "aws_s3_bucket.state" and
        .moved[0].to == "module.bootstrap.aws_s3_bucket.state"
      ' "$state" >/dev/null
      touch "$out"
    '';
    secretspecCheck = pkgs.runCommand "lucidity-secretspec-schema-check" {} ''
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${source}/secretspec.toml --profile operator --output schema.json
      ${pkgs.jq}/bin/jq -e '
        (.required | sort) == ["ADMIN_SSH_PUBLIC_KEY", "NEBULA_CA_PASSPHRASE"]
      ' schema.json >/dev/null
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${source}/secretspec.toml --profile coolify --output coolify-schema.json
      ${pkgs.jq}/bin/jq -e '
        .required == ["COOLIFY_API_TOKEN"]
      ' coolify-schema.json >/dev/null
      ${pkgs.secretspec}/bin/secretspec schema \
        --file ${source}/secretspec.toml --profile vm-worker --output vm-worker-schema.json
      ${pkgs.jq}/bin/jq -e '
        (.required | sort) == ["ADMIN_SSH_PUBLIC_KEY", "COOLIFY_WORKER_SSH_PUBLIC_KEY"]
      ' vm-worker-schema.json >/dev/null
      touch "$out"
    '';
    repositoryCheck =
      pkgs.runCommandLocal "lucidity-repository-policy-check" {
        nativeBuildInputs = [pkgs.ripgrep];
      } ''
        cd ${source}

        help=$(${lucidity}/bin/lucidity --help)
        for interface in generate check build vm infra secrets mesh release; do
          grep -Eq "(^|[[:space:]])$interface([[:space:]]|$)" <<<"$help"
        done

        if rg -n 'secretsmanager[[:space:]]+(get-secret-value|batch-get-secret-value)' nix scripts tests; then
          echo "direct Secrets Manager value retrieval is prohibited; use asm-exec" >&2
          exit 1
        fi
        if rg -n '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)' nix secretspec.toml; then
          echo "SSH public key material must be resolved from SecretSpec, not committed" >&2
          exit 1
        fi

        rg -q '^\[profiles\.coolify\]$' secretspec.toml
        rg -q '^COOLIFY_API_TOKEN = \{ required = true \}$' secretspec.toml
        rg -q 'coolify-worker-storage.service' nix/lib/mk-bootc-context.nix
        rg -q 'Environment=COOLIFY_CURL_BIN=/usr/bin/curl' nix/lib/mk-bootc-context.nix
        rg -q 'lucidity-admin-authorized-key.service' nix/lib/mk-bootc-context.nix
        rg -Fq 'secretspec run' nix/pkgs/cloud-init-fixture.nix
        rg -Fq '.#checks.x86_64-linux.static' .github/workflows/validate.yml
        rg -Fq '.#checks.x86_64-linux.mesh-vm' .github/workflows/validate.yml
        ! rg -q 'tests/run\.sh|tests/vm-(role|mesh)\.sh|ci/run-with-progress\.sh' \
          nix .github/workflows Makefile README.md
        touch "$out"
      '';
    cacheDocker = pkgs.writeShellScriptBin "docker" ''
      set -Eeuo pipefail
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
    cacheUnitCheck =
      pkgs.runCommandLocal "lucidity-cache-unit-check" {
        nativeBuildInputs = [cacheDocker pkgs.gnugrep];
      } ''
        export GITHUB_ACTOR=lucidity-ci
        export GITHUB_REPOSITORY=example/lucidity
        export GITHUB_TOKEN=not-a-real-token
        export GHCR_CACHE_WRITE=true

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

        BUILD_CACHE_ENGINE=docker BUILDX_BUILDER_NAME=lucidity-ci \
          ${lucidity}/bin/lucidity ci cache cleanup
        touch "$out"
      '';
    controllerUnitCheck = mkShellTest {
      name = "controller-unit";
      script = "tests/test-controller.sh";
      nativeBuildInputs = [pkgs.openssh pkgs.gnused];
    };
    workerUnitCheck = mkShellTest {
      name = "worker-unit";
      script = "tests/test-worker.sh";
      nativeBuildInputs = [pkgs.openssh];
    };
    amiImportUnitCheck = mkShellTest {
      name = "ami-import-unit";
      script = "tests/test-ami-import.sh";
      nativeBuildInputs = [pkgs.gawk pkgs.jq pkgs.gnused];
    };
    amiAuditUnitCheck = mkShellTest {
      name = "ami-audit-unit";
      script = "tests/test-ami-resource-audit.sh";
      nativeBuildInputs = [pkgs.jq];
    };
    deploymentUnitCheck = mkShellTest {
      name = "deployment-unit";
      script = "tests/test-deployment-validation.sh";
      nativeBuildInputs = [pkgs.jq];
    };
    textStyleUnitCheck = mkShellTest {
      name = "text-style-unit";
      script = "tests/test-text-style.sh";
      nativeBuildInputs = [pkgs.gitMinimal];
    };
    staticChecks = [
      manifestsCheck
      cloudInitCheck
      policyCheck
      infrastructureCheck
      secretspecCheck
      repositoryCheck
      cacheUnitCheck
      controllerUnitCheck
      workerUnitCheck
      amiImportUnitCheck
      amiAuditUnitCheck
      deploymentUnitCheck
      textStyleUnitCheck
    ];
    staticCheck = pkgs.runCommand "lucidity-static-checks" {} ''
      for check in ${lib.escapeShellArgs (map toString staticChecks)}; do
        test -e "$check"
      done
      touch "$out"
    '';
  in {
    treefmt = {
      projectRootFile = "flake.nix";
      programs = {
        actionlint.enable = true;
        alejandra.enable = true;
        deadnix.enable = true;
        shellcheck.enable = true;
      };
      settings.formatter = {
        deadnix.priority = 1;
        alejandra.priority = 2;
      };
    };
    packages =
      rolePackages
      // {
        inherit
          asmExec
          awsConfig
          awsWorkloadCredentialsProvider
          lucidity
          openbaoKmsPlugin
          ;
        default = lucidity;
      };
    apps = {
      lucidity.program = lib.getExe lucidity;
      default.program = lib.getExe lucidity;
    };
    devShells.default = pkgs.mkShellNoCC {
      packages = with pkgs; [
        actionlint
        codespell
        jq
        alejandra
        deadnix
        opentofu
        shellcheck
      ];
    };
    checks = {
      ami-audit-unit = amiAuditUnitCheck;
      ami-import-unit = amiImportUnitCheck;
      cache-unit = cacheUnitCheck;
      cloud-init = cloudInitCheck;
      controller-unit = controllerUnitCheck;
      deployment-unit = deploymentUnitCheck;
      infrastructure = infrastructureCheck;
      manifests = manifestsCheck;
      mesh-vm = import ../tests/mesh.nix {inherit pkgs;};
      policy = policyCheck;
      repository = repositoryCheck;
      secretspec = secretspecCheck;
      static = staticCheck;
      text-style-unit = textStyleUnitCheck;
      worker-unit = workerUnitCheck;
    };
  };
}
