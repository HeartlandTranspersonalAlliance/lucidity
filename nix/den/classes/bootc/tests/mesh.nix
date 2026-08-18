{pkgs}: let
  fixture =
    pkgs.runCommand "lucidity-ephemeral-mesh-fixture"
    {
      nativeBuildInputs = [
        pkgs.nebula
        pkgs.openssh
      ];
    }
    ''
      mkdir -p "$out"
      nebula-cert ca -name "Lucidity CI-only CA" -duration 24h \
        -out-crt "$out/ca.crt" -out-key "$out/ca.key"
      issue() {
        name=$1
        address=$2
        groups=$3
        nebula-cert sign -ca-crt "$out/ca.crt" -ca-key "$out/ca.key" \
          -name "$name" -networks "$address/16" -groups "$groups" \
          -duration 12h -out-crt "$out/$name.crt" -out-key "$out/$name.key"
      }
      issue controller 100.96.0.1 server,controller,lighthouse,relay
      issue worker 100.96.0.2 server,worker
      issue admin 100.96.0.10 user,admin
      issue ungrouped 100.96.0.20 ungrouped
      ssh-keygen -q -t ed25519 -N "" -C lucidity-ci-admin \
        -f "$out/admin-ssh"
      ssh-keygen -q -t ed25519 -N "" -C lucidity-ci-controller \
        -f "$out/controller-ssh"
    '';

  yaml = name: _address: _groups: controller:
    (pkgs.formats.yaml {}).generate "nebula-${name}.yml" {
      pki = {
        ca = "${fixture}/ca.crt";
        cert = "${fixture}/${name}.crt";
        key = "${fixture}/${name}.key";
        blocklist = [];
      };
      static_host_map =
        if controller
        then {
          # Keep the direct-path assertion deterministic in the isolated VM LAN.
          "100.96.0.2" = ["192.168.100.2:4242"];
        }
        else {
          "100.96.0.1" = ["192.168.100.1:4242"];
        };
      lighthouse = {
        am_lighthouse = controller;
        hosts =
          if controller
          then []
          else ["100.96.0.1"];
      };
      listen = {
        host = "0.0.0.0";
        port = 4242;
      };
      punchy = {
        punch = true;
        respond = true;
      };
      relay = {
        am_relay = controller;
        relays =
          if controller
          then []
          else ["100.96.0.1"];
        use_relays = !controller;
      };
      tun = {
        dev = "nebula1";
        disabled = false;
      };
      firewall = {
        inbound =
          if name == "controller"
          then [
            {
              port = 22;
              proto = "tcp";
              groups = ["admin"];
            }
            {
              port = "any";
              proto = "icmp";
              groups = ["server"];
            }
            {
              port = "any";
              proto = "icmp";
              groups = ["admin"];
            }
          ]
          else if name == "worker"
          then [
            {
              port = 22;
              proto = "tcp";
              groups = ["admin"];
            }
            {
              port = 22;
              proto = "tcp";
              groups = ["controller"];
            }
            {
              port = "any";
              proto = "icmp";
              groups = ["server"];
            }
            {
              port = "any";
              proto = "icmp";
              groups = ["admin"];
            }
          ]
          else [
            {
              port = "any";
              proto = "icmp";
              groups = ["server"];
            }
            {
              port = "any";
              proto = "icmp";
              groups = ["admin"];
            }
          ];
        outbound = [
          {
            port = "any";
            proto = "any";
            host = "any";
          }
        ];
      };
    };

  physical = {
    controller = "192.168.100.1";
    worker = "192.168.100.2";
    admin = "192.168.100.10";
    ungrouped = "192.168.100.20";
  };

  groups = {
    controller = [
      "server"
      "controller"
      "lighthouse"
      "relay"
    ];
    worker = [
      "server"
      "worker"
    ];
    admin = [
      "user"
      "admin"
    ];
    ungrouped = ["ungrouped"];
  };

  mkNode = name: {
    lib,
    pkgs,
    ...
  }: {
    virtualisation.vlans = [1];
    virtualisation.memorySize = 768;
    networking.useDHCP = false;
    networking.interfaces.eth1.ipv4.addresses = [
      {
        address = physical.${name};
        prefixLength = 24;
      }
    ];
    networking.firewall.trustedInterfaces = ["nebula1"];
    networking.firewall.allowedUDPPorts = [4242];

    boot.kernelModules = ["tun"];
    environment.systemPackages = [
      pkgs.nebula
      pkgs.openssh
      pkgs.iputils
      pkgs.nftables
    ];
    systemd.services.nebula = {
      description = "Lucidity CI Nebula peer";
      wantedBy = ["multi-user.target"];
      after = ["network.target"];
      serviceConfig = {
        ExecStart = "${pkgs.nebula}/bin/nebula -config /etc/nebula/config.yml";
        Restart = "on-failure";
        AmbientCapabilities = ["CAP_NET_ADMIN"];
        CapabilityBoundingSet = ["CAP_NET_ADMIN"];
      };
    };

    services.openssh = {
      enable = true;
      authorizedKeysFiles = lib.mkForce ["/run/lucidity-authorized-keys/%u"];
      settings = {
        PasswordAuthentication = false;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
      };
    };
    systemd.services.lucidity-test-authorized-keys = {
      description = "Install ephemeral Lucidity mesh SSH public keys";
      requiredBy = ["sshd.service"];
      before = ["sshd.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = "lucidity-authorized-keys";
        RuntimeDirectoryMode = "0755";
      };
      script = ''
        install -m 0644 ${fixture}/admin-ssh.pub /run/lucidity-authorized-keys/admin
        ${lib.optionalString (name == "worker") ''
          install -m 0644 ${fixture}/controller-ssh.pub /run/lucidity-authorized-keys/root
        ''}
      '';
    };
    users.users.admin = {
      isNormalUser = true;
      extraGroups = ["wheel"];
    };
    security.sudo.extraRules = [
      {
        users = ["admin"];
        commands = [
          {
            command = "ALL";
            options = ["NOPASSWD"];
          }
        ];
      }
    ];

    environment.etc = lib.mkMerge [
      {
        "nebula/config.yml".source = yaml name physical.${name} groups.${name} (name == "controller");
      }
      (lib.mkIf (name == "admin") {
        "lucidity/admin-ssh" = {
          source = "${fixture}/admin-ssh";
          mode = "0600";
        };
      })
      (lib.mkIf (name == "controller") {
        "lucidity/controller-ssh" = {
          source = "${fixture}/controller-ssh";
          mode = "0600";
        };
      })
    ];
    system.stateVersion = "25.11";
  };
