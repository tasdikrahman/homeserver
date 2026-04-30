{ config, ... }:

# Restic backup to Hetzner Object Storage (S3-compatible) setup:
#
# 1. Create a bucket in the Hetzner Console (Object Storage → Create Bucket).
#    Note the bucket name and region (e.g. nbg1).
#
# 2. Create S3 credentials (Object Storage → S3 Credentials → Generate).
#
# 3. Create the secrets directory and files:
#    sudo mkdir -p /etc/restic
#
# 4. Write the repository password (used to encrypt backup data):
#    echo "your-strong-passphrase" | sudo install -m 600 /dev/stdin /etc/restic/password
#
# 5. Write the S3 credentials env file:
#    sudo install -m 600 /dev/null /etc/restic/env
#    printf 'AWS_ACCESS_KEY_ID=<your-access-key-id>\nAWS_SECRET_ACCESS_KEY=<your-secret-access-key>\n' \
#      | sudo tee /etc/restic/env > /dev/null
#
# 6. Initialise the repository once (run as root):
#    sudo env $(cat /etc/restic/env | xargs) restic \
#      -r s3:https://nbg1.your-objectstorage.com/<bucket-name> \
#      --password-file /etc/restic/password init
#
# Replace fsn1 with your chosen region and <bucket-name> with your actual bucket.

{
  services.restic.backups.hetzner = {
    # Repository on Hetzner Object Storage.
    # Format: s3:https://<region>.your-objectstorage.com/<bucket-name>
    # Set this to your actual bucket URL, e.g.:
    #   s3:https://fsn1.your-objectstorage.com/homeserver-backups
    repository = "s3:https://nbg1.your-objectstorage.com/homeserver-tasdikrahman";

    # Passphrase used to encrypt backup data at rest.
    passwordFile = "/etc/restic/password";

    # AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY for Hetzner Object Storage.
    environmentFile = "/etc/restic/env";

    paths = [
      "/etc"
      "/var/lib"
    ];

    exclude = [
      "/var/lib/docker"
      "/var/lib/containers"
      "/var/lib/systemd/coredump"
    ];

    # Run daily at 02:00.
    timerConfig = {
      OnCalendar = "02:00";
      Persistent = true;
    };

    # Keep the last 7 daily, 4 weekly, and 12 monthly snapshots.
    pruneOpts = [
      "--keep-daily 7"
      "--keep-weekly 4"
      "--keep-monthly 12"
    ];
  };

  systemd.tmpfiles.rules = [
    "f /etc/restic/password 0600 root root -"
    "f /etc/restic/env      0600 root root -"
  ];
}
