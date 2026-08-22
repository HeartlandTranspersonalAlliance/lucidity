{lib, ...}: {
  options.nixpkgs = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = {};
    description = "Compatibility option consumed by Den's package-policy batteries.";
  };
  options.users = lib.mkOption {
    type = lib.types.attrsOf lib.types.anything;
    default = {};
    description = "Den user registry projection for non-NixOS bootc profiles.";
  };
  options.lucidity = {
    role = lib.mkOption {
      type = lib.types.enum [
        "controller"
        "worker"
      ];
    };
    hostName = lib.mkOption {type = lib.types.str;};
    overlayIPv4 = lib.mkOption {type = lib.types.str;};
    nebulaGroups = lib.mkOption {type = lib.types.listOf lib.types.str;};
    monitoring.httpsTargets = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    packages = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [];
    };
    admin = {
      name = lib.mkOption {
        type = lib.types.str;
        default = "admin";
      };
      sshPublicKeySecret = lib.mkOption {type = lib.types.str;};
      sshFingerprint = lib.mkOption {type = lib.types.str;};
    };
    persistentPaths = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
    };
    services = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
    };
    files = lib.mkOption {
      type = lib.types.attrsOf lib.types.lines;
      default = {};
    };
  };
}
