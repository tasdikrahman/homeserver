# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

NixOS configuration for a single self-hosted home server (Lenovo ThinkCentre M75q Gen 2, NixOS 25.11, LUKS-encrypted root). Every service is reachable only over Tailscale — nothing is exposed to the public internet. There is no application code here; changes are Nix modules that get applied with `nixos-rebuild`.

**This Claude Code session runs on a dev machine, not on the homeserver.** The repo here is only ever edited and pushed from this machine — Claude never has direct shell access to the homeserver itself. Any command that needs to run *on* the server (`nixos-rebuild switch`, `sudo install -m 600 ...` for secrets, `systemctl restart ...`, etc.) has to be handed to the user as text for them to copy-paste over there; it cannot be executed via Bash in this session.

## Commands

- Validate a change locally before pushing, if a Nix evaluator is available: `nixos-rebuild dry-build` (or `build` to build without activating) — otherwise this can only be checked by reading the module carefully, since the dev machine may not have the same Nix setup as the server.
- Format Nix files: `nixpkgs-fmt <file>` (this is what `nil`, the Nix LSP, uses for formatting — both are installed on the *server's* system profile per `configuration.nix`, not necessarily here).
- There is no test suite or linter beyond Nix's own evaluation.

**Deploys are automatic, driven by git push.** `nixos-auto-rebuild.service` (`nixos/services/auto-rebuild.nix`), running on the homeserver, polls `origin/main` of this repo every 5 minutes via a systemd timer, and on new commits runs `git pull --ff-only` followed by `nixos-rebuild switch` itself. **Pushing to `main` from here deploys to the live server within ~5 minutes** — there is no separate staging step or manual approval gate, and no `nixos-rebuild` command needs to be run by hand for a config change to take effect. It tracks the last commit it successfully *applied* in `/var/lib/nixos-auto-rebuild/last-applied-commit`, deliberately separate from git HEAD, so a failed `switch` (e.g. an eval error) gets retried on the next tick instead of being silently treated as "up to date." Because of this, treat every push to `main` as a production deploy — the "check with the user before risky actions" bar applies to `git push` here, not to some later manual step.

One-time setup commands documented in the service modules (creating `/etc/<service>/...` secret files, running `kanidm oauth2 show-basic-secret`, etc.) are things the user runs on the homeserver directly — surface them as instructions, don't try to run them.

## Architecture

### Module wiring
`nixos/configuration.nix` is the entrypoint: it imports `hardware-configuration.nix`, `containers.nix`, and every module under `nixos/services/`, and injects shared values (`tailscaleHost`, `hostname`, `username`, `sshPublicKey`, `resticRepository`) as `_module.args` sourced from `nixos/local.nix`. Every service module takes `{ config, pkgs, tailscaleHost, ... }` (or a subset) as its function arguments rather than reading globals directly.

`nixos/local.nix` is gitignored and holds machine-specific/secret values (`nixos/local.nix.example` is the template). `hardware-configuration.nix` is installer-generated — never edit it or symlink it from this repo; the copy at `/etc/nixos/hardware-configuration.nix` on the machine is authoritative.

### Container + networking pattern
All services run as Podman OCI containers (`virtualisation.oci-containers`, backend configured in `containers.nix`) with `--network=host`, because Podman's bridge network can't route to the Tailscale IP. To avoid port clashes, every container binds to an internal `1XXXX` port and Caddy (`nixos/services/caddy.nix`) reverse-proxies the well-known external port `XXXX` to it — e.g. Actual Budget listens on `15006` internally, exposed as `5006`. Kanidm is the one exception: it terminates TLS itself on `8443` directly, no Caddy in front.

Each service module is responsible for its own `networking.firewall.allowedTCPPorts` entry (only the external port), a `systemd.tmpfiles.rules` entry for its persistent data directory (matching the container image's UID/GID where relevant, e.g. Grafana's `472:472`, Postgres's `70:70`), and any container-specific environment/secrets wiring.

To add a new service, follow the existing pattern: internal port `1XXXX`, a new `nixos/services/<name>.nix` taking `{ config, pkgs, tailscaleHost, ... }`, a Caddy `virtualHost` on the external port, a firewall rule, a tmpfiles rule, and an import in `configuration.nix` (see README.md's "Adding a new service" section for the checklist).

### Shared TLS cert
`tailscale-cert.service`/`.timer` (defined in `caddy.nix`) provisions a single Tailscale-signed cert/key at `/var/lib/caddy/tls/{cert,key}.pem`, owned `root:caddy`. Caddy and Kanidm both consume it (Kanidm is added to the `caddy` group to read it). This unit has a history of quietly breaking — see the comments in `caddy.nix` — so preserve them if touching this file:
- No `RemainAfterExit` on the service: it previously left the unit stuck "active (exited)" forever, and a timer's "start" on an already-active oneshot is a no-op, silently killing renewals.
- The timer has both `OnCalendar = "weekly"` *and* `OnUnitActiveSec = "1d"` as a fallback, because the calendar trigger has been observed to stop re-arming after frequent daemon-reloads (caused by `nixos-rebuild switch` running every 5 minutes via auto-rebuild).
- The renewal script only reloads/restarts Caddy/Kanidm if the cert hash actually changed and the service is already active — neither picks up a renewed cert on its own (Caddy needs a reload; Kanidm reads `tls_chain`/`tls_key` once at startup).

### Podman + Tailscale MagicDNS DNS bug
Podman strips the host's nameserver (`100.100.100.100`, Tailscale MagicDNS) when generating a container's `/etc/resolv.conf`. Any container that needs to resolve `.ts.net` names (Miniflux, blackbox-exporter) works around this with `volumes = [ "/etc/resolv.conf:/etc/resolv.conf:ro" ]`. Apply the same fix to any new container that does DNS lookups over the Tailscale network.

### Secrets
No secrets live in git. Each service that needs one documents the manual setup steps as comments at the top of its module (create `/etc/<service>/...` files with `install -m 600`, write `KEY=value` env vars) and consumes them via `environmentFiles` (containers) or `passwordFile`/`environmentFile` (restic). `nixos/local.nix` itself is the one secret-bearing file that's part of this repo's structure but excluded via `.gitignore`.

### Monitoring stack
Prometheus (`prometheus.nix`) scrapes itself, Alertmanager, node-exporter, and a blackbox-exporter probing every service's HTTPS endpoint for uptime. Alerting rules (service down, high CPU/mem, low disk, stale/failed restic backups) route through Alertmanager to Telegram. Retention is capped at 7 days / 2 GB by design — this is not meant to be a long-term metrics store. Grafana is the dashboard layer on top.

### Backups
Restic backs up `/etc`, and each service's persistent data directory (`/var/lib/actual`, `/var/lib/grafana`, `/var/lib/kanidm`, `/var/lib/caddy/tls`, `/var/lib/miniflux-db`) to Hetzner Object Storage nightly, with 7 daily / 4 weekly / 12 monthly retention. When adding a new stateful service, add its data directory to `services.restic.backups.hetzner.paths` in `restic.nix`.

## Persistent data paths

| Path | Service |
|------|---------|
| `/var/lib/actual` | Actual Budget database |
| `/var/lib/prometheus` | Prometheus TSDB |
| `/var/lib/grafana` | Grafana |
| `/var/lib/caddy/tls` | Shared Tailscale TLS cert/key |
| `/var/lib/kanidm` | Kanidm database |
| `/var/lib/miniflux-db` | Miniflux's Postgres data |
| `/var/lib/alertmanager` | Alertmanager |
| `/var/lib/nixos-auto-rebuild` | Auto-rebuild's last-applied-commit state |
