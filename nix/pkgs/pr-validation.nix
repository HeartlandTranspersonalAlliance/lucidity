{
  lib,
  pkgs,
  plan,
  profileRunners ? {},
  nixCommand ? lib.getExe pkgs.nix,
}: let
  runnerNames = builtins.attrNames profileRunners;
  makeCase = field:
    lib.concatMapStringsSep "\n" (
      name: let
        runner = profileRunners.${name}.${field};
      in ''
        ${lib.escapeShellArg name}) printf '%s\n' ${lib.escapeShellArg (lib.getExe runner)} ;;
      ''
    )
    runnerNames;
  runnerCases = makeCase "run";
  cleanupCases = makeCase "cleanup";
in
  pkgs.writeShellApplication {
    name = "lucidity-pr-validation";
    runtimeInputs = with pkgs; [coreutils git jq];
    text =
      builtins.replaceStrings
      [
        "        # @cleanupCases@"
        "@nixCommand@"
        "@plan@"
        "        # @runnerCases@"
      ]
      [
        cleanupCases
        nixCommand
        "${plan}"
        runnerCases
      ]
      (builtins.readFile ./pr-validation.sh);
  }
