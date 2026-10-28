# Shared metadata-only manifest: exercised by the real CLI fixture and service.
{pkgs}:
(pkgs.formats.toml {}).generate "netbird-runtime-secretspec.toml" {
  project = {
    name = "lucidity-netbird-server";
    revision = "1.0";
  };
  profiles.default = builtins.listToAttrs (map (name: {
    inherit name;
    value = {
      description = "Dedicated NetBird runtime credential";
      required = true;
      as_path = true;
    };
  }) ["NETBIRD_AUTH_SECRET" "NETBIRD_STORE_KEY" "NETBIRD_COOKIE_KEY"]);
  scopes.default.secrets = ["NETBIRD_AUTH_SECRET" "NETBIRD_STORE_KEY" "NETBIRD_COOKIE_KEY"];
}
