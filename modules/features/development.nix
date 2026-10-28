{inputs, ...}: {
  imports = [inputs.devenv.flakeModule];
  flake-file.inputs.devenv = {
    url = "github:cachix/devenv/b31d7faa3e38604a7e11a4477ac994da87c030f1";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-parts.follows = "flake-parts";
  };

  perSystem = {
    lib,
    pkgs,
    ...
  }: {
    # Keep the legacy default shell intact. This is devenv's supported flake
    # module integration, not its evaluation-time SecretSpec integration.
    devenv.shells.devenv = {
      # No container-image outputs; this feature is development tools only.
      containers = lib.mkForce {};
      # Pure flake checks can evaluate the shell without a working directory.
      # Interactive use must supply PWD via `nix develop --impure .#devenv`.
      devenv.root = let
        pwd = builtins.getEnv "PWD";
      in
        if pwd == ""
        then inputs.self.outPath
        else pwd;
      packages = with pkgs; [
        secretspec
        alejandra
        deadnix
        jq
        opentofu
        shellcheck
      ];
      # No enterShell provider lookups, credentials, processes or services.
    };
  };
}
