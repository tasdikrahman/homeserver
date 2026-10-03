{ config, pkgs, tailscaleHost, ... }:

{
  # Kanidm is the identity provider for all services on this machine.
  # It handles user accounts and issues OIDC tokens for services like Actual Budget.
  # Kanidm handles its own TLS directly on port 8443 — no Caddy in front of it.
  # It reads the Tailscale cert via the caddy group (see users.users.kanidm below).
  #
  # Accounts are runtime state in Kanidm's own database, not declarative NixOS
  # config — they are created with the `kanidm` CLI and survive rebuilds.
  #
  # --- One-time setup, already done on this host ----------------------------
  #
  # Recorded here because none of it is declarative and none of it was written
  # down when it was first run. Reconstructed from the live state
  # (`kanidm system oauth2 get actual-budget`), so treat it as a guide for
  # wiring up the *next* OIDC service rather than a verified transcript.
  #
  #   # 1. Recover the built-in accounts (run as root on this host; kanidmd
  #   #    must be able to read its own DB, hence -u kanidm).
  #   sudo -u kanidm kanidmd recover-account idm_admin
  #   sudo -u kanidm kanidmd recover-account admin
  #
  #   # 2. Point the CLI at the server, if it doesn't already know the URI.
  #   #    (`kanidm login` fails with a connection error otherwise.)
  #   export KANIDM_URL=https://<tailscaleHost>:8443
  #   kanidm login --name idm_admin
  #
  #   # 3. A group per service — membership in it is what grants access.
  #   kanidm group create actual-budget-users
  #   kanidm group add-members actual-budget-users <your-username>
  #
  #   # 4. The OAuth2/OIDC client. The landing URL is where Kanidm sends
  #   #    someone who opens the app from Kanidm's own portal; the redirect URL
  #   #    must match the service's callback exactly (strict by default).
  #   kanidm system oauth2 create actual-budget "Actual Budget" https://<tailscaleHost>:5006/
  #   kanidm system oauth2 add-redirect-url actual-budget https://<tailscaleHost>:5006/openid/callback
  #
  #   # 5. Which claims the client may request, for members of that group.
  #   kanidm system oauth2 update-scope-map actual-budget actual-budget-users openid profile email
  #
  #   # 6. Actual needs RS256; Kanidm defaults to ES256 only.
  #   kanidm system oauth2 warning-enable-legacy-crypto actual-budget
  #
  #   # 7. Hand the client secret to Actual (see actual-budget.nix).
  #   kanidm system oauth2 show-basic-secret actual-budget
  #
  # Verify the result with `kanidm system oauth2 get actual-budget`: it should
  # show oauth2_rs_origin (the callback), oauth2_rs_origin_landing,
  # oauth2_rs_scope_map naming the group, and oauth2_jwt_legacy_crypto_enable.
  #
  # Persons are created separately, below. NOTE: `kanidm person create` makes
  # the account but NOT a credential — a fresh account has no
  # `primary_credential` and cannot log in until a reset token is used.
  #
  # --- Adding a person who needs Actual Budget access -----------------------
  #
  #   kanidm login --name idm_admin
  #   # (lost the idm_admin password? on this host:
  #   #   sudo -u kanidm kanidmd recover-account idm_admin)
  #
  #   kanidm person create <username> "<Display Name>"
  #   kanidm group add-members actual-budget-users <username>
  #   kanidm person credential create-reset-token <username> 86400
  #
  # The last command prints a self-service URL
  # (https://<host>:8443/ui/reset?token=…) — send that to the person and they
  # set their own password/passkey. The default TTL is short, hence the 86400.
  # `kanidm person get <username>` then shows `primary_credential: primary`,
  # which is the only reliable sign the reset actually completed.
  #
  # `actual-budget-users` is the group named in the client's scope map
  # (`kanidm system oauth2 get actual-budget`); membership is what authorises
  # the OIDC grant. A `mail` attribute is NOT required — no account here has
  # one and SSO works regardless.
  #
  # Kanidm access is only half of it: Actual keeps its own user list and will
  # reject an unknown identity with HTTP 400 on /openid/callback even though
  # the token exchange succeeded. See the user-provisioning comment in
  # actual-budget.nix for the second half (and the exact username format).
  #
  # Debugging a failed SSO login, in order — this sequence was what actually
  # isolated it on 2026-09-29, and most of the obvious suspects are red
  # herrings:
  #   1. Have them log into https://<host>:8443/ui/ directly. Works = their
  #      credential, network path to 8443 and Kanidm are all fine.
  #   2. journalctl -u kanidm -f -o cat | grep -viE "ui/login|handle_auth_valid"
  #      A real attempt logs handle_oauth2_token_exchange, then public_key.jwk,
  #      then userinfo. All three succeeding means Kanidm did its job and the
  #      failure is downstream in the service.
  #   3. sudo podman logs -f --tail 5 actual
  #      400 on /openid/callback *after* a successful exchange = unknown user.
  # Beware sub-second login→callback pairs in Actual's log with no matching
  # Kanidm traffic: that is a browser replaying a stale callback URL from
  # history, not a real attempt, and it will send you chasing a phantom.
  services.kanidm = {
    # enableServer/serverSettings were renamed to server.enable/server.settings
    # in 26.05. The old names still work as aliases but warn on every rebuild.
    server.enable = true;
    package = pkgs.kanidm_1_10;
    server.settings = {
      origin = "https://${tailscaleHost}:8443";
      domain = tailscaleHost;
      bindaddress = "[::]:8443";
      tls_chain = "/var/lib/caddy/tls/cert.pem";
      tls_key = "/var/lib/caddy/tls/key.pem";
    };
  };

  # Give the kanidm system user read access to the Tailscale certs (owned root:caddy).
  users.users.kanidm.extraGroups = [ "caddy" ];

  # Make Kanidm wait for certs to be provisioned before starting.
  systemd.services.kanidm.after = [ "tailscale-cert.service" ];
  systemd.services.kanidm.requires = [ "tailscale-cert.service" ];

  networking.firewall.allowedTCPPorts = [ 8443 ];
}
