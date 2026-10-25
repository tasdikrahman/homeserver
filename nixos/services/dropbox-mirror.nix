{ config, lib, pkgs, tailscaleHost, syncthingLaptopId, ... }:

# Read-only copy of the laptop's ~/Dropbox, kept current by Syncthing, and
# its folder view on :8090 behind Kanidm login.
#
# Pieces:
#   - this file: Syncthing, Caddy's read ACL on the mirror, oauth2-proxy
#     (the Kanidm login) and the firewall port.
#   - caddy.nix: the :8090 vhost. /oauth2/* goes to oauth2-proxy; everything
#     else passes forward_auth and is then served by file_server browse.
#     oauth2-proxy never proxies the files, it only answers "logged in?".
#   - kanidm.nix: the OAuth2 client and its full setup transcript. The client
#     is called paperless-files because the view first showed Paperless's
#     files (2026-10-24); renaming it would mean recreating it and its secret.
#   - /etc/oauth2-proxy/{client-secret,cookie-secret}: 0600 root, backed up
#     with /etc by restic.
#
# The laptop is the source. Its folder is "Send Only", this one "Receive
# Only", so nothing done here can ever reach the laptop or Dropbox. Paperless
# is separate and does not read this folder: it keeps its own copy of the
# documents imported on 2026-10-12, for search.
#
# Network: Syncthing listens on 22000, which is deliberately not in
# allowedTCPPorts. tailscale0 is a trusted interface, so the laptop reaches it
# over the tailnet while the LAN cannot. Discovery and relays are off, so no
# traffic or announcement ever leaves the tailnet; the laptop dials this host
# by name. The GUI is loopback-only; reach it with
#   ssh -L 18384:127.0.0.1:18384 <user>@<tailscaleHost>
#
# --- Syncthing, one-time setup --------------------------------------------
#
# 1. Laptop: install Syncthing and read its device ID (not a secret: it is a
#    certificate fingerprint, and only devices listed below are accepted):
#      sudo apt install syncthing
#      systemctl --user enable --now syncthing
#      syncthing device-id        # older versions: syncthing --device-id
#    Then, on the server, add it to nixos/local.nix (gitignored) as
#      syncthingLaptopId = "<id>";
#    Until it is set, the Syncthing half is off. Not a secret, but the repo is
#    public, and with global discovery on the ID would reveal the laptop's IP.
#
# 2. Server, after the deploy: this host's device ID, for the laptop side:
#      KEY=$(sudo grep -oP '(?<=<apikey>)[^<]+' /var/lib/syncthing/.config/syncthing/config.xml)
#      curl -s -H "X-API-Key: $KEY" http://127.0.0.1:18384/rest/system/status | grep -o '"myID":"[^"]*"'
#
# 3. Laptop: add this host as a device (address tcp://<tailscaleHost>:22000)
#    and share ~/Dropbox with it as folder ID "dropbox", type Send Only.
#
# Recovering a file deleted or overwritten on the laptop: Syncthing keeps the
# previous version for 30 days under /var/lib/dropbox-mirror/.stversions/.
#
# --- Kanidm login (oauth2-proxy), one-time setup --------------------------
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

let
  mirror = "/var/lib/dropbox-mirror";
in
lib.mkMerge [
  # Mirror: off until local.nix sets syncthingLaptopId.
  (lib.mkIf (syncthingLaptopId != null) {
    services.syncthing = {
      enable = true;
      # Internal port, per the 1XXXX convention. Loopback only, so no password.
      guiAddress = "127.0.0.1:18384";
      openDefaultPorts = false;

      # Devices and folders exist only as declared here; anything added in the
      # GUI is reverted on restart.
      overrideDevices = true;
      overrideFolders = true;

      settings = {
        options = {
          listenAddresses = [ "tcp://0.0.0.0:22000" ];
          globalAnnounceEnabled = false;
          localAnnounceEnabled = false;
          relaysEnabled = false;
          natEnabled = false;
          urAccepted = -1;
          crashReportingEnabled = false;
        };

        devices.laptop = {
          id = syncthingLaptopId;
          # Accept the laptop's incoming connection only; with discovery off
          # there is no address to dial it at.
          addresses = [ "dynamic" ];
        };

        folders.dropbox = {
          path = mirror;
          label = "Dropbox";
          type = "receiveonly";
          devices = [ "laptop" ];
          # 21 files on the laptop are mode 600. Copying modes would make them
          # unreadable for Caddy, whose access comes from the ACL below.
          ignorePerms = true;
          # Dropbox's own client state, not content.
          ignorePatterns = [
            "(?d).dropbox"
            "(?d).dropbox.cache"
          ];
          versioning = {
            type = "staggered";
            params = {
              cleanInterval = "3600";
              maxAge = toString (30 * 24 * 3600);
            };
          };
        };
      };
    };

    # The laptop is the source, so this is a real backup of it, not a spare
    # copy of Dropbox. Set here rather than in restic.nix so the path only
    # exists in the list while the mirror does (restic fails on a missing path).
    # Includes .stversions, the 30-day version store.
    services.restic.backups.hetzner.paths = [ mirror ];

    systemd.tmpfiles.rules = [
      "d ${mirror} 0750 syncthing syncthing -"
      # Read-only access for Caddy. Recursive, re-applied on every switch, and
      # the d: default entry makes newly synced files inherit it.
      "A+ ${mirror} - - - - u:caddy:rX,d:u:caddy:rX"
    ];
  })

  # Kanidm login for the :8090 view.
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

    # Caddy no longer reads /var/lib/paperless. Removing the tmpfiles ACL
    # rules does not revoke ACLs already set, so strip them once by hand on
    # the server (needed since the 2026-10-25 switch to dropbox-mirror.nix):
    #   sudo setfacl -R -x u:caddy -k /var/lib/paperless/media
    #   sudo setfacl -x u:caddy /var/lib/paperless

    networking.firewall.allowedTCPPorts = [ 8090 ];
  }
]
