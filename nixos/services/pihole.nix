{ config, pkgs, ... }:

{
  # Pi-hole — DNS-level ad and tracker blocker.
  # Uses host networking so it can bind to port 53 on all interfaces.
  # Port 53 on tailscale0 is already trusted (see networking.firewall.trustedInterfaces),
  # so Tailscale devices can use this machine as their DNS server automatically once
  # you set it as a custom nameserver in the Tailscale admin console.
  # Web UI runs on 15080 internally; Caddy proxies it to 8080 externally over HTTPS.
  virtualisation.oci-containers.containers.pihole = {
    image = "pihole/pihole:2026.04.1";
    # NET_ADMIN and NET_RAW are required for FTL to manage DNS and raw sockets.
    extraOptions = [ "--network=host" "--cap-add=NET_ADMIN" "--cap-add=NET_RAW" ];
    volumes = [
      "/var/lib/pihole/etc-pihole:/etc/pihole"
      "/var/lib/pihole/etc-dnsmasq.d:/etc/dnsmasq.d"
    ];
    autoStart = true;
    environment = {
      TZ = "Europe/Berlin";
      # Bind web UI to non-standard ports so they don't clash with Caddy.
      # v6 renamed WEB_PORT to FTLCONF_webserver_port; TLS port is separate.
      FTLCONF_webserver_port = "15080";
      # Disable Pi-hole's own TLS — Caddy handles TLS termination.
      FTLCONF_webserver_tls_port = "0";
      # Accept queries from all interfaces including tailscale0.
      # DNSMASQ_LISTENING is the v5 name; v6 uses FTLCONF_dns_listeningMode.
      DNSMASQ_LISTENING = "all";
      FTLCONF_dns_listeningMode = "all";
    };
    # Admin password loaded from file — never committed to git.
    # Create once: sudo mkdir -p /etc/pihole && sudo install -m 600 /dev/null /etc/pihole/webpassword
    # Then write: WEBPASSWORD=<your-chosen-password>
    environmentFiles = [ "/etc/pihole/webpassword" ];
  };

  systemd.tmpfiles.rules = [
    # Pi-hole persistent config and dnsmasq overrides.
    "d /var/lib/pihole/etc-pihole 0750 root root -"
    "d /var/lib/pihole/etc-dnsmasq.d 0750 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
  # Port 53 on tailscale0 is covered by trustedInterfaces — no explicit rule needed.
}
