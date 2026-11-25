#!/usr/bin/env bash
# Remove an alias.
# Usage: mailctl remove-alias <alias>
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
take_lock

[[ $# -eq 1 ]] || die "Usage: mailctl remove-alias <alias>"
alias=$(lower "$1")
alias_exists "$alias" || die "$alias is not an alias."

tmp=$(mktemp)
awk -v a="$alias" '$1 != a' "$ALIASES_FILE" >"$tmp"
install -m 0600 "$tmp" "$ALIASES_FILE"
rm -f "$tmp"
info "removed alias $alias"

"$(dirname "$0")/apply.sh"
