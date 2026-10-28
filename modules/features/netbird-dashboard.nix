{
  config,
  den,
  inputs,
  lib,
  ...
}: let
  mkPackage = pkgs: import ../../nix/pkgs/netbird-dashboard {inherit pkgs;};
  module = den.lib.aspects.resolve "nixos" den.aspects.lucidity-netbird-dashboard;
  evaluate = extra:
    (inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [{system.stateVersion = "26.05";}] ++ extra;
    }).config;
  baseline = evaluate [];
  disabled = evaluate [module];
  enabled = evaluate [module {lucidity.netbird.dashboard.enable = true;}];
  footprint = c: {
    services = builtins.attrNames c.systemd.services;
    timers = builtins.attrNames c.systemd.timers;
    users = builtins.attrNames c.users.users;
    groups = builtins.attrNames c.users.groups;
    tcp = c.networking.firewall.allowedTCPPorts;
    udp = c.networking.firewall.allowedUDPPorts;
    etc = builtins.attrNames c.environment.etc;
  };
in {
  den.aspects.lucidity-netbird-dashboard.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: {
    options.lucidity.netbird.dashboard.enable = lib.mkEnableOption "the NetBird dashboard static package (no web server or runtime configuration)";
    config = lib.mkIf config.lucidity.netbird.dashboard.enable {
      environment.systemPackages = [(mkPackage pkgs)];
    };
  };
  flake.nixosModules.lucidity-netbird-dashboard = module;
  perSystem = {pkgs, ...}: let
    package = mkPackage pkgs;
    contract = ../../nix/pkgs/netbird-dashboard/check.py;
    manifest = ../../nix/pkgs/netbird-dashboard/runtime-placeholders.json;
  in {
    packages.netbird-dashboard = package;
    checks = {
      netbird-dashboard-module = assert footprint baseline == footprint disabled;
      assert footprint baseline == footprint enabled;
      assert map toString baseline.environment.systemPackages == map toString disabled.environment.systemPackages;
      assert builtins.length enabled.environment.systemPackages == builtins.length baseline.environment.systemPackages + 1;
      assert lib.any (p: (p.pname or "") == "netbird-dashboard" && p.version == "2.96.0") enabled.environment.systemPackages;
      assert !disabled.lucidity.netbird.dashboard.enable;
      assert package.npmDeps.name == "netbird-dashboard-2.96.0-npm-deps";
      assert package.npmDeps.outputHash == package.npmDepsHash;
      assert package.npmDeps.src == package.src;
      assert package.meta.license.spdxId == "AGPL-3.0-only";
      assert builtins.attrNames config.den.hosts.x86_64-linux == ["controller" "worker"];
        pkgs.runCommand "netbird-dashboard-module-check" {} ''
          touch "$out"
        '';
      netbird-dashboard-source = pkgs.runCommand "netbird-dashboard-source-check" {} ''
        ${pkgs.python3}/bin/python ${contract} ${manifest} ${package.src}
        touch "$out"
      '';
      # Mandatory full build in the existing hermetic graph; no running server.
      netbird-dashboard-static = pkgs.runCommand "netbird-dashboard-static-check" {} ''
        ${pkgs.python3}/bin/python ${contract} ${manifest} ${package.src} ${package}
        touch "$out"
      '';
    };
  };
}
