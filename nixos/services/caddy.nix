{ config, pkgs, tailscaleHost, ... }:

let
  landingPage = pkgs.writeTextDir "index.html" ''
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="UTF-8">
      <meta name="viewport" content="width=device-width, initial-scale=1.0">
      <title>homeserver</title>
      <style>
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          background: #0f1117;
          color: #e2e8f0;
          min-height: 100vh;
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          padding: 2rem;
        }
        h1 { font-size: 1.5rem; font-weight: 600; margin-bottom: 2rem; color: #94a3b8; }
        .grid {
          display: grid;
          grid-template-columns: repeat(auto-fit, minmax(180px, 1fr));
          gap: 1rem;
          width: 100%;
          max-width: 700px;
        }
        a {
          display: flex;
          flex-direction: column;
          align-items: center;
          justify-content: center;
          padding: 1.5rem 1rem;
          background: #1e2330;
          border: 1px solid #2d3748;
          border-radius: 12px;
          text-decoration: none;
          color: #e2e8f0;
          transition: background 0.15s, border-color 0.15s;
        }
        a:hover { background: #2d3748; border-color: #4a5568; }
        .icon { font-size: 2rem; margin-bottom: 0.5rem; }
        .name { font-size: 0.95rem; font-weight: 500; }
        .desc { font-size: 0.75rem; color: #64748b; margin-top: 0.25rem; }
      </style>
    </head>
    <body>
      <h1>homeserver</h1>
      <div class="grid">
        <a href="https://${tailscaleHost}:5006">
          <span class="icon">💰</span>
          <span class="name">Actual Budget</span>
          <span class="desc">Finance</span>
        </a>
        <a href="https://${tailscaleHost}:8080">
          <span class="icon">📰</span>
          <span class="name">Miniflux</span>
          <span class="desc">RSS Reader</span>
        </a>
        <a href="https://${tailscaleHost}:3000">
          <span class="icon">📊</span>
          <span class="name">Grafana</span>
          <span class="desc">Dashboards</span>
        </a>
        <a href="https://${tailscaleHost}:9090">
          <span class="icon">🔥</span>
          <span class="name">Prometheus</span>
          <span class="desc">Metrics</span>
        </a>
        <a href="https://${tailscaleHost}:9093">
          <span class="icon">🔔</span>
          <span class="name">Alertmanager</span>
          <span class="desc">Alerts</span>
        </a>
        <a href="https://${tailscaleHost}:8443">
          <span class="icon">🔐</span>
          <span class="name">Kanidm</span>
          <span class="desc">Identity</span>
        </a>
      </div>
    </body>
    </html>
  '';
in

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
    virtualHosts."${tailscaleHost}" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        root * ${landingPage}
        file_server
      '';
    };
    virtualHosts."${tailscaleHost}:5006" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:15006
      '';
    };
    virtualHosts."${tailscaleHost}:9090" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:19090
      '';
    };
    virtualHosts."${tailscaleHost}:9093" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:19093
      '';
    };
    virtualHosts."${tailscaleHost}:3000" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:13000
      '';
    };
    virtualHosts."${tailscaleHost}:8080" = {
      extraConfig = ''
        tls /var/lib/caddy/tls/cert.pem /var/lib/caddy/tls/key.pem
        reverse_proxy localhost:18080
      '';
    };
  };
}
