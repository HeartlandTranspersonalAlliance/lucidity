{inputs, ...}: {
  flake-file.inputs.wrappers = {
    url = "github:lassulus/wrappers/37d05efcab820ef96f083b251040ae2848445959";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  den.aspects.lucidity-tools.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    cfg = config.lucidity.tools;
    # curl defaults to its bin output; wrappers places the new executable in out.
    curl =
      (inputs.wrappers.lib.wrapPackage {
        inherit pkgs;
        package = pkgs.curl;
        binName = "lucidity-curl";
        env.CURL_CA_BUNDLE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
        flags = {
          "--fail" = true;
          "--show-error" = true;
          "--connect-timeout" = "10";
        };
      }).out;
  in {
    options.lucidity.tools.enable = lib.mkEnableOption "Lucidity's declaratively wrapped diagnostic tools";
    config = lib.mkIf cfg.enable {
      environment.systemPackages = [curl pkgs.jq];
    };
  };
}
