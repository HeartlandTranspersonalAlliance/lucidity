{
  lib,
  role,
}: let
  controller = role == "controller";
  lighthouseHosts =
    if controller
    then []
    else ["100.96.0.1"];
  relayHosts =
    if controller
    then []
    else ["100.96.0.1"];
  inbound =
    if controller
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
    else [
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
    ];
in
  lib.generators.toYAML {} {
    pki = {
      ca = "/var/lib/nebula/ca.crt";
      cert = "/var/lib/nebula/host.crt";
      key = "/var/lib/nebula/host.key";
      blocklist = "@BLOCKLIST@";
    };
    static_host_map =
      if controller
      then {}
      else {
        "100.96.0.1" = ["mesh.heartlandta.org:4242"];
      };
    lighthouse = {
      am_lighthouse = controller;
      interval = 60;
      hosts = lighthouseHosts;
    };
    listen = {
      host = "0.0.0.0";
      port = 4242;
    };
    preferred_ranges = ["10.20.0.0/16"];
    punchy = {
      punch = true;
      respond = true;
    };
    relay = {
      relays = relayHosts;
      am_relay = controller;
      use_relays = !controller;
    };
    tun = {
      disabled = false;
      dev = "nebula1";
      drop_local_broadcast = true;
      drop_multicast = true;
    };
    logging = {
      level = "info";
      format = "json";
      disable_timestamp = false;
    };
    firewall = {
      conntrack = {
        tcp_timeout = "12m";
        udp_timeout = "3m";
        default_timeout = "10m";
      };
      inbound = inbound;
      outbound = [
        {
          port = "any";
          proto = "any";
          host = "any";
        }
      ];
    };
  }
