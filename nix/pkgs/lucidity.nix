{
  pkgs,
  ciWorkflow,
  nixpkgsProvenance,
}: let
  inherit (pkgs) lib;
  stripEnvBash = path:
    lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile path);
  runtimeScriptPaths = [
    ../../scripts/audit-ami-validation-resources.sh
    ../../scripts/build-disk.sh
    ../../scripts/check-text-style.sh
    ../../scripts/validate-ami-import.sh
    ../../scripts/validate-deployment.sh
    ../../scripts/validate-disk.sh
    ../../scripts/vm-init.sh
    ../../scripts/vm-integration.sh
    ../../scripts/vm-registry.sh
    ../../scripts/vm-start.sh
    ../../scripts/vm-stop.sh
    ../../scripts/vm-validate-update.sh
    ../../scripts/vm-validate.sh
  ];
  lucidityRuntimeScripts = pkgs.runCommand "lucidity-runtime-scripts" {} ''
    mkdir -p "$out/libexec/lucidity"
    ${lib.concatMapStringsSep "\n" (source: ''
        install -m 0755 ${source} "$out/libexec/lucidity/${baseNameOf source}"
      '')
      runtimeScriptPaths}
    patchShebangs "$out/libexec/lucidity"
  '';
  lucidityAmiAudit = pkgs.writeShellApplication {
    name = "lucidity-audit-ami-resources";
    runtimeInputs = with pkgs; [awscli2 coreutils jq];
    text = stripEnvBash ../../scripts/audit-ami-validation-resources.sh;
  };
  lucidityDeploymentValidation = pkgs.writeShellApplication {
    name = "lucidity-validate-deployment";
    runtimeInputs = with pkgs; [awscli2 coreutils curl jq];
    text = stripEnvBash ../../scripts/validate-deployment.sh;
  };
in
  (pkgs.writeShellApplication {
    name = "lucidity";
    runtimeInputs =
      (with pkgs; [
        awscli2
        coreutils
        curl
        findutils
        gawk
        git
        gh
        gnugrep
        gnused
        jq
        nix
        nebula
        openbao
        openssl
        openssh
        opentofu
        podman
        qemu-utils
        ripgrep
        secretspec
        shellcheck
        coldsnap
        xorriso
      ])
      ++ [ciWorkflow.prepare];
    text =
      builtins.replaceStrings
      [
        "@lucidityAmiAudit@"
        "@lucidityDeploymentValidation@"
        "@lucidityRuntimeScripts@"
        "@luciditySyftConfig@"
        "@lucidityNixpkgsUrl@"
        "@lucidityNixpkgsRev@"
        "@lucidityNixpkgsNarHash@"
      ]
      [
        (lib.getExe lucidityAmiAudit)
        (lib.getExe lucidityDeploymentValidation)
        "${lucidityRuntimeScripts}/libexec/lucidity"
        "${../../.github/syft.yaml}"
        nixpkgsProvenance.url
        (
          if nixpkgsProvenance.rev == null
          then ""
          else nixpkgsProvenance.rev
        )
        nixpkgsProvenance.narHash
      ]
      (builtins.readFile ./lucidity.sh);
  }).overrideAttrs (old: {
    passthru =
      (old.passthru or {})
      // {
        runtimeScripts = lucidityRuntimeScripts;
      };
  })
