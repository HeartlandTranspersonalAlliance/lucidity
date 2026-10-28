{inputs, ...}: {
  flake-file.inputs.quadlet-nix.url = "github:SEIAROTg/quadlet-nix/db3af9df6943692c78cf9a05e3bfeb7d82e94cf3";

  den.aspects.lucidity-quadlet.nixos = {
    config,
    lib,
    ...
  }: {
    imports = [inputs.quadlet-nix.nixosModules.quadlet];
    options.lucidity.quadlet.enable = lib.mkEnableOption "the optional Lucidity Podman Quadlet integration";
    # Upstream otherwise enables itself when an object is declared. Keep the
    # adapter inert until explicitly opted in, even if objects are present.
    config.virtualisation.quadlet.enable = lib.mkDefault config.lucidity.quadlet.enable;
  };
}
