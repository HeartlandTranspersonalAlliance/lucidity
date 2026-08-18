{
  description = "Lucidity guest Nix lifecycle smoke build";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = {nixpkgs, ...}: let
    systems = [
      "aarch64-linux"
      "x86_64-linux"
    ];
    forAllSystems = nixpkgs.lib.genAttrs systems;
  in {
    packages = forAllSystems (system: {
      default =
        nixpkgs.legacyPackages.${system}.writeText "lucidity-nix-smoke"
        "Determinate Nix guest build passed\n";
    });
  };
}
