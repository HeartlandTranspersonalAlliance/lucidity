{...}: {
  den.aspects.worker.bootc = {
    lucidity = {
      role = "worker";
      hostName = "worker";
      overlayIPv4 = "100.96.0.2";
      nebulaGroups = [
        "server"
        "worker"
      ];
      persistentPaths = [
        "/data/coolify"
        "/var/lib/coolify"
        "/var/lib/ooye"
      ];
      files = {
        "etc/coolify-worker/README" = ''
          The controller's SSH public key is enrolled at runtime through SSM.
          The matching private key never leaves the controller.
        '';
        "usr/share/lucidity/workloads/continuwuity/compose.yaml" = ''
          services:
            continuwuity:
              image: ''${CONTINUWUITY_REPOSITORY:?}@''${CONTINUWUITY_IMAGE_DIGEST:?}
              restart: unless-stopped
              labels:
                lucidity.workload: continuwuity
              environment:
                DEPLOYMENT_IMAGE_VERSION: ''${CONTINUWUITY_VERSION:?}
                CONTINUWUITY_SERVER_NAME: ''${MATRIX_SERVER_NAME:?}
                CONTINUWUITY_DATABASE_PATH: /var/lib/continuwuity
                CONTINUWUITY_ADDRESS: 0.0.0.0
                CONTINUWUITY_PORT: "8008"
                CONTINUWUITY_ALLOW_FEDERATION: "true"
                CONTINUWUITY_ALLOW_REGISTRATION: ''${MATRIX_ALLOW_REGISTRATION:-false}
                CONTINUWUITY_REGISTRATION_TOKEN: ''${MATRIX_REGISTRATION_TOKEN:-}
                CONTINUWUITY_WELL_KNOWN__CLIENT: https://''${MATRIX_SERVICE_HOSTNAME:?}
                CONTINUWUITY_WELL_KNOWN__SERVER: ''${MATRIX_SERVICE_HOSTNAME:?}:443
              volumes:
                - continuwuity-data:/var/lib/continuwuity
              expose:
                - "8008"
              extra_hosts:
                - host.docker.internal:host-gateway
              stdin_open: true
              tty: true
          volumes:
            continuwuity-data:
              name: lucidity-continuwuity-data
        '';
        "usr/share/lucidity/workloads/continuwuity/env.example" = ''
          # Rendered at launch from /etc/lucidity/deployment.json.
          # MATRIX_SERVER_NAME is permanent after initialization.
          MATRIX_SERVER_NAME=example.invalid
          MATRIX_SERVICE_HOSTNAME=matrix.example.invalid
          CONTINUWUITY_REPOSITORY=registry.example.invalid/continuwuity
          CONTINUWUITY_VERSION=v0.0.0
          CONTINUWUITY_IMAGE_DIGEST=sha256:replace-with-deployment-contract-digest
        '';
        "etc/openbao/worker-agent.hcl" = ''
          vault {
            address = "https://100.96.0.1:8200"
            ca_cert = "/etc/lucidity/openbao-ca.crt"
          }
          auto_auth {
            method "aws" {
              mount_path = "auth/aws"
              config = {
                type = "iam"
                role = "lucidity-worker"
              }
            }
            sink "file" {
              config = {
                path = "/run/openbao-agent/token"
                mode = 384
              }
            }
          }
        '';
        "usr/lib/systemd/system/openbao-agent-worker.service" = ''
          [Unit]
          Description=Authenticate the worker to controller OpenBao with AWS IAM
          Requires=nebula.service
          After=nebula.service network-online.target
          ConditionPathExists=/etc/lucidity/openbao-ca.crt
          [Service]
          User=root
          RuntimeDirectory=openbao-agent
          RuntimeDirectoryMode=0700
          ExecStart=/nix/var/nix/profiles/lucidity/bin/bao agent -config=/etc/openbao/worker-agent.hcl
          Restart=on-failure
          NoNewPrivileges=yes
          PrivateTmp=yes
          ProtectHome=yes
          ProtectSystem=strict
          ReadWritePaths=/run/openbao-agent
          [Install]
          WantedBy=multi-user.target
        '';
        "usr/libexec/lucidity/materialize-ooye-registration" = ''
          #!/usr/bin/env bash
          set -Eeuo pipefail
          if [[ ''${LUCIDITY_OOYE_REGISTRATION_RESOLVED:-0} != 1 ]]; then
            [[ -s /run/openbao-agent/token ]] || { echo "OpenBao worker token is unavailable" >&2; exit 1; }
            exec env \
              BAO_ADDR=https://100.96.0.1:8200 \
              BAO_CACERT=/etc/lucidity/openbao-ca.crt \
              BAO_TOKEN_PATH=/run/openbao-agent/token \
              LUCIDITY_OOYE_REGISTRATION_RESOLVED=1 \
              /nix/var/nix/profiles/lucidity/bin/secretspec run \
                --file /etc/lucidity/secretspec.toml \
                --profile ooye-worker \
                --scope ooye-registration \
                --reason "materialize OOYE application-service registration" \
                -- "$0"
          fi
          source_file="''${OOYE_REGISTRATION_FILE:?}"
          [[ -s $source_file ]] || { echo "OOYE registration is unavailable" >&2; exit 1; }
          install -D -o ooye -g ooye -m 0600 "$source_file" /var/lib/ooye/registration.yaml
        '';
        "usr/lib/systemd/system/ooye-registration.service" = ''
          [Unit]
          Description=Materialize OOYE registration from OpenBao
          Requires=openbao-agent-worker.service
          After=openbao-agent-worker.service
          ConditionPathExists=/etc/lucidity/openbao-ca.crt
          [Service]
          Type=oneshot
          ExecStart=/usr/libexec/lucidity/materialize-ooye-registration
          RemainAfterExit=yes
          NoNewPrivileges=yes
          PrivateTmp=yes
          ProtectHome=yes
          ProtectSystem=strict
          ReadWritePaths=/var/lib/ooye
          [Install]
          WantedBy=multi-user.target
        '';
        "etc/ooye/sharp-workaround.cjs" = ''
          "use strict"
          const {createRequire} = require("node:module")
          const path = require("node:path")
          const ooyeRoot = process.env.OOYE_ROOT
          const requireFromOoye = createRequire(path.join(ooyeRoot, "package.json"))
          const sharp = requireFromOoye("sharp")
          sharp.block({operation: ["VipsForeignLoadNsgif", "VipsForeignLoadTiff", "VipsForeignLoadVips"]})
        '';
        "usr/lib/systemd/system/ooye.service" = ''
          [Unit]
          Description=Out Of Your Element Matrix-Discord bridge
          Documentation=https://gitdab.com/cadence/out-of-your-element
          Requires=ooye-registration.service
          After=ooye-registration.service network-online.target
          ConditionPathExists=/var/lib/ooye/registration.yaml
          [Service]
          Type=simple
          User=ooye
          Group=ooye
          WorkingDirectory=/var/lib/ooye
          Environment=NODE_ENV=production
          Environment=NODE_OPTIONS=--require=/etc/ooye/sharp-workaround.cjs
          ExecStart=/nix/var/nix/profiles/lucidity/bin/ooye
          Restart=on-failure
          RestartSec=5s
          TimeoutStopSec=30s
          UMask=0077
          AmbientCapabilities=
          CapabilityBoundingSet=
          LockPersonality=true
          NoNewPrivileges=true
          PrivateDevices=true
          PrivateTmp=true
          ProtectClock=true
          ProtectControlGroups=true
          ProtectHome=true
          ProtectHostname=true
          ProtectKernelLogs=true
          ProtectKernelModules=true
          ProtectKernelTunables=true
          ProtectSystem=strict
          ReadWritePaths=/var/lib/ooye
          RemoveIPC=true
          RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
          RestrictNamespaces=true
          RestrictRealtime=true
          RestrictSUIDSGID=true
          SystemCallArchitectures=native
          [Install]
          WantedBy=multi-user.target
        '';
        "usr/libexec/lucidity/register-matrix-bootstrap-admin" = ''
          #!/usr/bin/env bash
          set -Eeuo pipefail
          username=''${1:-}
          [[ $username =~ ^[a-z0-9._=-]{1,64}$ ]] || {
            echo "register-matrix-bootstrap-admin requires a lowercase Matrix localpart" >&2
            exit 2
          }
          if [[ ''${LUCIDITY_MATRIX_BOOTSTRAP_RESOLVED:-0} != 1 ]]; then
            operator_token_path="''${BAO_TOKEN_PATH:-}"
            [[ -s $operator_token_path ]] || {
              echo "BAO_TOKEN_PATH must name a private, scoped Matrix-bootstrap operator token file" >&2
              exit 1
            }
            environment=$(/nix/var/nix/profiles/lucidity/bin/jq -er \
              '.environment | select(. == "production" or . == "test")' /etc/lucidity/deployment.json)
            profile=matrix-bootstrap
            [[ $environment != test ]] || profile=test-matrix-bootstrap
            exec env \
              BAO_ADDR=https://100.96.0.1:8200 \
              BAO_CACERT=/etc/lucidity/openbao-ca.crt \
              BAO_TOKEN_PATH="$operator_token_path" \
              LUCIDITY_MATRIX_BOOTSTRAP_RESOLVED=1 \
              /nix/var/nix/profiles/lucidity/bin/secretspec run \
                --file /etc/lucidity/secretspec.toml \
                --profile "$profile" \
                --scope matrix-bootstrap \
                --reason "register the first Matrix administrator" \
                -- "$0" "$username"
          fi
          registration_token_file="''${MATRIX_REGISTRATION_TOKEN_FILE:?}"
          admin_password_file="''${MATRIX_ADMIN_PASSWORD_FILE:?}"
          [[ -s $registration_token_file && -s $admin_password_file ]] || {
            echo "Matrix bootstrap files were not materialized" >&2; exit 1;
          }
          [[ $registration_token_file =~ ^/[^[:space:]]+$ ]] || {
            echo "Matrix registration token path is invalid" >&2; exit 1;
          }
          workdir=/usr/share/lucidity/workloads/continuwuity
          runtime=/run/lucidity/deployment.env
          [[ -s $runtime ]] || { echo "rendered deployment environment is unavailable" >&2; exit 1; }
          temporary=$(mktemp -d /dev/shm/lucidity-matrix-bootstrap.XXXXXX)
          trap 'find "$temporary" -type f -exec shred -u {} + 2>/dev/null || true; rmdir "$temporary" 2>/dev/null || true' EXIT
          chmod 0700 "$temporary"
          printf '%s\n' \
            'services:' \
            '  continuwuity:' \
            '    environment:' \
            '      CONTINUWUITY_ALLOW_REGISTRATION: "true"' \
            '      CONTINUWUITY_REGISTRATION_TOKEN: ""' \
            '      CONTINUWUITY_REGISTRATION_TOKEN_FILE: /run/secrets/matrix-registration-token' \
            '    volumes:' \
            "      - $registration_token_file:/run/secrets/matrix-registration-token:ro" \
            > "$temporary/bootstrap-compose.yaml"
          chmod 0600 "$temporary/bootstrap-compose.yaml"
          docker compose --env-file "$runtime" --file "$workdir/compose.yaml" \
            --file "$temporary/bootstrap-compose.yaml" up -d --wait
          matrix_hostname=$(/nix/var/nix/profiles/lucidity/bin/jq -r '.matrix.service_hostname' /etc/lucidity/deployment.json)
          /nix/var/nix/profiles/lucidity/bin/jq -n --arg username "$username" --rawfile password "$admin_password_file" \
            '{username:$username,password:($password | rtrimstr("\n")),initial_device_display_name:"Lucidity test bootstrap"}' \
            > "$temporary/register-initial.json"
          status=$(/nix/var/nix/profiles/lucidity/bin/curl --silent --show-error \
            --output "$temporary/register-challenge.json" --write-out '%{http_code}' \
            --header 'Content-Type: application/json' --data-binary @"$temporary/register-initial.json" \
            "https://$matrix_hostname/_matrix/client/v3/register")
          [[ $status == 401 ]] || {
            echo "Matrix registration did not return the expected authentication challenge" >&2; exit 1;
          }
          session=$(/nix/var/nix/profiles/lucidity/bin/jq -er \
            '.session | select(type == "string" and length > 0)' "$temporary/register-challenge.json")
          /nix/var/nix/profiles/lucidity/bin/jq --arg session "$session" --rawfile token "$registration_token_file" \
            '. + {auth:{type:"m.login.registration_token",token:($token | rtrimstr("\n")),session:$session}}' \
            "$temporary/register-initial.json" > "$temporary/register.json"
          /nix/var/nix/profiles/lucidity/bin/curl --fail --silent --show-error --output /dev/null \
            --header 'Content-Type: application/json' --data-binary @"$temporary/register.json" \
            "https://$matrix_hostname/_matrix/client/v3/register"
          docker compose --env-file "$runtime" --file "$workdir/compose.yaml" up -d --force-recreate --wait
          environment=$(/nix/var/nix/profiles/lucidity/bin/jq -er \
            '.environment | select(. == "production" or . == "test")' /etc/lucidity/deployment.json)
          IFS= read -r operator_token <"''${BAO_TOKEN_PATH:?}"
          BAO_TOKEN="$operator_token" /nix/var/nix/profiles/lucidity/bin/bao kv metadata delete \
            -mount=secret "lucidity/$environment/matrix-bootstrap"
          unset operator_token
          echo "Registered the first Matrix account, disabled registration, and revoked the OpenBao bootstrap material"
        '';
        "etc/lucidity/backup.d/50-worker-workloads.sh" = ''
          #!/usr/bin/env bash
          set -Eeuo pipefail
          destination=$1
          install -d -m 0700 "$destination/ooye" "$destination/continuwuity"
          ooye_active=false
          if systemctl is-active --quiet ooye.service; then
            ooye_active=true
            systemctl stop ooye.service
          fi
          continuwuity_container=$(docker ps --quiet --filter label=lucidity.workload=continuwuity | head -n 1)
          if [[ -n $continuwuity_container ]]; then
            docker stop "$continuwuity_container" >/dev/null
          fi
          cleanup() {
            [[ -z $continuwuity_container ]] || docker start "$continuwuity_container" >/dev/null || true
            [[ $ooye_active == false ]] || systemctl start ooye.service || true
          }
          trap cleanup EXIT
          if [[ -s /var/lib/ooye/registration.yaml ]]; then
            while IFS= read -r -d "" file; do
              cp -a "$file" "$destination/ooye/"
            done < <(find /var/lib/ooye -maxdepth 1 -type f \( -name registration.yaml -o -name "ooye.db*" \) -print0)
          fi
          volume=/var/lib/docker/volumes/lucidity-continuwuity-data/_data
          if [[ -d $volume ]]; then
            cp -a "$volume/." "$destination/continuwuity/"
          fi
        '';
      };
    };
  };
}
