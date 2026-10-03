# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

NixOS configuration for a single self-hosted home server (Lenovo ThinkCentre M75q Gen 2, NixOS 26.05, LUKS-encrypted root). Every service is reachable only over Tailscale — nothing is exposed to the public internet. There is no application code here; changes are Nix modules that get applied with `nixos-rebuild`.

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
- The script's `systemctl reload caddy` / `restart kanidm` calls **must keep `--no-block`**. This unit gets pulled into the same systemd transaction as `nixos-rebuild switch` (via `sysinit-reactivation.target`), so a blocking `systemctl reload` waits on a job that cannot be scheduled until that transaction finishes — which cannot happen until the script exits. Deadlock. It cost 2 days of stalled channel updates on 2026-09-26.
- `TimeoutStartSec` is a deliberate backstop, not boilerplate: anything that can hang while systemd holds a transaction open must be time-bounded, because a timer never re-triggers a unit that is still running.

### Podman + Tailscale MagicDNS DNS bug
Podman strips the host's nameserver (`100.100.100.100`, Tailscale MagicDNS) when generating a container's `/etc/resolv.conf`. Any container that needs to resolve `.ts.net` names (Miniflux, blackbox-exporter) works around this with `volumes = [ "/etc/resolv.conf:/etc/resolv.conf:ro" ]`. Apply the same fix to any new container that does DNS lookups over the Tailscale network.

### Secrets
No secrets live in git. Each service that needs one documents the manual setup steps as comments at the top of its module (create `/etc/<service>/...` files with `install -m 600`, write `KEY=value` env vars) and consumes them via `environmentFiles` (containers) or `passwordFile`/`environmentFile` (restic). `nixos/local.nix` itself is the one secret-bearing file that's part of this repo's structure but excluded via `.gitignore`.

### Identity / adding a user
Kanidm accounts are runtime state in its own database, not Nix config, so adding a person is a CLI procedure — documented in full at the top of `nixos/services/kanidm.nix`, along with the one-time OAuth2 client setup (reconstructed there, since it was never recorded when first run).

Granting access to a service takes **two** halves: the Kanidm account plus group membership, *and* a user in that service's own list. For Actual, see the provisioning comment in `actual-budget.nix` — the username it expects is the Kanidm **SPN** (`user@<tailscaleHost>`), not the bare login, and an unknown identity is rejected with HTTP 400 on `/openid/callback` *after* a fully successful token exchange, which reads as an OIDC fault but isn't. `kanidm person create` does not create a credential; the account cannot log in until a reset token has been used.

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

## Runbook: server unreachable over SSH/Tailscale

Claude has no shell on the server (see "What this repo is"), so triage is always a list of commands handed to the user to run at the physical console. Two facts shape the whole procedure:

- **Root is LUKS-encrypted.** After *any* reboot the box sits at the initrd passphrase prompt with no disk, no network and no sshd. "Unreachable" most often means "rebooted and waiting for a passphrase", not "broken".
- **The box auto-reboots on kernel panic/oops (`kernel.panic = 10`, `kernel.panic_on_oops = 1`) and on a systemd/hardware watchdog trip (`sp5100_tco`, 30s runtime / 30s reboot).** So an unexplained reboot is expected behaviour, not necessarily a new fault — but it means the LUKS prompt is where it lands.

So: **look at the monitor before typing anything.**

### Step 0 — from the dev machine, before walking over

**Rule out the client side and the tailnet before assuming the server is broken.** A stale client route or an expired node key produces exactly the same symptom as a dead box: nothing answers on any port.

```bash
tailscale status | grep -i <hostname>   # "offline, last seen ..." = box really is down
tailscale ping <hostname>               # the decisive test — see below
ip route get <tailscale-ip>             # must say "dev tailscale0", not via the LAN router
ip route show table 52 | grep <tailscale-ip>   # peer's route must be present
ping -c3 <tailscale-ip>
ping -c3 <lan-ip>          # LAN up but Tailscale down is a different bug than a dead box
ssh -vvv <user>@<lan-ip> 2>&1 | tail -30
```

Read `tailscale ping` first — it reports the tailnet-level reason and short-circuits the rest:

| `tailscale ping` says | Meaning | Fix |
|---|---|---|
| `peer's node key has expired` | Node key hit its expiry (default 180 days). Peer is dropped from the netmap, so no route is installed and *every* service goes dark at once | Admin console → machine → **Disable key expiry**; or `sudo tailscale up` at the server console. Not a server fault |
| `no matching peer` / peer absent | Node removed or logged out | Re-auth at the console |
| times out, but route is correct | Genuine reachability problem | Step 1 |

