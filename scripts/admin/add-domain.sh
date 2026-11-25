#!/usr/bin/env bash
# Host a new domain: registers it, creates its DKIM key, and prints the DNS records to enter.
# Usage: mailctl add-domain <domain>
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -eq 1 ]] || die "Usage: mailctl add-domain <domain>"
d=$(lower "$1")
valid_domain "$d" || die "'$d' is not a valid domain name."

if domain_exists "$d"; then
  info "$d is already hosted"
else
  printf '%s %s\n' "$d" "$DKIM_SELECTOR" >>"$DOMAINS_FILE"
  info "added $d"
fi

sel=$(domain_selector "$d")
key=$(dkim_key_file "$d" "$sel")
if [[ ! -s $key ]]; then
  rspamadm dkim_keygen -b 2048 -s "$sel" -d "$d" -k "$key" >/dev/null
  chown _rspamd:_rspamd "$key"
  chmod 0640 "$key"
  info "created DKIM key $key"
fi

"$(dirname "$0")/apply.sh"

echo
"$(dirname "$0")/dns-records.sh" "$d"

cat <<EOF

Next:
  1. mailctl add-mailbox <name>@$d
  2. Enter the DNS records above at your DNS provider, MX last.
  3. Once mta-sts.$d and autoconfig.$d point here, add them to the certificate:
       mailctl cert-update
EOF
