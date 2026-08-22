{lib, ...}: {
  perSystem = {
    lucidityProject,
    pkgs,
    ...
  }: let
    inherit
      (lucidityProject)
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
      openbaoKmsPlugin
      openbaoAuthPlugin
      rolePackages
      ;
  in {
    packages =
      rolePackages
      // {
        inherit
          asmExec
          awsConfig
          awsProductionVars
          awsTestVars
          awsWorkloadCredentialsProvider
          lucidity
          lucidityRelease
          openbaoKmsPlugin
          openbaoAuthPlugin
          ;
        ci-hermetic-check = ciWorkflow.hermeticCheck;
        ci-integration-classify = ciWorkflow.classify;
        ci-require-env = ciWorkflow.requireEnv;
        ci-workflow-gate = ciWorkflow.gate;
        ci-workflow-prepare = ciWorkflow.prepare;
        mesh-vm = meshVmCheck;
        default = lucidity;
      };
    apps = {
      lucidity.program = lib.getExe lucidity;
      default.program = lib.getExe lucidity;
      build-controller = mkLucidityApp "build-controller" [
        "build"
        "controller"
      ];
      build-worker = mkLucidityApp "build-worker" [
        "build"
        "worker"
      ];
      audit-ami-resources = mkLucidityApp "audit-ami-resources" [
        "ci"
        "audit-ami-resources"
      ];
      check = mkLucidityApp "check" ["check"];
      ci-hermetic-check.program = lib.getExe ciWorkflow.hermeticCheck;
      ci-integration-classify.program = lib.getExe ciWorkflow.classify;
      ci-require-env.program = lib.getExe ciWorkflow.requireEnv;
      ci-workflow-gate.program = lib.getExe ciWorkflow.gate;
      ci-workflow-prepare.program = lib.getExe ciWorkflow.prepare;
      ami = mkLucidityApp "ami" ["ami"];
      ci = mkLucidityAppWith lucidityRelease "ci" ["ci"];
      disk = mkLucidityApp "disk" ["disk"];
      generate = mkLucidityApp "generate" ["generate"];
      infra = mkLucidityApp "infra" ["infra"];
      state = mkLucidityApp "state" ["state"];
      release = mkLucidityAppWith lucidityRelease "release" ["release"];
      test-controller = mkLucidityApp "test-controller" [
        "vm"
        "test"
        "controller"
      ];
      test-mesh = mkLucidityApp "test-mesh" [
        "vm"
        "test"
        "mesh"
      ];
      test-integration = mkLucidityApp "test-integration" [
        "vm"
        "test"
        "integration"
      ];
      test-worker = mkLucidityApp "test-worker" [
        "vm"
        "test"
        "worker"
      ];
      validate-deployment = mkLucidityApp "validate-deployment" [
        "ci"
        "validate-deployment"
      ];
    };
    devShells.default = pkgs.mkShellNoCC {
      packages = with pkgs; [
        actionlint
        alejandra
        codespell
        deadnix
        jq
        opentofu
        shellcheck
      ];
    };
  };
}
