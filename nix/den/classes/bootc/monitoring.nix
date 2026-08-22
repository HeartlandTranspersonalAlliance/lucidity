{
  lib,
  pkgs,
  isController,
  overlayIPv4,
  httpsTargets,
  systemProfile,
}: let
  httpsTargetLines = lib.concatMapStringsSep "\n" (target: "                - ${builtins.toJSON target}") httpsTargets;
  lokiEndpoint = "http://100.96.0.1:3100/loki/api/v1/push";
  controllerFiles = lib.optionalAttrs isController {
    "etc/prometheus/prometheus.yml" = ''
            global:
              scrape_interval: 30s
              evaluation_interval: 30s
            rule_files:
              - /etc/prometheus/rules.yml
            alerting:
              alertmanagers:
                - static_configs:
                    - targets: ["127.0.0.1:9093"]
            scrape_configs:
              - job_name: prometheus
                static_configs:
                  - targets: ["127.0.0.1:9090"]
              - job_name: lucidity-nodes
                static_configs:
                  - targets: ["100.96.0.1:9100"]
                    labels:
                      role: controller
                  - targets: ["100.96.0.2:9100"]
                    labels:
                      role: worker
              - job_name: lucidity-alloy
                static_configs:
                  - targets: ["100.96.0.1:12345"]
                    labels:
                      role: controller
                  - targets: ["100.96.0.2:12345"]
                    labels:
                      role: worker
              - job_name: loki
                static_configs:
                  - targets: ["100.96.0.1:3100"]
              - job_name: https-canaries
                metrics_path: /probe
                params:
                  module: [https_2xx]
                static_configs:
                  - targets:
      ${httpsTargetLines}
                relabel_configs:
                  - source_labels: [__address__]
                    target_label: __param_target
                  - source_labels: [__param_target]
                    target_label: instance
                  - target_label: __address__
                    replacement: 127.0.0.1:9115
    '';
    "etc/prometheus/rules.yml" = ''
      groups:
        - name: lucidity
          rules:
            - alert: LucidityNodeUnavailable
              expr: up{job="lucidity-nodes"} == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Lucidity {{ $labels.role }} node is unavailable"
                description: "Prometheus cannot scrape node_exporter over Nebula at {{ $labels.instance }}."
            - alert: LucidityHttpsCanaryFailed
              expr: probe_success{job="https-canaries"} == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "HTTPS canary failed for {{ $labels.instance }}"
                description: "The public HTTPS endpoint failed the blackbox exporter probe."
            - alert: LucidityRoleServiceDown
              expr: lucidity_role_service_active == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Required service {{ $labels.service }} is down on {{ $labels.role }}"
                description: "The role-aware host collector reports a required systemd service as inactive."
            - alert: LucidityDockerContainerUnhealthy
              expr: lucidity_docker_unhealthy_containers > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Unhealthy Docker containers on {{ $labels.role }}"
                description: "{{ $value }} Docker containers report an unhealthy health check."
            - alert: LucidityBackupStale
              expr: lucidity_backup_configured == 1 and (time() - lucidity_backup_last_success_timestamp_seconds) > 108000
              for: 15m
              labels:
                severity: critical
              annotations:
                summary: "Application backup is stale on {{ $labels.role }}"
                description: "No successful restic backup has completed in the last 30 hours."
            - alert: LucidityFilesystemLow
              expr: node_filesystem_avail_bytes{fstype!~"tmpfs|overlay|squashfs"} / node_filesystem_size_bytes{fstype!~"tmpfs|overlay|squashfs"} < 0.15
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "Low filesystem space on {{ $labels.instance }}"
                description: "Filesystem {{ $labels.mountpoint }} has less than 15 percent free space."
            - alert: LucidityCpuSaturation
              expr: 100 * (1 - avg by(instance) (rate(node_cpu_seconds_total{mode="idle"}[5m]))) > 85
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "Sustained CPU saturation on {{ $labels.instance }}"
                description: "CPU utilization has remained above 85 percent for 15 minutes."
            - alert: LucidityReleaseMismatch
              expr: count(count by(version) (lucidity_release_info)) > 1
              for: 10m
              labels:
                severity: warning
              annotations:
                summary: "Controller and worker release versions differ"
                description: "The two production roles do not report the same bootc image version."
            - alert: LucidityAlloyUnavailable
              expr: up{job="lucidity-alloy"} == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Grafana Alloy is unavailable on {{ $labels.role }}"
                description: "The controller cannot scrape the node's Alloy health endpoint over Nebula."
            - alert: LucidityLokiUnavailable
              expr: up{job="loki"} == 0
              for: 5m
              labels:
                severity: critical
              annotations:
                summary: "Controller Loki is unavailable"
                description: "Prometheus cannot scrape the controller-hosted Loki service."
            - alert: LucidityAlloyDroppedLogs
              expr: sum by(instance) (rate(loki_write_dropped_entries_total[5m])) > 0
              for: 5m
              labels:
                severity: warning
              annotations:
                summary: "Grafana Alloy is dropping logs on {{ $labels.instance }}"
                description: "The Alloy Loki writer has dropped log entries for five minutes."
            - alert: LucidityControllerObservabilityDiskLow
              expr: node_filesystem_avail_bytes{instance="100.96.0.1:9100",mountpoint="/"} / node_filesystem_size_bytes{instance="100.96.0.1:9100",mountpoint="/"} < 0.20
              for: 15m
              labels:
                severity: warning
              annotations:
                summary: "Controller observability disk has less than 20 percent free"
                description: "Reduce log selection or retention before resizing the controller volume."
            - alert: LucidityControllerHeartbeat
              expr: vector(1)
              labels:
                severity: info
              annotations:
                summary: "Lucidity controller daily heartbeat"
                description: "Monitoring, Alertmanager, and self-hosted ntfy are alive. Treat a missing daily heartbeat as an incident."
    '';
    "etc/prometheus/blackbox.yml" = ''
      modules:
        https_2xx:
          prober: http
          timeout: 10s
          http:
            valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
            preferred_ip_protocol: ip4
            fail_if_not_ssl: true
    '';
    "etc/alertmanager/alertmanager.yml" = ''
      route:
        receiver: ntfy
        group_by: [alertname, role, instance]
        group_wait: 30s
        group_interval: 5m
        repeat_interval: 4h
        routes:
          - receiver: ntfy
            matchers:
              - alertname="LucidityControllerHeartbeat"
            repeat_interval: 24h
      receivers:
        - name: ntfy
          webhook_configs:
            - url: http://127.0.0.1:8000/hook
              send_resolved: true
    '';
    "etc/alertmanager-ntfy/config.yml" = ''
      http:
        addr: 127.0.0.1:8000
      ntfy:
        baseurl: https://ntfy.heartlandta.org
        notification:
          topic: lucidity-alerts
          priority: 'status == "firing" ? "high" : "default"'
          tags:
            - tag: rotating_light
              condition: status == "firing"
            - tag: white_check_mark
              condition: status == "resolved"
          templates:
            title: '{{ if eq .Status "resolved" }}Resolved: {{ end }}{{ index .Annotations "summary" }}'
            description: '{{ index .Annotations "description" }}'
        async: false
    '';
    "etc/ntfy/server.yml" = ''
      base-url: https://ntfy.heartlandta.org
      listen-http: 100.96.0.1:2586
      cache-file: /var/lib/ntfy/cache.db
      auth-file: /var/lib/ntfy/user.db
      auth-default-access: deny-all
      attachment-cache-dir: /var/lib/ntfy/attachments
      enable-login: true
      behind-proxy: true
    '';
    "etc/grafana/grafana.ini" = ''
      [server]
      http_addr = 127.0.0.1
      http_port = 3000
      domain = localhost
      [database]
      type = sqlite3
      path = /var/lib/grafana/grafana.db
      [paths]
      data = /var/lib/grafana
      logs = /var/log/grafana
      plugins = /var/lib/grafana/plugins
      provisioning = /etc/grafana/provisioning
      [auth.anonymous]
      enabled = true
      org_role = Viewer
      [users]
      allow_sign_up = false
    '';
    "etc/grafana/provisioning/datasources/prometheus.yml" = ''
      apiVersion: 1
      datasources:
        - name: Prometheus
          type: prometheus
          access: proxy
          url: http://127.0.0.1:9090
          isDefault: true
          editable: false
        - name: Loki
          uid: lucidity-loki
          type: loki
          access: proxy
          url: http://100.96.0.1:3100
          editable: false
    '';
    "etc/grafana/provisioning/dashboards/lucidity.yml" = ''
      apiVersion: 1
      providers:
        - name: Lucidity
          type: file
          disableDeletion: true
          editable: false
          options:
            path: /etc/grafana/dashboards
    '';
    "etc/grafana/dashboards/lucidity-overview.json" = builtins.toJSON {
      title = "Lucidity production overview";
      uid = "lucidity-production";
      schemaVersion = 41;
      refresh = "30s";
      time = {
        from = "now-6h";
        to = "now";
      };
      panels = [
        {
          id = 1;
          title = "Node scrape health";
          type = "stat";
          gridPos = {
            x = 0;
            y = 0;
            w = 8;
            h = 5;
          };
          targets = [{expr = ''up{job="lucidity-nodes"}'';}];
        }
        {
          id = 2;
          title = "HTTPS canaries";
          type = "stat";
          gridPos = {
            x = 8;
            y = 0;
            w = 8;
            h = 5;
          };
          targets = [{expr = ''probe_success{job="https-canaries"}'';}];
        }
        {
          id = 3;
          title = "Filesystem free percent";
          type = "timeseries";
          gridPos = {
            x = 0;
            y = 5;
            w = 16;
            h = 8;
          };
          targets = [{expr = ''100 * node_filesystem_avail_bytes{fstype!~="tmpfs|overlay|squashfs"} / node_filesystem_size_bytes{fstype!~="tmpfs|overlay|squashfs"}'';}];
        }
        {
          id = 4;
          title = "Alloy and Loki scrape health";
          type = "stat";
          gridPos = {
            x = 16;
            y = 0;
            w = 8;
            h = 5;
          };
          targets = [{expr = ''up{job=~"lucidity-alloy|loki"}'';}];
        }
        {
          id = 5;
          title = "Recent service logs";
          type = "logs";
          datasource = {
            type = "loki";
            uid = "lucidity-loki";
          };
          gridPos = {
            x = 0;
            y = 13;
            w = 24;
            h = 10;
          };
          targets = [{expr = ''{role=~"controller|worker"}'';}];
        }
      ];
    };
    "etc/loki/config.yml" = ''
      auth_enabled: false
      server:
        http_listen_address: 100.96.0.1
        http_listen_port: 3100
      common:
        path_prefix: /var/lib/loki
        replication_factor: 1
        ring:
          kvstore:
            store: inmemory
        storage:
          filesystem:
            chunks_directory: /var/lib/loki/chunks
            rules_directory: /var/lib/loki/rules
      schema_config:
        configs:
          - from: 2024-01-01
            store: tsdb
            object_store: filesystem
            schema: v13
            index:
              prefix: index_
              period: 24h
      limits_config:
        retention_period: 168h
        ingestion_rate_mb: 2
        ingestion_burst_size_mb: 4
      compactor:
        working_directory: /var/lib/loki/compactor
        retention_enabled: true
        delete_request_store: filesystem
    '';
    "usr/libexec/lucidity/alertmanager-ntfy" = ''
      #!/usr/bin/env bash
      set -Eeuo pipefail
      if [[ ''${LUCIDITY_NTFY_RESOLVED:-0} != 1 ]]; then
        credential_directory="''${CREDENTIALS_DIRECTORY:?}"
        exec env \
          BAO_ADDR=https://127.0.0.1:8200 \
          BAO_CACERT=/var/lib/openbao/tls/server.crt \
          BAO_TOKEN_PATH="$credential_directory/bao-token" \
          LUCIDITY_NTFY_RESOLVED=1 \
          ${pkgs.secretspec}/bin/secretspec run \
            --file /etc/lucidity/secretspec.toml \
            --profile monitoring-controller \
            --scope monitoring \
            --reason "publish Lucidity monitoring alerts" \
            -- "$0"
      fi
      credential="''${NTFY_ALERTMANAGER_TOKEN_FILE:?}"
      [[ -s $credential ]] || { echo "ntfy credential is unavailable" >&2; exit 1; }
      umask 077
      install -d -m 0700 /run/alertmanager-ntfy/state
      ${pkgs.jq}/bin/jq -n --rawfile token "$credential" '{ntfy:{auth:{token:($token | rtrimstr("\n"))}}}' > /run/alertmanager-ntfy/auth.yml
      exec ${pkgs.alertmanager-ntfy}/bin/alertmanager-ntfy --configs /etc/alertmanager-ntfy/config.yml,/run/alertmanager-ntfy/auth.yml
    '';
    "usr/libexec/lucidity/install-ntfy-route" = ''
      #!/usr/bin/env bash
      set -Eeuo pipefail
      install -d -m 0700 /data/coolify/proxy/dynamic
      install -m 0600 /etc/lucidity/ntfy-traefik.yml /data/coolify/proxy/dynamic/lucidity-ntfy.yml
      restorecon -F /data/coolify/proxy/dynamic/lucidity-ntfy.yml
    '';
    "etc/lucidity/ntfy-traefik.yml" = ''
      http:
        routers:
          lucidity-ntfy:
            rule: Host(`ntfy.heartlandta.org`)
            entryPoints: [https]
            service: lucidity-ntfy
            tls:
              certResolver: letsencrypt
        services:
          lucidity-ntfy:
            loadBalancer:
              servers:
                - url: http://100.96.0.1:2586
    '';
    "usr/lib/systemd/system/prometheus.service" = ''
      [Unit]
      Description=Lucidity Prometheus
      Requires=lucidity-nix-profile.service nebula.service
      After=lucidity-nix-profile.service nebula.service network-online.target
      [Service]
      User=prometheus
      Group=prometheus
      StateDirectory=prometheus
      ExecStart=${pkgs.prometheus}/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/lib/prometheus --storage.tsdb.retention.time=30d --web.listen-address=127.0.0.1:9090
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/var/lib/prometheus
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/loki.service" = ''
      [Unit]
      Description=Lucidity Loki log store
      Requires=lucidity-nix-profile.service nebula.service
      After=lucidity-nix-profile.service nebula.service
      [Service]
      User=loki
      Group=loki
      StateDirectory=loki
      ExecStart=${pkgs.grafana-loki}/bin/loki -config.file=/etc/loki/config.yml
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/var/lib/loki
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/prometheus-alertmanager.service" = ''
      [Unit]
      Description=Lucidity Prometheus Alertmanager
      Requires=lucidity-nix-profile.service
      After=lucidity-nix-profile.service network-online.target
      [Service]
      User=alertmanager
      Group=alertmanager
      StateDirectory=alertmanager
      ExecStart=${pkgs.prometheus-alertmanager}/bin/alertmanager --config.file=/etc/alertmanager/alertmanager.yml --storage.path=/var/lib/alertmanager --web.listen-address=127.0.0.1:9093
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/var/lib/alertmanager
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/prometheus-blackbox-exporter.service" = ''
      [Unit]
      Description=Lucidity Prometheus blackbox exporter
      Requires=lucidity-nix-profile.service
      After=lucidity-nix-profile.service network-online.target
      [Service]
      User=blackbox-exporter
      Group=blackbox-exporter
      ExecStart=${pkgs.prometheus-blackbox-exporter}/bin/blackbox_exporter --config.file=/etc/prometheus/blackbox.yml --web.listen-address=127.0.0.1:9115
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/grafana.service" = ''
      [Unit]
      Description=Lucidity Grafana
      Requires=lucidity-nix-profile.service prometheus.service
      After=lucidity-nix-profile.service prometheus.service
      [Service]
      User=grafana
      Group=grafana
      StateDirectory=grafana
      LogsDirectory=grafana
      ExecStart=${pkgs.grafana}/bin/grafana server --config=/etc/grafana/grafana.ini --homepath=${pkgs.grafana}/share/grafana
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/var/lib/grafana /var/log/grafana
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/ntfy.service" = ''
      [Unit]
      Description=Lucidity self-hosted ntfy
      Requires=lucidity-nix-profile.service nebula.service
      After=lucidity-nix-profile.service nebula.service network-online.target
      [Service]
      User=ntfy
      Group=ntfy
      StateDirectory=ntfy
      ExecStart=${pkgs.ntfy-sh}/bin/ntfy serve --config /etc/ntfy/server.yml
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/var/lib/ntfy
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/alertmanager-ntfy.service" = ''
      [Unit]
      Description=Forward Lucidity Alertmanager notifications to ntfy
      Requires=lucidity-nix-profile.service ntfy.service
      After=lucidity-nix-profile.service ntfy.service openbao.service
      ConditionPathExists=/var/lib/openbao/monitoring-token
      [Service]
      User=alertmanager-ntfy
      Group=alertmanager-ntfy
      RuntimeDirectory=alertmanager-ntfy
      LoadCredential=bao-token:/var/lib/openbao/monitoring-token
      Environment=XDG_STATE_HOME=/run/alertmanager-ntfy/state
      ExecStart=/usr/libexec/lucidity/alertmanager-ntfy
      Restart=on-failure
      NoNewPrivileges=yes
      PrivateTmp=yes
      ProtectHome=yes
      ProtectSystem=strict
      ReadWritePaths=/run/alertmanager-ntfy
      [Install]
      WantedBy=multi-user.target
    '';
    "usr/lib/systemd/system/lucidity-ntfy-route.service" = ''
      [Unit]
      Description=Install the ntfy route in Coolify's Traefik configuration
      Requires=coolify-controller-storage.service
      After=coolify-controller-storage.service
      Before=coolify-controller-bootstrap.service
      [Service]
      Type=oneshot
      ExecStart=/usr/libexec/lucidity/install-ntfy-route
      RemainAfterExit=yes
      [Install]
      WantedBy=multi-user.target
    '';
  };
