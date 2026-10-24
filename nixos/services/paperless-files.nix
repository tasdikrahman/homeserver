{ config, pkgs, tailscaleHost, ... }:

# Read-only folder view of Paperless's documents on :8090, behind Kanidm SSO.
#
# Caddy serves the files itself (file_server browse, see caddy.nix) and asks
# oauth2-proxy (forward_auth) whether each request is logged in. oauth2-proxy
# does the OIDC login against Kanidm; it never proxies the files.
#
# Pieces, all on this host:
#   - caddy.nix: the :8090 vhost. /oauth2/* goes to oauth2-proxy, everything
#     else passes forward_auth and is then served by file_server browse.
#   - this file: oauth2-proxy, Caddy's read ACLs, the firewall port.
#   - kanidm.nix: the paperless-files OAuth2 client and the full one-time
#     setup transcript (group, client, mail attribute, secret files).
#   - /etc/oauth2-proxy/{client-secret,cookie-secret}: secrets, 0600 root,
#     backed up with /etc by restic.
#
# --- One-time setup, on the server, BEFORE pushing this --------------------
#
# Run the paperless-files block in kanidm.nix. oauth2-proxy will not start
# without both secret files it creates, and a unit that fails to start makes
# `nixos-rebuild switch` fail — auto-rebuild would then retry every 5 minutes
# without recording the commit as applied.
#
# Cookie secret: 32 hex chars = a 32-byte AES key. Neither file may have a
# trailing newline, hence the printf / tr -d '\n' in that block.
#
# If login fails with a signing-algorithm error, fall back to
# `kanidm system oauth2 warning-enable-legacy-crypto paperless-files`.
#
# After the first login, `journalctl -u oauth2-proxy` should show
# "authenticated via OAuth2: Session{email:<your-address> ...}". An error about
# email_verified means Kanidm sent the address as unverified; then add
# `insecure-oidc-allow-unverified-email = true;` to extraConfig below (safe
# here: the Kanidm group, not the email, is what grants access).

{
  services.oauth2-proxy = {
    enable = true;
    provider = "oidc";
    oidcIssuerUrl = "https://${tailscaleHost}:8443/oauth2/openid/paperless-files";
    clientID = "paperless-files";
    clientSecretFile = "/etc/oauth2-proxy/client-secret";
    redirectURL = "https://${tailscaleHost}:8090/oauth2/callback";
    scope = "openid profile email";

    httpAddress = "http://127.0.0.1:14180";
    reverseProxy = true;
    trustedProxyIP = [ "127.0.0.1" ];

    # Auth-only mode: Caddy serves the files, so there is nothing to proxy to.
    upstream = "static://202";

    # Authorisation is Kanidm's scope map: only paperless-files-users members
    # get a token at all. Any identity that comes back is therefore allowed.
    email.domains = [ "*" ];

    cookie = {
      # Cookies are per host, not per port — a distinct name keeps this from
      # colliding with any other app on the same tailnet name.
      name = "_oauth2_proxy_files";
      secretFile = "/etc/oauth2-proxy/cookie-secret";
    };

    extraConfig = {
      # Kanidm requires PKCE by default.
      code-challenge-method = "S256";
      # Go straight to Kanidm instead of an oauth2-proxy "Sign in" page.
      skip-provider-button = true;
      # Under /oauth2/ so Caddy routes it here; the blackbox probe uses it.
      ping-path = "/oauth2/ping";
    };
  };

  # Fetches Kanidm's OIDC discovery document at startup and exits if it can't.
  systemd.services.oauth2-proxy = {
    after = [ "kanidm.service" ];
    wants = [ "kanidm.service" ];
    # The module sets Restart=always; without a delay a Kanidm that is slow to
    # come up burns through the start limit and leaves the unit failed.
    serviceConfig.RestartSec = "5s";
  };

  systemd.tmpfiles.rules = [
    # Read-only access for Caddy without changing Paperless's ownership.
    # Traverse-only on the parent, so data/ and consume/ stay unlistable.
    # A+ is recursive and re-applied on every switch; the d: default entry
    # makes new files inherit the read grant.
    "a+ /var/lib/paperless       - - - - u:caddy:x"
    "A+ /var/lib/paperless/media - - - - u:caddy:rX,d:u:caddy:rX"
  ];

  networking.firewall.allowedTCPPorts = [ 8090 ];
}
