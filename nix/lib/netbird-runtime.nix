# Metadata-only adapter to the pinned lassulus/wrappers API. Secrets are loaded
# at service start by SecretSpec, never by Nix evaluation or a build command.
{
  inputs,
  pkgs,
  package,
  baseConfig,
}: let
  manifest = import ./netbird-secretspec.nix {inherit pkgs;};
  helper = pkgs.writeText "netbird-runtime.py" (builtins.readFile ../runtime/netbird-runtime.py);
  metadata = pkgs.writeText "netbird-runtime-metadata.json" (builtins.toJSON {
    inherit baseConfig manifest helper;
    runtimeDirectory = "/run/lucidity-netbird-server";
    server = "${package}/bin/netbird-server";
    secretspec = "${pkgs.secretspec}/bin/secretspec";
    python = "${pkgs.python3}/bin/python3";
  });
in
  (inputs.wrappers.lib.wrapPackage {
    inherit pkgs;
    package = pkgs.python3;
    exePath = "${pkgs.python3}/bin/python3";
    binName = "lucidity-netbird-runtime";
    args = ["-I" (toString helper) "launch" (toString metadata)];
  }).out
