{...}: {
  den.aspects.lucidity-secretspec.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.lucidity.secretspec.enable = lib.mkEnableOption "the standalone SecretSpec operator CLI";
    config = lib.mkIf config.lucidity.secretspec.enable {
      # CLI only: no devenv evaluation-time secret injection, provider lookup,
      # generated credentials, automatic daemon environment, or service starts.
      environment.systemPackages = [pkgs.secretspec];
    };
  };
}
