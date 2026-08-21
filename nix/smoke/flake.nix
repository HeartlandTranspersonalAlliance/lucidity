{
  description = "Lucidity guest Nix lifecycle smoke build";

  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-weekly/0";

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
