{ pkgs, username, ... }:

{
  systemd.services.nixos-auto-rebuild = {
    description = "Pull homeserver repo and run nixos-rebuild switch if new commits exist";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
    };
    script = ''
      set -euo pipefail
      REPO="/home/${username}/development/src/github.com/${username}/homeserver"
      RUN_AS="/run/current-system/sw/bin/runuser -u ${username} --"

      $RUN_AS ${pkgs.git}/bin/git -C "$REPO" fetch origin main

      LOCAL=$($RUN_AS ${pkgs.git}/bin/git -C "$REPO" rev-parse HEAD)
      REMOTE=$($RUN_AS ${pkgs.git}/bin/git -C "$REPO" rev-parse origin/main)

      if [ "$LOCAL" = "$REMOTE" ]; then
        echo "Already up to date ($LOCAL)."
        exit 0
      fi

      echo "New commits detected. Pulling..."
      $RUN_AS ${pkgs.git}/bin/git -C "$REPO" pull --ff-only origin main
      echo "Applied:"
      $RUN_AS ${pkgs.git}/bin/git -C "$REPO" --no-pager log --oneline "$LOCAL..HEAD"

      echo "Running nixos-rebuild switch..."
      /run/current-system/sw/bin/nixos-rebuild switch
    '';
  };

  systemd.timers.nixos-auto-rebuild = {
    description = "Check for homeserver repo updates every 5 minutes";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2min";
      OnUnitActiveSec = "15min";
      Unit = "nixos-auto-rebuild.service";
    };
  };
}
