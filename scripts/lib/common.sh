#!/usr/bin/env bash
# Shared helpers for the mail server scripts. This file is sourced, not run.
# shellcheck disable=SC2034  # variables defined here are used by the scripts that source it

set -Eeuo pipefail
umask 022

MS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$MS_LIB_DIR/../.." && pwd)"
TEMPLATE_DIR="$REPO_DIR/templates"
CONFIG_FILE="${MAILSERVER_CONFIG:-$REPO_DIR/config/mailserver.env}"

# Server-side state (not in the repo; included in backups)
STATE_DIR=/etc/mailserver
DOMAINS_FILE=$STATE_DIR/domains
ALIASES_FILE=$STATE_DIR/aliases
SECRETS_FILE=$STATE_DIR/secrets.env
ALERTS_FILE=$STATE_DIR/alerts.env
LOCK_FILE=$STATE_DIR/.lock
DOVECOT_USERS=/etc/dovecot/users
DKIM_DIR=/var/lib/rspamd/dkim
DKIM_SELECTOR_MAP=/etc/rspamd/dkim_selectors.map
VMAIL_DIR=/var/vmail
VMAIL_UID=5000
VAR_DIR=/var/lib/mailserver
WEB_ROOT=/var/www/mail
ACME_ROOT=/var/www/acme
PUBLIC_RESOLVER=1.1.1.1

if [[ -t 1 ]]; then
  C_RED=$'\e[31m' C_YEL=$'\e[33m' C_GRN=$'\e[32m' C_BLD=$'\e[1m' C_OFF=$'\e[0m'
else
  C_RED='' C_YEL='' C_GRN='' C_BLD='' C_OFF=''
fi

info() { printf '%s==>%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%sWARNING:%s %s\n' "$C_YEL" "$C_OFF" "$*" >&2; }
die()  { printf '%sERROR:%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; exit 1; }
step() { printf '\n%s## %s%s\n' "$C_BLD" "$*" "$C_OFF"; }

trap 'printf "%sERROR:%s command failed at %s line %s\n" "$C_RED" "$C_OFF" "$(basename "$0")" "$LINENO" >&2' ERR

require_root() { [[ $EUID -eq 0 ]] || die "Run this as root."; }

# ---------------------------------------------------------------- config

REQUIRED_VARS=(MAIL_HOSTNAME PRIMARY_DOMAIN PUBLIC_IPV4 ADMIN_EMAIL DKIM_SELECTOR
  MTA_STS_MODE MTA_STS_ID MESSAGE_SIZE_LIMIT BACKUP_TIME REBOOT_TIME)
# Variables that templates may use as ${NAME}. Anything else (e.g. Postfix's own $myhostname) is left alone.
# PUBLIC_IPV6 is optional (empty when the server has no IPv6); INET_PROTOCOLS is derived from it.
TEMPLATE_VARS=(REPO_DIR "${REQUIRED_VARS[@]}" PUBLIC_IPV6 INET_PROTOCOLS TLS_CIPHERS TLS_GROUPS)

# TLS policy for Postfix (25, 465), Dovecot (993) and nginx (443): TLS 1.2 ciphers with forward
# secrecy and authenticated encryption only, strongest first; key exchange over elliptic curves
# only (no finite-field Diffie-Hellman). TLS 1.3 keeps OpenSSL's cipher suites, which are all strong.
# This is Mozilla's "intermediate" profile without DHE, and passes internet.nl's checks.
export TLS_CIPHERS=ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256
export TLS_GROUPS=X25519MLKEM768:X25519:prime256v1:secp384r1

# The names reserved for examples (RFC 2606), and their subdomains. No real server uses them.
is_example_name() { [[ ${1,,} =~ (^|\.)example\.(com|org|net)$ ]]; }

load_config() {
  if [[ ! -r $CONFIG_FILE ]]; then
    die "Config file not found: $CONFIG_FILE
       Create it from the example and edit it: cp config/mailserver.env.example config/mailserver.env"
  fi
  set -a
  # shellcheck source=../../config/mailserver.env.example
  source "$CONFIG_FILE"
  set +a
  local v
  for v in "${REQUIRED_VARS[@]}"; do
    [[ -n ${!v:-} ]] || die "$v is not set in $CONFIG_FILE"
  done
  if is_example_name "$PRIMARY_DOMAIN" || is_example_name "$MAIL_HOSTNAME" || is_example_name "${ADMIN_EMAIL#*@}" ||
     [[ $PUBLIC_IPV4 == 203.0.113.* || ${PUBLIC_IPV6:-} == 2001:db8:* ]]; then
    die "$CONFIG_FILE still contains the example values (example.com/.org/.net, 203.0.113.x, 2001:db8::). Set your own."
  fi
  case $MTA_STS_MODE in testing|enforce|none) ;; *) die "MTA_STS_MODE must be testing, enforce or none";; esac
  PUBLIC_IPV6=${PUBLIC_IPV6:-}
  # Without a public IPv6 address, Postfix uses IPv4 only, so it never tries to deliver over IPv6
  if [[ -n $PUBLIC_IPV6 ]]; then INET_PROTOCOLS=all; else INET_PROTOCOLS=ipv4; fi
  export REPO_DIR PUBLIC_IPV6 INET_PROTOCOLS
}

