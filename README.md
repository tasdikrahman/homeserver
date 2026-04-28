# homeserver

NixOS configuration for a self-hosted home server. All services are accessible only over [Tailscale](https://tailscale.com/) — nothing is exposed to the public internet.

## Hardware

- Machine running NixOS 25.11
- Root filesystem on LUKS-encrypted ext4
- Connected over WiFi (`wlp2s0`)

## Architecture

```
Tailscale VPN (tailscale0)
        │
        ├── :53   → Pi-hole (DNS ad blocker)
        ├── :5006  → Caddy → Actual Budget (port 15006 internally)
        ├── :8080  → Caddy → Pi-hole web UI (port 15080 internally)
        └── :8443  → Kanidm (identity provider, TLS direct)
```

All HTTPS services use a Tailscale-signed TLS certificate provisioned by `tailscale cert` and renewed weekly. Caddy handles TLS termination for Actual Budget and Pi-hole. Kanidm terminates TLS itself.

## Services

### Pi-hole
DNS-level ad and tracker blocker. Runs as a Podman container with host networking so it can bind to port 53 on all interfaces. All Tailscale devices use it as their DNS server via the Tailscale admin console nameserver setting.

- Web UI: `https://<tailscale-host>:8080/admin`
- DNS: port 53 on the Tailscale IP

**First-time setup:**
```bash
sudo mkdir -p /etc/pihole
sudo install -m 600 /dev/null /etc/pihole/webpassword
echo "WEBPASSWORD=<your-password>" | sudo tee /etc/pihole/webpassword
```

### Actual Budget
Self-hosted personal finance app. Runs as a Podman container with host networking. OIDC login is handled by Kanidm.

- URL: `https://<tailscale-host>:5006`

**First-time setup:**
```bash
sudo mkdir -p /etc/actual
sudo install -m 600 /dev/null /etc/actual/oidc-secret
echo "ACTUAL_OPENID_CLIENT_SECRET=<secret>" | sudo tee /etc/actual/oidc-secret
```

Get the secret from: `kanidm oauth2 show-basic-secret actual-budget`

### Kanidm
Identity provider that issues OIDC tokens for services like Actual Budget. Handles its own TLS directly on port 8443 using the Tailscale cert.

- URL: `https://<tailscale-host>:8443`
- CLI: `kanidm` (installed system-wide)

### Caddy
Reverse proxy and TLS terminator for Actual Budget and Pi-hole web UI. Uses a Tailscale-signed certificate stored at `/var/lib/caddy/tls/`.

### Tailscale
Mesh VPN that provides private connectivity between all devices. The `tailscale0` interface is fully trusted in the firewall — all service ports are only accessible to devices on the Tailscale network.

## Security

- Firewall denies all inbound traffic by default; `tailscale0` is the only trusted interface
- SSH: key-only auth, no root login, max 3 attempts, 20s grace timeout, allowlist of permitted users
- fail2ban monitors auth logs and bans IPs that repeatedly fail authentication
- Kernel hardening: SYN cookies, reverse path filtering, ICMP redirect rejection
- sudo requires a password even for wheel group members
- sshd has elevated CPU priority and OOM protection so it stays reachable under load
- Auto-upgrades apply NixOS updates automatically (reboot required manually for kernel updates)
- LUKS full-disk encryption

## File layout

```
nixos/
├── configuration.nix               # Base system: users, networking, SSH, security, packages
├── containers.nix                  # Podman setup and OCI container backend
├── hardware-configuration.nix      # Auto-generated hardware config (do not edit)
├── local.nix                       # Machine-specific values (gitignored — see local.nix.example)
├── local.nix.example               # Template for local.nix
└── services/
    ├── caddy.nix                   # Caddy reverse proxy + Tailscale TLS cert provisioning
    ├── kanidm.nix                  # Kanidm identity provider (OIDC)
    ├── actual-budget.nix           # Actual Budget container
    └── pihole.nix                  # Pi-hole DNS ad blocker container
```

## Local configuration

Machine-specific values (Tailscale hostname etc.) live in `nixos/local.nix`, which is gitignored. Copy the example and fill in your values:

```bash
cp nixos/local.nix.example nixos/local.nix
# edit nixos/local.nix with your tailscaleHost
```

## Persistent data

| Path | Service |
|------|---------|
| `/var/lib/actual` | Actual Budget database |
| `/var/lib/pihole/etc-pihole` | Pi-hole config and gravity database |
| `/var/lib/pihole/etc-dnsmasq.d` | dnsmasq overrides |
| `/var/lib/caddy/tls` | Tailscale TLS cert and key |
| `/var/lib/kanidm` | Kanidm database |

## Secret files (not in git)

| Path | Contents |
|------|---------|
| `nixos/local.nix` | `hostname`, `tailscaleHost`, `username`, `sshPublicKey` |
| `/etc/actual/oidc-secret` | `ACTUAL_OPENID_CLIENT_SECRET=...` |
| `/etc/pihole/webpassword` | `WEBPASSWORD=...` |

## Applying changes

```bash
sudo nixos-rebuild switch
```

## TODO

- [ ] Evaluate [AdGuard Home](https://github.com/AdguardTeam/AdGuardHome#comparison-pi-hole) as an alternative to Pi-hole
- [ ] Set up Restic backups to Hetzner Storage Box

## Adding a new service

1. Bind the container to an internal port (e.g. `1XXXX`)
2. Create `nixos/services/<name>.nix` accepting `{ config, pkgs, tailscaleHost, ... }`
3. Add a Caddy `virtualHost` on the external port (`XXXX`) in `caddy.nix`
4. Add the external port to `networking.firewall.allowedTCPPorts` in the new service file
5. Add a `tmpfiles` rule for the persistent data directory
6. Import the new file in `configuration.nix`
