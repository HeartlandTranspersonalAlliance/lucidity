{
  description = "Lucidity: Nix-owned AlmaLinux bootc infrastructure for Coolify";

  nixConfig = {
    extra-substituters = ["https://lucidity.cachix.org"];
    extra-trusted-public-keys = [
      "lucidity.cachix.org-1:EiVuaCjci+zOjSGxHE3nOXVNPVCfXfwfCFzba1vnirA="
    ];
  };

  inputs = {
    den.url = "github:denful/den";

    den-diagram.url = "github:denful/den-diagram";
    den-diagram.inputs.nixpkgs.follows = "nixpkgs";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";

    home-manager.url = "https://flakehub.com/f/nix-community/home-manager/0";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";

    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
    determinate.inputs.nixpkgs.follows = "nixpkgs";

    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0";

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
