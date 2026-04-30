{ config, pkgs, tailscaleHost, ... }:

{
  virtualisation.oci-containers.containers.grafana = {
    image = "grafana/grafana:11.5.2";
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/grafana:/var/lib/grafana"
    ];
    environment = {
      GF_SERVER_HTTP_ADDR = "127.0.0.1";
      GF_SERVER_HTTP_PORT = "13000";
      GF_SERVER_ROOT_URL  = "https://${tailscaleHost}:3000";
    };
    # Create once:
    #   sudo install -m 600 /dev/null /etc/grafana/secrets
    # Then write:
    #   GF_SECURITY_ADMIN_PASSWORD=<your-admin-password>
    environmentFiles = [ "/etc/grafana/secrets" ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    # grafana/grafana image runs as grafana (UID 472) — directory must be owned by that user.
    "d /var/lib/grafana 0750 472 472 -"
  ];

  networking.firewall.allowedTCPPorts = [ 3000 ];
}
