{
  jq,
  lib,
  openssh,
  role,
  secretspec,
  secretspecManifest,
  writeShellApplication,
}: let
  workerSecret = lib.optionalString (role == "worker") ''
    [[ ''${COOLIFY_WORKER_SSH_PUBLIC_KEY:-} =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)[[:space:]] ]] || {
      echo "SecretSpec did not resolve a valid COOLIFY_WORKER_SSH_PUBLIC_KEY" >&2
      exit 1
    }
    coolify_key=$COOLIFY_WORKER_SSH_PUBLIC_KEY
  '';
in
  assert lib.assertOneOf "role" role [
    "controller"
    "worker"
  ];
    writeShellApplication {
      name = "lucidity-cloud-init-${role}";
      runtimeInputs = [
        jq
        openssh
        secretspec
      ];
      text = ''
        set -Eeuo pipefail

        if [[ ''${1:-} == meta-data ]]; then
          if [[ $# -ne 1 ]]; then
            echo "usage: lucidity-cloud-init-${role} meta-data" >&2
            exit 2
          fi
          ${jq}/bin/jq --null-input \
            --arg role ${lib.escapeShellArg role} '
              {
                "instance-id": ("coolify-" + $role + "-local-1"),
                "local-hostname": ("coolify-" + $role + "-test")
              }
            '
          exit 0
        fi

        if [[ ''${LUCIDITY_CLOUD_INIT_SECRETSPEC_ACTIVE:-0} != 1 ]]; then
          export LUCIDITY_CLOUD_INIT_SECRETSPEC_ACTIVE=1
          exec secretspec run \
            --file ${secretspecManifest} \
            --reason "generate ${role} bootc cloud-init fixture" \
            --provider env:// \
            --profile vm-${role} \
            -- "$0" "$@"
        fi

        if [[ $# -ne 2 || $1 != user-data ]]; then
          echo "usage: lucidity-cloud-init-${role} user-data REGISTRY_HOST" >&2
          exit 2
        fi

        registry_host=$2
        [[ $registry_host =~ ^[[:alnum:].:-]+$ ]] || {
          echo "REGISTRY_HOST contains invalid characters" >&2
          exit 2
        }
        [[ ''${ADMIN_SSH_PUBLIC_KEY:-} =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-)[[:space:]] ]] || {
          echo "SecretSpec did not resolve a valid ADMIN_SSH_PUBLIC_KEY" >&2
          exit 1
        }

        key_file=$(mktemp)
        trap 'rm -f "$key_file"' EXIT
        printf '%s\n' "$ADMIN_SSH_PUBLIC_KEY" > "$key_file"
        admin_fingerprint=$(ssh-keygen -lf "$key_file" | awk '{print $2}')

        coolify_key=""
        ${workerSecret}
        connectivity_only=''${LUCIDITY_VM_CONNECTIVITY_ONLY:-0}
        [[ $connectivity_only == 0 || $connectivity_only == 1 ]] || {
          echo "LUCIDITY_VM_CONNECTIVITY_ONLY must be 0 or 1" >&2
          exit 2
        }

        printf '#cloud-config\n'
        jq --null-input \
          --arg role ${lib.escapeShellArg role} \
          --arg registryHost "$registry_host" \
          --arg adminKey "$ADMIN_SSH_PUBLIC_KEY" \
          --arg adminFingerprint "$admin_fingerprint" \
          --arg coolifyKey "$coolify_key" \
          --arg connectivityOnly "$connectivity_only" '
            {
              hostname: ("coolify-" + $role + "-test"),
              manage_etc_hosts: true,
              disable_root: false,
              ssh_pwauth: false,
              resize_rootfs: false,
              users: [
                "default",
                {
                  name: "admin",
                  lock_passwd: true,
                  ssh_authorized_keys: [$adminKey]
                }
              ],
              write_files: [
                {
                  path: "/etc/lucidity/vm-fixture",
                  owner: "root:root",
                  permissions: "0600",
                  content: "true\n"
                },
                {
                  path: "/etc/lucidity/admin-authorized-key.fingerprint",
                  owner: "root:root",
                  permissions: "0600",
                  content: ($adminFingerprint + "\n")
                },
                {
                  path: "/etc/lucidity/admin-authorized-key",
                  owner: "root:root",
                  permissions: "0600",
                  content: ($adminKey + "\n")
                },
                {
                  path: "/etc/containers/registries.conf.d/99-coolify-lifecycle-test.conf",
                  owner: "root:root",
                  permissions: "0644",
                  content: ("[[registry]]\nlocation = \"" + $registryHost + "\"\ninsecure = true\n")
                }
              ] + (
                if $role == "controller" and $connectivityOnly == "1" then [
                  {
                    path: "/etc/lucidity/vm-connectivity-only",
                    owner: "root:root",
                    permissions: "0600",
                    content: "true\n"
                  }
                ] else [] end
              ) + (
                if $role == "controller" then [
                  {
                    path: "/etc/systemd/system/openbao.service.d/99-lucidity-vm-fixture.conf",
                    owner: "root:root",
                    permissions: "0644",
                    content: "[Service]\nType=oneshot\nExecStartPre=\nExecStart=\nExecStart=/usr/bin/true\nRemainAfterExit=yes\n"
                  }
                ] else [
                  {
                    path: "/etc/coolify-worker/authorized_keys",
                    owner: "root:root",
                    permissions: "0600",
                    content: ($coolifyKey + "\n")
                  }
              ] end
              ),
              runcmd: (
                if $role == "controller" then [
                  ["systemctl", "daemon-reload"],
                  ["systemctl", "restart", "openbao.service"],
                  ["systemctl", "reset-failed", "coolify-controller-bootstrap.service"],
                  ["systemctl", "start", "--no-block", "coolify-controller-bootstrap.service"]
                ] else [] end
              )
            }
          '
      '';
    }
