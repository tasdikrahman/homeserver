{ config, pkgs, tailscaleHost, ... }:

# Paperless-ngx setup instructions:
#
# Do steps 1-4 BEFORE this module is deployed. Paperless refuses to start
# without PAPERLESS_SECRET_KEY and Postgres refuses to initialise without
# POSTGRES_PASSWORD, so with empty placeholder files all three containers just
# restart in a loop.
#
# 1. Create the secrets directory:
#    sudo mkdir -p /etc/paperless
#
# 2. Generate a Postgres password and a secret key:
#    openssl rand -hex 32      # Postgres password (hex: safe to use unquoted)
#    openssl rand -hex 64      # secret key
#
# 3. Write the Postgres secret (used by the paperless-db container):
#    sudo install -m 600 /dev/null /etc/paperless/db-secrets
#    echo "POSTGRES_PASSWORD=<postgres-password>" | sudo tee /etc/paperless/db-secrets > /dev/null
#
# 4. Write the Paperless secrets (same Postgres password). The admin account
#    is only created if it does not exist yet, so the password here is a
#    bootstrap value — change it in the UI afterwards if you like.
#    sudo install -m 600 /dev/null /etc/paperless/secrets
#    printf 'PAPERLESS_SECRET_KEY=<secret-key>\nPAPERLESS_DBPASS=<postgres-password>\nPAPERLESS_ADMIN_USER=admin\nPAPERLESS_ADMIN_PASSWORD=<your-admin-password>\n' \
#      | sudo tee /etc/paperless/secrets > /dev/null
#
# Access the UI at: https://<tailscaleHost>:8000
#
# Restoring: the nightly export in /var/lib/paperless/export is the supported
# restore path (`document_importer`), and it works across Paperless versions.
# The Postgres data directory is deliberately not backed up — see restic.nix.

