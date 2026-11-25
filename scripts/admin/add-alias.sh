#!/usr/bin/env bash
# Create an alias, or change where an existing alias delivers.
# Usage: mailctl add-alias <alias> <target>[,<target>...]
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -eq 2 ]] || die "Usage: mailctl add-alias <alias> <target>[,<target>...]"
alias=$(lower "$1")
targets=$(lower "$2")
valid_address "$alias" || die "'$alias' is not a valid address."
domain_exists "${alias#*@}" || die "${alias#*@} is not hosted. Run: mailctl add-domain ${alias#*@}"
mailbox_exists "$alias" && die "$alias is a mailbox, so it cannot also be an alias."

IFS=',' read -ra target_list <<<"$targets"
for t in "${target_list[@]}"; do
  [[ $t =~ ^[^@[:space:]]+@[^@[:space:]]+\.[a-z]{2,}$ ]] || die "'$t' is not a valid address."
  [[ $t == "$alias" ]] && die "An alias cannot point to itself."
  if domain_exists "${t#*@}"; then
    mailbox_exists "$t" || die "$t is not a mailbox on this server. Create it first, or point the alias at an existing mailbox."
  else
    warn "$t is outside this server. Forwarded mail can fail SPF checks at the receiver; DKIM usually still passes."
  fi
done

tmp=$(mktemp)
awk -v a="$alias" '$1 != a' "$ALIASES_FILE" >"$tmp"
printf '%s %s\n' "$alias" "$targets" >>"$tmp"
install -m 0600 "$tmp" "$ALIASES_FILE"
rm -f "$tmp"
info "alias $alias → $targets"

"$(dirname "$0")/apply.sh"
