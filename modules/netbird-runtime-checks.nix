{
  config,
  inputs,
  lib,
  ...
}: let
  serverModule = config.flake.nixosModules.lucidity-netbird-server;
  identityModule = config.flake.nixosModules.lucidity-netbird-local-identity;
  evaluate = extra:
    (inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [{system.stateVersion = "26.05";}] ++ extra;
    }).config;
  baseline = evaluate [];
  nftBaseline = evaluate [{networking.nftables.enable = true;}];
  disabledServer = evaluate [serverModule];
  disabledIdentity = evaluate [identityModule];
  identityOnly = evaluate [identityModule {lucidity.netbird.localIdentity.enable = true;}];
  fixture = {
    networking.nftables.enable = true;
    lucidity.netbird.localIdentity.enable = true;
    lucidity.netbird.server = {
      enable = true;
      exposedAddress = "https://netbird.example.test:8443";
      credentialFiles = {
        authSecret = "/run/secrets/relay";
        encryptionKey = "/run/secrets/store";
        sessionCookieEncryptionKey = "/run/secrets/cookie";
      };
    };
  };
  enabled = evaluate [identityModule fixture];
  exposed = evaluate [identityModule fixture {lucidity.netbird.server.exposeStun = true;}];
  noFirewall = evaluate [identityModule fixture {networking.nftables.enable = lib.mkForce false;}];
  emptyStun = evaluate [identityModule fixture {lucidity.netbird.server.stunPorts = lib.mkForce [];}];
  noCredentials = evaluate [identityModule fixture {lucidity.netbird.server.credentialFiles.authSecret = lib.mkForce null;}];
  collision = evaluate [identityModule fixture {lucidity.netbird.server.metricsPort = 9000;}];
  badOrigin = evaluate [identityModule fixture {lucidity.netbird.server.exposedAddress = lib.mkForce "https://host/oauth2";}];
  noIdentity = evaluate [serverModule (builtins.removeAttrs fixture ["lucidity"]) {lucidity.netbird.server = fixture.lucidity.netbird.server;}];
  rejectsPath = value:
    !(builtins.tryEval (builtins.deepSeq
      (evaluate [identityModule fixture {lucidity.netbird.server.credentialFiles.authSecret = lib.mkForce value;}]).lucidity.netbird.server.credentialFiles.authSecret
      true)).success;
  footprint = c: {
    services = builtins.attrNames c.systemd.services;
    timers = builtins.attrNames c.systemd.timers;
    users = builtins.attrNames c.users.users;
    groups = builtins.attrNames c.users.groups;
    packages = map toString c.environment.systemPackages;
    etc = builtins.attrNames c.environment.etc;
    inherit (c.networking.firewall) allowedTCPPorts allowedUDPPorts;
    nftables = {inherit (c.networking.nftables) enable tables;};
    podman = c.virtualisation.podman.enable;
  };
  fails = c: builtins.any (a: !a.assertion && lib.hasPrefix "Lucidity NetBird" a.message) c.assertions;
  unit = enabled.systemd.services.lucidity-netbird-server;
in {
  perSystem = {pkgs, ...}: {
    checks.netbird-runtime-eval = assert builtins.all (c: footprint c == footprint baseline) [disabledServer disabledIdentity identityOnly];
    assert !fails enabled;
    assert builtins.all rejectsPath ["relative" "/nix/store/fixture" "/nix/../nix/store/fixture" ../nix/runtime/netbird-runtime.py "${../nix/runtime/netbird-runtime.py}"];
    assert builtins.all fails [noFirewall emptyStun noCredentials collision badOrigin noIdentity];
    assert enabled.lucidity.netbird.server.identitySettings.issuer == "https://netbird.example.test:8443/oauth2";
    assert enabled.lucidity.netbird.server.identitySettings.localAuthDisabled == false;
    assert enabled.networking.firewall.allowedTCPPorts == baseline.networking.firewall.allowedTCPPorts;
    assert enabled.networking.firewall.allowedUDPPorts == baseline.networking.firewall.allowedUDPPorts;
    assert exposed.networking.firewall.allowedUDPPorts == [3478];
    assert lib.hasInfix "iifname != \"lo\" tcp dport 9190 counter drop" enabled.networking.nftables.tables.lucidity-netbird.content;
    assert !(lib.hasInfix "udp dport" exposed.networking.nftables.tables.lucidity-netbird.content);
    assert builtins.attrNames enabled.systemd.services == builtins.attrNames (nftBaseline.systemd.services // {lucidity-netbird-server = {};});
    assert !enabled.virtualisation.podman.enable;
    assert unit.requires == ["nftables.service"] && unit.bindsTo == ["nftables.service"];
    assert unit.serviceConfig.User != "root" && unit.serviceConfig.CapabilityBoundingSet == "";
    assert builtins.length unit.serviceConfig.LoadCredential == 3;
      pkgs.runCommand "lucidity-netbird-runtime-eval" {} "touch $out";
    checks.netbird-runtime-renderer = pkgs.runCommand "lucidity-netbird-runtime-renderer" {nativeBuildInputs = [pkgs.python3 pkgs.secretspec pkgs.yq-go];} ''
      export NETBIRD_TEST_SECRETSPEC=${pkgs.secretspec}/bin/secretspec
      export NETBIRD_TEST_YQ=${pkgs.yq-go}/bin/yq
      export NETBIRD_TEST_MANIFEST=${import ../nix/lib/netbird-secretspec.nix {inherit pkgs;}}
      export HOME="$TMPDIR/home"
      mkdir -p "$HOME"
      cp -r ${../tests} tests
      mkdir -p nix/runtime
      cp ${../nix/runtime/netbird-runtime.py} nix/runtime/netbird-runtime.py
      python3 tests/test-netbird-runtime.py
      touch "$out"
    '';
    checks.netbird-runtime-vm = import ../tests/netbird-runtime.nix {inherit pkgs serverModule identityModule;};
  };
}
