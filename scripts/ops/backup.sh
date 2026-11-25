#!/usr/bin/env bash
# Encrypted backup with restic (S3 or any restic repository), while the server keeps running (Maildir is one file per
# message, so a live copy is consistent). Run nightly by mailserver-backup.timer.
# Usage: mailctl backup
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
load_secrets

# secrets.env is loaded with export, so restic sees RESTIC_PASSWORD and any backend credentials
export RESTIC_REPOSITORY="$BACKUP_REPOSITORY" RESTIC_CACHE_DIR=/var/cache/restic

trap 'printf "%sERROR:%s backup failed at line %s\n" "$C_RED" "$C_OFF" "$LINENO" >&2
      "$REPO_DIR/scripts/ops/notify.sh" "Backup failed" "The backup failed. Check: journalctl -u mailserver-backup" || true' ERR

# A freshly rebuilt server has no mailboxes yet. Backing it up would create an empty "latest"
# backup, which a later "mailctl restore --apply" would then restore.
if [[ -z $(list_mailboxes) ]]; then
  "$REPO_DIR/scripts/ops/notify.sh" "Backup skipped" "There are no mailboxes, so nothing was backed up. On a rebuilt server, restore first: mailctl restore --apply" || true
  die "There are no mailboxes on this server, so nothing was backed up. On a rebuilt server, restore first: mailctl restore --apply"
fi

# Make Valkey (spam learning data) write its current state to disk first
command -v valkey-cli >/dev/null && valkey-cli SAVE >/dev/null 2>&1 || true

paths=()
for p in "$VMAIL_DIR" "$STATE_DIR" /etc/dovecot /etc/postfix /etc/rspamd "$DKIM_DIR" /etc/nginx \
         "$WEB_ROOT" /etc/letsencrypt /var/lib/valkey; do
  [[ -e $p ]] && paths+=("$p")
done

step "Backing up to $RESTIC_REPOSITORY"
restic backup --tag nightly --exclude "$SECRETS_FILE" --exclude "$LOCK_FILE" "${paths[@]}"

step "Removing old backups"
prune=()
[[ $(date +%u) == 7 ]] && prune=(--prune)   # pruning frees storage; once a week is enough
restic forget --tag nightly --keep-daily "${BACKUP_KEEP_DAILY:-7}" --keep-weekly "${BACKUP_KEEP_WEEKLY:-4}" \
  --keep-monthly "${BACKUP_KEEP_MONTHLY:-6}" "${prune[@]}"

if [[ $(date +%u) == 7 ]]; then
  step "Weekly repository check"
  restic check --read-data-subset=5%
fi

if [[ $(date +%d) == 01 ]]; then
  step "Monthly restore test"
  "$REPO_DIR/scripts/ops/restore.sh" --verify
fi

install -d -m 0700 "$VAR_DIR"
touch "$VAR_DIR/last-backup-ok"
info "backup finished"
