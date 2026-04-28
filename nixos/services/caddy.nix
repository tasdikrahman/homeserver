{ config, pkgs, tailscaleHost, ... }:

{
  systemd.tmpfiles.rules = [
    # TLS certs written by tailscale-cert.service, read by caddy and kanidm groups.
    "d /var/lib/caddy/tls 0750 root caddy -"
  ];

  # Provisions a Tailscale-signed TLS cert before Caddy and Kanidm start.
  # Actual Budget requires HTTPS (SharedArrayBuffer won't work over plain HTTP).
  # Kanidm also requires TLS — it reads the same certs via the caddy group.
  systemd.services.tailscale-cert = {
    after = [ "tailscaled.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    before = [ "caddy.service" "kanidm.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      # Keeps the unit in "active" state after the script exits so that
      # dependent services see the dependency as satisfied on subsequent starts.
      RemainAfterExit = true;
    };
    script = ''
      ${pkgs.tailscale}/bin/tailscale cert \
        --cert-file /var/lib/caddy/tls/cert.pem \
        --key-file /var/lib/caddy/tls/key.pem \
        ${tailscaleHost}
      chown root:caddy /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
      chmod 640 /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
    '';
  };

  # Tailscale certs expire after 90 days; renew weekly to stay well ahead.
  systemd.timers.tailscale-cert = {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "weekly";
      # Catch up missed runs if the machine was offline at the scheduled time.
      Persistent = true;
    };
  };

  # Caddy is the TLS terminator for application services on this machine.
  # Each service gets its own external HTTPS port matching its well-known port number.
  # The container binds to an internal port (1XXXX) so Caddy can own the external port (XXXX).
  # To add a new service: bind it internally to 1XXXX, add a virtualHost on XXXX here,
  # and add XXXX to allowedTCPPorts in the relevant service file.
  services.caddy = {
    enable = true;
    virtualHosts."${tailscaleHost}:5006" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:15006
      '';
    };
    virtualHosts."${tailscaleHost}:8080" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:15080
      '';
    };
  };
}
