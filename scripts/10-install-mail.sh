#!/usr/bin/env bash
# Runbook step 3: install and configure the mail stack. Safe to re-run; re-run it after changing any template.
#   Postfix, Dovecot, Rspamd (+ Valkey, Unbound), nginx, certbot, fail2ban.
# Usage: scripts/10-install-mail.sh [--self-signed]
#   --self-signed  use a self-signed certificate instead of Let's Encrypt (local testing only)
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

SELF_SIGNED=0
[[ ${1:-} == "--self-signed" ]] && SELF_SIGNED=1

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# Key that signs Rspamd's apt repository (https://rspamd.com/apt-stable/gpg.key)
RSPAMD_KEY_FINGERPRINT="3FA347D5E599BE4595CA2576FFA232EDBF21E25E"

# ---------------------------------------------------------------- preconditions
step "Checking preconditions"
[[ -f /etc/ssh/sshd_config.d/10-mailserver.conf ]] || die "Run scripts/00-host-setup.sh first."
command -v envsubst >/dev/null || die "envsubst missing: run scripts/00-host-setup.sh first."
if (( ! SELF_SIGNED )); then
  if ! dns A "$MAIL_HOSTNAME" | grep -qxF "$PUBLIC_IPV4"; then
    die "$MAIL_HOSTNAME does not resolve to $PUBLIC_IPV4 yet. Create the A record at your DNS provider first (docs/runbook.md, step 0)."
  fi
  info "$MAIL_HOSTNAME resolves to $PUBLIC_IPV4"
  if [[ $(dns -x "$PUBLIC_IPV4" | sed 's/\.$//') != "$MAIL_HOSTNAME" ]]; then
    warn "Reverse DNS for $PUBLIC_IPV4 is not $MAIL_HOSTNAME yet. Set it at your hosting provider before sending mail."
  fi
fi

