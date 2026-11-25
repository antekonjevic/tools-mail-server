#!/usr/bin/env bash
# Remove a mailbox. Its stored mail is kept unless --delete-mail is given.
# Usage: mailctl remove-mailbox <address> [--delete-mail]
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -ge 1 ]] || die "Usage: mailctl remove-mailbox <address> [--delete-mail]"
a=$(lower "$1")
mailbox_exists "$a" || die "$a is not a mailbox."

pointing=$(list_aliases | awk -v a="$a" '{n = split($2, t, ","); for (i = 1; i <= n; i++) if (t[i] == a) print $1}')
if [[ -n $pointing ]]; then
  die "These aliases deliver to $a; remove or re-point them first: $(paste -sd' ' - <<<"$pointing")"
fi

tmp=$(mktemp)
awk -F: -v a="$a" '$1 != a' "$DOVECOT_USERS" >"$tmp"
install -m 0640 -o root -g dovecot "$tmp" "$DOVECOT_USERS"
rm -f "$tmp"
info "removed mailbox $a"

maildir="$VMAIL_DIR/${a#*@}/${a%@*}"
if [[ ${2:-} == "--delete-mail" && -d $maildir ]]; then
  read -rp "Type the address again to permanently delete its mail: " confirm
  [[ $confirm == "$a" ]] || die "Not confirmed; the mail in $maildir was kept."
  rm -rf -- "$maildir"
  info "deleted $maildir"
elif [[ -d $maildir ]]; then
  info "its mail is kept in $maildir"
fi

"$(dirname "$0")/apply.sh"
