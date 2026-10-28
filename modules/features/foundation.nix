{den, ...}: {
  den.aspects.lucidity-foundation = {
    includes = [
      den.aspects.lucidity-tools
      den.aspects.lucidity-quadlet
      den.aspects.lucidity-secretspec
    ];
    nixos = {
      config,
      lib,
      ...
    }: {
      options.lucidity.foundation.enable = lib.mkEnableOption "Lucidity's native NixOS foundation";
      config = lib.mkIf config.lucidity.foundation.enable {
        # Deliberately no users, SSH, networking, disks, or stateVersion here.
        services.journald.extraConfig = ''
          SystemMaxUse=1G
          MaxRetentionSec=7day
        '';
      };
    };
  };
}
