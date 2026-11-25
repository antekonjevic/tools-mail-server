#!/usr/bin/env bash
# Stop hosting a domain. It must have no mailboxes or aliases left. The DKIM key is kept.
# Usage: mailctl remove-domain <domain>
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -eq 1 ]] || die "Usage: mailctl remove-domain <domain>"
d=$(lower "$1")
domain_exists "$d" || die "$d is not hosted."

left=$( { list_mailboxes; list_aliases | awk '{print $1}'; } | grep "@$d\$" || true)
[[ -z $left ]] || die "Remove these first: $(paste -sd' ' - <<<"$left")"

tmp=$(mktemp)
awk -v d="$d" '$1 != d' "$DOMAINS_FILE" >"$tmp"
install -m 0600 "$tmp" "$DOMAINS_FILE"
rm -f "$tmp"
info "removed $d. Delete its DNS records at your DNS provider, starting with MX."

"$(dirname "$0")/apply.sh"