# ---------------------------------------------------------------- packages
step "Rspamd repository"
# shellcheck source=/dev/null  # the server's own file
. /etc/os-release
keyfile=/etc/apt/keyrings/rspamd.asc
if [[ ! -s $keyfile ]]; then
  install -d -m 0755 /etc/apt/keyrings
  tmpkey=$(mktemp)
  curl -fsSL https://rspamd.com/apt-stable/gpg.key -o "$tmpkey"
  fpr=$(gpg --show-keys --with-colons "$tmpkey" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')
  [[ $fpr == "$RSPAMD_KEY_FINGERPRINT" ]] || die "Rspamd signing key fingerprint mismatch (got '$fpr'). Not adding the repository."
  install -m 0644 "$tmpkey" "$keyfile"
  rm -f "$tmpkey"
fi
cat >/etc/apt/sources.list.d/rspamd.sources.new <<EOF
Types: deb
URIs: https://rspamd.com/apt-stable/
Suites: ${VERSION_CODENAME}
Components: main
Signed-By: $keyfile
EOF
install_file /etc/apt/sources.list.d/rspamd.sources.new /etc/apt/sources.list.d/rspamd.sources
rm -f /etc/apt/sources.list.d/rspamd.sources.new

step "Installing packages"
debconf-set-selections <<EOF
postfix postfix/main_mailer_type select No configuration
postfix postfix/mailname string $MAIL_HOSTNAME
EOF
apt-get update -q
packages=(postfix dovecot-core dovecot-imapd dovecot-lmtpd dovecot-sieve
  rspamd valkey-server unbound nginx certbot fail2ban swaks)
# shellcheck disable=SC2016  # ${db:Status-Status} is a dpkg-query field, not a shell variable
installed() { [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]; }
new_packages=0
for p in "${packages[@]}"; do installed "$p" || new_packages=1; done
# A newly installed service starts at once with Ubuntu's default configuration; Dovecot's would
# accept logins of system accounts on port 993. So service starts are blocked while packages are
# installed. This script starts every service itself further down, once its configuration is in
# place. A policy-rc.d that already exists is left alone.
policy=/usr/sbin/policy-rc.d blocked=0
if (( new_packages )) && [[ ! -e $policy ]]; then
  printf '#!/bin/sh\n# Temporary, from 10-install-mail.sh: no service starts while packages are installed\nexit 101\n' >"$policy"
  chmod 0755 "$policy"
  blocked=1
  trap 'rm -f "$policy"' EXIT
fi
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold install "${packages[@]}"
if (( blocked )); then
  rm -f "$policy"
  trap - EXIT
fi
info "Postfix $(postconf -d -h mail_version 2>/dev/null || echo '?'), Dovecot $(dovecot --version | awk '{print $1}'), Rspamd $(rspamd --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"

# ---------------------------------------------------------------- users and directories
step "Users and directories"
getent group vmail >/dev/null || groupadd --gid "$VMAIL_UID" vmail
getent passwd vmail >/dev/null || useradd --uid "$VMAIL_UID" --gid vmail --home-dir "$VMAIL_DIR" \
  --no-create-home --shell /usr/sbin/nologin vmail
install -d -m 0700 -o vmail -g vmail "$VMAIL_DIR"
install -d -m 0700 "$STATE_DIR" "$VAR_DIR"
install -d -m 0755 "$WEB_ROOT/.well-known" "$WEB_ROOT/autoconfig" "$ACME_ROOT"
# Earlier versions served one autoconfig file that listed every hosted domain
rm -rf "$WEB_ROOT/mail"
install -d -m 0750 -o _rspamd -g _rspamd "$DKIM_DIR"
[[ -f $DOMAINS_FILE ]] || printf '# domain  dkim-selector   (managed with mailctl)\n' >"$DOMAINS_FILE"
[[ -f $ALIASES_FILE ]] || printf '# alias  target[,target...]   (managed with mailctl)\n' >"$ALIASES_FILE"
[[ -f $DOVECOT_USERS ]] || printf '# address:password-hash   (managed with mailctl)\n' >"$DOVECOT_USERS"
chown root:dovecot "$DOVECOT_USERS"; chmod 0640 "$DOVECOT_USERS"
chmod 0600 "$DOMAINS_FILE" "$ALIASES_FILE"

# ---------------------------------------------------------------- configuration
step "Writing configuration"
# Postfix
render postfix/main.cf /etc/postfix/main.cf
render postfix/submission_header_checks /etc/postfix/submission_header_checks
[[ -f /etc/postfix/master.cf ]] || cp /usr/share/postfix/master.cf.dist /etc/postfix/master.cf
# Port 465: TLS from the first byte, login required, sender must match the login
postconf -M "submissions/inet=submissions inet n - y - - smtpd"
for p in \
  "syslog_name=postfix/submissions" \
  "smtpd_tls_wrappermode=yes" \
  "smtpd_tls_security_level=encrypt" \
  "smtpd_sasl_auth_enable=yes" \
  "smtpd_client_restrictions=permit_sasl_authenticated,reject" \
  "smtpd_sender_restrictions=reject_sender_login_mismatch,permit_sasl_authenticated,reject" \
  "smtpd_relay_restrictions=permit_sasl_authenticated,reject" \
  "smtpd_recipient_restrictions=reject_non_fqdn_recipient,reject_unknown_recipient_domain,permit_sasl_authenticated,reject" \
  "milter_macro_daemon_name=ORIGINATING" \
  "cleanup_service_name=submission-cleanup"; do
  postconf -P "submissions/inet/$p"
done
postconf -M "submission-cleanup/unix=submission-cleanup unix n - y - 0 cleanup"
postconf -P "submission-cleanup/unix/header_checks=regexp:/etc/postfix/submission_header_checks"
# Port 587 is not used
postconf -MX submission/inet 2>/dev/null || true
render postfix/aliases /etc/aliases
newaliases

# Dovecot
render dovecot/dovecot.conf /etc/dovecot/dovecot.conf 0644 root:dovecot
install -d -m 0755 /etc/dovecot/sieve/bin
# (before.sieve lists the hosted domains, so "mailctl apply" writes it, further down)
for f in learn-spam.sieve learn-ham.sieve; do
  install_file "$TEMPLATE_DIR/dovecot/sieve/$f" "/etc/dovecot/sieve/$f"
done
for f in learn-spam.sh learn-ham.sh; do
  install_file "$TEMPLATE_DIR/dovecot/sieve/bin/$f" "/etc/dovecot/sieve/bin/$f" 0755
done

# Rspamd
for dir in local.d override.d; do
  for f in "$TEMPLATE_DIR/rspamd/$dir"/*; do
    render "rspamd/$dir/$(basename "$f")" "/etc/rspamd/$dir/$(basename "$f")"
  done
done
# Logged-in users may use only their own addresses in the From header
install_file "$TEMPLATE_DIR/rspamd/rspamd.local.lua" /etc/rspamd/rspamd.local.lua
[[ -f $DKIM_SELECTOR_MAP ]] || install -m 0644 /dev/null "$DKIM_SELECTOR_MAP"

# Unbound, fail2ban, certbot hook
render unbound/mailserver.conf /etc/unbound/unbound.conf.d/mailserver.conf
render fail2ban/mailserver-dovecot.conf /etc/fail2ban/filter.d/mailserver-dovecot.conf
render fail2ban/mailserver.local /etc/fail2ban/jail.d/mailserver.local
render letsencrypt/deploy-hook.sh /etc/letsencrypt/renewal-hooks/deploy/mailserver-reload.sh 0755

# nginx: port 80 first; port 443 once a certificate exists
rm -f /etc/nginx/sites-enabled/default
render nginx/mailserver-http.conf /etc/nginx/sites-available/mailserver-http.conf
render nginx/mailserver-https.conf /etc/nginx/sites-available/mailserver-https.conf
ln -sf /etc/nginx/sites-available/mailserver-http.conf /etc/nginx/sites-enabled/mailserver-http.conf

# ---------------------------------------------------------------- supporting services
step "Starting supporting services"
# Unbound's DNSSEC root key is normally created on its first start; the config check needs it now
if [[ ! -s /var/lib/unbound/root.key ]]; then
  /usr/libexec/unbound-helper root_trust_anchor_update || true
fi
unbound-checkconf >/dev/null
systemctl enable --now unbound valkey-server >/dev/null 2>&1
systemctl restart unbound
nginx -t 2>/dev/null || nginx -t
systemctl enable --now nginx >/dev/null 2>&1
systemctl reload nginx

# ---------------------------------------------------------------- certificate
step "TLS certificate"
if (( SELF_SIGNED )); then
  "$REPO_DIR/scripts/admin/cert-update.sh" --self-signed
else
  "$REPO_DIR/scripts/admin/cert-update.sh"
fi
ln -sf /etc/nginx/sites-available/mailserver-https.conf /etc/nginx/sites-enabled/mailserver-https.conf
nginx -t 2>/dev/null || nginx -t
systemctl reload nginx

# ---------------------------------------------------------------- mail services
step "Generating mail tables and starting mail services"
"$REPO_DIR/scripts/admin/apply.sh" --no-reload
for f in before learn-spam learn-ham; do
  sievec "/etc/dovecot/sieve/$f.sieve"
done
postfix check
doveconf -n >/dev/null
rspamadm configtest >/dev/null
systemctl enable rspamd postfix dovecot fail2ban >/dev/null 2>&1
systemctl restart rspamd postfix dovecot fail2ban

# ---------------------------------------------------------------- admin command
ln -sf "$REPO_DIR/scripts/mailctl" /usr/local/sbin/mailctl

# ---------------------------------------------------------------- checks
step "Checking that everything is listening"
sleep 2
missing=0
for port in 25 465 993 80 443; do
  if ss -Hltn "sport = :$port" | grep -q .; then
    info "port $port is listening"
  else
    warn "port $port is NOT listening"; missing=1
  fi
done
for port in 110 143 587 995 4190; do
  if ss -Hltn "sport = :$port" | grep -q .; then warn "port $port is listening but should not be"; missing=1; fi
done
(( missing == 0 )) || die "Some services are not listening as expected. Check: journalctl -xe"

step "Done"
cat <<EOF
The mail stack is installed. Next:
    mailctl add-domain $PRIMARY_DOMAIN
    mailctl add-mailbox $ADMIN_EMAIL
Then follow docs/runbook.md to enter the DNS records.
EOF
