# DO-NOT-EDIT. This file was auto-generated using github:denful/flake-file.
# Use `nix run .#write-flake` to regenerate it.
{
  description = "Lucidity: bootc compatibility and opt-in native NixOS features";

  outputs = inputs: inputs.flake-parts.lib.mkFlake {inherit inputs;} (inputs.import-tree ./modules);

  nixConfig = {
    extra-substituters = ["https://lucidity.cachix.org"];
    extra-trusted-public-keys = ["lucidity.cachix.org-1:EiVuaCjci+zOjSGxHE3nOXVNPVCfXfwfCFzba1vnirA="];
  };

  inputs = {
    den.url = "github:denful/den";
    den-diagram = {
      url = "github:denful/den-diagram";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    determinate = {
      url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    devenv = {
      url = "github:cachix/devenv/b31d7faa3e38604a7e11a4477ac994da87c030f1";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    flake-file.url = "github:denful/flake-file/7b08dbc223bb1a758a515aad9653a6bf196bc772";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    home-manager = {
      url = "https://flakehub.com/f/nix-community/home-manager/0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    import-tree.url = "github:denful/import-tree/eb1b52eaecc57f7c136d07ae8a93e724dfecac46";
    nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0";
    ooye = {
      url = "git+https://gitdab.com/cadence/out-of-your-element.git?rev=b5768697644ef64717641693e20fc730604fa7b6";
      flake = false;
    };
    openbao-plugins = {
      url = "github:openbao/openbao-plugins";
      flake = false;
    };
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix/db3af9df6943692c78cf9a05e3bfeb7d82e94cf3";
    terranix = {
      url = "github:terranix/terranix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wrappers = {
      url = "github:lassulus/wrappers/37d05efcab820ef96f083b251040ae2848445959";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