has_ipv6() { [[ -n $PUBLIC_IPV6 ]]; }

load_secrets() {
  [[ -r $SECRETS_FILE ]] || die "Missing $SECRETS_FILE. Copy config/secrets.env.example there and fill it in."
  set -a
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  set +a
}

load_alerts() {
  if [[ -r $ALERTS_FILE ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$ALERTS_FILE"
    set +a
  fi
  ALERT_CHANNELS=${ALERT_CHANNELS:-}
}

# render TEMPLATE DEST [MODE] [OWNER:GROUP]
# Fills ${VARS} from TEMPLATE_VARS into templates/TEMPLATE and writes DEST only when the content changed.
render() {
  local src="$TEMPLATE_DIR/$1" dest=$2 mode=${3:-0644} owner=${4:-root:root} tmp vars
  [[ -r $src ]] || die "Template missing: $src"
  # shellcheck disable=SC2016  # the ${...} are for envsubst, not the shell
  vars=$(printf '${%s} ' "${TEMPLATE_VARS[@]}")
  tmp=$(mktemp)
  envsubst "$vars" <"$src" >"$tmp"
  install_file "$tmp" "$dest" "$mode" "$owner"
  rm -f "$tmp"
}

# install_file SOURCE DEST [MODE] [OWNER:GROUP] — copies only when the content changed
install_file() {
  local src=$1 dest=$2 mode=${3:-0644} owner=${4:-root:root}
  if [[ -f $dest ]] && cmp -s "$src" "$dest"; then
    chmod "$mode" "$dest"; chown "$owner" "$dest"
    return 0
  fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$src" "$dest"
  printf '    updated %s\n' "$dest"
}

# ---------------------------------------------------------------- validation

lower() { printf '%s' "${1,,}"; }

valid_domain() {
  [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# Local parts may not contain "+": it is the plus-addressing separator.
valid_address() {
  [[ $1 =~ ^[a-z0-9]([a-z0-9._-]{0,62}[a-z0-9])?@([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]
}

# ---------------------------------------------------------------- state lists

list_domains() {
  [[ -f $DOMAINS_FILE ]] || return 0
  awk '!/^[[:space:]]*(#|$)/ {print $1}' "$DOMAINS_FILE"
}

domain_selector() { awk -v d="$1" '!/^[[:space:]]*#/ && $1 == d {print $2}' "$DOMAINS_FILE"; }
domain_exists() { list_domains | grep -qxF "$1"; }

list_mailboxes() {
  [[ -f $DOVECOT_USERS ]] || return 0
  awk -F: '!/^[[:space:]]*(#|$)/ {print $1}' "$DOVECOT_USERS"
}

mailbox_exists() { list_mailboxes | grep -qxF "$1"; }

# Prints "alias targets" pairs (targets comma-separated)
list_aliases() {
  [[ -f $ALIASES_FILE ]] || return 0
  awk '!/^[[:space:]]*(#|$)/ {print $1, $2}' "$ALIASES_FILE"
}

alias_exists() { list_aliases | awk '{print $1}' | grep -qxF "$1"; }

# Serialises admin commands. Scripts called by a script that holds the lock inherit it.
take_lock() {
  [[ ${MAILCTL_LOCK_HELD:-} == 1 ]] && return 0
  install -d -m 0700 "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -w 30 9 || die "Another mailserver command is still running."
  export MAILCTL_LOCK_HELD=1
}

# ---------------------------------------------------------------- services

reload_if_active() {
  local unit
  for unit in "$@"; do
    if systemctl is-active --quiet "$unit"; then systemctl reload "$unit"; fi
  done
}

# ---------------------------------------------------------------- DNS

# Queries a public resolver, so results show what the rest of the internet sees.
dns() { dig +short +time=3 +tries=2 "@$PUBLIC_RESOLVER" "$@" 2>/dev/null || true; }

# TXT records with multi-string values joined, one record per line, without quotes
dns_txt() { dns TXT "$1" | sed -e 's/" "//g' -e 's/"//g'; }

dkim_key_file() { printf '%s/%s.%s.key' "$DKIM_DIR" "$1" "$2"; }

# The DKIM TXT value for DOMAIN SELECTOR, derived from the private key
dkim_txt_value() {
  local key
  key=$(dkim_key_file "$1" "$2")
  [[ -r $key ]] || return 1
  printf 'v=DKIM1; k=rsa; p=%s' "$(openssl pkey -in "$key" -pubout -outform DER 2>/dev/null | base64 -w0)"
}

# Splits a TXT value into quoted strings of at most 255 characters (the DNS limit per string),
# the form most DNS providers expect for long values such as DKIM keys
quoted_txt() { fold -w 255 <<<"$1" | sed 's/.*/"&"/' | paste -sd' ' -; }

# Prints the records a domain needs, one per line: KEY|NAME|TYPE|VALUE (MX last)
expected_domain_records() {
  local d=$1 sel dkim
  sel=$(domain_selector "$d")
  dkim=$(dkim_txt_value "$d" "$sel" || echo "(DKIM key missing: run mailctl add-domain $d)")
  printf '%s\n' \
    "spf|$d|TXT|v=spf1 ip4:$PUBLIC_IPV4${PUBLIC_IPV6:+ ip6:$PUBLIC_IPV6} ~all" \
    "dkim|$sel._domainkey.$d|TXT|$dkim" \
    "dmarc|_dmarc.$d|TXT|v=DMARC1; p=none; rua=mailto:reports@$d" \
    "cname|mta-sts.$d|CNAME|$MAIL_HOSTNAME" \
    "mtasts|_mta-sts.$d|TXT|v=STSv1; id=$MTA_STS_ID" \
    "tlsrpt|_smtp._tls.$d|TXT|v=TLSRPTv1; rua=mailto:reports@$d" \
    "cname|autoconfig.$d|CNAME|$MAIL_HOSTNAME" \
    "srv|_imaps._tcp.$d|SRV|0 1 993 $MAIL_HOSTNAME" \
    "srv|_submissions._tcp.$d|SRV|0 1 465 $MAIL_HOSTNAME" \
    "caa|$d|CAA|0 issue \"letsencrypt.org\"" \
    "mx|$d|MX|10 $MAIL_HOSTNAME"
}

expected_server_records() {
  echo "a|$MAIL_HOSTNAME|A|$PUBLIC_IPV4"
  if has_ipv6; then echo "aaaa|$MAIL_HOSTNAME|AAAA|$PUBLIC_IPV6"; fi
  echo "spf|$MAIL_HOSTNAME|TXT|v=spf1 a -all"
  echo "ptr4|$PUBLIC_IPV4|PTR|$MAIL_HOSTNAME"
  if has_ipv6; then echo "ptr6|$PUBLIC_IPV6|PTR|$MAIL_HOSTNAME"; fi
}

# check_record KEY NAME TYPE VALUE → prints "OK", "MISSING" or "DIFFERENT: <current>"
check_record() {
  local key=$1 name=$2 type=$3 want=$4 have
  case $key in
    spf)    have=$(dns_txt "$name" | grep -i '^v=spf1' || true) ;;
    dmarc)  have=$(dns_txt "$name" | grep -i '^v=DMARC1' || true)
            if [[ -n $have ]]; then echo "OK (current: $have)"; return; fi ;;
    dkim|mtasts|tlsrpt) have=$(dns_txt "$name") ;;
    mx)     have=$(dns MX "$name" | sed 's/\.$//') ;;
    srv)    have=$(dns SRV "$name" | sed 's/\.$//') ;;
    caa)    have=$(dns CAA "$name") ;;
    cname)  have=$(dns CNAME "$name" | sed 's/\.$//')
            if [[ -z $have ]] && dns A "$name" | grep -qxF "$PUBLIC_IPV4"; then echo "OK (A record)"; return; fi ;;
    a)      have=$(dns A "$name") ;;
    aaaa)   have=$(dns AAAA "$name") ;;
    ptr4|ptr6) have=$(dns -x "$name" | sed 's/\.$//') ;;
    *)      die "unknown record check: $key" ;;
  esac
  if [[ -z $have ]]; then
    echo "MISSING"
  elif grep -qixF -- "$want" <<<"$have"; then
    echo "OK"
  else
    echo "DIFFERENT: $(paste -sd' ' - <<<"$have")"
  fi
}
