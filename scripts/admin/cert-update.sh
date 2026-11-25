#!/usr/bin/env bash
# Get or update the Let's Encrypt certificate. It covers the mail hostname plus mta-sts.<domain>
# and autoconfig.<domain> for every hosted domain whose DNS already points to this server.
# Run it again after adding those DNS records for a new domain.
# Usage: mailctl cert-update [--force] [--self-signed]
#   --self-signed  local testing only: create a self-signed certificate instead
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config

force=0 self_signed=0
for arg in "$@"; do
  case $arg in
    --force) force=1 ;;
    --self-signed) self_signed=1 ;;
    *) die "Usage: mailctl cert-update [--force] [--self-signed]" ;;
  esac
done

live="/etc/letsencrypt/live/$MAIL_HOSTNAME"
names=("$MAIL_HOSTNAME")
skipped=()

if (( ! self_signed )); then
  dns A "$MAIL_HOSTNAME" | grep -qxF "$PUBLIC_IPV4" || die "$MAIL_HOSTNAME does not resolve to $PUBLIC_IPV4."
fi
while read -r d; do
  for n in "mta-sts.$d" "autoconfig.$d"; do
    if (( self_signed )) || dns A "$n" | grep -qxF "$PUBLIC_IPV4"; then names+=("$n"); else skipped+=("$n"); fi
  done
done < <(list_domains)

wanted=$(printf '%s\n' "${names[@]}" | sort)
current=""
if [[ -r $live/cert.pem ]]; then
  current=$(openssl x509 -in "$live/cert.pem" -noout -ext subjectAltName 2>/dev/null |
    grep -o 'DNS:[^,]*' | cut -d: -f2 | sort || true)
fi

if [[ $wanted == "$current" ]] && (( ! force )); then
  info "the certificate already covers: $(paste -sd' ' - <<<"$wanted")"
elif (( self_signed )); then
  warn "creating a SELF-SIGNED certificate (testing only; mail clients and other servers will not trust it)"
  install -d -m 0755 "$live"
  san=$(printf 'DNS:%s,' "${names[@]}")
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 30 \
    -subj "/CN=$MAIL_HOSTNAME" -addext "subjectAltName=${san%,}" \
    -keyout "$live/privkey.pem" -out "$live/cert.pem" 2>/dev/null
  cp "$live/cert.pem" "$live/fullchain.pem"
  chmod 0600 "$live/privkey.pem"
  touch "$live/SELF-SIGNED"
else
  # A test certificate left behind would block certbot
  [[ -f $live/SELF-SIGNED ]] && rm -rf "$live"
  email_args=(--register-unsafely-without-email)
  [[ -n ${ACME_EMAIL:-} ]] && email_args=(--email "$ACME_EMAIL")
  domain_args=()
  for n in "${names[@]}"; do domain_args+=(-d "$n"); done
  if ! certbot certonly --webroot -w "$ACME_ROOT" --cert-name "$MAIL_HOSTNAME" "${domain_args[@]}" \
    --non-interactive --agree-tos "${email_args[@]}"; then
    die "Let's Encrypt could not issue the certificate; certbot's reason is above. Most often port 80 can't be
       reached from the internet: check for a firewall at your hosting provider (docs/runbook.md, step 0).
       Let's Encrypt allows only a few failed attempts per hour, so fix the cause before trying again."
  fi
  info "certificate issued for: ${names[*]}"
fi

reload_if_active postfix dovecot nginx

if ((${#skipped[@]})); then
  warn "not in the certificate yet, because their DNS does not point here: ${skipped[*]}"
  echo "         Add the CNAME records (mailctl dns-records), then run: mailctl cert-update"
fi
