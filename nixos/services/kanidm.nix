{ config, pkgs, tailscaleHost, ... }:

{
  # Kanidm is the identity provider for all services on this machine.
  # It handles user accounts and issues OIDC tokens for services like Actual Budget.
  # Kanidm handles its own TLS directly on port 8443 — no Caddy in front of it.
  # It reads the Tailscale cert via the caddy group (see users.users.kanidm below).
  services.kanidm = {
    enableServer = true;
    package = pkgs.kanidm_1_9;
    serverSettings = {
      origin = "https://${tailscaleHost}:8443";
      domain = tailscaleHost;
      bindaddress = "[::]:8443";
      tls_chain = "/var/lib/caddy/tls/cert.pem";
      tls_key = "/var/lib/caddy/tls/key.pem";
    };
  };

  # Give the kanidm system user read access to the Tailscale certs (owned root:caddy).
  users.users.kanidm.extraGroups = [ "caddy" ];

  # Make Kanidm wait for certs to be provisioned before starting.
  systemd.services.kanidm.after = [ "tailscale-cert.service" ];
  systemd.services.kanidm.requires = [ "tailscale-cert.service" ];

  networking.firewall.allowedTCPPorts = [ 8443 ];
}
