{...}: {
  den.aspects.controller.bootc = {pkgs, ...}: {
    lucidity = {
      role = "controller";
      hostName = "controller";
      overlayIPv4 = "100.96.0.1";
      nebulaGroups = [
        "server"
        "controller"
        "lighthouse"
        "relay"
      ];
      packages = with pkgs; [
        alertmanager-ntfy
        grafana
        grafana-loki
        ntfy-sh
        openssl
        prometheus
        prometheus-alertmanager
        prometheus-blackbox-exporter
      ];
      persistentPaths = [
        "/data/coolify"
        "/var/lib/coolify"
        "/var/lib/openbao"
        "/var/lib/ntfy"
        "/var/lib/prometheus"
        "/var/lib/alertmanager"
        "/var/lib/grafana"
        "/var/lib/loki"
        "/var/lib/alloy"
      ];
      files = {
        "etc/openbao/openbao.hcl.in" = ''
          ui = false
          disable_mlock = false
          api_addr = "https://127.0.0.1:8200"
          cluster_addr = "https://127.0.0.1:8201"
          plugin_directory = "/var/lib/openbao/plugins"

          storage "raft" {
            path = "/var/lib/openbao/raft"
            node_id = "lucidity-controller"
          }

          listener "tcp" {
            address = "127.0.0.1:8200"
            cluster_address = "127.0.0.1:8201"
            tls_disable = false
            tls_cert_file = "/var/lib/openbao/tls/server.crt"
            tls_key_file = "/var/lib/openbao/tls/server.key"
          }

          @OVERLAY_LISTENER@

          plugin "kms" "awskms" {
            command = "@AWS_KMS_PLUGIN@"
            sha256sum = "@AWS_KMS_PLUGIN_SHA256@"
          }

          seal "awskms" {
            region = "us-east-2"
            kms_key_id = "@OPENBAO_KMS_ALIAS@"
          }
        '';
      };
    };
  };
}
