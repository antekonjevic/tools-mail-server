#!/usr/bin/env bash
# Runbook step 8: nightly encrypted backups with restic (S3 or any other restic repository). Safe to re-run.
# Needs: BACKUP_REPOSITORY in config/mailserver.env, and /etc/mailserver/secrets.env filled in.
# Usage: scripts/20-install-backups.sh
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

[[ $BACKUP_REPOSITORY != *CHANGE-ME* ]] || die "Set BACKUP_REPOSITORY in config/mailserver.env first."
# First run: only create the secrets file. That's an expected stop, not an error.
if [[ ! -f $SECRETS_FILE ]]; then
  install -m 0600 "$REPO_DIR/config/secrets.env.example" "$SECRETS_FILE"
  step "Secrets file created"
  cat <<EOF
$SECRETS_FILE was created from the example; nothing else was set up yet.
Fill it in, and keep a copy of every value in your password manager:
    nano $SECRETS_FILE
Then run this script again.
EOF
  exit 0
fi
chmod 0600 "$SECRETS_FILE"
load_secrets
required=(RESTIC_PASSWORD)
# S3 repositories need an access key; other backends take their own variables (see the restic docs)
[[ $BACKUP_REPOSITORY == s3:* ]] && required+=(AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY)
for v in "${required[@]}"; do
  [[ -n ${!v:-} ]] || die "$v is empty in $SECRETS_FILE"
done
(( ${#RESTIC_PASSWORD} >= 20 )) || die "RESTIC_PASSWORD is too short; generate one with: openssl rand -base64 32"

step "Installing restic"
apt-get -y -q install restic
export RESTIC_REPOSITORY="$BACKUP_REPOSITORY" RESTIC_CACHE_DIR=/var/cache/restic

step "Backup repository"
if out=$(restic cat config 2>&1); then
  info "repository already initialised at $RESTIC_REPOSITORY"
elif grep -qiE 'does not exist|Is there a repository' <<<"$out"; then
  restic init
else
  printf '%s\n' "$out" >&2
  die "Could not reach the backup repository. Check BACKUP_REPOSITORY and the credentials in $SECRETS_FILE."
fi

step "Nightly timer"
render systemd/mailserver-backup.service /etc/systemd/system/mailserver-backup.service
render systemd/mailserver-backup.timer /etc/systemd/system/mailserver-backup.timer
systemctl daemon-reload
systemctl enable --now mailserver-backup.timer >/dev/null 2>&1
info "backups run daily at $BACKUP_TIME UTC"

step "First backup"
if [[ -z $(list_mailboxes) ]]; then
  warn "No mailboxes yet, so no backup was made. If this is a rebuilt server, restore first: mailctl restore --apply"
else
  "$REPO_DIR/scripts/ops/backup.sh"
  restic snapshots
fi

step "Done"
echo "Next: the restore drill (docs/runbook.md, step 8), then scripts/30-install-monitoring.sh"
