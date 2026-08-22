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
        modules = [
          inputs.determinate.homeManagerModules.default
          ../home/admin.nix
        ];
      }
  );

  perSystem = {
    config,
    pkgs,
    system,
    ...
  }: let
    ciWorkflow = import ../pkgs/ci-workflow.nix {inherit pkgs;};
    nixpkgsProvenance = {
      url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0";
      rev = inputs.nixpkgs.sourceInfo.rev or null;
      narHash = inputs.nixpkgs.sourceInfo.narHash;
    };
    lucidity = import ../pkgs/lucidity.nix {inherit pkgs ciWorkflow nixpkgsProvenance;};
    lucidityRelease = pkgs.symlinkJoin {
      name = "lucidity-release-tools";
      paths = [lucidity];
      nativeBuildInputs = [pkgs.makeWrapper];
      meta.mainProgram = "lucidity";
      postBuild = ''
        wrapProgram "$out/bin/lucidity" \
          --prefix PATH : ${lib.makeBinPath (with pkgs; [docker-client gh gzip syft])}
      '';
    };
    asmExec = pkgs.callPackage ../pkgs/asm-exec.nix {};
    awsWorkloadCredentialsProvider =
      pkgs.callPackage ../pkgs/aws-workload-credentials-provider.nix {};
    openbaoKmsPlugin = pkgs.callPackage ../pkgs/openbao-kms-aws.nix {
      openbaoPluginsSrc = inputs.openbao-plugins;
    };
    openbaoAuthPlugin = pkgs.callPackage ../pkgs/openbao-auth-aws.nix {
      openbaoPluginsSrc = inputs.openbao-plugins;
    };
    ooye = pkgs.callPackage ../pkgs/ooye.nix {
      ooyeSrc = inputs.ooye;
    };
    meshVmCheck = import ../den/classes/bootc/tests/mesh.nix {inherit pkgs;};
    awsConfig =
      pkgs.runCommand "lucidity-aws-config.tf.json" {
        nativeBuildInputs = [pkgs.jq];
      } ''
        jq '
          .variable.account_cost_budget_notification_email.default = null |
          .variable.controller_ami_id.default = null |
          .variable.worker_ami_id.default = null |
          .variable.cloudflare_zone_id.default = null |
          .variable.github_oidc_provider_arn.default = null |
          .variable.root_volume_kms_key_arn.default = null
          | .variable.shared_snapshot_kms_key_arn.default = null
          | .variable.state_bucket_name.default = null
          | .variable.application_backup_bucket_arn.default = null
          | .variable.application_backup_bucket_kms_key_arn.default = null
          | .variable.application_backup_secret_kms_key_arn.default = null
        ' ${config.terranix.terranixConfigurations.aws.result.terraformConfiguration} > "$out"
      '';
    productionDeployment = builtins.fromJSON (builtins.readFile ../../deployments/production.json);
    awsProductionVars = pkgs.writeText "lucidity-production.auto.tfvars.json" (
      builtins.toJSON {
        deployment_contract = productionDeployment;
        deployment_stage = null;
        enable_account_security_baseline = true;
        enable_ami_launch_validation = true;
        enable_instance_management = true;
        enable_network = true;
        enable_openbao = true;
        enable_runtime_secrets = true;
        flow_log_retention_days = 90;
      }
    );
    testDeployment = builtins.fromJSON (builtins.readFile ../../deployments/test.json);
    awsTestVars = pkgs.writeText "lucidity-test.auto.tfvars.json" (
      builtins.toJSON {
        environment = testDeployment.environment;
        deployment_stage = "foundation";
        deployment_contract = testDeployment;
        vpc_name = "lucidity-test";
        vpc_cidr = "10.21.0.0/16";
        availability_zone_count = 2;
        enable_account_security_baseline = false;
        enable_account_cost_budget = false;
        enable_shared_release_resources = false;
        enable_ami_launch_validation = false;
        enable_instance_management = true;
        enable_network = true;
        enable_openbao = true;
        enable_runtime_secrets = true;
        flow_log_retention_days = 30;
        ec2_node_names = {
          controller = "lucidity-test-controller";
          worker = "lucidity-test-worker";
        };
        cloudflare_zone_name = "heartlandta.org";
        cloudflare_dns_records = {
          "coolify.test" = {
            role = "controller";
            proxied = true;
          };
          "apps.test" = {
            role = "worker";
            proxied = true;
          };
          "*.apps.test" = {
            role = "worker";
            proxied = true;
          };
          test = {
            role = "worker";
            proxied = true;
          };
          "matrix.test" = {
            role = "worker";
            proxied = true;
          };
          "ntfy.test" = {
            role = "controller";
            proxied = true;
          };
          "mesh.test" = {
            role = "controller";
            proxied = false;
          };
        };
        tags = {
          Environment = "test";
          ReviewAfter = testDeployment.review_after;
          DataPolicy = "synthetic-only";
        };
      }
    );
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
          ++ [lucidity asmExec]
          ++ lib.optionals (role == "controller") [
            awsWorkloadCredentialsProvider
            openbaoAuthPlugin
          ]
          ++ lib.optional (role == "worker") ooye;
        pathsToLink = [
          "/bin"
          "/share"
        ];
      };
      homeActivation = flakeConfig.flake.homeConfigurations.${role}.activationPackage;
      context = import ../den/classes/bootc/image.nix {
        inherit
          lib
          pkgs
          profileConfig
          systemProfile
          homeActivation
          openbaoKmsPlugin
          openbaoAuthPlugin
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
          nixpkgs = nixpkgsProvenance;
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
    mkLucidityAppWith = package: name: arguments: let
      application = pkgs.writeShellApplication {
        name = "lucidity-${name}";
        runtimeInputs = [package];
        text = ''
          exec ${lib.getExe package} ${lib.escapeShellArgs arguments} "$@"
        '';
      };
    in {
      program = lib.getExe application;
    };
    mkLucidityApp = mkLucidityAppWith lucidity;
    source = lib.fileset.toSource {
      root = ../..;
      fileset = ../..;
    };
    mkSource = _name: paths:
      lib.fileset.toSource {
        root = ../..;
        fileset = lib.fileset.unions paths;
      };
    mkPatchedSource = name: paths: let
      selectedSource = mkSource name paths;
    in
      pkgs.runCommand "lucidity-${name}-source" {} ''
        cp -R ${selectedSource} "$out"
        chmod -R u+w "$out"
        while IFS= read -r script; do
          if head -n 1 "$script" | grep -Fqx '#!/usr/bin/env bash'; then
            chmod u+x "$script"
          fi
        done < <(find "$out" -type f -print)
        patchShebangs "$out"
      '';
    mkShellTest = {
      name,
      script,
      files,
      nativeBuildInputs ? [],
    }: let
      testSource = mkPatchedSource "${name}-test" files;
    in
      pkgs.runCommand "lucidity-${name}-check" {
        nativeBuildInputs =
          [pkgs.bash pkgs.coreutils pkgs.gnugrep]
          ++ nativeBuildInputs;
      } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME"
        bash ${testSource}/${script}
        touch "$out"
      '';
  in {
    _module.args.lucidityProject = {
      inherit
        asmExec
        awsConfig
        awsProductionVars
        awsTestVars
        awsWorkloadCredentialsProvider
        ciWorkflow
        lucidity
        lucidityRelease
        meshVmCheck
        mkLucidityApp
        mkLucidityAppWith
        mkPatchedSource
        mkShellTest
        mkSource
        openbaoKmsPlugin
        openbaoAuthPlugin
        rolePackages
        source
        ;
    };
  };
}
