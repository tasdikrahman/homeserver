{ config, tailscaleHost, ... }:

# Miniflux setup instructions:
#
# 1. Create the secrets directory:
#    sudo mkdir -p /etc/miniflux
#
# 2. Generate a strong Postgres password:
#    openssl rand -base64 32
#
# 3. Write the Postgres secret (used by the miniflux-db container):
#    sudo install -m 600 /dev/null /etc/miniflux/db-secrets
#    echo "POSTGRES_PASSWORD=<your-generated-password>" | sudo tee /etc/miniflux/db-secrets > /dev/null
#
# 4. Write the Miniflux application secrets (use the same Postgres password):
#    sudo install -m 600 /dev/null /etc/miniflux/secrets
#    printf 'DATABASE_URL=postgresql://miniflux:<your-generated-password>@127.0.0.1:15432/miniflux?sslmode=disable\nADMIN_USERNAME=admin\nADMIN_PASSWORD=<your-admin-password>\n' \
#      | sudo tee /etc/miniflux/secrets > /dev/null
#
# 5. After nixos-rebuild switch, restart containers in order:
#    sudo systemctl restart podman-miniflux-db.service
#    sudo systemctl restart podman-miniflux.service
#
# Access the UI at: https://<tailscaleHost>:8080

{
  # Postgres database for Miniflux.
  # Listens on 127.0.0.1:15432 — not exposed to the network.
  virtualisation.oci-containers.containers.miniflux-db = {
    # Pinned to an exact minor rather than the floating `17-alpine` tag: Podman
    # never re-pulls a tag it already has locally, so a floating tag silently
    # stays on whichever minor it first pulled and never picks up security
    # fixes. Bumping the minor is safe in place; a major (18) needs a
    # dump/restore of /var/lib/miniflux-db.
    image = "postgres:17.11-alpine";
    extraOptions = [ "--network=host" ];
    volumes = [ "/var/lib/miniflux-db:/var/lib/postgresql/data" ];
    environment = {
      POSTGRES_DB   = "miniflux";
      POSTGRES_USER = "miniflux";
      PGPORT        = "15432";
    };
    environmentFiles = [ "/etc/miniflux/db-secrets" ];
    autoStart = true;
  };

  virtualisation.oci-containers.containers.miniflux = {
    image = "miniflux/miniflux:2.3.3";
    extraOptions = [ "--network=host" ];
    # Podman strips the host nameserver (100.100.100.100, Tailscale MagicDNS) when
    # generating the container's /etc/resolv.conf, leaving it without a nameserver.
    # Miniflux (Go) then falls back to 127.0.0.1:53 and all feed lookups fail with
    # "connection refused". Bind-mount the host's working resolv.conf instead.
    volumes = [ "/etc/resolv.conf:/etc/resolv.conf:ro" ];
    environment = {
      LISTEN_ADDR    = "127.0.0.1:18080";
      RUN_MIGRATIONS = "1";
      CREATE_ADMIN   = "1";
    };
    environmentFiles = [ "/etc/miniflux/secrets" ];
    # Orders this unit after podman-miniflux-db and restarts it with the DB.
    dependsOn = [ "miniflux-db" ];
    autoStart = true;
  };

  # Ordering alone is not enough: the DB unit counts as started as soon as the
  # container is up, a second or two before Postgres accepts connections.
  # Miniflux exits immediately on "connection refused", and with systemd's
  # default 100ms restart delay it burned through the start limit (5 starts in
  # 10s) in under a second and stayed failed. Seen 2026-10-11 when a switch
  # restarted both containers: `switch-to-configuration` returned exit 4 and
  # auto-rebuild reported a failed deploy, although the config itself was fine.
  # A 5s delay keeps retries under the start limit, so it retries until the DB
  # is ready instead of giving up.
  systemd.services.podman-miniflux.serviceConfig.RestartSec = "5s";

  systemd.tmpfiles.rules = [
    # postgres:17-alpine runs as uid/gid 70 inside the container — must match here
    # or postgres cannot read its own data directory (pg_logical/snapshots etc).
    "d /var/lib/miniflux-db 0750 70 70 -"
    # Placeholder files so NixOS activation doesn't fail if secrets haven't been written yet.
    "f /etc/miniflux/db-secrets 0600 root root -"
    "f /etc/miniflux/secrets    0600 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
