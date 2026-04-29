{ config, pkgs, tailscaleHost, ... }:

let
  prometheusConfig = pkgs.writeText "prometheus.yml" ''
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
      - job_name: 'prometheus'
        static_configs:
          - targets: ['localhost:19090']
  '';
in

{
  virtualisation.oci-containers.containers.prometheus = {
    image = "prom/prometheus:v3.11.3";
    extraOptions = [ "--network=host" ];
    volumes = [
      "${prometheusConfig}:/etc/prometheus/prometheus.yml:ro"
      "/var/lib/prometheus:/prometheus"
    ];
    cmd = [
      "--config.file=/etc/prometheus/prometheus.yml"
      "--storage.tsdb.path=/prometheus"
      "--web.listen-address=127.0.0.1:19090"
    ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/prometheus 0750 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 9090 ];
}
