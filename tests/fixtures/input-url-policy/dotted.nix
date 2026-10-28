{
  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0";
  inputs.home-manager.url = "https://flakehub.com/f/nix-community/home-manager/0";
  inputs.determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/3";
  outputs = _: throw "URL policy must not evaluate flake outputs";
}
