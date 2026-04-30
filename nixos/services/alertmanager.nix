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
        webhook_configs:
          - url: 'http://127.0.0.1:18083'
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
    cmd = [
      "--config.file=/etc/alertmanager/alertmanager.yml"
      "--storage.path=/alertmanager"
      "--web.listen-address=127.0.0.1:19093"
    ];
    autoStart = true;
  };

  # alertmanager-bot bridges Alertmanager webhook calls to Telegram messages.
  # It polls the Telegram API — no inbound connection from Telegram needed.
  virtualisation.oci-containers.containers.alertmanager-bot = {
    image = "metalmatze/alertmanager-bot:0.4.3";
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/alertmanager-bot:/data"
    ];
    environment = {
      ALERTMANAGER_URL = "http://127.0.0.1:19093";
      LISTEN_ADDR      = "127.0.0.1:18083";
      STORE            = "bolt";
      BOLT_PATH        = "/data/bot.db";
    };
    # Create once:
    #   sudo install -m 600 /dev/null /etc/alertmanager-bot/secrets
    # Then write:
    #   TELEGRAM_TOKEN=<token from @BotFather>
    #   TELEGRAM_ADMIN=<your numeric chat ID>
    environmentFiles = [ "/etc/alertmanager-bot/secrets" ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/alertmanager 0750 nobody nobody -"
    "d /var/lib/alertmanager-bot 0750 nobody nobody -"
  ];

  networking.firewall.allowedTCPPorts = [ 9093 ];
}
