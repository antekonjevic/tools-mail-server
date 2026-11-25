#!/usr/bin/env bash
# Create a mailbox. A strong password is generated and shown once, unless --prompt is given.
# The first mailbox of a domain also receives that domain's postmaster@, abuse@ and reports@ mail.
# Usage: mailctl add-mailbox <address> [--prompt]
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -ge 1 ]] || die "Usage: mailctl add-mailbox <address> [--prompt]"
a=$(lower "$1")
valid_address "$a" || die "'$a' is not a valid address (plus signs are not allowed in mailbox names)."
domain=${a#*@}
domain_exists "$domain" || die "$domain is not hosted yet. Run: mailctl add-domain $domain"
mailbox_exists "$a" && die "$a already exists. To change its password: mailctl reset-password $a"
alias_exists "$a" && die "$a is already an alias. Remove it first: mailctl remove-alias $a"

source "$(dirname "$0")/../lib/password.sh"
read_or_generate_password "${2:-}"
hash=$(password_hash "$PASSWORD")
printf '%s:%s\n' "$a" "$hash" >>"$DOVECOT_USERS"
info "created mailbox $a"

for local in postmaster abuse reports; do
  if ! alias_exists "$local@$domain" && ! mailbox_exists "$local@$domain"; then
    printf '%s %s\n' "$local@$domain" "$a" >>"$ALIASES_FILE"
    info "created alias $local@$domain → $a"
  fi
done

"$(dirname "$0")/apply.sh"

cat <<EOF

  Address:   $a
  Username:  $a
EOF
if [[ $PASSWORD_GENERATED == 1 ]]; then
  cat <<EOF
  Password:  $PASSWORD

  Save this password in your password manager now. It is not stored anywhere in readable form.
EOF
fi
cat <<EOF

  Mail app settings: IMAP $MAIL_HOSTNAME port 993 SSL/TLS, SMTP $MAIL_HOSTNAME port 465 SSL/TLS.
  Apple setup file:  mailctl apple-profile $a
EOF
