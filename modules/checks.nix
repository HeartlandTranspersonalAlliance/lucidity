{
  config,
  inputs,
  lib,
  ...
}: let
  modules = config.flake.nixosModules;
  evaluate = extra:
    (inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [{system.stateVersion = "26.05";}] ++ extra;
    }).config;
  baseline = evaluate [];
  disabled = evaluate [modules.lucidity];
  enabled = evaluate [
    modules.lucidity
    {
      lucidity.foundation.enable = true;
      lucidity.tools.enable = true;
      lucidity.secretspec.enable = true;
      lucidity.quadlet.enable = true;
      virtualisation.quadlet.containers.fixture = {
        # Evaluation fixture only: never pulled, built, deployed, or auto-started.
        autoStart = false;
        containerConfig.image = "localhost/lucidity-evaluation-fixture:unused";
      };
    }
  ];
  dormant = evaluate [
    modules.lucidity-quadlet
    {
      virtualisation.quadlet.containers.fixture.containerConfig.image = "localhost/lucidity-evaluation-fixture:unused";
    }
  ];
  wrappedCurl = lib.findFirst (p: (p.meta.mainProgram or "") == "lucidity-curl") null enabled.environment.systemPackages;
  sameFootprint = a: b:
    builtins.attrNames a.systemd.services
    == builtins.attrNames b.systemd.services
    && builtins.attrNames a.systemd.timers == builtins.attrNames b.systemd.timers
    && a.networking.firewall.allowedTCPPorts == b.networking.firewall.allowedTCPPorts
    && a.networking.firewall.allowedUDPPorts == b.networking.firewall.allowedUDPPorts
    && builtins.attrNames a.environment.etc == builtins.attrNames b.environment.etc
    && a.virtualisation.podman.enable == b.virtualisation.podman.enable
    && map toString a.environment.systemPackages == map toString b.environment.systemPackages;
in {
  perSystem = {pkgs, ...}: {
    checks.nixos-foundation = assert builtins.attrNames config.den.hosts.x86_64-linux == ["controller" "worker"];
    assert sameFootprint baseline disabled;
    assert sameFootprint baseline dormant;
    assert !disabled.lucidity.foundation.enable;
    assert !disabled.lucidity.tools.enable;
    assert !disabled.lucidity.secretspec.enable;
    assert !disabled.virtualisation.quadlet.enable;
    assert enabled.virtualisation.podman.enable;
    assert enabled.systemd.services.fixture.wantedBy == [];
    assert lib.hasInfix "SystemMaxUse=1G" enabled.services.journald.extraConfig;
    assert lib.hasInfix "Image=localhost/lucidity-evaluation-fixture:unused" enabled.environment.etc."containers/systemd/fixture.container".text;
    assert wrappedCurl != null;
    assert wrappedCurl.flags."--fail";
    assert wrappedCurl.flags."--connect-timeout" == "10";
      pkgs.runCommand "lucidity-nixos-foundation-check" {} ''
        ${wrappedCurl}/bin/lucidity-curl --version > "$out"
        grep -Fq 'curl ' "$out"
      '';
  };
}
