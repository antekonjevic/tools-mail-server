#!/usr/bin/env bash
# Restore from the restic backup.
# Usage:
#   mailctl restore --list                    list backups (snapshots)
#   mailctl restore --to <dir> [snapshot]     restore everything into a directory, to look at or copy single files
#   mailctl restore --verify                  test-restore settings, DKIM keys and a sample of mail from the latest backup
#   mailctl restore --apply [snapshot] [--yes]
#                                             put mail, mailboxes, aliases and DKIM keys back in place; configuration
#                                             stays as installed from this repository (mail services are stopped meanwhile)
#   snapshot defaults to "latest"
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
load_secrets

# secrets.env is loaded with export, so restic sees RESTIC_PASSWORD and any backend credentials
export RESTIC_REPOSITORY="$BACKUP_REPOSITORY" RESTIC_CACHE_DIR=/var/cache/restic

# What --apply puts back: mail and the server's state. Configuration (Postfix, Dovecot, Rspamd, nginx…)
# is not restored. It comes from this repository, and old copies of files that packages own would
# otherwise stay in place across package upgrades (dpkg keeps changed config files).
STATE_PATHS=("$VMAIL_DIR" "$STATE_DIR" "$DOVECOT_USERS" "$DKIM_DIR" /var/lib/valkey)
# How many random messages --verify restores (all of them could fill the disk)
VERIFY_SAMPLE=10

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

# On a rebuilt server restic is not installed yet (20-install-backups.sh runs after the restore)
command -v restic >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get -y -q install restic >/dev/null

count_messages() { find "$1" -type f \( -path '*/cur/*' -o -path '*/new/*' \) 2>/dev/null | wc -l; }

action=${1:-}
shift || true
case $action in
  --list)
    restic snapshots
    ;;

  --to)
    dir=${1:-}; snap=${2:-latest}
    [[ -n $dir ]] || usage
    install -d -m 0700 "$dir"
    restic restore "$snap" --target "$dir"
    info "restored $snap into $dir"
    ;;

  --verify)
    # Restores the settings, the DKIM keys and a random sample of messages, rather than all mail,
    # so the test needs little disk space. The weekly "restic check" reads a share of all stored data.
    scratch=$(mktemp -d /var/tmp/mailserver-restore-test.XXXXXX)
    trap 'rm -rf "$scratch"' EXIT
    mapfile -t backed_up < <(restic ls --recursive latest "$VMAIL_DIR" 2>/dev/null |
      grep -E "^$VMAIL_DIR/.+/(cur|new)/[^/]+\$" || true)
    sample=()
    if ((${#backed_up[@]})); then
      # Names with glob characters are skipped: restic would read them as patterns
      mapfile -t sample < <(printf '%s\n' "${backed_up[@]}" | grep -v '[][*?\\]' | shuf -n "$VERIFY_SAMPLE" || true)
    fi
    settings=("$STATE_DIR/domains" "$STATE_DIR/aliases" "$DOVECOT_USERS" /etc/postfix/main.cf /etc/dovecot/dovecot.conf)
    includes=()
    for p in "${settings[@]}" "$DKIM_DIR" "${sample[@]}"; do includes+=(--include "$p"); done
    restic restore latest --target "$scratch" "${includes[@]}" >/dev/null
    missing=()
    for f in "${settings[@]}" "${sample[@]}"; do
      [[ -s $scratch$f ]] || missing+=("$f")
    done
    while read -r d; do
      key=$(dkim_key_file "$d" "$(domain_selector "$d")")
      [[ -s $scratch$key ]] || missing+=("$key")
    done < <(list_domains)
    live=$(count_messages "$VMAIL_DIR")
    if ((${#missing[@]})); then
      "$REPO_DIR/scripts/ops/notify.sh" "Restore test failed" "Could not restore from the latest backup: ${missing[*]}" || true
      die "could not restore from the latest backup: ${missing[*]}"
    fi
    if (( live > 0 && ${#backed_up[@]} == 0 )); then
      "$REPO_DIR/scripts/ops/notify.sh" "Restore test failed" "The latest backup contains no messages, but $live are stored live." || true
      die "the latest backup contains no messages"
    fi
    info "restore test passed: restored a sample of ${#sample[@]} of ${#backed_up[@]} messages in the backup ($live live now), plus settings and DKIM keys"
    ;;

  --apply)
    snap=latest yes=0
    for arg in "$@"; do
      case $arg in --yes) yes=1 ;; *) snap=$arg ;; esac
    done
    restic snapshots "$snap" >/dev/null 2>&1 || [[ $snap == latest ]] || die "snapshot $snap not found"
    if (( ! yes )); then
      warn "This overwrites mail, mailboxes and their passwords, domains, aliases and DKIM keys with the backup '$snap'."
      read -rp "Type 'restore' to continue: " confirm
      [[ $confirm == restore ]] || die "Cancelled."
    fi
    includes=()
    for p in "${STATE_PATHS[@]}"; do includes+=(--include "$p"); done
    step "Stopping mail services"
    systemctl stop postfix dovecot rspamd valkey-server
    step "Restoring $snap: ${STATE_PATHS[*]}"
    restic restore "$snap" --target / "${includes[@]}"
    step "Fixing ownership"
    chown -R vmail:vmail "$VMAIL_DIR"
    chown -R _rspamd:_rspamd "$DKIM_DIR"
    chown root:dovecot "$DOVECOT_USERS"; chmod 0640 "$DOVECOT_USERS"
    [[ -d /var/lib/valkey ]] && chown -R valkey:valkey /var/lib/valkey
    step "Starting mail services"
    systemctl start valkey-server rspamd
    "$REPO_DIR/scripts/admin/apply.sh" --no-reload
    systemctl start dovecot postfix
    systemctl reload nginx
    info "restored $snap. Check the mailboxes in your mail apps."
    echo "    Configuration was not restored; it is the one installed from this repository."
    ;;

  *) usage ;;
esac
