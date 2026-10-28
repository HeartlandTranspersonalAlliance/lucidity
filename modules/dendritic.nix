{inputs, ...}: {
  # Matches the pinned Den template; no undocumented host-loading layer.
  imports = [
    inputs.flake-file.flakeModules.dendritic
    inputs.den.flakeModules.dendritic
  ];
  flake-file.description = "Lucidity: bootc compatibility and opt-in native NixOS features";
  flake-file.formatter = pkgs: pkgs.alejandra;
  flake-file.nixConfig = {
    extra-substituters = ["https://lucidity.cachix.org"];
    extra-trusted-public-keys = ["lucidity.cachix.org-1:EiVuaCjci+zOjSGxHE3nOXVNPVCfXfwfCFzba1vnirA="];
  };
  flake-file.inputs = {
    flake-file.url = "github:denful/flake-file/7b08dbc223bb1a758a515aad9653a6bf196bc772";
    import-tree.url = "github:denful/import-tree/eb1b52eaecc57f7c136d07ae8a93e724dfecac46";

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

    ooye = {
      url = "git+https://gitdab.com/cadence/out-of-your-element.git?rev=b5768697644ef64717641693e20fc730604fa7b6";
      flake = false;
    };

    terranix.url = "github:terranix/terranix";
    terranix.inputs.nixpkgs.follows = "nixpkgs";

    treefmt-nix.url = "github:numtide/treefmt-nix";
    treefmt-nix.inputs.nixpkgs.follows = "nixpkgs";
  };
}
