{
  lib,
  pkgs,
  profileConfig,
  systemProfile,
  homeActivation,
  openbaoKmsPlugin,
  asmExec,
  awsWorkloadCredentialsProvider,
}: let
  cfg = profileConfig.lucidity;
  role = cfg.role;
  isController = role == "controller";
  closure = pkgs.closureInfo {
    rootPaths =
      [
        systemProfile
        homeActivation
      ]
      ++ lib.optional isController openbaoKmsPlugin;
  };
  nebulaConfig = import ./nebula.nix {
    inherit lib role;
  };

  generatedFiles =
    cfg.files
    // {
      "etc/nebula/config.yml.in" = nebulaConfig;
      "etc/ssh/sshd_config.d/40-lucidity.conf" = ''
        PasswordAuthentication no
        KbdInteractiveAuthentication no
        PermitRootLogin ${
          if isController
          then "no"
          else "prohibit-password"
        }
        AuthorizedKeysFile .ssh/authorized_keys
      '';
      "etc/lucidity/role" = "${role}\n";
      "etc/lucidity/backup-target.env.example" = builtins.replaceStrings ["@ROLE@"] [role] cfg.files."etc/lucidity/backup-target.env.example";
      "usr/libexec/lucidity/backup" = builtins.readFile ../../aspects/common/files/backup.sh;
      "usr/lib/lucidity/profile-path" = "${systemProfile}\n";
      "usr/lib/lucidity/home-activation-path" = "${homeActivation}\n";
      "usr/share/lucidity/nix-smoke/flake.nix" = builtins.readFile ../../../smoke/flake.nix;
      "usr/share/lucidity/nix-smoke/flake.lock" = builtins.readFile ../../../smoke/flake.lock;
      "usr/lib/sysusers.d/lucidity.conf" = ''
        g docker - -
        u admin - "Lucidity administrator" /var/home/admin /bin/bash
        ${lib.optionalString isController ''
          g aws-wcp-token - -
          u aws-wcp - "AWS Workload Credentials Provider" /var/lib/aws-workload-credentials-provider /sbin/nologin
          m aws-wcp aws-wcp-token
        ''}
        ${lib.optionalString isController ''u openbao - "OpenBao service" /var/lib/openbao /sbin/nologin''}
      '';
      "usr/lib/tmpfiles.d/lucidity.conf" = ''
        d /var/lib/docker 0710 root docker -
        d /var/lib/amazon 0755 root root -
        d /var/lib/amazon/ssm 0755 root root -
        d /var/home/admin 0700 admin admin -
        d /var/home/admin/.ssh 0700 admin admin -
        d /var/lib/nebula 0700 root root -
        d /var/lib/nix 0755 root root -
        d /var/lib/coolify 0700 root root -
        d /var/lib/lucidity-backup 0700 root root -
        d /var/lib/lucidity-backup/staging 0700 root root -
        d /var/lib/lucidity-restore 0700 root root -
        d /etc/lucidity/backup.d 0700 root root -
        d /var/usrlocal 0755 root root -
        d /var/usrlocal/bin 0755 root root -
        d /etc/coolify-worker 0700 root root -
        d /data/coolify 0700 root root -
        ${lib.optionalString isController ''
          d /etc/coolify-controller 0700 root root -
          d /var/lib/aws-workload-credentials-provider 0750 aws-wcp aws-wcp -
          d /var/lib/openbao 0700 openbao openbao -
          d /var/lib/openbao/raft 0700 openbao openbao -
          d /var/lib/openbao/tls 0700 openbao openbao -
          d /var/lib/openbao/plugins 0700 openbao openbao -
          d /var/lib/openbao/snapshots 0700 openbao openbao -
        ''}
      '';
      "usr/libexec/lucidity/activate-nix-profile" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        profile=$(< /usr/lib/lucidity/profile-path)
        activation=$(< /usr/lib/lucidity/home-activation-path)
        install -d -m 0755 /nix/store
        for seed_path in /usr/lib/lucidity/nix-seed/store/*; do
          destination=/nix/store/''${seed_path##*/}
          [[ -e $destination ]] || cp -a "$seed_path" /nix/store/
        done
        /nix/var/nix/profiles/default/bin/nix-store --load-db < /usr/lib/lucidity/nix-seed/registration
        /nix/var/nix/profiles/default/bin/nix-store --verify-path "$profile"
        /nix/var/nix/profiles/default/bin/nix-env --profile /nix/var/nix/profiles/lucidity --set "$profile"
        install -d -m 0755 /var/usrlocal/bin
        ln -sfn /nix/var/nix/profiles/lucidity/bin/lucidity /var/usrlocal/bin/lucidity
        runuser -u admin -- env \
          HOME=/var/home/admin \
          USER=admin \
          LOGNAME=admin \
          PATH=/nix/var/nix/profiles/default/bin:${systemProfile}/bin:/usr/bin:/bin \
          "$activation/activate"
      '';
      "usr/libexec/lucidity/install-admin-authorized-key" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        source_file=/etc/lucidity/admin-authorized-key
        destination=/var/home/admin/.ssh/authorized_keys
        expected_fingerprint=${lib.escapeShellArg cfg.admin.sshFingerprint}
        if [[ -e /etc/lucidity/vm-fixture ]]; then
          fingerprint_file=/etc/lucidity/admin-authorized-key.fingerprint
          [[ -s $fingerprint_file ]] || {
            echo "VM fixture administrator fingerprint is unavailable" >&2
            exit 1
          }
          IFS= read -r expected_fingerprint < "$fingerprint_file"
          [[ $expected_fingerprint == SHA256:* ]] || {
            echo "VM fixture administrator fingerprint is invalid" >&2
            exit 1
          }
        fi
        [[ -s $source_file ]] || {
          echo "administrator public key is unavailable" >&2
          exit 1
        }
        read -r _ actual_fingerprint _ < <(/usr/bin/ssh-keygen -lf "$source_file")
        [[ $actual_fingerprint == "$expected_fingerprint" ]] || {
          echo "administrator public key fingerprint mismatch" >&2
          exit 1
        }
        install -d -o admin -g admin -m 0700 /var/home/admin/.ssh
        install -o admin -g admin -m 0600 "$source_file" "$destination"
        restorecon -RF /var/home/admin/.ssh
      '';
      "usr/libexec/lucidity/install-determinate-nix" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        installer=/usr/libexec/lucidity/nix-installer
        receipt=/nix/receipt.json
        if [[ -e $receipt ]]; then
          systemctl daemon-reload
          systemctl start nix.mount nix-daemon.socket nix-daemon.service
          exit 0
        fi
        [[ $(getenforce) == Enforcing ]] || {
          echo "Determinate Nix installation requires SELinux enforcing mode" >&2
          exit 1
        }
        exec "$installer" install ostree --no-confirm --determinate \
          --persistence /var/lib/nix --diagnostic-endpoint ""
      '';
      "usr/libexec/lucidity/prepare-nebula" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        install -d -m 0700 /var/lib/nebula /run/nebula
        if [[ ! -s /var/lib/nebula/host.key || ! -s /var/lib/nebula/host.pub ]]; then
          umask 077
          ${pkgs.nebula}/bin/nebula-cert keygen \
            -out-key /var/lib/nebula/host.key \
            -out-pub /var/lib/nebula/host.pub
        fi
        blocklist='[]'
        if [[ -s /var/lib/nebula/blocklist ]]; then
          blocklist=$(${pkgs.jq}/bin/jq -Rsc 'split("\n") | map(select(length > 0))' /var/lib/nebula/blocklist)
        fi
        ${pkgs.gnused}/bin/sed "s|\"@BLOCKLIST@\"|$blocklist|" \
          /etc/nebula/config.yml.in > /run/nebula/config.yml
        chmod 0600 /run/nebula/config.yml
      '';
      "usr/libexec/lucidity/check-nebula-expiry" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        [[ -s /var/lib/nebula/host.crt ]] || exit 0
        expiry=$(${pkgs.nebula}/bin/nebula-cert print -json -path /var/lib/nebula/host.crt | ${pkgs.jq}/bin/jq -r '.details.notAfter')
        expiry_epoch=$(${pkgs.coreutils}/bin/date --date "$expiry" +%s)
        now=$(${pkgs.coreutils}/bin/date +%s)
        days=$(( (expiry_epoch - now) / 86400 ))
        if (( days <= 7 )); then
          echo "CRITICAL: Nebula certificate expires in $days days" >&2
          exit 1
        elif (( days <= 30 )); then
          echo "WARNING: Nebula certificate expires in $days days" >&2
        elif (( days <= 60 )); then
          echo "NOTICE: Nebula certificate expires in $days days" >&2
        fi
      '';
      "usr/lib/systemd/system/lucidity-nix-profile.service" = ''
        [Unit]
        Description=Activate the locked Lucidity Nix and Home Manager profiles
        Requires=determinate-nix-install.service
        After=determinate-nix-install.service

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/activate-nix-profile
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/determinate-nix-install.service" = ''
        [Unit]
        Description=Install Determinate Nix with the native OSTree planner
        After=network-online.target
        Wants=network-online.target
        StartLimitIntervalSec=15min
        StartLimitBurst=3

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/install-determinate-nix
        RemainAfterExit=yes
        TimeoutStartSec=30min
        Restart=on-failure
        RestartSec=1min

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/lucidity-admin-authorized-key.service" = ''
        [Unit]
        Description=Install the SecretSpec-provisioned administrator SSH key
        After=cloud-final.service
        ConditionPathExists=/etc/lucidity/admin-authorized-key

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/install-admin-authorized-key
        RemainAfterExit=yes

        [Install]
        WantedBy=cloud-init.target
      '';
      "usr/lib/systemd/system/nebula.service" = ''
        [Unit]
        Description=Lucidity Nebula mesh
        Requires=lucidity-nix-profile.service
        After=lucidity-nix-profile.service network-online.target
        Wants=network-online.target
        ConditionPathExists=/var/lib/nebula/ca.crt
        ConditionPathExists=/var/lib/nebula/host.crt

        [Service]
        Type=simple
        ExecStartPre=/usr/libexec/lucidity/prepare-nebula
        ExecStart=${pkgs.nebula}/bin/nebula -config /run/nebula/config.yml
        Restart=on-failure
        RestartSec=5s
        AmbientCapabilities=CAP_NET_ADMIN
        CapabilityBoundingSet=CAP_NET_ADMIN
        DeviceAllow=/dev/net/tun rw
        LockPersonality=yes
        MemoryDenyWriteExecute=yes
        NoNewPrivileges=yes
        PrivateDevices=no
        PrivateTmp=yes
        ProtectClock=yes
        ProtectControlGroups=yes
        ProtectHome=yes
        ProtectHostname=yes
        ProtectKernelLogs=yes
        ProtectKernelModules=yes
        ProtectKernelTunables=yes
        ProtectSystem=strict
        ReadWritePaths=/var/lib/nebula /run/nebula
        RestrictAddressFamilies=AF_INET AF_INET6 AF_NETLINK
        RestrictNamespaces=yes
        RestrictRealtime=yes
        SystemCallArchitectures=native

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/lucidity-nebula-expiry.service" = ''
        [Unit]
        Description=Check Nebula certificate expiry thresholds
        After=nebula.service

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/check-nebula-expiry
      '';
      "usr/lib/systemd/system/lucidity-nebula-expiry.timer" = ''
        [Unit]
        Description=Daily Nebula certificate expiry check

        [Timer]
        OnCalendar=daily
        Persistent=true
        RandomizedDelaySec=30m

        [Install]
        WantedBy=timers.target
      '';
      "usr/lib/systemd/system/lucidity-backup.service" = ''
        [Unit]
        Description=Back up Lucidity application data to an independent restic repository
        Wants=network-online.target
        After=network-online.target
        ConditionPathExists=/etc/lucidity/backup-target.env
        ${lib.optionalString isController "Requires=openbao.service\nAfter=openbao.service"}

        [Service]
        Type=oneshot
        User=root
        UMask=0077
        ${lib.optionalString isController "LoadCredential=bao-token:/var/lib/openbao/backup-token"}
        Environment=PATH=${systemProfile}/bin:/usr/sbin:/usr/bin:/sbin:/bin
        ExecStart=/usr/libexec/lucidity/backup run
        LockPersonality=yes
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectClock=yes
        ProtectControlGroups=yes
        ProtectHome=read-only
        ProtectHostname=yes
        ProtectKernelLogs=yes
        ProtectKernelModules=yes
        ProtectKernelTunables=yes
        ProtectSystem=strict
        ReadWritePaths=/var/lib/lucidity-backup /var/lib/lucidity-restore ${lib.optionalString isController "/var/lib/openbao/snapshots"}
        RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
        RestrictNamespaces=yes
        RestrictRealtime=yes
        SystemCallArchitectures=native
      '';
      "usr/lib/systemd/system/lucidity-backup.timer" = ''
        [Unit]
        Description=Daily Lucidity application-data backup

        [Timer]
        OnCalendar=*-*-* 03:30:00 UTC
        Persistent=true
        RandomizedDelaySec=15m

        [Install]
        WantedBy=timers.target
      '';
    }
    // lib.optionalAttrs isController {
      "etc/coolify-controller/runtime-secrets.env.example" = ''
        # Provision this reference-only file as runtime-secrets.env through SSM.
        COOLIFY_APP_ID={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:APP_ID}}
        COOLIFY_APP_KEY={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:APP_KEY}}
        COOLIFY_DB_PASSWORD={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:DB_PASSWORD}}
        COOLIFY_REDIS_PASSWORD={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:REDIS_PASSWORD}}
        COOLIFY_PUSHER_APP_ID={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:PUSHER_APP_ID}}
        COOLIFY_PUSHER_APP_KEY={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:PUSHER_APP_KEY}}
        COOLIFY_PUSHER_APP_SECRET={{resolve:secretsmanager:lucidity/production/controller-runtime:SecretString:PUSHER_APP_SECRET}}
      '';
      "usr/libexec/lucidity/bootstrap-controller" =
        builtins.readFile ../../aspects/controller/files/bootstrap-controller.sh;
      "usr/libexec/lucidity/bootstrap-controller-with-secrets" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        reference_file=''${COOLIFY_RUNTIME_SECRETS_FILE:-/etc/coolify-controller/runtime-secrets.env}
        bootstrap_bin=''${COOLIFY_BOOTSTRAP_BIN:-/usr/libexec/lucidity/bootstrap-controller}
        token_file=''${AWS_WCP_TOKEN_FILE:-/run/awssmatoken}
        asm_exec_bin=''${ASM_EXEC_BIN:-${asmExec}/bin/asm-exec}
        variables=(
          COOLIFY_APP_ID COOLIFY_APP_KEY COOLIFY_DB_PASSWORD
          COOLIFY_REDIS_PASSWORD COOLIFY_PUSHER_APP_ID
          COOLIFY_PUSHER_APP_KEY COOLIFY_PUSHER_APP_SECRET
        )
        if [[ ! -e $reference_file ]]; then
          exec "$bootstrap_bin"
        fi
        for variable in "''${variables[@]}"; do
          value=''${!variable:-}
          [[ $value =~ ^\{\{resolve:secretsmanager:.+:SecretString:[^}:]+(:AWSCURRENT)?\}\}$ ]] || {
            echo "$reference_file must define $variable as a Secrets Manager dynamic reference" >&2
            exit 1
          }
        done
        [[ -r $token_file ]] || {
          echo "AWS workload credentials token is unavailable" >&2
          exit 1
        }
        IFS= read -r token < "$token_file"
        [[ -n $token ]] || {
          echo "AWS workload credentials token is empty" >&2
          exit 1
        }
        AWS_TOKEN="$token" exec "$asm_exec_bin" -- \
          env -u AWS_TOKEN "$bootstrap_bin"
      '';
      "usr/libexec/lucidity/workload-credentials-provider-token" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        token_file=/run/awssmatoken
        case "''${1:-}" in
          start)
            install -o root -g aws-wcp-token -m 0640 /dev/null "$token_file"
            head -c 32 /dev/urandom | sha256sum | cut -d ' ' -f 1 > "$token_file"
            ;;
          stop)
            rm -f "$token_file"
            ;;
          *)
            echo "usage: ''${0##*/} start|stop" >&2
            exit 2
            ;;
        esac
      '';
      "usr/lib/systemd/system/aws-workload-credentials-provider-token.service" = ''
        [Unit]
        Description=Initialize the AWS Workload Credentials Provider SSRF token
        Before=aws-workload-credentials-provider-sm.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/libexec/lucidity/workload-credentials-provider-token start
        ExecStop=/usr/libexec/lucidity/workload-credentials-provider-token stop

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/aws-workload-credentials-provider-sm.service" = ''
        [Unit]
        Description=AWS Workload Credentials Provider for Secrets Manager
        Requires=aws-workload-credentials-provider-token.service
        After=aws-workload-credentials-provider-token.service network-online.target cloud-final.service
        Wants=network-online.target
        ConditionPathExists=/etc/coolify-controller/runtime-secrets.env

        [Service]
        Type=simple
        User=aws-wcp
        Group=aws-wcp
        SupplementaryGroups=aws-wcp-token
        WorkingDirectory=/var/lib/aws-workload-credentials-provider
        Environment=AWS_TOKEN=file:///run/awssmatoken
        ExecStart=${awsWorkloadCredentialsProvider}/bin/aws-workload-credentials-provider sm start
        ExecStartPost=${pkgs.curl}/bin/curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 1 --retry-max-time 30 --connect-timeout 1 http://127.0.0.1:2773/ping
        Restart=on-failure
        RestartSec=5s
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectHome=yes
        ProtectSystem=strict
        ReadWritePaths=/var/lib/aws-workload-credentials-provider
        RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX

        [Install]
        WantedBy=cloud-init.target
      '';
      "usr/libexec/lucidity/prepare-controller-storage" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        source_path=''${COOLIFY_PERSISTENT_SOURCE:-/var/lib/coolify}
        target_path=''${COOLIFY_PERSISTENT_TARGET:-/data/coolify}
        install -d -m 0700 "$source_path"
        [[ -d $target_path ]] || {
          echo "controller storage mountpoint $target_path is missing" >&2
          exit 1
        }
        if ! mountpoint --quiet "$target_path"; then
          mount --bind "$source_path" "$target_path"
        fi
        restorecon -RF "$target_path"
      '';
      "usr/lib/systemd/system/coolify-controller-storage.service" = ''
        [Unit]
        Description=Bind persistent Coolify controller storage
        After=local-fs.target
        Before=coolify-controller-bootstrap.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/libexec/lucidity/prepare-controller-storage

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/coolify-controller-bootstrap.service" = ''
        [Unit]
        Description=Initialize the Coolify controller after the secure mesh and CA custodian
        Requires=coolify-controller-storage.service docker.service openbao.service
        After=coolify-controller-storage.service docker.service openbao.service network-online.target cloud-final.service aws-workload-credentials-provider-sm.service
        Wants=network-online.target aws-workload-credentials-provider-sm.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        EnvironmentFile=-/etc/coolify-controller/runtime-secrets.env
        Environment=PATH=${systemProfile}/bin:/usr/sbin:/usr/bin:/sbin:/bin
        Environment=COOLIFY_CURL_BIN=/usr/bin/curl
        ExecStart=/usr/libexec/lucidity/bootstrap-controller-with-secrets
        TimeoutStartSec=15min

        [Install]
        WantedBy=cloud-init.target
      '';
      "usr/lib/lucidity/openbao-kms-plugin-path" = "${openbaoKmsPlugin}/bin/openbao-plugin-kms-aws\n";
      "usr/libexec/lucidity/prepare-openbao" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        install -d -o openbao -g openbao -m 0700 \
          /var/lib/openbao/raft /var/lib/openbao/tls /var/lib/openbao/plugins /var/lib/openbao/snapshots
        if [[ ! -s /var/lib/openbao/tls/server.key ]]; then
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
            -subj /CN=localhost -days 825 \
            -addext subjectAltName=IP:127.0.0.1,DNS:localhost \
            -keyout /var/lib/openbao/tls/server.key \
            -out /var/lib/openbao/tls/server.crt
          chown openbao:openbao /var/lib/openbao/tls/server.key /var/lib/openbao/tls/server.crt
          chmod 0600 /var/lib/openbao/tls/server.key
        fi
        plugin=$(< /usr/lib/lucidity/openbao-kms-plugin-path)
        install -m 0500 -o openbao -g openbao "$plugin" /var/lib/openbao/plugins/openbao-plugin-kms-aws
        sha=$(${pkgs.coreutils}/bin/sha256sum /var/lib/openbao/plugins/openbao-plugin-kms-aws | ${pkgs.coreutils}/bin/cut -d' ' -f1)
        ${pkgs.gnused}/bin/sed \
          -e "s|@AWS_KMS_PLUGIN@|/var/lib/openbao/plugins/openbao-plugin-kms-aws|" \
          -e "s|@AWS_KMS_PLUGIN_SHA256@|$sha|" \
          /etc/openbao/openbao.hcl.in > /run/openbao.hcl
        chown openbao:openbao /run/openbao.hcl
        chmod 0600 /run/openbao.hcl
      '';
      "usr/libexec/lucidity/openbao-snapshot" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        token_file=/run/credentials/openbao-snapshot.service/bao-token
        [[ -s $token_file ]] || { echo "OpenBao snapshot token credential is unavailable" >&2; exit 1; }
        export BAO_ADDR=https://127.0.0.1:8200
        export BAO_CACERT=/var/lib/openbao/tls/server.crt
        export BAO_TOKEN
        BAO_TOKEN=$(< "$token_file")
        snapshot=/var/lib/openbao/snapshots/raft-$(${pkgs.coreutils}/bin/date -u +%Y%m%dT%H%M%SZ).snap
        temporary="$snapshot.tmp"
        trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT
        ${pkgs.openbao}/bin/bao operator raft snapshot save "$temporary"
        chown openbao:openbao "$temporary"
        chmod 0600 "$temporary"
        mv "$temporary" "$snapshot"
        ${pkgs.findutils}/bin/find /var/lib/openbao/snapshots -type f -name 'raft-*.snap' -mtime +7 -delete
      '';
      "usr/lib/systemd/system/openbao.service" = ''
        [Unit]
        Description=Lucidity OpenBao CA custody service
        Requires=lucidity-nix-profile.service
        After=lucidity-nix-profile.service nebula.service

        [Service]
        User=openbao
        Group=openbao
        Type=notify
        ExecStartPre=+/usr/libexec/lucidity/prepare-openbao
        ExecStart=${pkgs.openbao}/bin/bao server -config=/run/openbao.hcl
        Restart=on-failure
        RestartSec=5s
        AmbientCapabilities=CAP_IPC_LOCK
        CapabilityBoundingSet=CAP_IPC_LOCK
        LockPersonality=yes
        MemoryDenyWriteExecute=yes
        NoNewPrivileges=yes
        PrivateDevices=yes
        PrivateTmp=yes
        ProtectClock=yes
        ProtectControlGroups=yes
        ProtectHome=yes
        ProtectHostname=yes
        ProtectKernelLogs=yes
        ProtectKernelModules=yes
        ProtectKernelTunables=yes
        ProtectSystem=strict
        ReadWritePaths=/var/lib/openbao /run
        RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
        RestrictNamespaces=yes
        RestrictRealtime=yes
        SystemCallArchitectures=native

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/openbao-snapshot.service" = ''
        [Unit]
        Description=Create an atomic OpenBao Raft snapshot
        Requires=openbao.service
        After=openbao.service

        [Service]
        Type=oneshot
        User=root
        LoadCredential=bao-token:/var/lib/openbao/operator-token
        ExecStart=/usr/libexec/lucidity/openbao-snapshot
      '';
      "usr/lib/systemd/system/openbao-snapshot.timer" = ''
        [Unit]
        Description=Daily OpenBao Raft snapshot before node backup

        [Timer]
        OnCalendar=*-*-* 04:30:00 UTC
        Persistent=true
        RandomizedDelaySec=10m

        [Install]
        WantedBy=timers.target
      '';
    }
    // lib.optionalAttrs (!isController) {
      "usr/libexec/lucidity/bootstrap-worker" = builtins.readFile ../../aspects/worker/files/bootstrap-worker.sh;
      "usr/libexec/lucidity/prepare-worker-storage" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        source_path=/var/lib/coolify
        target_path=/data/coolify
        install -d -m 0700 "$source_path"
        [[ -d $target_path ]] || {
          echo "worker storage mountpoint $target_path is missing from the bootc image" >&2
          exit 1
        }
        if ! mountpoint --quiet "$target_path"; then
          mount --bind "$source_path" "$target_path"
        fi
        restorecon -RF "$target_path"
      '';
      "usr/lib/systemd/system/coolify-worker-storage.service" = ''
        [Unit]
        Description=Bind persistent Coolify worker storage
        After=local-fs.target
        Before=coolify-worker-authorized-keys.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/libexec/lucidity/prepare-worker-storage

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/coolify-worker-authorized-keys.service" = ''
        [Unit]
        Description=Install the controller's runtime-provisioned worker SSH key
        Requires=coolify-worker-storage.service
        After=coolify-worker-storage.service nebula.service cloud-final.service
        ConditionPathExists=/etc/coolify-worker/authorized_keys

        [Service]
        Type=oneshot
        Environment=PATH=${systemProfile}/bin:/usr/sbin:/usr/bin:/sbin:/bin
        ExecStart=/usr/libexec/lucidity/bootstrap-worker --authorized-key-file /etc/coolify-worker/authorized_keys
        RemainAfterExit=yes

        [Install]
        WantedBy=cloud-init.target
      '';
    };

  fileSources =
    lib.mapAttrs (
      path: content: pkgs.writeText (builtins.replaceStrings ["/"] ["-"] path) content
    )
    generatedFiles;

  installFiles = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (path: source: ''
      install -D -m ${
        if lib.hasPrefix "usr/libexec/" path
        then "0755"
        else "0644"
      } ${source} "$out/rootfs/${path}"
    '')
    fileSources
  );

  enabledUnits =
    [
      "determinate-nix-install.service"
      "lucidity-nix-profile.service"
      "lucidity-admin-authorized-key.service"
      "nebula.service"
      "lucidity-nebula-expiry.timer"
      "lucidity-backup.timer"
    ]
    ++ lib.optionals isController [
      "openbao.service"
      "openbao-snapshot.timer"
      "aws-workload-credentials-provider-token.service"
      "aws-workload-credentials-provider-sm.service"
      "coolify-controller-storage.service"
      "coolify-controller-bootstrap.service"
    ]
    ++ lib.optionals (!isController) [
      "coolify-worker-storage.service"
      "coolify-worker-authorized-keys.service"
    ];

  containerfile = pkgs.writeText "Containerfile-${role}" ''
    ARG BASE_IMAGE=quay.io/almalinuxorg/almalinux-bootc:10
    FROM ''${BASE_IMAGE}

    ARG SSM_AGENT_RPM_URL=https://s3.us-east-2.amazonaws.com/amazon-ssm-us-east-2/3.3.5068.0/linux_amd64/amazon-ssm-agent.rpm
    ARG NIX_INSTALLER_VERSION=3.21.0
    ARG NIX_INSTALLER_SHA256=b9911496659f0c35c642353d592926c024c205b597e8094bf73a42908a75e462
    ARG IMAGE_VERSION=dev

    RUN dnf -y install dnf-plugins-core && \
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo && \
        dnf -y install ca-certificates cloud-init container-selinux curl \
          docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin \
          NetworkManager openssh-server policycoreutils policycoreutils-python-utils \
          rsyslog selinux-policy-targeted sudo && \
        dnf -y install "''${SSM_AGENT_RPM_URL}" && \
        dnf clean all && \
        rm -rf /run/cloud-init /var/cache/* /var/lib/cloud /var/lib/dnf /var/log/*

    COPY rootfs/ /

    RUN rm -rf /usr/local && ln -s ../var/usrlocal /usr/local && \
        install -d -m 0755 /nix /usr/libexec/lucidity /var/lib/nix && \
        install -d -m 0700 /data/coolify /var/lib/coolify && \
        semanage fcontext -a -t container_file_t '/data/coolify(/.*)?' && \
        curl --fail --location --silent --show-error \
          --output /usr/libexec/lucidity/nix-installer \
          "https://github.com/DeterminateSystems/nix-installer/releases/download/v''${NIX_INSTALLER_VERSION}/nix-installer-x86_64-linux" && \
        echo "''${NIX_INSTALLER_SHA256}  /usr/libexec/lucidity/nix-installer" | sha256sum --check --strict && \
        chmod 0755 /usr/libexec/lucidity/* && \
        systemctl enable ${lib.concatStringsSep " " enabledUnits} \
          amazon-ssm-agent.service bootc-fetch-apply-updates.timer \
          cloud-config.service cloud-final.service cloud-init-local.service cloud-init.service \
          docker.service sshd.service && \
        bootc container lint

    LABEL org.opencontainers.image.title="Lucidity ${role}" \
          org.opencontainers.image.description="Nix-owned AlmaLinux bootc ${role}" \
          org.opencontainers.image.source="https://github.com/HeartlandTranspersonalAlliance/lucidity" \
          org.opencontainers.image.licenses="AGPL-3.0-only" \
          io.lucidity.role="${role}" \
          io.lucidity.image-version="''${IMAGE_VERSION}"
  '';
in
  pkgs.runCommand "lucidity-${role}-bootc-context" {} ''
    mkdir -p "$out/rootfs/usr/lib/lucidity/nix-seed/store"
    ${installFiles}
    install -m 0644 ${containerfile} "$out/Containerfile"
    install -m 0644 ${closure}/registration "$out/rootfs/usr/lib/lucidity/nix-seed/registration"
    while IFS= read -r store_path; do
      cp -a "$store_path" "$out/rootfs/usr/lib/lucidity/nix-seed/store/"
    done < ${closure}/store-paths
    ln -s ${systemProfile} "$out/system-profile"
    ln -s ${homeActivation} "$out/home-activation"
  ''
