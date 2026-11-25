#!/usr/bin/env bash
# Set a new password for a mailbox (generated unless --prompt is given).
# Usage: mailctl reset-password <address> [--prompt]
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -ge 1 ]] || die "Usage: mailctl reset-password <address> [--prompt]"
a=$(lower "$1")
mailbox_exists "$a" || die "$a is not a mailbox."

source "$(dirname "$0")/../lib/password.sh"
read_or_generate_password "${2:-}"
hash=$(password_hash "$PASSWORD")

tmp=$(mktemp)
awk -F: -v a="$a" -v h="$hash" 'BEGIN {OFS=":"} $1 == a {print a, h; next} {print}' "$DOVECOT_USERS" >"$tmp"
install -m 0640 -o root -g dovecot "$tmp" "$DOVECOT_USERS"
rm -f "$tmp"
info "password changed for $a (apps must log in again with the new one)"
if [[ $PASSWORD_GENERATED == 1 ]]; then
  printf '\n  Password:  %s\n\n  Save it in your password manager now. It is not stored anywhere in readable form.\n' "$PASSWORD"
fi
