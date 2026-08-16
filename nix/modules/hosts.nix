{
  inputs,
  lib,
  ...
}: let
  instantiate = {modules, ...}:
    lib.evalModules {
      modules = [./profile-options.nix] ++ modules;
      specialArgs = {
        inherit inputs;
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      };
    };

  admin = {
    classes = [];
    lucidity.sshPublicKeySecret = "ADMIN_SSH_PUBLIC_KEY";
    lucidity.sshFingerprint = "SHA256:azw3+qLpmhaHpAcVRQnZHYyBBlEtzCAf2svZ+DhvtAk";
  };

  mkHost = name: role: overlayIPv4: nebulaGroups: instanceType: rootVolumeGiB: {
    class = "bootc";
    hostName = name;
    inherit instantiate;
    intoAttr = [
      "denConfigurations"
      name
    ];
    users.admin = admin;
    lucidity = {
      inherit
        role
        overlayIPv4
        nebulaGroups
        instanceType
        rootVolumeGiB
        ;
      admin = {
        inherit (admin.lucidity) sshPublicKeySecret sshFingerprint;
      };
    };
  };
in {
  den.hosts.x86_64-linux = {
    controller =
      mkHost "controller" "controller" "100.96.0.1" [
        "server"
        "controller"
        "lighthouse"
        "relay"
      ] "t3a.small"
      40;

    worker =
      mkHost "worker" "worker" "100.96.0.2" [
        "server"
        "worker"
      ] "t3a.medium"
      80;
  };
}
