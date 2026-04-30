{ config, pkgs, tailscaleHost, ... }:

let
  blackboxConfig = pkgs.writeText "blackbox.yml" ''
    modules:
      http_2xx:
        prober: http
        timeout: 5s
        http:
          valid_http_versions: ["HTTP/1.1", "HTTP/2.0"]
          valid_status_codes: []
          method: GET
  '';

  alertRules = pkgs.writeText "rules.yml" ''
    groups:
      - name: service_availability
        rules:
          - alert: ServiceDown
            expr: probe_success == 0
            for: 2m
            labels:
              severity: critical
            annotations:
              summary: "Service Down: {{ $labels.service }}"
              description: "The {{ $labels.service }} service ({{ $labels.instance }}) has been unreachable for more than 2 minutes."

      - name: backups
        rules:
          - alert: ResticBackupFailed
            expr: node_systemd_unit_state{name="restic-backups-hetzner.service",state="failed"} == 1
            for: 5m
            labels:
              severity: critical
            annotations:
              summary: "Restic backup failed"
              description: "The restic backup service has entered a failed state."

          - alert: ResticBackupStale
            expr: time() - node_systemd_timer_last_trigger_seconds{name="restic-backups-hetzner.timer"} > 90000
            for: 1h
            labels:
              severity: warning
            annotations:
              summary: "Restic backup hasn't run in over 25 hours"
              description: "The last restic backup ran more than 25 hours ago."
  '';

  prometheusConfig = pkgs.writeText "prometheus.yml" ''
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    alerting:
      alertmanagers:
        - static_configs:
            - targets: ['127.0.0.1:19093']

    rule_files:
      - /etc/prometheus/rules.yml

    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['127.0.0.1:19090']

      - job_name: 'alertmanager'
        static_configs:
          - targets: ['127.0.0.1:19093']

      - job_name: 'node'
        static_configs:
          - targets: ['127.0.0.1:9100']

      - job_name: 'blackbox'
        metrics_path: /probe
        params:
          module: [http_2xx]
        static_configs:
          - targets: ["https://${tailscaleHost}:5006"]
            labels:
              service: "Actual Budget"
          - targets: ["https://${tailscaleHost}:8443"]
            labels:
              service: "Kanidm"
          - targets: ["https://${tailscaleHost}:9090"]
            labels:
              service: "Prometheus"
          - targets: ["https://${tailscaleHost}:9093"]
            labels:
              service: "Alertmanager"
          - targets: ["https://${tailscaleHost}:3000"]
            labels:
              service: "Grafana"
        relabel_configs:
          - source_labels: [__address__]
            target_label: __param_target
          - source_labels: [__param_target]
            target_label: instance
          - target_label: __address__
            replacement: '127.0.0.1:19115'
  '';
in

{
  virtualisation.oci-containers.containers.blackbox-exporter = {
    image = "prom/blackbox-exporter:v0.28.0";
    extraOptions = [ "--network=host" ];
    volumes = [
      "${blackboxConfig}:/etc/blackbox/blackbox.yml:ro"
    ];
    cmd = [
      "--config.file=/etc/blackbox/blackbox.yml"
      "--web.listen-address=127.0.0.1:19115"
    ];
    autoStart = true;
  };

  virtualisation.oci-containers.containers.prometheus = {
    image = "prom/prometheus:v3.11.3";
    extraOptions = [ "--network=host" ];
    volumes = [
      "${prometheusConfig}:/etc/prometheus/prometheus.yml:ro"
      "${alertRules}:/etc/prometheus/rules.yml:ro"
      "/var/lib/prometheus:/prometheus"
    ];
    cmd = [
      "--config.file=/etc/prometheus/prometheus.yml"
      "--storage.tsdb.path=/prometheus"
      "--web.listen-address=127.0.0.1:19090"
      # Storage is intentionally kept small — 7 days and 2 GB max by design.
      "--storage.tsdb.retention.time=7d"
      "--storage.tsdb.retention.size=2GB"
    ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    # prom/prometheus and prom/blackbox-exporter images run as nobody — directories must be owned by that user.
    "d /var/lib/prometheus 0750 nobody nobody -"
  ];

  services.prometheus.exporters.node = {
    enable = true;
    listenAddress = "127.0.0.1";
    port = 9100;
    enabledCollectors = [ "systemd" ];
  };

  networking.firewall.allowedTCPPorts = [ 9090 ];
}
