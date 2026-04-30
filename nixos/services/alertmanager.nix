{ config, pkgs, ... }:

# Native Alertmanager Telegram setup instructions:
# 1. Create the secrets directory:
#    sudo mkdir -p /etc/alertmanager
#
# 2. Create the bot_token file:
#    echo "<YOUR_BOT_TOKEN>" | sudo tee /etc/alertmanager/bot_token > /dev/null
#
# 3. Create the chat_id file:
#    echo "<YOUR_CHAT_ID>" | sudo tee /etc/alertmanager/chat_id > /dev/null
#
# 4. Ensure permissions allow the container to read them:
#    sudo chmod 644 /etc/alertmanager/bot_token /etc/alertmanager/chat_id

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
          - bot_token_file: '/etc/alertmanager/bot_token'
            chat_id_file: '/etc/alertmanager/chat_id'
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
      "/etc/alertmanager/bot_token:/etc/alertmanager/bot_token:ro"
      "/etc/alertmanager/chat_id:/etc/alertmanager/chat_id:ro"
    ];
    cmd = [
      "--config.file=/etc/alertmanager/alertmanager.yml"
      "--storage.path=/alertmanager"
      "--web.listen-address=127.0.0.1:19093"
    ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/alertmanager 0750 nobody nobody -"
    "f /etc/alertmanager/bot_token 0644 root root -"
    "f /etc/alertmanager/chat_id 0644 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 9093 ];
}
