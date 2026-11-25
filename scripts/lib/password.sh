#!/usr/bin/env bash
# Password helpers for mailbox scripts. Sourced after common.sh.
# shellcheck disable=SC2034  # PASSWORD and PASSWORD_GENERATED are read by the calling script

# read_or_generate_password [--prompt] → sets PASSWORD and PASSWORD_GENERATED
read_or_generate_password() {
  if [[ ${1:-} == "--prompt" ]]; then
    local again
    read -rsp "New password: " PASSWORD; echo
    read -rsp "Repeat password: " again; echo
    [[ $PASSWORD == "$again" ]] || die "The passwords do not match."
    (( ${#PASSWORD} >= 12 )) || die "Use at least 12 characters."
    PASSWORD_GENERATED=0
  else
    local raw
    raw=$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9')
    PASSWORD=${raw:0:24}
    PASSWORD_GENERATED=1
  fi
}

# The strongest scheme this Dovecot build supports
password_scheme() {
  local schemes
  schemes=$(doveadm pw -l)
  for s in ARGON2ID BLF-CRYPT SHA512-CRYPT; do
    if grep -qw -- "$s" <<<"$schemes"; then echo "$s"; return; fi
  done
  die "Dovecot supports none of ARGON2ID, BLF-CRYPT, SHA512-CRYPT."
}

password_hash() { doveadm pw -s "$(password_scheme)" -p "$1"; }
