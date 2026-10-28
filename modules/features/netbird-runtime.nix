{
  den,
  inputs,
  ...
}: {
  den.aspects.lucidity-netbird-server.nixos = import ../../nix/modules/netbird-server.nix {inherit inputs;};
  den.aspects.lucidity-netbird-local-identity = {
    includes = [den.aspects.lucidity-netbird-server];
    nixos = {
      config,
      lib,
      ...
    }: {
      options.lucidity.netbird.localIdentity.enable = lib.mkEnableOption "the embedded local NetBird identity configuration (no account creation)";
      config = lib.mkIf config.lucidity.netbird.localIdentity.enable {
        lucidity.netbird.server.identitySettings = {
          issuer = "${config.lucidity.netbird.server.exposedAddress}/oauth2";
          localAuthDisabled = false;
          dashboardRedirectURIs = map (path: "${config.lucidity.netbird.server.exposedAddress}${path}") ["/nb-auth" "/nb-silent-auth"];
          cliRedirectURIs = ["http://localhost:53000/"];
        };
      };
    };
  };
  flake.nixosModules = {
    lucidity-netbird-server = den.lib.aspects.resolve "nixos" den.aspects.lucidity-netbird-server;
    lucidity-netbird-local-identity = den.lib.aspects.resolve "nixos" den.aspects.lucidity-netbird-local-identity;
  };
}
