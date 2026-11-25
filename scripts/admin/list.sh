#!/usr/bin/env bash
# Show hosted domains, mailboxes and aliases.
# Usage: mailctl list
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config

step "Domains (DKIM selector)"
awk '!/^[[:space:]]*(#|$)/ {printf "  %-32s %s\n", $1, $2}' "$DOMAINS_FILE"

step "Mailboxes"
while read -r m; do
  dir="$VMAIL_DIR/${m#*@}/${m%@*}"
  size=$( [[ -d $dir ]] && du -sh "$dir" 2>/dev/null | cut -f1 || echo "empty")
  printf '  %-40s %s\n' "$m" "$size"
done < <(list_mailboxes)

step "Aliases"
list_aliases | awk '{printf "  %-40s → %s\n", $1, $2}'