`ip route get` returning `via <router> dev <lan-if>` means packets never entered `tailscale0` — a client-side routing problem on the laptop, nothing to do with the server. An ICMP error sourced from an ISP hop (rather than a tailnet address) confirms it.

Beware two misleading signals: `Online=true` in `tailscale status --json` only means the node holds a control-plane connection — an expired node still shows online. And `systemctl show tailscaled -p ActiveEnterTimestamp` only changes on `systemctl restart`, *not* on `tailscale down && up`, so it can't tell you whether a re-auth was attempted; read `journalctl -u tailscaled` for `Switching ipn state` lines instead.

Only once the tailnet path is proven good: LAN ping works but SSH refused → sshd problem. Nothing answers → box down or stuck at LUKS.

### Escape hatch — SSH over the LAN

`services.openssh.openFirewall` defaults to true, so **port 22 is open on the LAN interface as well as `tailscale0`** — the firewall's `trustedInterfaces = [ "tailscale0" ]` does not restrict it. Any tailnet-level failure (expired key, logged-out node, Tailscale outage) can therefore be fixed over the local network from a machine on the same FRITZ!Box, with no keyboard/monitor trip. This is the escape hatch to reach for *before* walking to the box.

The server's LAN address is not fixed in this repo; find it by port signature rather than by hostname (it does not register a usable `.fritz.box` name). `nmap` is not installed on the dev laptop, so:

```bash
# 1. find live hosts (a full /24 port scan in parallel drops probes over wifi — sweep first)
for i in $(seq 1 254); do (ping -c1 -W1 192.168.178.$i >/dev/null 2>&1 && echo "ALIVE: 192.168.178.$i") & done; wait

# 2. fingerprint them — the server is the one with the service ports open
for ip in <alive ips>; do for p in 22 3000 5006 8443 9090; do \
  (timeout 1 bash -c "echo >/dev/tcp/192.168.178.$ip/$p" 2>/dev/null && echo "192.168.178.$ip:$p OPEN") & done; done; wait
```

The homeserver answers on 22 (sshd), 3000 (Grafana), 5006 (Actual), 8443 (Kanidm) and 9090 (Prometheus) — as of 2026-09-28 it was `192.168.178.39`, but treat that as a hint, not a fact. Seeing those ports open is also the only *direct* proof the box is healthy; everything derived from `tailscale status` is second-hand.

### Tailscale node key expiry — the standing trap

Every Tailscale node key expires **180 days after registration** by default. On expiry the node deauthenticates itself, `tailscale status` on the box prints `Logged out.`, and it drops out of every peer's netmap — so all services go dark at once while the machine is perfectly healthy. Renewal is an interactive browser login (`sudo tailscale up` → visit printed URL), which is impossible remotely once the tailnet path is already gone. That is why this failure is worse than it looks: it removes the exact route you would use to repair it.

**Prevention (do this for the server, not for laptops/phones):** admin console → https://login.tailscale.com/admin/machines → the machine's `...` menu → **Disable key expiry**. It is a tailnet-side property — nothing to run on the server, nothing to configure in this repo. Tailscale's own guidance endorses this selectively, for "trusted servers, subnet routers, or remote IoT devices that are hard to reach" (https://tailscale.com/kb/1028/key-expiry); leave expiry enabled on personal devices, where the rotation is doing real security work. The alternative sanctioned route is tagging the device (`tag:server` + `tagOwners` in the ACL, re-auth with `--advertise-tags`), since tagged devices get expiry disabled by default — more idiomatic for infrastructure, but it costs an ACL edit and another re-auth for little gain on a single-user tailnet.

Accepted tradeoff: the node keeps tailnet access until manually removed. Acceptable for a box physically at home on a LUKS-encrypted disk; revoke by deleting the machine in the admin console if it is ever lost.

Re-auth, when it has already expired:

```bash
sudo tailscale up                 # prints a login URL — open it in a browser on any machine
sudo tailscale up --force-reauth  # if it returns with no URL
tailscale status && tailscale ip -4
```

The node keeps its existing `100.x` address across re-auth, so Caddy, Prometheus and MagicDNS names need no changes. A *different* IP means it registered as a new node — clean up the duplicate in the admin console.

### Step 1 — read the console screen

