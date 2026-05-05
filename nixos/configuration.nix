# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running ‘nixos-help’).

{ config, pkgs, hostname, username, sshPublicKey, ... }:

let
  local = import ./local.nix;
in

{
  _module.args.tailscaleHost    = local.tailscaleHost;
  _module.args.hostname         = local.hostname;
  _module.args.username         = local.username;
  _module.args.sshPublicKey     = local.sshPublicKey;
  _module.args.resticRepository = local.resticRepository;

  imports =
    [ ./hardware-configuration.nix
      ./containers.nix
      ./services/caddy.nix
      ./services/kanidm.nix
      ./services/actual-budget.nix
      ./services/prometheus.nix
      ./services/alertmanager.nix
      ./services/grafana.nix
      ./services/miniflux.nix
      ./services/restic.nix
    ];

  # Bootloader.
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
  # Stop TTY from blanking
  boot.kernelParams = [ "consoleblank=0" ];

  # Disable sleep/suspend/hibernate entirely
  systemd.targets.sleep.enable = false;
  systemd.targets.suspend.enable = false;
  systemd.targets.hibernate.enable = false;
  systemd.targets.hybrid-sleep.enable = false;

  networking.hostName = hostname;
  # networking.wireless.enable = true;  # Enables wireless support via wpa_supplicant.

  # Configure network proxy if necessary
  # networking.proxy.default = "http://user:password@proxy:port/";
  # networking.proxy.noProxy = "127.0.0.1,localhost,internal.domain";

  # Enable networking
  networking.networkmanager.enable = true;

  # Disable systemd-resolved's stub listener so Pi-hole can bind to port 53.
  # Without this, resolved occupies 127.0.0.53:53 and conflicts with Pi-hole.
  services.resolved.extraConfig = "DNSStubListener=no";

  # Firewall: deny all inbound traffic by default, only allow SSH.
  # Add ports here as you expose more services (e.g. 80, 443 for HTTP/S).
  networking.firewall = {
    enable = true;
    trustedInterfaces = [ "tailscale0" ];
  };

  # Set your time zone.
  time.timeZone = "Europe/Berlin";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_GB.UTF-8";

  i18n.extraLocaleSettings = {
    LC_ADDRESS = "de_DE.UTF-8";
    LC_IDENTIFICATION = "de_DE.UTF-8";
    LC_MEASUREMENT = "de_DE.UTF-8";
    LC_MONETARY = "de_DE.UTF-8";
    LC_NAME = "de_DE.UTF-8";
    LC_NUMERIC = "de_DE.UTF-8";
    LC_PAPER = "de_DE.UTF-8";
    LC_TELEPHONE = "de_DE.UTF-8";
    LC_TIME = "de_DE.UTF-8";
  };

  # Enable the X11 windowing system.
  services.xserver.enable = true;

  # Enable the GNOME Desktop Environment.
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;

  # Configure keymap in X11
  services.xserver.xkb = {
    layout = "gb";
    variant = "";
  };

  # Configure console keymap
  console.keyMap = "uk";

  # Printing disabled — not needed on a headless/home server, reduces attack surface.
  services.printing.enable = false;

  # Enable sound with pipewire.
  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
    # If you want to use JACK applications, uncomment this
    #jack.enable = true;

    # use the example session manager (no others are packaged yet so this is enabled by default,
    # no need to redefine it in your config for now)
    #media-session.enable = true;
  };

  # Enable touchpad support (enabled default in most desktopManager).
  # services.xserver.libinput.enable = true;

  # Define a user account. Don’t forget to set a password with ‘passwd’.
  users.users.${username} = {
    isNormalUser = true;
    description = username;
    extraGroups = [ "networkmanager" "wheel" ];
    shell = pkgs.zsh;
    packages = with pkgs; [
    #  thunderbird
    ];
    openssh.authorizedKeys.keys = [ sshPublicKey ];
  };

  # Unlocks the GNOME keyring at login so stored credentials (SSH keys, wifi
  # passwords, etc.) are available immediately without a second passphrase prompt.
  security.pam.services.login.enableGnomeKeyring = true;

  # Install firefox.
  programs.firefox.enable = true;

  programs.tmux.extraConfig = ''
    set -g mouse on
    set -g mode-keys vi
    bind-key -T copy-mode-vi MouseDragEnd1Pane send-keys -X copy-pipe-and-cancel "xclip -selection clipboard"
    bind-key -T copy-mode-vi y send-keys -X copy-pipe-and-cancel "xclip -selection clipboard"
  '';

  # Install ohmyzsh
  programs.zsh = {
    enable = true;
    ohMyZsh = {
      enable = true;
      theme = "afowler";
      plugins = [ "git" "sudo" "autojump" ];
    };
    interactiveShellInit = ''
      source ${pkgs.autojump}/share/autojump/autojump.zsh
    '';
  };

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    # editors
    vim
    neovim
    gcc          # to compile nvim treesitter
    tree-sitter  # treesitter CLI, required by nvim-treesitter to compile parsers
    luarocks     # lua package manager, required by some nvim plugins

    # Network tools
    curl
    nmap
    dig
    traceroute
    tcpdump
    wget

    # Version control
    git

    # file & archive
    rsync
    unzip
    tree

    # terminal quality of life
    tmux
    fzf
    jq
    autojump

    # clipboard
    xclip

    # Misc
    lsof
    strace
    which
    ripgrep

    nil          # nix LSP
    nixpkgs-fmt  # formatter nil_ls uses
    go           # go toolchain
    gopls        # go LSP
    rustup       # rust toolchain manager — run `rustup install stable` after rebuild

    # Identity management CLI — used to manage Kanidm users and OAuth2 clients
    kanidm_1_9

    # Backup tool
    restic
  ];

  # Some programs need SUID wrappers, can be configured further or are
  # started in user sessions.
  # programs.mtr.enable = true;
  # programs.gnupg.agent = {
  #   enable = true;
  #   enableSSHSupport = true;
  # };

  # List services that you want to enable:

  # Enable the OpenSSH daemon.
  # services.openssh.enable = true;

  # This value determines the NixOS release from which the default
  # settings for stateful data, like file locations and database versions
  # on your system were taken. It‘s perfectly fine and recommended to leave
  # this value at the release version of the first install of this system.
  # Before changing this value read the documentation for this option
  # (e.g. man configuration.nix or on https://nixos.org/nixos/options.html).
  system.stateVersion = "25.11"; # Did you read the comment?

  # SSH hardening:
  # - No root login: forces use of a named user account
  # - No password auth: key-only login, immune to brute-force password attacks
  # - MaxAuthTries: limits attempts per connection before disconnect
  # - LoginGraceTime: closes unauthenticated connections after 20s
  # - AllowUsers: whitelist of permitted logins; rejects any other account even if it exists
  services.openssh = {
    enable = true;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      MaxAuthTries = 3;
      LoginGraceTime = 20;
      AllowUsers = [ username ];
    };
  };

  # fail2ban: monitors auth logs and temporarily bans IPs that repeatedly fail to authenticate.
  # Protects against distributed brute-force attacks that stay under per-connection limits.
  services.fail2ban = {
    enable = true;
    maxretry = 5;
  };

  # Kernel hardening:
  # - tcp_syncookies: mitigates SYN flood DoS attacks
  # - rp_filter: drops packets with spoofed source IPs (reverse path filtering)
  # - accept_redirects=0: ignores ICMP redirect messages that could alter routing
  # - icmp_echo_ignore_broadcasts: prevents the server being used as a smurf attack amplifier
  boot.kernel.sysctl = {
    "net.ipv4.tcp_syncookies" = 1;
    "net.ipv4.conf.all.rp_filter" = 1;
    "net.ipv4.conf.all.accept_redirects" = 0;
    "net.ipv6.conf.all.accept_redirects" = 0;
    "net.ipv4.icmp_echo_ignore_broadcasts" = 1;
  };

  # Auto-upgrade: pulls and applies NixOS updates automatically.
  # allowReboot=false means it applies the new config but won't reboot automatically;
  # a manual reboot is needed to activate kernel updates.
  system.autoUpgrade = {
    enable = true;
    allowReboot = false;
  };

  # Require password for sudo even for wheel group members.
  # Prevents an unattended session from being escalated to root silently.
  security.sudo.wheelNeedsPassword = true;

  # Give sshd higher CPU scheduling priority and protect it from the OOM killer.
  # This ensures SSH remains accessible even when the server is under heavy load
  # or running out of memory — so you can always log in and kill runaway processes.
  # Nice=-10: lower value = higher priority (-20 is highest, 19 is lowest)
  # OOMScoreAdjust=-900: makes the kernel very unlikely to kill sshd when memory is low
  systemd.services.sshd.serviceConfig = {
    Nice = -10;
    OOMScoreAdjust = -900;
  };

  # Enable modern nix CLI (nix build, nix shell, nix eval, etc.) and flakes.
  # Both are still technically experimental but widely used and stable in practice.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  # enable tailscale
  services.tailscale.enable = true;
}
