# homeserver

NixOS configuration for a self-hosted home server. All services are accessible only over [Tailscale](https://tailscale.com/) — nothing is exposed to the public internet.

## Hardware

- Lenovo ThinkCentre M75q Gen 2 running NixOS 26.05
- Root filesystem on LUKS-encrypted ext4, unlocked automatically at boot by the TPM (passphrase kept as fallback — see [Disk encryption](#disk-encryption))
- Connected over WiFi (`wlp2s0`)

## Architecture

```
Tailscale VPN (tailscale0)
        │
        ├── :443   → Caddy → landing page
        ├── :3000  → Caddy → Grafana          (port 13000 internally)
        ├── :3002  → Caddy → SilverBullet     (port 13002 internally)
        ├── :5006  → Caddy → Actual Budget    (port 15006 internally)
        ├── :8000  → Caddy → Paperless-ngx    (port 18000 internally)
        ├── :8080  → Caddy → Miniflux         (port 18080 internally)
        ├── :8090  → Caddy → Paperless files  (read-only, Kanidm login via oauth2-proxy on 14180)
        ├── :8443  → Kanidm (identity provider, TLS direct)
        ├── :9090  → Caddy → Prometheus       (port 19090 internally)
        └── :9093  → Caddy → Alertmanager     (port 19093 internally)
```

All services run as Podman containers with host networking (except Kanidm, which is a native NixOS service). Each binds to an internal `1XXXX` port on loopback and Caddy serves it on the well-known port `XXXX`.

All HTTPS services use a Tailscale-signed TLS certificate provisioned by `tailscale cert` and renewed weekly. Caddy terminates TLS for everything except Kanidm, which terminates TLS itself.

## Services

### Actual Budget
Self-hosted personal finance app. OIDC login is handled by Kanidm.

- URL: `https://<tailscale-host>:5006`

**First-time setup:**
```bash
sudo mkdir -p /etc/actual
sudo install -m 600 /dev/null /etc/actual/oidc-secret
echo "ACTUAL_OPENID_CLIENT_SECRET=<secret>" | sudo tee /etc/actual/oidc-secret
```

Get the secret from: `kanidm oauth2 show-basic-secret actual-budget`

**Note on Sync & Connectivity (NextDNS/Tailscale):**
If you use NextDNS and cannot reach the `.ts.net` endpoints (or sync fails), you must integrate NextDNS directly into Tailscale to prevent DNS conflicts:
1. Go to **Tailscale Admin Console > DNS**.
2. Add your **NextDNS Configuration ID** as a Global Nameserver.
3. Enable **"Override local DNS"**.
4. Enable **"Use with exit node"** in the NextDNS settings within Tailscale.
5. Disable any standalone NextDNS apps/profiles on your devices.

**Verifying the setup:**
- Visit [test.nextdns.io](https://test.nextdns.io) on your device.
- It should show `status: "ok"` and `protocol: "DOH"`.
- Visit [dnsleaktest.com](https://www.dnsleaktest.com) to ensure your DNS queries are going to NextDNS and not your ISP.

### Kanidm
Identity provider that issues OIDC tokens for Actual Budget and SilverBullet. Handles its own TLS directly on port 8443 using the Tailscale cert. Adding a user and the OAuth2 client setup are documented at the top of `nixos/services/kanidm.nix`.

- URL: `https://<tailscale-host>:8443`
- CLI: `kanidm` (installed system-wide)

### Paperless-ngx
Document archive with OCR (German and English). The app (internal port 18000), Postgres and a Valkey task broker run with host networking, the last two bound to loopback only. Tika and Gotenberg convert Office files and emails; they run on Podman's bridge network, reachable from loopback only. A nightly export at 01:30 feeds the restic backup.

- URL: `https://<tailscale-host>:8000`
- Files are stored in the same folder tree as Dropbox (`PAPERLESS_FILENAME_FORMAT`, from each document's "Dropbox folder" custom field); uploads made after the import land in `inbox/<year>/`.
- Files: `https://<tailscale-host>:8090` — read-only folder view of `media/documents` (`originals/` and `archive/`), served by Caddy's `file_server browse`, with Kanidm login through oauth2-proxy (internal port 14180). Setup and ACLs are in `nixos/services/paperless-files.nix`.

### SilverBullet
Markdown notes. One container listening internally on port 13002. Accounts, spaces and Kanidm SSO are managed in its own Dashboard; there are no secret files. Full-text search is the Silversearch library, installed inside each space from `Library/Std/Pages/Library Manager` (search with `Ctrl-s`); it indexes in the browser and needs no server config.

- URL: `https://<tailscale-host>:3002`

### Miniflux
RSS reader, with its own Postgres container on `127.0.0.1:15432`.

- URL: `https://<tailscale-host>:8080`

### Prometheus, Alertmanager and Grafana
Prometheus scrapes itself, Alertmanager, node-exporter and a blackbox-exporter that probes every service's HTTPS endpoint. Data is retained for 7 days and capped at 2 GB by design. Alerts (service down, high CPU/memory, low disk, failed or stale backups, unexpected reboot) go through Alertmanager to Telegram. Grafana is the dashboard layer.

- Prometheus: `https://<tailscale-host>:9090`
- Alertmanager: `https://<tailscale-host>:9093`
- Grafana: `https://<tailscale-host>:3000`

### Restic backups
Nightly at 02:00 to Hetzner Object Storage (S3), with 7 daily / 4 weekly / 12 monthly retention. Covers `/etc` and each service's data directory; Paperless is backed up through its nightly export rather than its live Postgres directory.

### Caddy
Reverse proxy and TLS terminator for every service except Kanidm. Uses a Tailscale-signed certificate stored at `/var/lib/caddy/tls/`.

### Tailscale
Mesh VPN that provides private connectivity between all devices. The `tailscale0` interface is fully trusted in the firewall — all service ports are only accessible to devices on the Tailscale network. Node key expiry is disabled for this machine in the Tailscale admin console; an expired key silently takes every service offline.

## Security

- Firewall denies all inbound traffic by default; `tailscale0` is the only trusted interface (SSH on port 22 is also open on the LAN, as an escape hatch for when Tailscale is down)
- SSH: key-only auth, no root login, max 3 attempts, 20s grace timeout, allowlist of permitted users
- fail2ban monitors auth logs and bans IPs that repeatedly fail authentication
- Kernel hardening: SYN cookies, reverse path filtering, ICMP redirect rejection
- sudo requires a password even for wheel group members
- sshd has elevated CPU priority and OOM protection so it stays reachable under load
- Hardware watchdog and auto-reboot on kernel panic
- Auto-upgrades apply NixOS updates nightly from the pinned channel (reboot required manually for kernel updates)
- LUKS full-disk encryption with TPM2 auto-unlock

## Disk encryption

The root partition is LUKS2. The systemd initrd tries the TPM first (`tpm2-device=auto`), so the box comes back on its own after reboots and power cuts, and falls back to the passphrase prompt if the TPM refuses. The key is sealed to PCR 7 (Secure Boot state), which kernel updates don't change.

Keyslots are set up by hand on the server, not in Nix:

```bash
sudo systemd-cryptenroll --recovery-key /dev/disk/by-uuid/<luks-uuid>   # store it off this machine
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=7 /dev/disk/by-uuid/<luks-uuid>
```

Keyslot 0 is the passphrase, 1 the recovery key and 2 the TPM. After a BIOS update or TPM reset, type the passphrase at the console and re-enroll with `--wipe-slot=tpm2` added to the second command.

For the box to come back after a power cut at all, the BIOS setting **Power → After Power Loss** (F1 at boot) must be **Power On**. This is not something Nix can configure.

Tradeoff: without Secure Boot, the TPM releases the key to anything that boots on this machine. The encryption protects a disk that leaves the machine (repair, disposal), not a stolen machine. Clear the TPM or run `cryptsetup luksErase` before the disk leaves the house.

## File layout

```
nixos/
├── configuration.nix               # Base system: users, networking, SSH, security, boot, packages
├── containers.nix                  # Podman setup and OCI container backend
├── hardware-configuration.nix      # Auto-generated hardware config (do not edit)
├── local.nix                       # Machine-specific values (gitignored — see local.nix.example)
├── local.nix.example               # Template for local.nix
└── services/
    ├── actual-budget.nix           # Actual Budget container
    ├── alertmanager.nix            # Alertmanager container, Telegram routing
    ├── auto-rebuild.nix            # Pulls origin/main every 5 min and runs nixos-rebuild switch
    ├── caddy.nix                   # Caddy reverse proxy + Tailscale TLS cert provisioning
    ├── grafana.nix                 # Grafana container
    ├── kanidm.nix                  # Kanidm identity provider (OIDC)
    ├── miniflux.nix                # Miniflux and its Postgres containers
    ├── paperless.nix               # Paperless-ngx, Postgres, Valkey, Tika, Gotenberg, nightly export
    ├── paperless-files.nix         # Read-only file view of the documents: oauth2-proxy (Kanidm SSO), ACLs
    ├── prometheus.nix              # Prometheus, blackbox-exporter, node-exporter, alert rules
    ├── restic.nix                  # Nightly restic backup to Hetzner Object Storage
    └── silverbullet.nix            # SilverBullet notes container
```

## Local configuration

Machine-specific values live in `nixos/local.nix`, which is gitignored. Copy the example and fill in your values:

```bash
cp nixos/local.nix.example nixos/local.nix
# edit nixos/local.nix: hostname, tailscaleHost, username, sshPublicKey, resticRepository
```

## Persistent data

| Path | Service |
|------|---------|
| `/var/lib/actual` | Actual Budget database |
| `/var/lib/prometheus` | Prometheus TSDB |
| `/var/lib/alertmanager` | Alertmanager |
| `/var/lib/grafana` | Grafana |
| `/var/lib/caddy/tls` | Tailscale TLS cert and key |
| `/var/lib/kanidm` | Kanidm database |
| `/var/lib/miniflux-db` | Miniflux's Postgres data |
| `/var/lib/paperless` | Paperless documents, nightly export, search index |
| `/var/lib/paperless-db` | Paperless's Postgres data |
| `/var/lib/silverbullet` | SilverBullet notes, accounts and SSO settings |
| `/var/lib/nixos-auto-rebuild` | Last commit auto-rebuild applied |

## Secret files (not in git)

Each module documents how to create its files at the top.

| Path | Contents |
|------|---------|
| `nixos/local.nix` | `hostname`, `tailscaleHost`, `username`, `sshPublicKey`, `resticRepository` |
| `/etc/actual/oidc-secret` | `ACTUAL_OPENID_CLIENT_SECRET=...` |
| `/etc/grafana/secrets` | `GF_SECURITY_ADMIN_PASSWORD=...` |
| `/etc/alertmanager/bot_token`, `/etc/alertmanager/chat_id` | Telegram bot token and chat ID |
| `/etc/miniflux/db-secrets` | `POSTGRES_PASSWORD=...` |
| `/etc/miniflux/secrets` | `DATABASE_URL`, admin username and password |
| `/etc/paperless/secrets` | `PAPERLESS_SECRET_KEY`, `PAPERLESS_DBPASS`, bootstrap admin user and password |
| `/etc/paperless/db-secrets` | `POSTGRES_PASSWORD=...` |
| `/etc/oauth2-proxy/client-secret` | Kanidm `paperless-files` client secret, bare value, no newline (Paperless file view) |
| `/etc/oauth2-proxy/cookie-secret` | 32 hex chars, no newline: oauth2-proxy session cookie key |
| `/etc/restic/password` | Restic repository password |
| `/etc/restic/env` | Hetzner S3 access key and secret |

## Initial setup on a new machine

Clone the repo to the path auto-rebuild expects, and create `local.nix` from the example:

```bash
git clone https://github.com/tasdikrahman/homeserver ~/development/src/github.com/tasdikrahman/homeserver
cd ~/development/src/github.com/tasdikrahman/homeserver
cp nixos/local.nix.example nixos/local.nix
# edit local.nix with your hostname, tailscaleHost, username, sshPublicKey and resticRepository
```

Symlink the config files into `/etc/nixos/` so `nixos-rebuild` picks them up:

```bash
sudo ln -sf ~/development/src/github.com/tasdikrahman/homeserver/nixos/configuration.nix /etc/nixos/configuration.nix
sudo ln -sf ~/development/src/github.com/tasdikrahman/homeserver/nixos/containers.nix /etc/nixos/containers.nix
sudo ln -sf ~/development/src/github.com/tasdikrahman/homeserver/nixos/services /etc/nixos/services
```

`hardware-configuration.nix` is machine-specific — keep the one generated by the installer at `/etc/nixos/hardware-configuration.nix` and do not symlink it from this repo.

Then apply once by hand; after that, auto-rebuild takes over:

```bash
sudo nixos-rebuild switch
```

Then create the secret files listed above, and enroll the TPM (see [Disk encryption](#disk-encryption)).

## Applying changes

Push to `main`. `nixos-auto-rebuild.timer` on the server polls `origin/main` every 5 minutes, fast-forwards the checkout and runs `nixos-rebuild switch`. Every push to `main` is a production deploy. Check what was last applied with:

```bash
cat /var/lib/nixos-auto-rebuild/last-applied-commit
sudo journalctl -u nixos-auto-rebuild -n 40 --no-pager
```

## TODO

- [ ] Bump the channel to NixOS 26.11 before 26.05 goes end-of-life on 2026-12-31
- [ ] Test a restore from the restic backup
- [ ] Back up Miniflux through `pg_dump` instead of its live Postgres directory

## Adding a new service

1. Bind the container to an internal port (e.g. `1XXXX`) on `127.0.0.1`
2. Create `nixos/services/<name>.nix` accepting `{ config, pkgs, tailscaleHost, ... }`
3. Add a Caddy `virtualHost` on the external port (`XXXX`) in `caddy.nix`
4. Add the external port to `networking.firewall.allowedTCPPorts` in the new service file
5. Add a `tmpfiles` rule for the persistent data directory
6. Add the data directory to the restic paths in `restic.nix` (or a dump/export step for databases)
7. Import the new file in `configuration.nix`
