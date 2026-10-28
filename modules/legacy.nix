# Explicit bridge: nix/ also contains plain functions, not flake-parts modules.
{inputs, ...}: {
  imports = [
    inputs.treefmt-nix.flakeModule
    ../nix/den/schema.nix
    ../nix/den/classes/bootc
    ../nix/den/policies/bootc-output.nix
    ../nix/den/entities/hosts.nix
    ../nix/den/aspects/common
    ../nix/den/aspects/controller
    ../nix/den/aspects/worker
    ../nix/den/classes/terranix.nix
    ../nix/flake/project.nix
    ../nix/flake/architecture.nix
    ../nix/flake/checks.nix
    ../nix/flake/formatting.nix
    ../nix/flake/outputs.nix
  ];
}
