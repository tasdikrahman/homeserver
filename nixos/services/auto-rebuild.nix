{ pkgs, username, ... }:

{
  systemd.tmpfiles.rules = [
    # Tracks the last commit actually applied via `nixos-rebuild switch`,
    # separate from the git repo's HEAD — see comment in the service script.
    "d /var/lib/nixos-auto-rebuild 0750 root root -"
  ];

  systemd.services.nixos-auto-rebuild = {
    description = "Pull homeserver repo and run nixos-rebuild switch if new commits exist";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    # systemd services don't inherit the NIX_PATH an interactive root shell
    # gets from /etc/set-environment via PAM. Without it, `nixos-rebuild
    # switch` fails with "file 'nixpkgs/nixos' was not found in the Nix
    # search path" — and since the git pull above already fast-forwards
    # before this runs, the failure goes unnoticed: the next run just sees
    # "already up to date" and skips retrying the rebuild forever.
    environment = {
      NIX_PATH = "/root/.nix-defexpr/channels:nixpkgs=/nix/var/nix/profiles/per-user/root/channels/nixos:nixos-config=/etc/nixos/configuration.nix:/nix/var/nix/profiles/per-user/root/channels";
    };
    script = ''
      set -euo pipefail
      REPO="/home/${username}/development/src/github.com/${username}/homeserver"
      RUN_AS="/run/current-system/sw/bin/runuser -u ${username} --"
      # Tracks the last commit actually applied via a successful
      # `nixos-rebuild switch`. Deliberately separate from git HEAD: HEAD
      # advances as soon as `git pull` runs, so comparing against HEAD alone
      # means a failed switch (e.g. a NIX_PATH or eval error) gets silently
      # treated as "already up to date" on every later run and never retried.
      STATE_FILE="/var/lib/nixos-auto-rebuild/last-applied-commit"

      $RUN_AS ${pkgs.git}/bin/git -C "$REPO" fetch origin main

      LOCAL=$($RUN_AS ${pkgs.git}/bin/git -C "$REPO" rev-parse HEAD)
      REMOTE=$($RUN_AS ${pkgs.git}/bin/git -C "$REPO" rev-parse origin/main)
      LAST_APPLIED=""
      if [ -f "$STATE_FILE" ]; then
        LAST_APPLIED=$(cat "$STATE_FILE")
      fi

      if [ "$LAST_APPLIED" = "$REMOTE" ]; then
        echo "Already applied ($REMOTE)."
        exit 0
      fi

      echo "Pulling..."
      $RUN_AS ${pkgs.git}/bin/git -C "$REPO" pull --ff-only origin main
      echo "New commits since last applied ($LAST_APPLIED):"
      $RUN_AS ${pkgs.git}/bin/git -C "$REPO" --no-pager log --oneline "$LOCAL..HEAD"

      echo "Running nixos-rebuild switch..."
      /run/current-system/sw/bin/nixos-rebuild switch

      echo "$REMOTE" > "$STATE_FILE"
    '';
  };

  systemd.timers.nixos-auto-rebuild = {
    description = "Check for homeserver repo updates every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "5min";
      Unit = "nixos-auto-rebuild.service";
    };
  };
}
