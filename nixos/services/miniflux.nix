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
    image = "postgres:17-alpine";
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
    image = "miniflux/miniflux:2.2.19";
    extraOptions = [ "--network=host" ];
    environment = {
      LISTEN_ADDR    = "127.0.0.1:18080";
      RUN_MIGRATIONS = "1";
      CREATE_ADMIN   = "1";
    };
    environmentFiles = [ "/etc/miniflux/secrets" ];
    autoStart = true;
  };

  systemd.tmpfiles.rules = [
    # postgres:17-alpine runs as uid 999 inside the container.
    "d /var/lib/miniflux-db 0750 999 999 -"
    "f /etc/miniflux/db-secrets 0600 root root -"
    "f /etc/miniflux/secrets    0600 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 8080 ];
}
