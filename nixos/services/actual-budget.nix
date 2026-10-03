{ config, pkgs, tailscaleHost, ... }:

{
  # Actual Budget container. Uses host networking so it can reach Kanidm on the
  # same machine — Podman's bridge network can't route to the Tailscale IP.
  # Listens on 15006 internally (ACTUAL_PORT) to avoid clashing with Caddy on 5006.
  virtualisation.oci-containers.containers.actual = {
    image = "actualbudget/actual-server:26.10.0";
    extraOptions = [ "--network=host" ];
    volumes = [
      "/var/lib/actual:/data"
      # Podman strips the host nameserver (100.100.100.100, Tailscale MagicDNS)
      # when generating the container's /etc/resolv.conf, so the OIDC discovery
      # URL (a .ts.net hostname) fails to resolve at container startup with
      # "getaddrinfo ENOTFOUND" — breaking SSO login (password login is
      # unaffected since it never does a DNS lookup). Same fix as
      # miniflux/blackbox-exporter: bind-mount the host's working resolv.conf.
      "/etc/resolv.conf:/etc/resolv.conf:ro"
    ];
    autoStart = true;
    # Non-secret OIDC config — safe to keep in git.
    environment = {
      ACTUAL_PORT                   = "15006";
      ACTUAL_OPENID_DISCOVERY_URL   = "https://${tailscaleHost}:8443/oauth2/openid/actual-budget";
      ACTUAL_OPENID_CLIENT_ID       = "actual-budget";
      ACTUAL_OPENID_SERVER_HOSTNAME = "https://${tailscaleHost}:5006";
    };
    # Secret loaded from a file on the server — never committed to git.
    # Create it once: sudo install -m 600 /dev/null /etc/actual/oidc-secret
    # Then write: ACTUAL_OPENID_CLIENT_SECRET=<secret from `kanidm oauth2 show-basic-secret actual-budget`>
    environmentFiles = [ "/etc/actual/oidc-secret" ];

    # --- Giving someone access (two halves, both required) -----------------
    #
    # Being valid in Kanidm is not enough. Actual keeps its own user list and
    # rejects an unknown identity with HTTP 400 on /openid/callback — *after*
    # a completely successful token exchange and userinfo fetch, which makes
    # it look like an OIDC fault when it isn't. The browser just shows
    # "openid grant failed".
    #
    # 1. Create the person in Kanidm and add them to actual-budget-users
    #    (see the comment block at the top of kanidm.nix).
    # 2. In Actual as the owner, add them to the User Directory, then grant
    #    them access to the budget file (two separate steps — a user with no
    #    file access logs in to an empty file list).
    #
    # The username Actual expects is the Kanidm **SPN**, not the bare login:
    #
    #     leahelenepollmer@nixos.pipefish-sun.ts.net     <- correct
    #     leahelenepollmer                               <- rejected
    #
    # That is the `spn` field from `kanidm person get <username>`, and it is
    # what Kanidm sends as preferred_username. Confirm the format against an
    # account that already works:
    #
    #   sudo nix-shell -p sqlite --run "sqlite3 \
    #     'file:/var/lib/actual/server-files/account.sqlite?mode=ro' \
    #     '.headers on' 'select user_name, role, owner from users;'"
    #
    # Give additional people role BASIC, not ADMIN — ADMIN can see every
    # budget file on the server and manage users. Read that DB read-only and
    # never INSERT a user by hand: Actual also maintains the user_access table
    # and a manual row leaves a half-created account.
    #
    # The first identity ever to log in bootstraps the instance and becomes
    # owner automatically (hence /account/needs-bootstrap and
    # /admin/owner-created in the logs), so the owner account was never added
    # by hand — only everyone after them needs this.
  };

  systemd.tmpfiles.rules = [
    # Persist Actual Budget data across container restarts and rebuilds.
    "d /var/lib/actual 0750 root root -"
  ];

  networking.firewall.allowedTCPPorts = [ 5006 ];
}
