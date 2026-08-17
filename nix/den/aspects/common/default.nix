{den, ...}: {
  den.aspects.bootc-common.bootc = {pkgs, ...}: {
    lucidity = {
      packages = with pkgs; [
        age
        awscli2
        bashInteractive
        btop
        curl
        git
        jq
        nebula
        openbao
        openssh
        ripgrep
        secretspec
        tmux
        vim
      ];
      admin = {
        name = "admin";
        sshPublicKeySecret = "ADMIN_SSH_PUBLIC_KEY";
        sshFingerprint = "SHA256:azw3+qLpmhaHpAcVRQnZHYyBBlEtzCAf2svZ+DhvtAk";
      };
      persistentPaths = [
        "/var/home/admin"
        "/var/lib/docker"
        "/var/lib/nebula"
        "/var/lib/nix"
        "/var/usrlocal"
      ];
      files = {
        "etc/docker/daemon.json" = builtins.toJSON {
          data-root = "/var/lib/docker";
          live-restore = true;
          log-driver = "local";
        };
        "etc/selinux/config" = ''
          SELINUX=enforcing
          SELINUXTYPE=targeted
        '';
        "etc/sudoers.d/90-lucidity-admin" = ''
          admin ALL=(ALL) NOPASSWD: ALL
        '';
      };
    };
  };

  den.aspects.controller.includes = [den.aspects.bootc-common];
  den.aspects.worker.includes = [den.aspects.bootc-common];
}
