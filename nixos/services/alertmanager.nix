{ config, pkgs, ... }:

let
  alertmanagerConfig = pkgs.writeText "alertmanager.yml" ''
    global:
      resolve_timeout: 5m

    route:
      group_by: ['alertname', 'instance']
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 4h
      receiver: 'telegram'

    receivers:
      - name: 'telegram'
        telegram_configs:
          - bot_token: ''${TELEGRAM_TOKEN}
            chat_id: ''${TELEGRAM_CHAT_ID}
            send_resolved: true
  '';
in

{
  virtualisation.oci-containers.containers.alertmanager = {
    image = "prom/alertmanager:v0.32.1";
    extraOptions = [ "--network=host" ];
    volumes = [
      "${alertmanagerConfig}:/etc/alertmanager/alertmanager.yml:ro"
      "/var/lib/alertmanager:/alertmanager"
    ];
    # Alertmanager supports environment variable expansion in its config file.
    cmd = [
      "--config.file=/etc/alertmanager/alertmanager.yml"
      "--config.expand-envvars"
      "--storage.path=/alertmanager"
      "--web.listen-address=127.0.0.1:19093"
    ];
    # Create once:
    #   sudo mkdir -p /etc/alertmanager
    #   sudo install -m 600 /dev/null /etc/alertmanager/secrets
    # Then write:
    #   TELEGRAM_TOKEN=<token from @BotFather>
    #   TELEGRAM_CHAT_ID=<your numeric chat ID>
    environmentFiles = [ "/etc/alertmanager/secrets" ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/alertmanager 0750 nobody nobody -"
  ];

  networking.firewall.allowedTCPPorts = [ 9093 ];
}
