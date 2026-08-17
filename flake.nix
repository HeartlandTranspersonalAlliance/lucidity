{
  description = "Lucidity: Nix-owned AlmaLinux bootc infrastructure for Coolify";

  inputs = {
    den.url = "github:denful/den";

    den-diagram.url = "github:denful/den-diagram";
    den-diagram.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    home-manager.url = "github:nix-community/home-manager";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    openbao-plugins = {
      url = "github:openbao/openbao-plugins";
      flake = false;
    };

    terranix.url = "github:terranix/terranix";
    terranix.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs:
    inputs.flake-parts.lib.mkFlake {inherit inputs;} {
      imports = [
        inputs.treefmt-nix.flakeModule
        ./nix/den/schema.nix
        ./nix/den/classes/bootc
        ./nix/den/policies/bootc-output.nix
        ./nix/den/entities/hosts.nix
        ./nix/den/aspects/common
        ./nix/den/aspects/controller
        ./nix/den/aspects/worker
        ./nix/den/classes/terranix.nix
        ./nix/flake/project.nix
        ./nix/flake/architecture.nix
        ./nix/flake/checks.nix
        ./nix/flake/formatting.nix
        ./nix/flake/outputs.nix
      ];
    };
}
