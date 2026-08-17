{mkBootcHost, ...}: let
  admin = {
    classes = [];
    lucidity.sshPublicKeySecret = "ADMIN_SSH_PUBLIC_KEY";
    lucidity.sshFingerprint = "SHA256:azw3+qLpmhaHpAcVRQnZHYyBBlEtzCAf2svZ+DhvtAk";
  };
in {
  den.hosts.x86_64-linux = {
    controller = mkBootcHost {
      name = "controller";
      role = "controller";
      overlayIPv4 = "100.96.0.1";
      nebulaGroups = [
        "server"
        "controller"
        "lighthouse"
        "relay"
      ];
      instanceType = "t3a.small";
      rootVolumeGiB = 40;
      inherit admin;
    };

    worker = mkBootcHost {
      name = "worker";
      role = "worker";
      overlayIPv4 = "100.96.0.2";
      nebulaGroups = [
        "server"
        "worker"
      ];
      instanceType = "t3a.medium";
      rootVolumeGiB = 80;
      inherit admin;
    };
  };
}
