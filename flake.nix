{
  description = "Lucidity: Nix-owned AlmaLinux bootc infrastructure for Coolify";

  inputs = {
    den.url = "github:denful/den";

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
        ./nix/modules/den.nix
        ./nix/modules/hosts.nix
        ./nix/modules/aspects/common.nix
        ./nix/modules/aspects/controller.nix
        ./nix/modules/aspects/worker.nix
        ./nix/modules/terranix.nix
        ./nix/modules/outputs.nix
      ];
    };
}
