{...}: {
  perSystem = {
    lib,
    pkgs,
    system,
    ...
  }: let
    profile = id: attribute: {inherit id attribute;};
    planData = {
      schemaVersion = 1;
      shards = [
        {
          id = "policy";
          pureProfiles = [
            (profile "cache-unit" "checks.${system}.cache-unit")
            (profile "ci-workflow-unit" "checks.${system}.ci-workflow-unit")
            (profile "release-unit" "checks.${system}.release-unit")
            (profile "repository" "checks.${system}.repository")
            (profile "secretspec" "checks.${system}.secretspec")
            (profile "text-style-unit" "checks.${system}.text-style-unit")
            (profile "treefmt" "checks.${system}.treefmt")
            (profile "yaml-policy" "checks.${system}.yaml-policy")
          ];
          mutableProfiles = [];
        }
        {
          id = "roles";
          pureProfiles = [
            (profile "controller-unit" "checks.${system}.controller-unit")
            (profile "lifecycle-scope" "checks.${system}.lifecycle-scope")
            (profile "runtime-tools" "checks.${system}.runtime-tools")
            (profile "worker-unit" "checks.${system}.worker-unit")
          ];
          mutableProfiles = [];
        }
      ];
    };
    plan = pkgs.writeText "lucidity-pr-validation-plan.json" (builtins.toJSON planData);
    validator = pkgs.callPackage ../pkgs/pr-validation.nix {inherit plan;};
    planner = pkgs.writeShellApplication {
      name = "lucidity-pr-validation-plan";
      runtimeInputs = [pkgs.coreutils];
      text = ''
        [[ $# -eq 0 ]] || { echo "lucidity-pr-validation-plan accepts no arguments" >&2; exit 2; }
        cat ${plan}
      '';
    };

    successfulRunner = pkgs.writeShellScriptBin "mutable-success" ''
      set -Eeuo pipefail
      printf 'success\n' >>"$HOME/mutable-runs.log"
    '';
    failingRunner = pkgs.writeShellScriptBin "mutable-failure" ''
      set -Eeuo pipefail
      printf 'failure\n' >>"$HOME/mutable-runs.log"
      exit 1
    '';
    failureCleanup = pkgs.writeShellApplication {
      name = "cleanup-failure";
      text = ''
        printf 'failure\n' >>"$HOME/mutable-cleanups.log"
      '';
    };
    successCleanup = pkgs.writeShellApplication {
      name = "cleanup-success";
      text = ''
        printf 'success\n' >>"$HOME/mutable-cleanups.log"
      '';
    };
    mockNix = pkgs.writeShellScript "mock-nix" ''
      set -Eeuo pipefail
      printf '%s\n' "$*" >>"$HOME/nix-builds.log"
      if [[ $* == *checks.x86_64-linux.failure* ]]; then
        exit 1
      fi
    '';
    testPlan = pkgs.writeText "lucidity-pr-validation-test-plan.json" (builtins.toJSON {
      schemaVersion = 1;
      shards = [
        {
          id = "hybrid";
          pureProfiles = [
            (profile "pure-success" "checks.x86_64-linux.success")
            (profile "pure-failure" "checks.x86_64-linux.failure")
          ];
          mutableProfiles = [
            {id = "mutable-failure";}
            {id = "mutable-success";}
          ];
        }
      ];
    });
    testValidator = pkgs.callPackage ../pkgs/pr-validation.nix {
      plan = testPlan;
      nixCommand = "${mockNix}";
      profileRunners = {
        mutable-failure = {
          run = failingRunner;
          cleanup = failureCleanup;
        };
        mutable-success = {
          run = successfulRunner;
          cleanup = successCleanup;
        };
      };
    };
    unknownRunnerPlan = pkgs.writeText "lucidity-pr-validation-unknown-runner.json" (builtins.toJSON {
      schemaVersion = 1;
      shards = [
        {
          id = "unknown";
          pureProfiles = [];
          mutableProfiles = [{id = "not-embedded";}];
        }
      ];
    });
    unknownRunnerValidator = pkgs.callPackage ../pkgs/pr-validation.nix {
      plan = unknownRunnerPlan;
      nixCommand = "${mockNix}";
    };
    invalidPlan = pkgs.writeText "lucidity-pr-validation-invalid-plan.json" (builtins.toJSON {
      schemaVersion = 1;
      shards = [
        {
          id = "invalid";
          pureProfiles = [(profile "package" "packages.x86_64-linux.default")];
          mutableProfiles = [];
        }
      ];
    });
    invalidValidator = pkgs.callPackage ../pkgs/pr-validation.nix {
      plan = invalidPlan;
      nixCommand = "${mockNix}";
    };
    contractCheck =
      pkgs.runCommand "lucidity-pr-validation-contract-check" {
        nativeBuildInputs = [pkgs.jq];
      } ''
        jq -e '
          .schemaVersion == 1 and
          ([.shards[].id] == ["policy", "roles"]) and
          all(.shards[].pureProfiles[]; .attribute | startswith("checks.${system}.")) and
          all(.shards[]; .mutableProfiles == [])
        ' ${plan} >$out
      '';
    unitCheck =
      pkgs.runCommand "lucidity-pr-validation-unit-check" {
        nativeBuildInputs = [pkgs.jq];
      } ''
        mkdir home repository
        touch repository/flake.nix
        export HOME=$PWD/home
        export LUCIDITY_REPOSITORY_ROOT=$PWD/repository
        export PR_VALIDATION_RESULTS=$PWD/results.json

        if ${lib.getExe testValidator} hybrid; then
          echo 'hybrid validator accepted a failing profile' >&2
          exit 1
        fi
        test "$(wc -l <home/nix-builds.log)" -eq 3
        grep -Fq -- '--keep-going' home/nix-builds.log
        grep -Fq 'checks.x86_64-linux.success' home/nix-builds.log
        grep -Fq 'checks.x86_64-linux.failure' home/nix-builds.log
        test "$(wc -l <home/mutable-runs.log)" -eq 2
        grep -Fxq failure home/mutable-runs.log
        grep -Fxq success home/mutable-runs.log
        test "$(wc -l <home/mutable-cleanups.log)" -eq 2
        jq -e '
          .schemaVersion == 1 and .shard == "hybrid" and
          [.results[] | [.id, .kind, .outcome]] == [
            ["pure-success", "pure", "success"],
            ["pure-failure", "pure", "failure"],
            ["mutable-failure", "mutable", "failure"],
            ["mutable-success", "mutable", "success"]
          ]
        ' results.json >/dev/null

        rm -f home/*.log
        if ${lib.getExe unknownRunnerValidator} unknown 2>/dev/null; then
          echo 'validator accepted an unknown mutable runner' >&2
          exit 1
        fi
        test ! -e home/nix-builds.log
        test ! -e home/mutable-runs.log

        if ${lib.getExe invalidValidator} invalid 2>/dev/null; then
          echo 'validator accepted a non-check flake attribute' >&2
          exit 1
        fi
        test ! -e home/nix-builds.log
        touch $out
      '';
  in {
    packages = {
      pr-validation = validator;
      pr-validation-plan = plan;
    };
    apps = {
      pr-validation.program = lib.getExe validator;
      pr-validation-plan.program = lib.getExe planner;
    };
    checks = {
      pr-validation-contract = contractCheck;
      pr-validation-unit = unitCheck;
    };
  };
}
