#!/usr/bin/env bash
# Show the DNS records to enter at your DNS provider, and whether each is already live on the internet.
# Usage: mailctl dns-records              server records + every hosted domain
#        mailctl dns-records <domain>     one domain
#        mailctl dns-records --server     the server's own records (A, AAAA, PTR…)
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config

show() {  # show KEY NAME TYPE VALUE [NOTE]
  local key=$1 name=$2 type=$3 value=$4 note=${5:-} shown status
  case $type in
    TXT) shown=$(quoted_txt "$value") ;;
    *)   shown=$value ;;
  esac
  status=$(check_record "$key" "$name" "$type" "$value")
  case $status in
    OK*)      status="${C_GRN}${status}${C_OFF}" ;;
    *)        status="${C_YEL}${status}${C_OFF}" ;;
  esac
  printf '  %-6s %s%s\n' "$type" "$name" "${note:+   ($note)}"
  printf '         value: %s\n' "$shown"
  printf '         now:   %s\n\n' "$status"
}

server_records() {
  step "Server: $MAIL_HOSTNAME"
  echo "  DNS zone: $PRIMARY_DOMAIN. Reverse DNS (PTR) is not part of your DNS zone: it is set at the"
  echo "  hosting provider that owns the IP addresses (often a \"reverse DNS\" field, or a support request)."
  echo
  while IFS='|' read -r key name type value; do
    note=""
    [[ $key == ptr4 || $key == ptr6 ]] && note="set at your hosting provider"
    show "$key" "$name" "$type" "$value" "$note"
  done < <(expected_server_records)
}

domain_records() {
  local d=$1
  domain_exists "$d" || die "$d is not hosted. Run: mailctl add-domain $d"
  step "Domain: $d"
  echo "  DNS zone: $d. Most DNS consoles want only the part before \"$d\" as the record name"
  echo "  (empty or @ for $d itself). Long TXT values are shown split into quoted pieces; enter them as shown."
  echo
  while IFS='|' read -r key name type value; do
    note=""
    [[ $key == caa ]] && note="only Let's Encrypt may issue certificates; keep any CAA records your other services need"
    [[ $key == mx ]] && note="add this LAST, once everything above shows OK"
    show "$key" "$name" "$type" "$value" "$note"
  done < <(expected_domain_records "$d")
}

case ${1:-} in
  "")       server_records; while read -r d; do domain_records "$d"; done < <(list_domains) ;;
  --server) server_records ;;
  *)        domain_records "$(lower "$1")" ;;
esac