in
  pkgs.testers.runNixOSTest {
    name = "lucidity-mesh-vm";
    globalTimeout = 5 * 60;
    qemu.forceAccel = true;
    nodes = {
      controller = mkNode "controller";
      worker = mkNode "worker";
      admin = mkNode "admin";
      ungrouped = mkNode "ungrouped";
    };
    testScript = ''
      import datetime as dt

      start_all()
      for machine in (controller, worker, admin, ungrouped):
          machine.wait_for_unit("nebula.service", timeout=dt.timedelta(seconds=60))
          machine.wait_for_unit("sshd.service", timeout=dt.timedelta(seconds=60))

      controller.wait_until_succeeds("ping -c 1 -W 2 100.96.0.2", timeout=dt.timedelta(seconds=30))
      admin.wait_until_succeeds("ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /etc/lucidity/admin-ssh admin@100.96.0.1 sudo -n true", timeout=dt.timedelta(seconds=30))
      admin.wait_until_succeeds("ssh -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /etc/lucidity/admin-ssh admin@100.96.0.2 sudo -n true", timeout=dt.timedelta(seconds=30))
      admin.fail("ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /etc/lucidity/admin-ssh root@100.96.0.1 true")
      controller.succeed("ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /etc/lucidity/controller-ssh root@100.96.0.2 true")
      worker.fail("ssh -o BatchMode=yes -o ConnectTimeout=3 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@100.96.0.1 true")
      ungrouped.fail("ping -c 1 -W 2 100.96.0.1")

      admin.succeed("nft add table inet relaytest; nft 'add chain inet relaytest output { type filter hook output priority -100; policy accept; }'; nft add rule inet relaytest output ip daddr 192.168.100.2 udp dport 4242 drop")
      worker.succeed("nft add table inet relaytest; nft 'add chain inet relaytest output { type filter hook output priority -100; policy accept; }'; nft add rule inet relaytest output ip daddr 192.168.100.10 udp dport 4242 drop")
      admin.succeed("systemctl restart nebula.service")
      worker.succeed("systemctl restart nebula.service")
      admin.sleep(duration=dt.timedelta(seconds=20))
      admin.succeed("ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /etc/lucidity/admin-ssh admin@100.96.0.2 true")
      # These are disposable test VMs. QMP termination is deterministic,
      # whereas guest poweroff can leave the driver waiting forever on a
      # QEMU process after every assertion has already passed.
      for machine in (ungrouped, admin, worker, controller):
          machine.crash()
    '';
  }
