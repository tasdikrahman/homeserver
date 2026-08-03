{ config, pkgs, tailscaleHost, ... }:

{
  # Actual Budget container. Uses host networking so it can reach Kanidm on the
  # same machine — Podman's bridge network can't route to the Tailscale IP.
  # Listens on 15006 internally (ACTUAL_PORT) to avoid clashing with Caddy on 5006.
  virtualisation.oci-containers.containers.actual = {
    image = "actualbudget/actual-server:26.8.0";
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/actual:/data"
      # Podman strips the host nameserver (100.100.100.100, Tailscale MagicDNS)
      # when generating the container's /etc/resolv.conf, so the OIDC discovery
      # URL (a .ts.net hostname) fails to resolve at container startup with
      # "getaddrinfo ENOTFOUND" — breaking SSO login (password login is
      # unaffected since it never does a DNS lookup). Same fix as
      # miniflux/blackbox-exporter: bind-mount the host's working resolv.conf.
      "/etc/resolv.conf:/etc/resolv.conf:ro"
    ];
    autoStart = true;
    # Non-secret OIDC config — safe to keep in git.
    environment = {
      ACTUAL_PORT                   = "15006";
      ACTUAL_OPENID_DISCOVERY_URL   = "https://${tailscaleHost}:8443/oauth2/openid/actual-budget";
      ACTUAL_OPENID_CLIENT_ID       = "actual-budget";
      ACTUAL_OPENID_SERVER_HOSTNAME = "https://${tailscaleHost}:5006";
    };
    # Secret loaded from a file on the server — never committed to git.
    # Create it once: sudo install -m 600 /dev/null /etc/actual/oidc-secret
    # Then write: ACTUAL_OPENID_CLIENT_SECRET=<secret from `kanidm oauth2 show-basic-secret actual-budget`>
    environmentFiles = [ "/etc/actual/oidc-secret" ];
  };

  systemd.tmpfiles.rules = [
    # Persist Actual Budget data across container restarts and rebuilds.
    "d /var/lib/actual 0750 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 5006 ];
}
