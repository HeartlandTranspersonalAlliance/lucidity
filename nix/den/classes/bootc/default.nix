{lib, ...}: let
  hostSchema = {...}: {
    options.lucidity = {
      role = lib.mkOption {
        type = lib.types.enum ["controller" "worker"];
        description = "Lucidity bootc role.";
      };
      overlayIPv4 = lib.mkOption {
        type = lib.types.str;
        description = "Nebula overlay address without its prefix length.";
      };
      nebulaGroups = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        description = "Certificate groups assigned to this host.";
      };
      instanceType = lib.mkOption {
        type = lib.types.str;
        description = "Production EC2 instance type.";
      };
      rootVolumeGiB = lib.mkOption {
        type = lib.types.ints.positive;
        description = "Production gp3 root volume size.";
      };
      admin = {
        sshPublicKeySecret = lib.mkOption {type = lib.types.str;};
        sshFingerprint = lib.mkOption {type = lib.types.str;};
      };
    };
  };

  userSchema = {...}: {
    options.lucidity = {
      sshPublicKeySecret = lib.mkOption {
        type = lib.types.str;
        description = "SecretSpec name resolving to this user's OpenSSH public key.";
      };
      sshFingerprint = lib.mkOption {
        type = lib.types.str;
        description = "Expected SHA256 fingerprint for the resolved public key.";
      };
    };
  };
in {
  den.classes.bootc.description = "AlmaLinux bootc host profile";
  den.schema.host.imports = [hostSchema];
  den.schema.user.imports = [userSchema];
}