| On screen | Meaning | Next |
|---|---|---|
| LUKS passphrase prompt | Box rebooted | Enter passphrase, then Step 3 (read the *prior* boot) |
| Login prompt / GDM | Booted fine; network or sshd broke | Step 2 |
| Frozen, no cursor blink, Caps Lock LED dead | Same class as the 2026-08-03 hard freeze. Watchdog should have rebooted within 30s; if it didn't, the watchdog is not armed | Power-cycle, then Step 3 + the watchdog check |
| Kernel panic text / emergency shell | | Photograph the screen, then Step 3 |

### Step 2 — box is up: collect state

```bash
sudo systemctl status sshd tailscaled --no-pager -l
ip -br addr
sudo tailscale status
sudo systemctl --failed --no-pager
sudo ss -tlnp | grep -E ':22|:8443|:443'
df -h / /boot /nix
free -h
uptime
```

`/` or `/boot` at 100% alone kills session setup and rebuilds. Then `journalctl -u sshd -n 50 --no-pager` / `-u tailscaled` as indicated.

### Step 3 — why it went down (prior boot)

```bash
sudo journalctl --list-boots | tail -5
sudo journalctl -b -1 -p err --no-pager | tail -60
sudo journalctl -b -1 -n 100 --no-pager        # tail of the prior boot, last lines before death
sudo journalctl -b -1 -k --no-pager | grep -iE 'panic|oops|oom|watchdog|mce|hardware error|thermal|ata|nvme'
sudo dmesg -T | grep -iE 'sp5100|watchdog|mce|thermal|nvme'
last -x reboot shutdown | head -10
```

An empty prior-boot tail with no error is the signature of the 2026-08-03 silent freeze (no OOM, no panic, nothing in the journal).

**Always check the watchdog actually armed** — the config loads `sp5100_tco`, but module load can silently fail:

```bash
lsmod | grep -i tco
ls -l /dev/watchdog*
sudo systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
sudo wdctl
```

`RuntimeWatchdogUSec=0` or a missing `/dev/watchdog` means the watchdog never worked, which explains any freeze that wasn't auto-recovered.

Hardware-level checks (survive OS death): `sensors`, `smartctl -H -A /dev/nvme0n1` (or `nvme smart-log`), and grep the prior boot for `temperature|critical`.

### Step 4 — deploy state

Auto-rebuild switches on every new commit, up to every 5 minutes, so a bad config lands fast:

```bash
cat /var/lib/nixos-auto-rebuild/last-applied-commit
sudo systemctl status nixos-auto-rebuild.service --no-pager -l
sudo journalctl -u nixos-auto-rebuild -n 40 --no-pager
```

`last-applied-commit` lagging behind `origin/main` means a switch is failing (eval error) and being retried every tick.

### One-shot dump

Hand the user this instead of the individual commands when the box is reachable enough to type:

```bash
{ date; uptime; echo "--- failed ---"; systemctl --failed --no-pager;
  echo "--- net ---"; ip -br addr; tailscale status 2>&1 | head -20;
  echo "--- listen ---"; ss -tlnp | grep -E ':22|:443|:8443';
  echo "--- disk ---"; df -h; free -h;
  echo "--- boots ---"; journalctl --list-boots | tail -5;
  echo "--- prev boot tail ---"; journalctl -b -1 -n 80 --no-pager;
  echo "--- prev boot err ---"; journalctl -b -1 -p err --no-pager | tail -40;
  echo "--- watchdog ---"; lsmod | grep -i tco; ls -l /dev/watchdog*; systemctl show -p RuntimeWatchdogUSec;
  echo "--- rebuild ---"; cat /var/lib/nixos-auto-rebuild/last-applied-commit; systemctl status nixos-auto-rebuild --no-pager -l | tail -20;
} 2>&1 | sudo tee /tmp/triage.txt
```

Retrieve with `scp <user>@<host>:/tmp/triage.txt .` once SSH is back, or photograph the screen if it isn't.

### Incident log

Append one line per outage here — the pattern across incidents is worth more than any single postmortem.

