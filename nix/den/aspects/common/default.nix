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
        prometheus-node-exporter
        ripgrep
        restic
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
        "/var/lib/lucidity-monitoring"
        "/var/usrlocal"
      ];
      files = {
        "etc/lucidity/secretspec.toml" = builtins.readFile ../../../../secretspec.toml;
        "etc/lucidity/backup-target.env.example" = ''
          # Copy to /etc/lucidity/backup-target.env and select exactly one backend.
          # Keep credentials in SecretSpec, never in this file.
          LUCIDITY_BACKUP_BACKEND=aws-s3
          LUCIDITY_BACKUP_REPOSITORY=s3:s3.us-east-2.amazonaws.com/example-bucket/lucidity/@ROLE@
          # LUCIDITY_BACKUP_PATHS=/var/lib/coolify:/var/lib/nebula
          # LUCIDITY_BACKUP_HOOK_DIRECTORY=/etc/lucidity/backup.d
        '';
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
