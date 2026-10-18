{ config, pkgs, tailscaleHost, ... }:

# SilverBullet setup instructions:
#
# There are no secret files. SilverBullet 2.x runs in multi-space mode, where
# accounts and spaces are created in its own Dashboard rather than through
# environment variables, and everything it stores (notes, users.json,
# authentication.json) lives in /var/lib/silverbullet.
#
# 1. After the first deploy, open https://<tailscaleHost>:3002 straight away
#    and create the administrator account. Until that is done the setup page
#    is open to every device on the tailnet.
#
# 2. Keep that local administrator even after SSO is added — it is the
#    recovery login if the identity provider is unreachable.
#
# SSO (Kanidm) is configured in the Dashboard under Admin -> Authentication,
# not here. The callback path is /.auth/central/oidc/callback, the client
# must use Authorization Code with PKCE, and the provider has to supply a
# verified email — Kanidm accounts on this host have no mail attribute by
# default, so that needs setting first.
#
# Full-text search is not in SilverBullet 2.x core and needs nothing here: it
# is the Silversearch library, installed per space from the page
# Library/Std/Pages/Library Manager. It lands under Library/ in the space (so
# restic backs it up with the notes), indexes in each browser rather than on
# the server, and searches with Ctrl-s. Settings go in the space's CONFIG page
# (config.set { silversearch = { ... } }); ignoreDiacritics = true is worth it
# for German notes.

{
  virtualisation.oci-containers.containers.silverbullet = {
    # The -slim image leaves out Chromium. The full image bundles it for the
    # experimental Runtime API (driving a headless client over HTTP / the `sb`
    # CLI), which is not used here and is not worth the memory on an 8 GB box.
    # Drop the suffix if that API is ever wanted.
    image = "ghcr.io/silverbulletmd/silverbullet:2.12.0-slim";
    extraOptions = [ "--network=host" ];
    volumes = [
      # The server runs as whoever owns this directory (see tmpfiles below).
      "/var/lib/silverbullet:/data"
      # Podman strips the host nameserver (100.100.100.100, Tailscale MagicDNS)
      # from the container's /etc/resolv.conf. Same fix as the other services;
      # needed here so the server can reach Kanidm's .ts.net name for SSO.
      "/etc/resolv.conf:/etc/resolv.conf:ro"
    ];
    environment = {
      # Listens on 13002 internally, exposed by Caddy as 3002. The upstream
      # default of 3000 is Grafana's port. The image defaults to binding
      # 0.0.0.0, which with host networking would also expose the plain-HTTP
      # port to the whole tailnet — loopback only, Caddy is the way in.
      SB_HOSTNAME = "127.0.0.1";
      SB_PORT     = "13002";
    };
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    # Notes are plain Markdown files. Owned by uid/gid 1000 so they stay
    # readable and editable from the normal login account on the host.
    "d /var/lib/silverbullet 0750 1000 1000 -"
  ];

  networking.firewall.allowedTCPPorts = [ 3002 ];
}
