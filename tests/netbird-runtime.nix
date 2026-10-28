# CI-only integration test. These VMs have no route permitted to the Internet,
# use disposable synthetic credentials, and never create an owner or setup key.
{
  pkgs,
  serverModule,
  identityModule,
}: let
  probe = pkgs.writeText "netbird-stun-probe.py" ''
    import socket
    import struct
    import sys

    address, expected = sys.argv[1:]
    family = socket.AF_INET6 if ":" in address else socket.AF_INET
    transaction = b"fixture-test"
    request = struct.pack("!HHI", 1, 0, 0x2112A442) + transaction
    with socket.socket(family, socket.SOCK_DGRAM) as sock:
        sock.settimeout(2)
        sock.sendto(request, (address, 3478))
        try:
            response, _ = sock.recvfrom(2048)
        except socket.timeout:
            assert expected == "blocked", "local STUN did not respond"
        else:
            assert expected == "available", "STUN escaped the non-loopback guard"
            assert len(response) >= 20
            assert response[:2] == b"\x01\x01"
            assert response[4:20] == request[4:20]
  '';
  common = {
    virtualisation = {
      memorySize = 1024;
      cores = 1;
      vlans = [1];
      # QEMU also blocks external egress while testing nftables stop/restart.
      restrictNetwork = true;
    };
    networking = {
      useDHCP = false;
      nftables = {
        enable = true;
        tables.netbird-test-egress = {
          family = "inet";
          content = ''
            chain output {
              type filter hook output priority -200; policy drop;
              oifname "lo" accept
              ip daddr 192.168.77.0/24 accept
              ip6 daddr fd77::/64 accept
              ip6 daddr fe80::/10 accept
              ip6 daddr ff02::/16 accept
            }
          '';
        };
      };
      # Deliberately permissive input policy: the service's dedicated nft inet
      # guard must still win over trusted interfaces and broad port allowances.
      firewall = {
        enable = true;
        trustedInterfaces = ["eth1"];
        allowedTCPPorts = [8081 9000 9190 9999];
        allowedUDPPorts = [3478];
      };
    };
    environment.systemPackages = [pkgs.curl pkgs.python3 pkgs.nftables];
    system.stateVersion = "26.05";
  };