- **2026-08-03** — Total freeze: SSH, Tailscale and all services down, zero trace in kernel or journal logs (no OOM, no panic, no error). Disk was 35%/69%, so not a fill-up. Led to the hardware watchdog + `kernel.panic` auto-reboot + zram swap + Nix GC changes in `41839fb`, and the `ServerRebooted` Prometheus alert in `b1e27b1`.
- **2026-09-28** — All services unreachable over Tailscale; the box was healthy throughout. The server's **Tailscale node key expired** (`keyexpiry=2026-09-25T21:37:45Z`), logging the node out and dropping it from the netmap, so no peer route was installed — `ip route get` sent traffic out the LAN router instead of `tailscale0`. `tailscale status` still reported `online=true` (an expired node keeps its control-plane connection), which sent the first pass of triage down a false client-side-routing path; `tailscale down && up` on the laptop predictably changed nothing. `tailscale ping nixos` returned `peer's node key has expired` and settled it in one command. Recovered by SSHing in over the LAN (`192.168.178.39:22`) and running `sudo tailscale up` — no console trip needed; the node came back on the same `100.107.120.6` with no duplicate. The iPhone expired 5 minutes after the server (same registration session ~2026-03-29) and the iPad was due 2026-10-20. **Lessons: run `tailscale ping` before anything else; `Online=true` proves nothing about a node's usability; the LAN SSH path is the escape hatch for any tailnet-level failure; and key expiry must stay disabled on this server.**
- **2026-09-28 (b)** — Found while investigating why Tailscale was stuck at 1.90.9: `nixos-upgrade.service` had been `activating (start)` since **2026-09-26 04:40**, so no channel update had run for 2 days and its timer showed `Trigger: n/a` (systemd will not re-trigger a unit that is still running). `systemctl list-jobs` showed the deadlock outright: `nixos-upgrade/start running`, `tailscale-cert/start running`, `caddy/reload waiting`, `multi-user.target/start waiting` — `tailscale-cert.service` had called a *blocking* `systemctl reload caddy.service` from inside the switch's own transaction. Sep 26 was simply the day the cert actually rotated, so the script took its reload branch. Fixed by adding `--no-block` to both `systemctl` calls plus `TimeoutStartSec` on `tailscale-cert.service` and `nixos-upgrade.service`. **Separately and more seriously, this exposed that `nixos-25.11` went EOL on 2026-06-30** — the nightly upgrade had been rebuilding a byte-identical store path (`iwawspy0…`) for months, so the machine has received no security updates since. 26.05 'Yarara' is the only supported release (until 2026-12-31). **Lesson: an `autoUpgrade` that "succeeds" every night proves nothing; check that the store path actually changes and that the channel is still supported.**

### Release upgrades

The channel is pinned declaratively in `system.autoUpgrade.channel`, so a release bump is a one-line diff — but the switch itself is **not** unattended, for three reasons specific to this machine: a new kernel needs a reboot, and a reboot stops at the LUKS prompt until someone types a passphrase; Kanidm cannot skip minor versions, so a release that drops the pinned attribute breaks evaluation; and auto-rebuild retries every 5 minutes, so an eval error becomes a failing switch on every tick.

`system.stateVersion` is **not** a version to bump. It records the release this machine was first installed with (25.11) so NixOS preserves the right defaults for stateful data, and it stays at that value forever.

Procedure, run on the server with console access available for the reboot:

```bash
sudo nix-channel --add https://channels.nixos.org/nixos-<release> nixos
sudo nix-channel --update
sudo nixos-rebuild dry-build 2>&1 | grep -iE "^error|error:|warning"   # the gate — read every warning
df -h / /boot                                   # a release jump needs room beside the old generation
tmux new -s upgrade                             # the switch restarts tailscaled; don't run it bare over SSH
sudo systemctl stop nixos-auto-rebuild.timer    # don't race the switch
sudo nixos-rebuild switch
sudo systemctl start nixos-auto-rebuild.timer   # ALWAYS restart it — a stopped timer silently kills deploys
```

Expect `tailscale-cert.service` and `nixos-auto-rebuild.service` to fail *during* the switch: the resolver restarts, so `tailscale cert` and `git fetch` briefly lose DNS. Both recover on retry; clear them with `systemctl start` and confirm `systemctl --failed` is empty.

Then reboot for the kernel (`readlink /run/booted-system/kernel` vs `/run/current-system/kernel` shows whether one is staged), and afterwards verify the watchdog is still armed — a renamed option or a new kernel can silently disable it:

```bash
uname -r; lsmod | grep -i tco; ls -l /dev/watchdog*
systemctl show -p RuntimeWatchdogUSec -p RebootWatchdogUSec
```

The 2026-09-28 upgrade went 25.11 → 26.05, kernel 6.12.93 → 6.18.54, Tailscale 1.90.9 → 1.98.10. **26.05 is supported until 2026-12-31 — bump to 26.11 before then.**