in {
  files =
    {
      "etc/alloy/config.alloy" = ''
        logging {
          level = "info"
        }

        loki.write "controller" {
          endpoint {
            url = "${lokiEndpoint}"
          }
        }

        loki.process "local" {
          stage.static_labels {
            values = {
              role = "${
          if isController
          then "controller"
          else "worker"
        }",
              host = "${
          if isController
          then "controller"
          else "worker"
        }",
            }
          }
          forward_to = [loki.write.controller.receiver]
        }

        loki.source.journal "systemd" {
          max_age = "12h"
          labels = {
            job = "systemd-journal",
          }
          forward_to = [loki.process.local.receiver]
        }

        local.file_match "docker" {
          path_targets = [{
            __path__ = "/var/lib/docker/containers/*/*-json.log",
            job = "docker",
          }]
        }

        loki.source.file "docker" {
          targets = local.file_match.docker.targets
          forward_to = [loki.process.local.receiver]
        }
      '';
      "usr/lib/systemd/system/alloy.service" = ''
        [Unit]
        Description=Lucidity Grafana Alloy log collector
        Requires=lucidity-nix-profile.service nebula.service
        After=lucidity-nix-profile.service nebula.service
        ${lib.optionalString isController "Requires=loki.service\nAfter=loki.service"}
        [Service]
        User=root
        StateDirectory=alloy
        ExecStart=${pkgs.grafana-alloy}/bin/alloy run --server.http.listen-addr=${overlayIPv4}:12345 --storage.path=/var/lib/alloy /etc/alloy/config.alloy
        Restart=on-failure
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectHome=yes
        ProtectSystem=strict
        ReadWritePaths=/var/lib/alloy
        ReadOnlyPaths=/var/log/journal /run/log/journal /var/lib/docker/containers
        [Install]
        WantedBy=multi-user.target
      '';
      "usr/libexec/lucidity/monitoring-collector" = builtins.readFile ./files/monitoring-collector.sh;
      "usr/lib/systemd/system/prometheus-node-exporter.service" = ''
        [Unit]
        Description=Lucidity Prometheus node exporter
        Requires=lucidity-nix-profile.service nebula.service
        After=lucidity-nix-profile.service nebula.service
        [Service]
        User=lucidity-metrics
        Group=lucidity-metrics
        ExecStart=${pkgs.prometheus-node-exporter}/bin/node_exporter --web.listen-address=${overlayIPv4}:9100 --collector.textfile.directory=/var/lib/lucidity-monitoring/textfile
        Restart=on-failure
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectHome=yes
        ProtectSystem=strict
        [Install]
        WantedBy=multi-user.target
      '';
      "usr/lib/systemd/system/lucidity-monitoring-collector.service" = ''
        [Unit]
        Description=Collect Lucidity role and lifecycle metrics
        Requires=lucidity-nix-profile.service
        After=lucidity-nix-profile.service
        [Service]
        Type=oneshot
        User=root
        Environment=PATH=${systemProfile}/bin:/usr/sbin:/usr/bin:/sbin:/bin
        ExecStart=/usr/libexec/lucidity/monitoring-collector
        NoNewPrivileges=yes
        PrivateTmp=yes
        ProtectHome=read-only
        ProtectSystem=strict
        ReadWritePaths=/var/lib/lucidity-monitoring
      '';
      "usr/lib/systemd/system/lucidity-monitoring-collector.timer" = ''
        [Unit]
        Description=Refresh Lucidity role and lifecycle metrics
        [Timer]
        OnBootSec=2m
        OnUnitActiveSec=1m
        RandomizedDelaySec=10s
        Persistent=true
        [Install]
        WantedBy=timers.target
      '';
    }
    // controllerFiles;
  enabledUnits =
    ["prometheus-node-exporter.service" "lucidity-monitoring-collector.timer" "alloy.service"]
    ++ lib.optionals isController [
      "prometheus.service"
      "loki.service"
      "prometheus-alertmanager.service"
      "prometheus-blackbox-exporter.service"
      "grafana.service"
      "ntfy.service"
      "alertmanager-ntfy.service"
      "lucidity-ntfy-route.service"
    ];
}