in
  pkgs.testers.runNixOSTest {
    name = "lucidity-netbird-runtime";
    globalTimeout = 5 * 60;
    qemu.forceAccel = true;
    nodes = {
      server = {
        imports = [common serverModule identityModule];
        # Keep the upstream public-origin health probe local and predictably
        # degraded: this runtime intentionally has no TLS ingress on port 443.
        networking.hosts."127.0.0.1" = ["netbird.example.test"];
        networking.interfaces.eth1 = {
          ipv4.addresses = [
            {
              address = "192.168.77.1";
              prefixLength = 24;
            }
          ];
          ipv6.addresses = [
            {
              address = "fd77::1";
              prefixLength = 64;
            }
          ];
        };
        lucidity.netbird = {
          server = {
            enable = true;
            exposedAddress = "https://netbird.example.test";
            credentialFiles = {
              authSecret = "/run/netbird-fixture/relay";
              encryptionKey = "/run/netbird-fixture/store";
              sessionCookieEncryptionKey = "/run/netbird-fixture/cookie";
            };
          };
          localIdentity.enable = true;
        };
        # Test-only privileged preflight proves the guard exists before the
        # unprivileged native process starts, including after firewall restart.
        systemd.services.lucidity-netbird-server.serviceConfig.ExecStartPre = "+${pkgs.nftables}/bin/nft list table inet lucidity-netbird";
        systemd.services.netbird-fixture = {
          before = ["lucidity-netbird-server.service"];
          requiredBy = ["lucidity-netbird-server.service"];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            UMask = "0077";
          };
          script = ''
            mkdir -m 0700 -p /run/netbird-fixture
            ${pkgs.python3}/bin/python - <<'PY'
            import base64
            from pathlib import Path
            directory = Path("/run/netbird-fixture")
            (directory / "relay").write_text("synthetic-test-relay-$-\\-quote\"-newline\n")
            (directory / "store").write_bytes(base64.b64encode(bytes(range(32))))
            (directory / "cookie").write_bytes(base64.b64encode(bytes(range(32, 64))))
            PY
          '';
        };
        systemd.services.netbird-test-control = {
          wantedBy = ["multi-user.target"];
          serviceConfig = {
            DynamicUser = true;
            ExecStart = "${pkgs.python3}/bin/python -m http.server 9999 --bind :: --directory /run";
          };
        };
      };
      client = {
        imports = [common];
        networking.interfaces.eth1 = {
          ipv4.addresses = [
            {
              address = "192.168.77.2";
              prefixLength = 24;
            }
          ];
          ipv6.addresses = [
            {
              address = "fd77::2";
              prefixLength = 64;
            }
          ];
        };
      };
    };
    testScript = ''
      import json

      start_all()
      server.wait_for_unit("lucidity-netbird-server.service")
      server.wait_for_unit("netbird-test-control.service")
      server.wait_until_succeeds("curl --noproxy '*' -fsS http://127.0.0.1:8081/api/instance")
      status = server.succeed("curl --noproxy '*' -sS -o /tmp/netbird-health.json -w '%{http_code}' http://127.0.0.1:9000/health").strip()
      assert status == "503", "private foundation must not claim public TLS health"
      health = json.loads(server.succeed("cat /tmp/netbird-health.json"))
      assert health["status"] == "unhealthy" and health["certificate_valid"] is False
      instance = json.loads(server.succeed("curl --noproxy '*' -fsS http://127.0.0.1:8081/api/instance"))
      assert instance["setup_required"] is True

      # Confirm both IP families actually reach the trusted interface before
      # attributing rejected probes to the dedicated guard.
      for address in ("192.168.77.1", "[fd77::1]"):
          client.wait_until_succeeds(f"curl --noproxy '*' --max-time 3 -fsS http://{address}:9999/")
          for port, path in ((8081, "/api/instance"), (9000, "/health"), (9190, "/metrics")):
              client.fail(f"curl --noproxy '*' --max-time 3 -fsS http://{address}:{port}{path}")
      for address in ("127.0.0.1", "[::1]"):
          server.succeed(f"curl --noproxy '*' --max-time 3 -fsS http://{address}:9190/metrics > /dev/null")
      for address in ("127.0.0.1", "::1"):
          server.succeed(f"python ${probe} {address} available")
      for address in ("192.168.77.1", "fd77::1"):
          client.succeed(f"python ${probe} {address} blocked")
      rules = json.loads(server.succeed("nft -j list table inet lucidity-netbird"))
      drops = [item["rule"] for item in rules["nftables"] if "rule" in item
               and any("drop" in expr for expr in item["rule"].get("expr", []))]
      assert len(drops) == 2
      for rule in drops:
          assert rule["family"] == "inet"
          assert sum(expr.get("counter", {}).get("packets", 0) for expr in rule["expr"]) >= 2

      # Persist a canary beside the SQLite stores, outside the generated config.
      # No account, owner password, setup token, or browser auth is created.
      server.succeed("test -s /var/lib/lucidity-netbird-server/store.db")
      server.succeed("echo state-canary > /var/lib/lucidity-netbird-server/ci-canary")
      server.succeed("systemctl restart lucidity-netbird-server.service")
      server.wait_until_succeeds("curl --noproxy '*' -fsS http://127.0.0.1:8081/api/instance")
      status = server.succeed("curl --noproxy '*' -sS -o /tmp/netbird-health.json -w '%{http_code}' http://127.0.0.1:9000/health").strip()
      assert status == "503", "private foundation must not claim public TLS health"
      health = json.loads(server.succeed("cat /tmp/netbird-health.json"))
      assert health["status"] == "unhealthy" and health["certificate_valid"] is False
      server.succeed("grep -Fx state-canary /var/lib/lucidity-netbird-server/ci-canary")
      instance = json.loads(server.succeed("curl --noproxy '*' -fsS http://127.0.0.1:8081/api/instance"))
      assert instance["setup_required"] is True
      server.succeed("test $(stat -c %a /run/lucidity-netbird-server) = 700")
      server.succeed("test $(stat -c %a /run/lucidity-netbird-server/config.json) = 600")
      assert server.succeed("systemctl show -p User --value lucidity-netbird-server.service").strip() not in ("", "root")
      server.succeed("test -z \"$(systemctl show -p AmbientCapabilities --value lucidity-netbird-server.service)\"")

      # Ensure guard stays effective after daemon restart.
      client.fail("curl --noproxy '*' --max-time 3 -fsS http://192.168.77.1:9190/metrics")
      client.succeed("python ${probe} fd77::1 blocked")
      # Explicit nftables restart propagates through Requires/BindsTo and
      # recovers availability without an extra manual server restart.
      invocation = server.succeed("systemctl show -p InvocationID --value lucidity-netbird-server.service").strip()
      server.succeed("systemctl restart nftables.service")
      server.wait_until_succeeds("curl --noproxy '*' -fsS http://127.0.0.1:8081/api/instance")
      restarted = server.succeed("systemctl show -p InvocationID --value lucidity-netbird-server.service").strip()
      assert restarted and restarted != invocation
      client.fail("curl --noproxy '*' --max-time 3 -fsS http://192.168.77.1:9190/metrics")
      client.succeed("python ${probe} fd77::1 blocked")
      # BindsTo must stop the complete SecretSpec/native cgroup before the
      # firewall is removed. No listener may outlive its guard.
      server.succeed("systemctl stop nftables.service")
      server.wait_until_fails("systemctl is-active --quiet lucidity-netbird-server.service")
      server.fail("curl --noproxy '*' --max-time 3 -fsS http://127.0.0.1:8081/api/instance")
      server.succeed("systemctl start nftables.service lucidity-netbird-server.service")
      server.wait_until_succeeds("curl --noproxy '*' -fsS http://127.0.0.1:8081/api/instance")
      client.fail("curl --noproxy '*' --max-time 3 -fsS http://192.168.77.1:9190/metrics")
      client.succeed("python ${probe} fd77::1 blocked")
      for machine in (client, server):
          machine.crash()
    '';
  }
