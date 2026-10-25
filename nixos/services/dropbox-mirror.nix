{ config, lib, pkgs, tailscaleHost, syncthingLaptopId, ... }:

# Read-only copy of the laptop's ~/Dropbox, kept current by Syncthing and
# shown on :8090 (caddy.nix) behind the same Kanidm login as before
# (paperless-files.nix).
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
# --- One-time setup -------------------------------------------------------
#
# 1. Laptop: install Syncthing and read its device ID (not a secret: it is a
#    certificate fingerprint, and only devices listed below are accepted):
#      sudo apt install syncthing
#      systemctl --user enable --now syncthing
#      syncthing device-id        # older versions: syncthing --device-id
#    Then, on the server, add it to nixos/local.nix (gitignored) as
#      syncthingLaptopId = "<id>";
#    Until it is set, this whole module is off. Not a secret, but the repo is
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

let
  mirror = "/var/lib/dropbox-mirror";
in
lib.mkIf (syncthingLaptopId != null) {
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
}