{
  # Postgres database for Paperless.
  virtualisation.oci-containers.containers.paperless-db = {
    # Exact minor, not a floating tag — see the note in miniflux.nix.
    image = "postgres:18.6-alpine";
    extraOptions = [ "--network=host" ];
    # Postgres 18 images keep their data under /var/lib/postgresql/<major>/,
    # so the mount point is the parent directory, not .../data as with 17.
    volumes = [ "/var/lib/paperless-db:/var/lib/postgresql" ];
    environment = {
      POSTGRES_DB   = "paperless";
      POSTGRES_USER = "paperless";
      PGPORT        = "15433";
    };
    # With host networking the container shares the host's interfaces, and
    # tailscale0 is a trusted interface in the firewall — anything listening on
    # 0.0.0.0 is reachable from every device on the tailnet. Loopback only.
    cmd = [ "-c" "listen_addresses=127.0.0.1" ];
    environmentFiles = [ "/etc/paperless/db-secrets" ];
    autoStart = true;
  };

  # Task broker for Paperless (Valkey, the Redis fork upstream now ships with).
  # Holds only the task queue, so nothing is persisted.
  virtualisation.oci-containers.containers.paperless-broker = {
    image = "valkey/valkey:9.1.2-alpine";
    extraOptions = [ "--network=host" ];
    # No authentication is configured, so the loopback bind is what protects
    # it — same reasoning as listen_addresses above.
    cmd = [ "valkey-server" "--bind" "127.0.0.1" "--port" "16379" "--save" "" "--appendonly" "no" ];
    autoStart = true;
  };

  virtualisation.oci-containers.containers.paperless = {
    image = "ghcr.io/paperless-ngx/paperless-ngx:3.3.0";
    extraOptions = [
      "--network=host"
      # OCR is by far the heaviest workload on this 8 GB machine. Cap it so a
      # runaway job is killed inside the container instead of pushing the
      # whole box into memory pressure.
      "--memory=2g"
      # The image's built-in healthcheck is hard-coded to localhost:8000. With
      # host networking that is Caddy's TLS port, not Paperless, so it would
      # report the container unhealthy forever. Point it at the real port.
      "--health-cmd=curl -fsS -L --max-time 2 http://127.0.0.1:18000"
    ];
    volumes = [
      "/var/lib/paperless/data:/usr/src/paperless/data"
      "/var/lib/paperless/media:/usr/src/paperless/media"
      "/var/lib/paperless/export:/usr/src/paperless/export"
      "/var/lib/paperless/consume:/usr/src/paperless/consume"
      # Podman strips the host nameserver (100.100.100.100, Tailscale MagicDNS)
      # from the container's /etc/resolv.conf. Same fix as miniflux/actual, and
      # required for the OIDC discovery URL (a .ts.net name) once SSO is added.
      "/etc/resolv.conf:/etc/resolv.conf:ro"
    ];
    environment = {
      # Listens on 18000 internally to avoid clashing with Caddy on 8000. The
      # default bind address is `::` (all interfaces), hence the explicit one.
      PAPERLESS_PORT      = "18000";
      PAPERLESS_BIND_ADDR = "127.0.0.1";
      PAPERLESS_URL       = "https://${tailscaleHost}:8000";

      # Must be set explicitly since 3.x — the default engine is SQLite.
      PAPERLESS_DBENGINE = "postgresql";
      PAPERLESS_DBHOST   = "127.0.0.1";
      PAPERLESS_DBPORT   = "15433";
      PAPERLESS_REDIS    = "redis://127.0.0.1:16379";

      PAPERLESS_TIME_ZONE    = "Europe/Berlin";
      # German and English both ship in the image; no extra language install.
      PAPERLESS_OCR_LANGUAGE = "deu+eng";

      # Keep the footprint small: one consumer task at a time, one web worker.
      PAPERLESS_TASK_WORKERS       = "1";
      PAPERLESS_THREADS_PER_WORKER = "2";
      PAPERLESS_WEBSERVER_WORKERS  = "1";

      # The container starts as root and drops to this uid/gid for everything
      # it writes. Must match the ownership of /var/lib/paperless below.
      USERMAP_UID = "1000";
      USERMAP_GID = "1000";
    };
    environmentFiles = [ "/etc/paperless/secrets" ];
    dependsOn = [ "paperless-db" "paperless-broker" ];
    autoStart = true;
  };

  # A started container is not a ready database — see the note in miniflux.nix.
  # The delay keeps restarts under systemd's start limit so Paperless retries
  # until Postgres accepts connections instead of ending up failed.
  systemd.services.podman-paperless.serviceConfig.RestartSec = "5s";

  # Nightly export, timed to finish before the 02:00 restic run. This is what
  # gets backed up rather than the live Postgres data directory, which restic
  # would copy file by file while the database is writing to it.
  systemd.services.paperless-export = {
    description = "Export Paperless documents and metadata for backup";
    after = [ "podman-paperless.service" ];
    serviceConfig = {
      Type = "oneshot";
      # A timer never re-triggers a unit that is still running, so a hung
      # export must not be able to hold this unit active forever.
      TimeoutStartSec = "25min";
    };
    script = ''
      /run/current-system/sw/bin/podman exec paperless \
        document_exporter /usr/src/paperless/export \
        --compare-checksums --delete --no-progress-bar
    '';
  };

  systemd.timers.paperless-export = {
    description = "Nightly Paperless export ahead of the restic backup";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "01:30";
      Persistent = true;
    };
  };

  systemd.tmpfiles.rules = [
    "d /var/lib/paperless         0750 1000 1000 -"
    "d /var/lib/paperless/data    0750 1000 1000 -"
    "d /var/lib/paperless/media   0750 1000 1000 -"
    "d /var/lib/paperless/export  0750 1000 1000 -"
    "d /var/lib/paperless/consume 0750 1000 1000 -"
    # postgres:*-alpine runs as uid/gid 70 inside the container.
    "d /var/lib/paperless-db 0750 70 70 -"
    # Placeholder files so NixOS activation doesn't fail if secrets haven't been written yet.
    "f /etc/paperless/db-secrets 0600 root root -"
    "f /etc/paperless/secrets    0600 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 8000 ];
}
