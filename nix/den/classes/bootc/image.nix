{
  lib,
  pkgs,
  profileConfig,
  systemProfile,
  homeActivation,
  openbaoKmsPlugin,
  openbaoAuthPlugin,
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
      ++ lib.optional isController openbaoKmsPlugin
      ++ lib.optional isController openbaoAuthPlugin;
  };
  nebulaConfig = import ./nebula.nix {
    inherit lib role;
  };
  monitoring = import ./monitoring.nix {
    inherit lib pkgs isController systemProfile;
    overlayIPv4 = cfg.overlayIPv4;
  };

  generatedFiles =
    cfg.files
    // monitoring.files
    // {
      "etc/containers/registries.conf.d/50-lucidity-ecr.conf" = ''
        # Resolve private ECR credentials from the EC2 instance profile at
        # request time. No registry token is written to the image or disk.
        credential-helpers = ["ecr-login"]
      '';
      "etc/systemd/system/bootc-fetch-apply-updates.service.d/10-lucidity-ecr-auth.conf" = ''
        [Unit]
        Requires=lucidity-bootc-ecr-auth.service
        After=lucidity-bootc-ecr-auth.service
      '';
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
      "usr/libexec/lucidity/prepare-bootc-ecr-auth" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        command -v docker-credential-ecr-login >/dev/null
        install -d -m 0700 /run/ostree
        temporary=$(mktemp /run/ostree/auth.json.XXXXXX)
        trap 'rm -f -- "''${temporary:-}"' EXIT
        printf '{}\n' >"$temporary"
        chmod 0600 "$temporary"
        mv -f "$temporary" /run/ostree/auth.json
      '';
      "usr/lib/lucidity/profile-path" = "${systemProfile}\n";
      "usr/lib/lucidity/home-activation-path" = "${homeActivation}\n";
      "usr/share/lucidity/nix-smoke/flake.nix" = builtins.readFile ../../../smoke/flake.nix;
      "usr/share/lucidity/nix-smoke/flake.lock" = builtins.readFile ../../../smoke/flake.lock;
      "usr/lib/sysusers.d/lucidity.conf" = ''
        g docker - -
        u admin - "Lucidity administrator" /var/home/admin /bin/bash
        u lucidity-metrics - "Lucidity metrics reader" /var/lib/lucidity-monitoring /sbin/nologin
        ${lib.optionalString isController ''
          g aws-wcp-token - -
          u aws-wcp - "AWS Workload Credentials Provider" /var/lib/aws-workload-credentials-provider /sbin/nologin
          m aws-wcp aws-wcp-token
          u prometheus - "Prometheus service" /var/lib/prometheus /sbin/nologin
          u alertmanager - "Alertmanager service" /var/lib/alertmanager /sbin/nologin
          u blackbox-exporter - "Blackbox exporter service" /var/empty /sbin/nologin
          u grafana - "Grafana service" /var/lib/grafana /sbin/nologin
          u loki - "Loki service" /var/lib/loki /sbin/nologin
          u ntfy - "ntfy service" /var/lib/ntfy /sbin/nologin
          u alertmanager-ntfy - "Alertmanager ntfy forwarder" /var/empty /sbin/nologin
        ''}
        ${lib.optionalString isController ''u openbao - "OpenBao service" /var/lib/openbao /sbin/nologin''}
        ${lib.optionalString (!isController) ''u ooye - "Out Of Your Element bridge" /var/lib/ooye /sbin/nologin''}
      '';
      "usr/lib/sysusers.d/nix.conf" = ''
        # Keep EPEL's nix-system identities deterministic and compatible with
        # the Determinate Nix Installer migration planner.
        g nixbld 30000
        g nixbld-1 31001
        g nixbld-2 31002
        g nixbld-3 31003
        g nixbld-4 31004
        g nixbld-5 31005
        g nixbld-6 31006
        g nixbld-7 31007
        g nixbld-8 31008
        g nixbld-9 31009
        g nixbld-10 31010
        u nixbld-1 30001:30000 "Nix build user 1" /var/empty /sbin/nologin
        u nixbld-2 30002:30000 "Nix build user 2" /var/empty /sbin/nologin
        u nixbld-3 30003:30000 "Nix build user 3" /var/empty /sbin/nologin
        u nixbld-4 30004:30000 "Nix build user 4" /var/empty /sbin/nologin
        u nixbld-5 30005:30000 "Nix build user 5" /var/empty /sbin/nologin
        u nixbld-6 30006:30000 "Nix build user 6" /var/empty /sbin/nologin
        u nixbld-7 30007:30000 "Nix build user 7" /var/empty /sbin/nologin
        u nixbld-8 30008:30000 "Nix build user 8" /var/empty /sbin/nologin
        u nixbld-9 30009:30000 "Nix build user 9" /var/empty /sbin/nologin
        u nixbld-10 30010:30000 "Nix build user 10" /var/empty /sbin/nologin
        m nixbld-1 nixbld
        m nixbld-2 nixbld
        m nixbld-3 nixbld
        m nixbld-4 nixbld
        m nixbld-5 nixbld
        m nixbld-6 nixbld
        m nixbld-7 nixbld
        m nixbld-8 nixbld
        m nixbld-9 nixbld
        m nixbld-10 nixbld
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
        d /var/lib/lucidity-monitoring 0755 root root -
        d /var/lib/lucidity-monitoring/textfile 0755 root lucidity-metrics -
        d /etc/lucidity/backup.d 0700 root root -
        d /var/usrlocal 0755 root root -
        d /var/usrlocal/bin 0755 root root -
        d /etc/coolify-worker 0700 root root -
        ${lib.optionalString (!isController) ''
          d /var/lib/ooye 0700 ooye ooye -
          d /etc/openbao 0755 root root -
          d /etc/ooye 0755 root root -
        ''}
        d /data/coolify 0700 root root -
        ${lib.optionalString isController ''
          d /etc/coolify-controller 0700 root root -
          d /var/lib/aws-workload-credentials-provider 0750 aws-wcp aws-wcp -
          d /var/lib/openbao 0700 openbao openbao -
          d /var/lib/openbao/raft 0700 openbao openbao -
          d /var/lib/openbao/tls 0700 openbao openbao -
          d /var/lib/openbao/plugins 0700 openbao openbao -
          d /var/lib/openbao/snapshots 0700 openbao openbao -
          d /var/lib/ntfy 0700 ntfy ntfy -
          d /var/lib/ntfy/attachments 0700 ntfy ntfy -
          d /var/lib/loki 0700 loki loki -
          d /var/lib/loki/chunks 0700 loki loki -
          d /var/lib/loki/rules 0700 loki loki -
          d /var/lib/loki/compactor 0700 loki loki -
        ''}
      '';
      "usr/libexec/lucidity/activate-nix-profile" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        profile=$(< /usr/lib/lucidity/profile-path)
        activation=$(< /usr/lib/lucidity/home-activation-path)
        nix_profile=/nix/var/nix/profiles/default/bin
        "$nix_profile/nix-store" --verify-path "$profile"
        "$nix_profile/nix-env" --profile /nix/var/nix/profiles/lucidity --set "$profile"
        install -d -m 0755 /var/usrlocal/bin
        ln -sfn /nix/var/nix/profiles/lucidity/bin/lucidity /var/usrlocal/bin/lucidity
        runuser -u admin -- env \
          HOME=/var/home/admin \
          USER=admin \
          LOGNAME=admin \
          NIX_REMOTE=daemon \
          PATH=/nix/var/nix/profiles/default/bin:${systemProfile}/bin:/usr/bin:/bin \
          "$activation/activate"
      '';
      "usr/libexec/lucidity/install-determinate-nix-selinux-policy" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        policy=/usr/share/selinux/packages/determinate-nix.pp
        [[ -s $policy ]]
        if ! semodule -l | awk '$1 == "nix" { found = 1 } END { exit !found }'; then
          semodule -i "$policy"
        fi
      '';
      "usr/libexec/lucidity/provision-determinate-nix" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        seed=/usr/lib/lucidity/determinate-nix-seed
        state=/var/lib/nix
        parent=''${state%/*}

        valid_installation() {
          [[ -x $1/nix-installer && -f $1/receipt.json && -d $1/store && -d $1/var/nix ]]
        }

        valid_installation "$seed" || {
          echo "The immutable Determinate Nix seed is incomplete: $seed" >&2
          exit 1
        }
        install -d -m 0755 "$parent" "$state"
        if find "$state" -mindepth 1 -print -quit | grep -q .; then
          valid_installation "$state" || {
            echo "Refusing to replace malformed Determinate Nix state: $state" >&2
            exit 1
          }
        else
          stage="$parent/.nix-seed.$$"
          trap 'rm -rf -- "''${stage:-}"' EXIT
          install -d -m 0755 "$stage"
          cp -a --reflink=auto "$seed/." "$stage/"
          valid_installation "$stage"
          rmdir "$state"
          mv "$stage" "$state"
          trap - EXIT
        fi
        restorecon -RF "$state"
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
        contract=/etc/lucidity/deployment.json
        [[ -s $contract ]] || { echo "deployment contract is unavailable" >&2; exit 1; }
        mesh_hostname=$(${pkgs.jq}/bin/jq -er '.runtime.mesh_hostname | select(test("^[A-Za-z0-9.-]+$"))' "$contract")
        vpc_cidr=$(${pkgs.jq}/bin/jq -er '.runtime.vpc_cidr | select(test("^[0-9./]+$"))' "$contract")
        ${pkgs.gnused}/bin/sed \
          -e "s|\"@BLOCKLIST@\"|$blocklist|" \
          -e "s|@MESH_HOSTNAME@|$mesh_hostname|g" \
          -e "s|@VPC_CIDR@|$vpc_cidr|g" \
          /etc/nebula/config.yml.in > /run/nebula/config.yml
        chmod 0600 /run/nebula/config.yml
      '';
      "usr/libexec/lucidity/render-deployment-contract" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        contract=/etc/lucidity/deployment.json
        [[ -f $contract && $(stat -c %U:%G:%a "$contract") == root:root:600 ]] || {
          echo "deployment contract must be root-owned with mode 0600" >&2
          exit 1
        }
        ${pkgs.jq}/bin/jq -e '
          .schema_version == 1 and
          (.environment == "production" or .environment == "test") and
          (.region | test("^[a-z]{2}-[a-z]+-[0-9]+$")) and
          (.release | test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) and
          (.runtime.controller_secret_id | test("^[A-Za-z0-9/_+=.@-]+$")) and
          (.runtime.openbao_kms_alias | test("^alias/[A-Za-z0-9/_-]+$")) and
          (.runtime.mesh_hostname | test("^[A-Za-z0-9.-]+$")) and
          (.runtime.ntfy_url | test("^https://[A-Za-z0-9.-]+$")) and
          (.runtime.blackbox_targets | type == "array" and length > 0) and
          (.matrix.server_name | test("^[A-Za-z0-9.-]+$")) and
          (.matrix.service_hostname | test("^[A-Za-z0-9.-]+$")) and
          (.workloads.continuwuity.digest | test("^sha256:[0-9a-f]{64}$"))
        ' "$contract" >/dev/null
        install -d -m 0700 /run/lucidity
        umask 077
        environment=$(${pkgs.jq}/bin/jq -r '.environment' "$contract")
        ${pkgs.gnused}/bin/sed "s|@ENVIRONMENT@|$environment|g" \
          /etc/lucidity/secretspec.toml.in > /etc/lucidity/secretspec.toml
        chown root:root /etc/lucidity/secretspec.toml
        chmod 0600 /etc/lucidity/secretspec.toml
        ${pkgs.jq}/bin/jq -r '
          [
            "LUCIDITY_ENVIRONMENT=" + (.environment | @sh),
            "LUCIDITY_RELEASE=" + (.release | @sh),
            "MATRIX_SERVER_NAME=" + (.matrix.server_name | @sh),
            "MATRIX_SERVICE_HOSTNAME=" + (.matrix.service_hostname | @sh),
            "CONTINUWUITY_REPOSITORY=" + (.workloads.continuwuity.repository | @sh),
            "CONTINUWUITY_VERSION=" + (.workloads.continuwuity.version | @sh),
            "CONTINUWUITY_IMAGE_DIGEST=" + (.workloads.continuwuity.digest | @sh)
          ] | .[]
        ' "$contract" > /run/lucidity/deployment.env
        ${lib.optionalString isController ''
          ntfy_url=$(${pkgs.jq}/bin/jq -r '.runtime.ntfy_url' "$contract")
          ntfy_hostname=$(${pkgs.jq}/bin/jq -r '.dns.ntfy' "$contract")
          ${pkgs.jq}/bin/jq -r '.runtime.blackbox_targets[] | "                - " + @json' \
            "$contract" > /run/lucidity/blackbox-targets.yml
          ${pkgs.gawk}/bin/awk -v targets=/run/lucidity/blackbox-targets.yml '
            $0 == "@BLACKBOX_TARGETS@" {
              while ((getline line < targets) > 0) print line
              close(targets)
              next
            }
            { print }
          ' /etc/prometheus/prometheus.yml.in > /run/lucidity/prometheus.yml
          ${pkgs.gnused}/bin/sed \
            -e "s|@NTFY_URL@|$ntfy_url|g" \
            /etc/alertmanager-ntfy/config.yml.in > /run/lucidity/alertmanager-ntfy.yml
          ${pkgs.gnused}/bin/sed \
            -e "s|@NTFY_URL@|$ntfy_url|g" \
            /etc/ntfy/server.yml.in > /run/lucidity/ntfy-server.yml
          ${pkgs.gnused}/bin/sed \
            -e "s|@NTFY_HOSTNAME@|$ntfy_hostname|g" \
            /etc/lucidity/ntfy-traefik.yml.in > /run/lucidity/ntfy-traefik.yml
        ''}
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
        Requires=nix-daemon.service
        After=nix-daemon.service

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/activate-nix-profile
        RemainAfterExit=yes

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/lucidity-render-deployment.service" = ''
        [Unit]
        Description=Validate and render the non-secret Lucidity deployment contract
        After=cloud-final.service
        ConditionPathExists=/etc/lucidity/deployment.json

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/render-deployment-contract
        RemainAfterExit=yes

        [Install]
        WantedBy=cloud-init.target
      '';
      "usr/lib/systemd/system/lucidity-bootc-ecr-auth.service" = ''
        [Unit]
        Description=Prepare ephemeral bootc authentication for private ECR
        Requires=lucidity-nix-profile.service
        After=lucidity-nix-profile.service
        Before=bootc-fetch-apply-updates.service

        [Service]
        Type=oneshot
        RemainAfterExit=yes
        Environment=PATH=${systemProfile}/bin:/usr/sbin:/usr/bin:/sbin:/bin
        ExecStart=/usr/libexec/lucidity/prepare-bootc-ecr-auth

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/lucidity-nix-selinux.service" = ''
        [Unit]
        Description=Install the Determinate Nix SELinux policy
        DefaultDependencies=no
        After=local-fs-pre.target
        ConditionSecurity=selinux
        Before=lucidity-nix-seed.service

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/install-determinate-nix-selinux-policy
        RemainAfterExit=yes
      '';
      "usr/lib/systemd/system/lucidity-nix-seed.service" = ''
        [Unit]
        Description=Provision persistent Determinate Nix state
        DefaultDependencies=no
        Requires=lucidity-nix-selinux.service
        After=local-fs-pre.target lucidity-nix-selinux.service
        Before=nix.mount local-fs.target
        RequiresMountsFor=/var/lib

        [Service]
        Type=oneshot
        ExecStart=/usr/libexec/lucidity/provision-determinate-nix
        RemainAfterExit=yes
      '';
      "usr/lib/systemd/system/nix.mount" = ''
        [Unit]
        Description=Mount persistent Determinate Nix state on /nix
        Requires=lucidity-nix-seed.service
        After=lucidity-nix-seed.service
        Before=local-fs.target
        PropagatesStopTo=nix-daemon.service
        ConditionPathIsDirectory=/nix
        DefaultDependencies=no

        [Mount]
        What=/var/lib/nix
        Where=/nix
        Type=none
        DirectoryMode=0755
        Options=bind

        [Install]
        RequiredBy=nix-daemon.service
        RequiredBy=nix-daemon.socket
        RequiredBy=determinate-nixd.socket
      '';
      "usr/lib/systemd/system/nix-daemon.service" = ''
        [Unit]
        Description=Nix Daemon, with Determinate Nix superpowers
        Documentation=man:nix-daemon https://determinate.systems
        RequiresMountsFor=/nix/store /nix/var /nix/var/nix/db
        ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

        [Service]
        ExecStart=@/usr/bin/determinate-nixd determinate-nixd daemon
        KillMode=process
        LimitNOFILE=1048576
        LimitSTACK=64M
        TasksMax=1048576

        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/nix-daemon.socket" = ''
        [Unit]
        Description=Determinate Nix Daemon Socket
        Before=multi-user.target
        RequiresMountsFor=/nix/store /nix/var /nix/var/nix/db
        ConditionPathIsReadWrite=/nix/var/nix/daemon-socket

        [Socket]
        FileDescriptorName=nix-daemon.socket
        ListenStream=/nix/var/nix/daemon-socket/socket

        [Install]
        WantedBy=sockets.target
      '';
      "usr/lib/systemd/system/determinate-nixd.socket" = ''
        [Unit]
        Description=Determinate Nixd Daemon Socket
        Before=multi-user.target
        RequiresMountsFor=/nix/store /nix/var/determinate

        [Socket]
        FileDescriptorName=determinate-nixd.socket
        DirectoryMode=0755
        ListenStream=/nix/var/determinate/determinate-nixd.socket
        Service=nix-daemon.service

        [Install]
        WantedBy=sockets.target
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
        Requires=lucidity-nix-profile.service lucidity-render-deployment.service
        After=lucidity-nix-profile.service lucidity-render-deployment.service network-online.target
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
        # The launch template writes runtime-secrets.env from the deployment-specific
        # Secrets Manager identifier. Do not copy static references into this image.
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
        ConditionPathExists=!/etc/lucidity/vm-connectivity-only

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
      "usr/lib/lucidity/openbao-auth-plugin-path" = "${openbaoAuthPlugin}/bin/openbao-plugin-auth-aws\n";
      "usr/libexec/lucidity/prepare-openbao" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        install -d -o openbao -g openbao -m 0700 \
          /var/lib/openbao/raft /var/lib/openbao/tls /var/lib/openbao/plugins /var/lib/openbao/snapshots
        if [[ ! -s /var/lib/openbao/tls/server.key ]]; then
          ${pkgs.openssl}/bin/openssl req -x509 -newkey rsa:3072 -sha256 -nodes \
            -subj /CN=localhost -days 825 \
            -addext subjectAltName=IP:127.0.0.1,IP:100.96.0.1,DNS:localhost \
            -keyout /var/lib/openbao/tls/server.key \
            -out /var/lib/openbao/tls/server.crt
          chown openbao:openbao /var/lib/openbao/tls/server.key /var/lib/openbao/tls/server.crt
          chmod 0600 /var/lib/openbao/tls/server.key
        fi
        plugin=$(< /usr/lib/lucidity/openbao-kms-plugin-path)
        install -m 0500 -o openbao -g openbao "$plugin" /var/lib/openbao/plugins/openbao-plugin-kms-aws
        sha=$(${pkgs.coreutils}/bin/sha256sum /var/lib/openbao/plugins/openbao-plugin-kms-aws | ${pkgs.coreutils}/bin/cut -d' ' -f1)
        auth_plugin=$(< /usr/lib/lucidity/openbao-auth-plugin-path)
        install -m 0500 -o openbao -g openbao "$auth_plugin" /var/lib/openbao/plugins/openbao-plugin-auth-aws
        auth_sha=$(${pkgs.coreutils}/bin/sha256sum /var/lib/openbao/plugins/openbao-plugin-auth-aws | ${pkgs.coreutils}/bin/cut -d' ' -f1)
        printf '%s\n' "$auth_sha" > /var/lib/openbao/plugins/openbao-plugin-auth-aws.sha256
        chown openbao:openbao /var/lib/openbao/plugins/openbao-plugin-auth-aws.sha256
        chmod 0400 /var/lib/openbao/plugins/openbao-plugin-auth-aws.sha256
        contract=/etc/lucidity/deployment.json
        [[ -s $contract ]] || { echo "deployment contract is unavailable" >&2; exit 1; }
        kms_alias=$(${pkgs.jq}/bin/jq -er '.runtime.openbao_kms_alias | select(test("^alias/[A-Za-z0-9/_-]+$"))' "$contract")
        overlay_listener=
        if [[ -e /var/lib/openbao/overlay-listener.enabled ]]; then
          overlay_listener='listener "tcp" { address = "100.96.0.1:8200"; tls_disable = false; tls_cert_file = "/var/lib/openbao/tls/server.crt"; tls_key_file = "/var/lib/openbao/tls/server.key" }'
        fi
        ${pkgs.gnused}/bin/sed \
          -e "s|@AWS_KMS_PLUGIN@|/var/lib/openbao/plugins/openbao-plugin-kms-aws|" \
          -e "s|@AWS_KMS_PLUGIN_SHA256@|$sha|" \
          -e "s|@OPENBAO_KMS_ALIAS@|$kms_alias|" \
          -e "s|@OVERLAY_LISTENER@|$overlay_listener|" \
          /etc/openbao/openbao.hcl.in > /run/openbao.hcl
        chown openbao:openbao /run/openbao.hcl
        chmod 0600 /run/openbao.hcl
      '';
      "usr/libexec/lucidity/register-openbao-aws-auth" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        worker_role_arn=''${1:-}
        [[ $worker_role_arn =~ ^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_-]+$ ]] || {
          echo "register-openbao-aws-auth requires the exact worker IAM role ARN" >&2
          exit 2
        }
        export BAO_ADDR=''${BAO_ADDR:-https://127.0.0.1:8200}
        export BAO_CACERT=''${BAO_CACERT:-/var/lib/openbao/tls/server.crt}
        environment=$(${pkgs.jq}/bin/jq -er '.environment | select(. == "production" or . == "test")' /etc/lucidity/deployment.json)
        sha=$(< /var/lib/openbao/plugins/openbao-plugin-auth-aws.sha256)
        ${pkgs.openbao}/bin/bao plugin register -sha256="$sha" auth openbao-plugin-auth-aws
        if ! ${pkgs.openbao}/bin/bao auth list -format=json | ${pkgs.jq}/bin/jq -e 'has("aws/")' >/dev/null; then
          ${pkgs.openbao}/bin/bao auth enable -path=aws openbao-plugin-auth-aws
        fi
        ${pkgs.openbao}/bin/bao policy write lucidity-worker - <<POLICY
        path "secret/data/lucidity/$environment/worker-ooye" {
          capabilities = ["read"]
        }
        POLICY
        ${pkgs.openbao}/bin/bao write auth/aws/role/lucidity-worker \
          auth_type=iam bound_iam_principal_arn="$worker_role_arn" \
          policies=lucidity-worker resolve_aws_unique_ids=true
      '';
      "usr/libexec/lucidity/enable-openbao-overlay" = ''
        #!/usr/bin/env bash
        set -Eeuo pipefail
        [[ -s /var/lib/nebula/ca.crt && -s /var/lib/nebula/host.crt && -s /var/lib/nebula/host.key ]] || {
          echo "install the controller Nebula identity before enabling the OpenBao overlay listener" >&2
          exit 1
        }
        systemctl is-active --quiet nebula.service
        install -o openbao -g openbao -m 0600 /dev/null /var/lib/openbao/overlay-listener.enabled
        systemctl restart openbao.service
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
        Requires=lucidity-nix-profile.service lucidity-render-deployment.service
        After=lucidity-nix-profile.service lucidity-render-deployment.service network-online.target

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
        if lib.hasPrefix "usr/libexec/" path || (lib.hasPrefix "etc/lucidity/backup.d/" path && lib.hasSuffix ".sh" path)
        then "0755"
        else "0644"
      } ${source} "$out/rootfs/${path}"
    '')
    fileSources
  );

  enabledUnits =
    [
      "nix.mount"
      "nix-daemon.service"
      "nix-daemon.socket"
      "determinate-nixd.socket"
      "lucidity-nix-profile.service"
      "lucidity-render-deployment.service"
      "lucidity-bootc-ecr-auth.service"
      "lucidity-admin-authorized-key.service"
      "nebula.service"
      "lucidity-nebula-expiry.timer"
      "lucidity-backup.timer"
    ]
    ++ monitoring.enabledUnits
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
      "openbao-agent-worker.service"
      "ooye-registration.service"
      "ooye.service"
    ];

  containerfile = pkgs.writeText "Containerfile-${role}" ''
    ARG BASE_IMAGE=quay.io/almalinuxorg/almalinux-bootc:10

    FROM scratch AS lucidity-nix-closure
    COPY nix-closure /nix-closure

    FROM ''${BASE_IMAGE}
    SHELL ["/bin/bash", "-Eeuo", "pipefail", "-c"]

    ARG SSM_AGENT_RPM_URL=https://s3.us-east-2.amazonaws.com/amazon-ssm-us-east-2/3.3.5068.0/linux_amd64/amazon-ssm-agent.rpm
    ARG NIX_INSTALLER_VERSION=3.21.9
    ARG NIX_INSTALLER_SHA256=58cf15422853e95187405d66b0cdb306e66f602218ee0032386c46b1b776a6d1
    ARG NIX_SELINUX_POLICY_SHA256=44a7427c40825b1fb3b331c480d55569296b619c7c50ff27ee2e237eb1bdcd8d
    ARG NIX_SELINUX_FILE_CONTEXTS_SHA256=668726761299f1c51b74aa5c6cc1a8196e206bb6ccf04eeecd944eadc13713c9
    ARG DETERMINATE_NIX_SELINUX_FILE_CONTEXTS_SHA256=28591de36f73fc2560b022e003552a195785d2c1a78ec53e88148ffd2271d31b
    ARG IMAGE_VERSION=dev

    RUN dnf -y install dnf-plugins-core epel-release && \
        dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo && \
        dnf clean all

    COPY rootfs/usr/lib/sysusers.d/nix.conf /tmp/lucidity-nix-sysusers.conf

    RUN systemd-sysusers /tmp/lucidity-nix-sysusers.conf && \
        dnf -y install ca-certificates cloud-init container-selinux curl \
          docker-buildx-plugin docker-ce docker-ce-cli docker-compose-plugin \
          NetworkManager openssh-server policycoreutils policycoreutils-python-utils \
          nix nix-daemon rsyslog selinux-policy-targeted sudo && \
        rpm -q nix nix-daemon nix-filesystem nix-system && \
        [[ $(rpm -qf --qf '%{NAME}\n' /nix) == nix-filesystem ]] && \
        dnf -y install "''${SSM_AGENT_RPM_URL}" && \
        dnf clean all && \
        rm -f /tmp/lucidity-nix-sysusers.conf && \
        rm -rf /run/cloud-init /var/cache/* /var/lib/cloud /var/lib/dnf /var/log/*

    COPY rootfs/ /

    # The installer migration preflight rejects any PATH-visible nix-env.
    # The build hides only EPEL's binary for planning, then restores the RPM-owned file.
    # Install the pinned Determinate policy explicitly because builders on
    # non-SELinux hosts make the installer skip its SELinux action.
    RUN --mount=type=bind,from=lucidity-nix-closure,source=/nix-closure,target=/run/lucidity-nix-closure,ro \
        printf '%s\n' "''${IMAGE_VERSION}" > /usr/lib/lucidity/image-version && \
        rm -rf /usr/local && ln -s ../var/usrlocal /usr/local && \
        install -d -m 0755 /var/usrlocal/bin /usr/libexec/lucidity /var/lib/nix && \
        install -d -m 0700 /data/coolify /var/lib/coolify && \
        semanage fcontext -a -t container_file_t '/data/coolify(/.*)?' && \
        curl --fail --location --silent --show-error \
          --output /usr/libexec/lucidity/nix-installer \
          "https://github.com/DeterminateSystems/nix-installer/releases/download/v''${NIX_INSTALLER_VERSION}/nix-installer-x86_64-linux" && \
        echo "''${NIX_INSTALLER_SHA256}  /usr/libexec/lucidity/nix-installer" | sha256sum --check --strict && \
        chmod 0755 /usr/libexec/lucidity/nix-installer && \
        curl --fail --location --silent --show-error \
          --output /usr/share/selinux/packages/determinate-nix.pp \
          "https://raw.githubusercontent.com/DeterminateSystems/nix-installer/v''${NIX_INSTALLER_VERSION}/src/action/linux/selinux/determinate-nix.pp" && \
        echo "''${NIX_SELINUX_POLICY_SHA256}  /usr/share/selinux/packages/determinate-nix.pp" | sha256sum --check --strict && \
        curl --fail --location --silent --show-error \
          --output /usr/share/selinux/packages/nix.fc \
          "https://raw.githubusercontent.com/DeterminateSystems/nix-installer/v''${NIX_INSTALLER_VERSION}/src/action/linux/selinux/nix.fc" && \
        echo "''${NIX_SELINUX_FILE_CONTEXTS_SHA256}  /usr/share/selinux/packages/nix.fc" | sha256sum --check --strict && \
        curl --fail --location --silent --show-error \
          --output /usr/share/selinux/packages/determinate-nix.fc \
          "https://raw.githubusercontent.com/DeterminateSystems/nix-installer/v''${NIX_INSTALLER_VERSION}/src/action/linux/selinux/determinate-nix.fc" && \
        echo "''${DETERMINATE_NIX_SELINUX_FILE_CONTEXTS_SHA256}  /usr/share/selinux/packages/determinate-nix.fc" | sha256sum --check --strict && \
        semodule -i /usr/share/selinux/packages/determinate-nix.pp && \
        mv /usr/bin/nix-env /usr/bin/nix-env.epel && \
        HOME=/var/roothome /usr/libexec/lucidity/nix-installer install linux \
          --determinate \
          --diagnostic-endpoint "" \
          --force \
          --nix-build-group-id 30000 \
          --nix-build-user-count 10 \
          --nix-build-user-id-base 30000 \
          --nix-build-user-prefix nixbld- \
          --no-confirm \
          --no-modify-profile \
          --no-start-daemon && \
        mv /usr/bin/nix-env.epel /usr/bin/nix-env && \
        install -D -m 0555 /usr/local/bin/determinate-nixd /usr/bin/determinate-nixd && \
        rm -f /usr/local/bin/determinate-nixd \
          /etc/tmpfiles.d/nix-daemon.conf \
          /etc/systemd/system/determinate-nixd.socket \
          /etc/systemd/system/nix-daemon.service \
          /etc/systemd/system/nix-daemon.socket && \
        find /etc/systemd/system -type l \( \
          -lname '/etc/systemd/system/determinate-nixd.socket' -o \
          -lname '/etc/systemd/system/nix-daemon.service' -o \
          -lname '/etc/systemd/system/nix-daemon.socket' \
        \) -delete && \
        for seed_path in /run/lucidity-nix-closure/store/*; do \
          destination=/nix/store/''${seed_path##*/}; \
          [[ -e $destination ]] || cp -a "$seed_path" /nix/store/; \
        done && \
        /nix/var/nix/profiles/default/bin/nix-store --load-db < /run/lucidity-nix-closure/registration && \
        /nix/var/nix/profiles/default/bin/nix-store --verify-path ${systemProfile} && \
        /nix/var/nix/profiles/default/bin/nix-store --verify-path ${homeActivation} && \
        /nix/var/nix/profiles/default/bin/nix-env \
          --profile /nix/var/nix/profiles/lucidity --set ${systemProfile} && \
        install -d -m 0755 /usr/lib/lucidity/determinate-nix-seed && \
        mv /nix/* /usr/lib/lucidity/determinate-nix-seed/ && \
        rm -rf /var/roothome && \
        semodule -l | awk '$1 == "nix" { found = 1 } END { exit !found }' && \
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
    mkdir -p "$out/rootfs" "$out/nix-closure/store"
    ${installFiles}
    install -m 0644 ${containerfile} "$out/Containerfile"
    install -m 0644 ${closure}/registration "$out/nix-closure/registration"
    while IFS= read -r store_path; do
      cp -a "$store_path" "$out/nix-closure/store/"
    done < ${closure}/store-paths
  ''
