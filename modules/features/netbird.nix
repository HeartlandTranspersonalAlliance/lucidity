{
  den,
  inputs,
  ...
}: {
  # Package-only opt-in: no daemon, firewall, provider lookup, or credentials.
  den.aspects.lucidity-netbird-packages.nixos = {
    config,
    lib,
    pkgs,
    ...
  }: let
    packages = import ../../nix/pkgs/netbird.nix {inherit pkgs;};
  in {
    options.lucidity.netbird.packages.enable = lib.mkEnableOption "the native NetBird client, combined server and proxy binaries";
    config = lib.mkIf config.lucidity.netbird.packages.enable {
      environment.systemPackages = [packages.client packages.server packages.proxy];
    };
  };
  flake.nixosModules.lucidity-netbird-packages = den.lib.aspects.resolve "nixos" den.aspects.lucidity-netbird-packages;

  perSystem = {pkgs, ...}: let
    packages = import ../../nix/pkgs/netbird.nix {inherit pkgs;};
    evaluate = extra:
      (inputs.nixpkgs.lib.nixosSystem {
        system = pkgs.stdenv.hostPlatform.system;
        modules = [{system.stateVersion = "26.05";}] ++ extra;
      }).config;
    module = den.lib.aspects.resolve "nixos" den.aspects.lucidity-netbird-packages;
    baseline = evaluate [];
    disabled = evaluate [module];
    enabled = evaluate [module {lucidity.netbird.packages.enable = true;}];
    footprint = c: {
      services = builtins.attrNames c.systemd.services;
      timers = builtins.attrNames c.systemd.timers;
      inherit (c.networking.firewall) allowedTCPPorts allowedUDPPorts;
      etc = builtins.attrNames c.environment.etc;
      users = builtins.attrNames c.users.users;
      podman = c.virtualisation.podman.enable;
    };
  in {
    packages = {
      netbird-client = packages.client;
      netbird-server = packages.server;
      netbird-proxy = packages.proxy;
    };
    checks.netbird-packages-eval = assert footprint baseline == footprint disabled;
    assert footprint baseline == footprint enabled;
    assert map toString baseline.environment.systemPackages == map toString disabled.environment.systemPackages;
    assert builtins.all (p: builtins.elem p enabled.environment.systemPackages) (builtins.attrValues packages);
    assert builtins.all (p: p.version == "0.81.5" && p.GOTOOLCHAIN == "local" && p.pnpmDeps == null) (builtins.attrValues packages);
    assert builtins.all (p: builtins.elem "-X github.com/netbirdio/netbird/version.version=0.81.5" p.ldflags) (builtins.attrValues packages);
    assert packages.server.src == packages.client.src && packages.proxy.src == packages.client.src;
    assert packages.server.subPackages == ["combined"];
      pkgs.runCommand "lucidity-netbird-packages-eval" {} "touch $out";
    # Building this check builds all three packages using the unchanged root pin.
    # Only help/version inspection: no listener, account creation or auth calls.
    checks.netbird-packages-smoke =
      pkgs.runCommand "lucidity-netbird-packages-smoke" {
        nativeBuildInputs = [pkgs.go];
      } ''
        export HOME="$TMPDIR/home"
        mkdir -p "$HOME" "$out"
        # Proxy's main can start profiling from NB_PPROF_ADDR even for --help.
        # Keep these invocations safe if the check environment later grows.
        runClean() { env -i HOME="$HOME" PATH="$PATH" "$@"; }
        test -x ${packages.client}/bin/netbird
        test -x ${packages.server}/bin/netbird-server
        test -x ${packages.proxy}/bin/netbird-proxy
        runClean ${packages.client}/bin/netbird version > "$out/client-version"
        grep -Fq '0.81.5' "$out/client-version"
        runClean ${packages.proxy}/bin/netbird-proxy --version > "$out/proxy-version"
        grep -Fq '0.81.5' "$out/proxy-version"
        runClean ${packages.server}/bin/netbird-server --help > "$out/server-help"
        grep -Fq -- '--config' "$out/server-help"
        runClean ${packages.proxy}/bin/netbird-proxy --help > "$out/proxy-help"
        for binary in ${packages.client}/bin/netbird ${packages.server}/bin/netbird-server ${packages.proxy}/bin/netbird-proxy; do
          go version -m "$binary" >> "$out/build-info"
        done
        # Go omits linker flags from build metadata with Nix's -trimpath.
        # Check entrypoints here; shared source/version flags are asserted above.
        for entrypoint in client combined proxy/cmd/proxy; do
          grep -Fxq "$(printf '\tpath\tgithub.com/netbirdio/netbird/%s' "$entrypoint")" "$out/build-info"
        done
      '';
  };
}
