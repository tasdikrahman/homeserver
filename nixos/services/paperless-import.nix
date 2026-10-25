{ config, pkgs, ... }:

# Nightly import of new documents from the Dropbox mirror into Paperless.
#
# Runs paperless-import/import.py against /var/lib/dropbox-mirror (the
# Syncthing copy of the laptop's ~/Dropbox, see dropbox-mirror.nix), then
# set_folders.py, which files each new document under its Dropbox folder
# (PAPERLESS_FILENAME_FORMAT in paperless.nix). It only ever adds: nothing is
# deleted or moved in Paperless, and a file it already has is skipped. Files
# that failed once are skipped too; retry them by hand with --retry-failed.
#
# 01:00, so new documents are in the 01:30 export and the 02:00 restic run.
# Run it any time with `sudo systemctl start paperless-import`, and read the
# result with `journalctl -u paperless-import`.
#
# --- One-time setup, on the server, BEFORE pushing this (done 2026-10-25) --
#
# Everything here is personal, and this repo is public, so none of it is in
# git. From the laptop, scp these to /tmp on the server:
#   - config.json: ~/.config/paperless-import/config.json with "host" set to
#     "http://127.0.0.1:18000" (format: paperless-import/config.example.json)
#   - token: ~/.config/paperless/token. A copy, not a new token: Paperless has
#     one per user, and regenerating it would break the laptop's.
#   - state.jsonl: ~/.local/state/paperless-import/state.jsonl. Its paths are
#     relative to the Dropbox root, and the mirror has the same layout.
# Then on the server:
#   sudo install -d -m 700 /etc/paperless-import
#   sudo install -m 600 /tmp/pi-config.json /etc/paperless-import/config.json
#   sudo install -m 600 /tmp/token /etc/paperless-import/token
#   sudo install -d -m 755 /var/lib/paperless-import
#   sudo install -m 600 /tmp/state.jsonl /var/lib/paperless-import/state.jsonl
#   rm /tmp/pi-config.json /tmp/token /tmp/state.jsonl
# systemd hands the two /etc files to the unit as credentials and takes over
# ownership of /var/lib/paperless-import (StateDirectory) on the first run.

let
  python = pkgs.python3.withPackages (ps: [ ps.requests ]);
  # Copied into the store as a whole: set_folders.py imports import.py from
  # its own directory.
  scripts = ./paperless-import;
in
{
  users.users.paperless-import = {
    isSystemUser = true;
    group = "paperless-import";
    # The mirror is 0750 syncthing:syncthing; read access only.
    extraGroups = [ "syncthing" ];
  };
  users.groups.paperless-import = { };

  systemd.services.paperless-import = {
    description = "Import new documents from the Dropbox mirror into Paperless";
    after = [ "podman-paperless.service" "syncthing.service" ];
    environment = {
      # %d is the unit's credentials directory (LoadCredential below).
      PAPERLESS_IMPORT_CONFIG = "%d/config";
      PAPERLESS_TOKEN_FILE = "%d/token";
      PAPERLESS_IMPORT_STATE = "/var/lib/paperless-import/state.jsonl";
      PYTHONUNBUFFERED = "1";
    };
    serviceConfig = {
      Type = "oneshot";
      User = "paperless-import";
      Group = "paperless-import";
      ExecStart = [
        "${python}/bin/python3 ${scripts}/import.py --root /var/lib/dropbox-mirror"
        "${python}/bin/python3 ${scripts}/set_folders.py --apply"
      ];
      # Root-only files, readable by this unit alone, only while it runs.
      LoadCredential = [
        "config:/etc/paperless-import/config.json"
        "token:/etc/paperless-import/token"
      ];
      StateDirectory = "paperless-import";
      StateDirectoryMode = "0700";
      # A timer never re-triggers a unit that is still running, so a hung
      # import must not be able to hold this unit active forever.
      TimeoutStartSec = "2h";

      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateDevices = true;
      NoNewPrivileges = true;
      ReadOnlyPaths = [ "/var/lib/dropbox-mirror" ];
      # Talks to Paperless on 127.0.0.1 only.
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
    };
  };

  systemd.timers.paperless-import = {
    description = "Nightly import of new documents into Paperless";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:00";
      Persistent = true;
    };
  };

  # The run state: which files are already in Paperless.
  services.restic.backups.hetzner.paths = [ "/var/lib/paperless-import" ];
}
