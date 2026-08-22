{
  inputs,
  lib,
  ...
}: let
  instantiate = {modules, ...}:
    lib.evalModules {
      modules = [../classes/bootc/profile.nix] ++ modules;
      specialArgs = {
        inherit inputs;
        pkgs = inputs.nixpkgs.legacyPackages.x86_64-linux;
      };
    };
in {
  _module.args.mkBootcHost = {
    name,
    role,
    overlayIPv4,
    nebulaGroups,
    instanceType,
    rootVolumeGiB,
    monitoring ? {httpsTargets = [];},
    admin,
  }: {
    class = "bootc";
    hostName = name;
    inherit instantiate;
    intoAttr = ["denConfigurations" name];
    users.admin = admin;
    lucidity = {
      inherit role overlayIPv4 nebulaGroups instanceType rootVolumeGiB monitoring;
      admin = {
        inherit (admin.lucidity) sshPublicKeySecret sshFingerprint;
      };
    };
  };
}
