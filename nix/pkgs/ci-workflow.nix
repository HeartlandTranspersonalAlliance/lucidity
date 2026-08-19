{pkgs}: let
  inherit (pkgs) lib;
  stripEnvBash = path:
    lib.removePrefix "#!/usr/bin/env bash\n" (builtins.readFile path);
  mkProgram = {
    name,
    script,
    runtimeInputs,
  }:
    pkgs.writeShellApplication {
      inherit name runtimeInputs;
      text = stripEnvBash script;
    };
in {
  prepare = mkProgram {
    name = "lucidity-ci-workflow-prepare";
    script = ../../scripts/ci-workflow-prepare.sh;
    runtimeInputs = with pkgs; [coreutils gitMinimal jq];
  };
  gate = mkProgram {
    name = "lucidity-ci-workflow-gate";
    script = ../../scripts/ci-workflow-gate.sh;
    runtimeInputs = with pkgs; [jq];
  };
  hermeticCheck = mkProgram {
    name = "lucidity-ci-hermetic-check";
    script = ../../scripts/ci-hermetic-check.sh;
    runtimeInputs = with pkgs; [coreutils nix];
  };
  requireEnv = mkProgram {
    name = "lucidity-ci-require-env";
    script = ../../scripts/ci-require-env.sh;
    runtimeInputs = [];
  };
}
