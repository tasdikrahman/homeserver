{ config, pkgs, ... }:

{
  virtualisation.podman = {
    enable = true;
    # Exposes a Docker-compatible socket and `docker` CLI alias so any tooling
    # that expects Docker works without modification.
    dockerCompat = true;
  };

  # Declares podman as the OCI runtime; NixOS generates systemd units for each
  # container defined under virtualisation.oci-containers.containers.*.
  virtualisation.oci-containers.backend = "podman";
}
