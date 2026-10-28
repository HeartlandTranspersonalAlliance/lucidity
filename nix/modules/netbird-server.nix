{inputs}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.lucidity.netbird.server;
  port = lib.types.ints.between 1024 65535;
  externalPath = lib.types.addCheck lib.types.str (s: lib.hasPrefix "/" s && !builtins.hasContext s && !(lib.hasPrefix "/nix/store" s) && builtins.all (p: p != "." && p != "..") (lib.splitString "/" s) && builtins.match ".*[\n\r:].*" s == null);
  credentials = {
    authSecret = "NETBIRD_AUTH_SECRET";
    encryptionKey = "NETBIRD_STORE_KEY";
    sessionCookieEncryptionKey = "NETBIRD_COOKIE_KEY";
  };
  runtime = import ../lib/netbird-runtime.nix {
    inherit inputs pkgs;
    inherit (cfg) package;
    baseConfig = {
      server = {
        listenAddress = "127.0.0.1:${toString cfg.httpPort}";
        inherit (cfg) exposedAddress stunPorts metricsPort;
        healthcheckAddress = "127.0.0.1:${toString cfg.healthPort}";
        logLevel = "warn";
        logFile = "console";
        dataDir = "/var/lib/lucidity-netbird-server";
        disableAnonymousMetrics = true;
        disableGeoliteUpdate = true;
        store.engine = "sqlite";
        auth =
          if cfg.identitySettings == null
          then {}
          else cfg.identitySettings;
      };
    };
  };
  ports = [cfg.httpPort cfg.healthPort cfg.metricsPort] ++ cfg.stunPorts;
in {
  options.lucidity.netbird.server = {
    enable = lib.mkEnableOption "the private native combined NetBird server";
    package = lib.mkOption {
      type = lib.types.package;
      default = (import ../pkgs/netbird.nix {inherit pkgs;}).server;
    };
    exposedAddress = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "HTTPS origin only, without trailing slash, userinfo, path, query or fragment. No ingress is created.";
    };
    httpPort = lib.mkOption {
      type = port;
      default = 8081;
    };
    healthPort = lib.mkOption {
      type = port;
      default = 9000;
    };
    metricsPort = lib.mkOption {
      type = port;
      default = 9190;
    };
    stunPorts = lib.mkOption {
      type = lib.types.listOf port;
      default = [3478];
    };
    exposeStun = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Explicitly allow inbound STUN UDP; does not publish HTTP or metrics.";
    };
    credentialFiles = lib.genAttrs (builtins.attrNames credentials) (name:
      lib.mkOption {
        type = lib.types.nullOr externalPath;
        default = null;
        description = "External absolute file path (string, never a Nix path or value) for ${name}; provision separately.";
      });
    identitySettings = lib.mkOption {
      internal = true;
      default = null;
      type = lib.types.nullOr (lib.types.submodule {
        options = {
          issuer = lib.mkOption {type = lib.types.str;};
          localAuthDisabled = lib.mkOption {type = lib.types.bool;};
          dashboardRedirectURIs = lib.mkOption {type = lib.types.listOf lib.types.str;};
          cliRedirectURIs = lib.mkOption {type = lib.types.listOf lib.types.str;};
        };
      });
    };
  };
  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.networking.nftables.enable;
        message = "Lucidity NetBird requires an already enabled nftables backend; it never switches the host firewall backend.";
      }
      {
        assertion = cfg.exposedAddress != "" && builtins.match "https://[^/@?#[:space:]]+(:[0-9]+)?" cfg.exposedAddress != null;
        message = "Lucidity NetBird exposedAddress must be a bare HTTPS origin; runtime also validates it before exec.";
      }
      {
        assertion = cfg.stunPorts != [] && builtins.length (lib.unique ports) == builtins.length ports;
        message = "Lucidity NetBird requires nonempty explicit STUN ports and distinct HTTP/health/metrics/STUN ports.";
      }
      {
        assertion = builtins.all (v: v != null) (builtins.attrValues cfg.credentialFiles);
        message = "Lucidity NetBird requires all three external credential file paths.";
      }
      {
        assertion = cfg.identitySettings != null;
        message = "Lucidity NetBird requires the explicit local-identity leaf.";
      }
    ];
    users.users.lucidity-netbird-server = {
      isSystemUser = true;
      group = "lucidity-netbird-server";
      home = "/var/lib/lucidity-netbird-server";
    };
    users.groups.lucidity-netbird-server = {};
    networking.firewall.allowedUDPPorts = lib.optionals cfg.exposeStun cfg.stunPorts;
    networking.nftables.tables.lucidity-netbird = {
      family = "inet";
      content = ''
        chain private-listeners {
          type filter hook input priority -10; policy accept;
          iifname != "lo" tcp dport ${toString cfg.metricsPort} counter drop
          ${lib.optionalString (!cfg.exposeStun) ''iifname != "lo" udp dport { ${lib.concatMapStringsSep ", " toString cfg.stunPorts} } counter drop''}
        }
      '';
    };
    systemd.services.lucidity-netbird-server = {
      description = "Private native NetBird combined server";
      wantedBy = ["multi-user.target"];
      requires = ["nftables.service"];
      after = ["nftables.service" "network.target"];
      bindsTo = ["nftables.service"];
      serviceConfig = {
        ExecStart = lib.getExe runtime;
        User = "lucidity-netbird-server";
        Group = "lucidity-netbird-server";
        StateDirectory = "lucidity-netbird-server";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "lucidity-netbird-server";
        RuntimeDirectoryMode = "0700";
        LoadCredential =
          lib.mapAttrsToList (name: variable: "${variable}:${
            if cfg.credentialFiles.${name} == null
            then "/invalid-unconfigured"
            else cfg.credentialFiles.${name}
          }")
          credentials;
        UMask = "0077";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectKernelLogs = true;
        ProtectControlGroups = true;
        ProtectClock = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        LockPersonality = true;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
      };
    };
  };
}
