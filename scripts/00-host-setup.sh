#!/usr/bin/env bash
# Runbook step 2: prepare and harden the server. Safe to re-run.
#   hostname, time zone, updates, swap, SSH hardening, firewall, automatic security updates, logging.
# Usage: scripts/00-host-setup.sh
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

# shellcheck source=/dev/null  # the server's own file
. /etc/os-release
if [[ ${VERSION_ID:-} != "26.04" ]]; then
  warn "These scripts were written and tested for Ubuntu 26.04; this is ${PRETTY_NAME:-unknown}."
fi

# ---------------------------------------------------------------- SSH safety check first
step "Checking SSH key login"
if [[ ! -s /root/.ssh/authorized_keys ]]; then
  die "/root/.ssh/authorized_keys is empty or missing. Password login is about to be turned off, which would lock you out."
fi
info "root has $(grep -cvE '^[[:space:]]*(#|$)' /root/.ssh/authorized_keys) SSH key(s)"

# ---------------------------------------------------------------- hostname and time
step "Hostname and time"
short=${MAIL_HOSTNAME%%.*}
if [[ $(hostname -f 2>/dev/null || hostname) != "$MAIL_HOSTNAME" ]]; then
  hostnamectl set-hostname "$MAIL_HOSTNAME"
  info "hostname set to $MAIL_HOSTNAME"
fi
if [[ -d /etc/cloud/cloud.cfg.d ]]; then
  render host/cloud-init.cfg /etc/cloud/cloud.cfg.d/99-mailserver.cfg
fi
hosts_line="$PUBLIC_IPV4 $MAIL_HOSTNAME $short"
if ! grep -qxF "$hosts_line" /etc/hosts; then
  # Rewritten in place (not replaced), so it also works where /etc/hosts is a mount
  tmp=$(mktemp)
  grep -vE "[[:space:]]${MAIL_HOSTNAME//./\\.}([[:space:]]|$)" /etc/hosts >"$tmp" || true
  echo "$hosts_line" >>"$tmp"
  cat "$tmp" >/etc/hosts
  rm -f "$tmp"
  info "added $MAIL_HOSTNAME to /etc/hosts"
fi
echo "$MAIL_HOSTNAME" >/etc/mailname
timedatectl set-timezone UTC 2>/dev/null || ln -sf /usr/share/zoneinfo/UTC /etc/localtime
timedatectl set-ntp true 2>/dev/null || warn "could not enable time synchronisation (fine inside a test container)"

# ---------------------------------------------------------------- packages
step "Installing updates and base packages"
apt-get update -q
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
apt-get -y -q install ufw unattended-upgrades needrestart curl ca-certificates gettext-base \
  bind9-dnsutils jq openssl rsync cron gpg

# ---------------------------------------------------------------- swap
step "Swap"
if swapon --show=NAME --noheadings | grep -q .; then
  info "swap already active"
else
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile >/dev/null
  fi
  if swapon /swapfile 2>/dev/null; then
    grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
    info "2 GB swap file enabled"
  else
    warn "could not enable swap (fine inside a test container)"
  fi
fi
echo 'vm.swappiness=10' >/etc/sysctl.d/90-mailserver.conf
sysctl -q -p /etc/sysctl.d/90-mailserver.conf 2>/dev/null || true

# ---------------------------------------------------------------- SSH
step "SSH: key login only"
render host/sshd.conf /etc/ssh/sshd_config.d/10-mailserver.conf
sshd -t || die "the SSH configuration test failed; nothing was reloaded"
systemctl try-reload-or-restart ssh.service 2>/dev/null || true
info "password login is off; root can log in with an SSH key only"

# ---------------------------------------------------------------- firewall
step "Firewall"
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw limit 22/tcp comment 'SSH' >/dev/null
ufw allow 25/tcp comment 'SMTP' >/dev/null
ufw allow 80/tcp comment 'HTTP: Lets Encrypt' >/dev/null
ufw allow 443/tcp comment 'HTTPS: MTA-STS, autoconfig' >/dev/null
ufw allow 465/tcp comment 'SMTP submission (TLS)' >/dev/null
ufw allow 993/tcp comment 'IMAP (TLS)' >/dev/null
ufw --force enable >/dev/null
ufw status verbose | sed 's/^/    /'

# ---------------------------------------------------------------- automatic updates
step "Automatic security updates"
render host/20auto-upgrades /etc/apt/apt.conf.d/20auto-upgrades
render host/52mailserver-unattended-upgrades /etc/apt/apt.conf.d/52mailserver-unattended-upgrades
render host/needrestart.conf /etc/needrestart/conf.d/90-mailserver.conf
systemctl enable --now unattended-upgrades.service >/dev/null 2>&1 || true
info "security updates install daily; reboots happen at $REBOOT_TIME UTC only when required"

# ---------------------------------------------------------------- logging and state
step "Logging"
render host/journald.conf /etc/systemd/journald.conf.d/90-mailserver.conf
systemctl restart systemd-journald
install -d -m 0700 "$STATE_DIR" "$VAR_DIR"

step "Done"
cat <<EOF
The server is prepared. Before logging out, open a NEW terminal and check that you can still log in:
    ssh root@$PUBLIC_IPV4

Next: scripts/10-install-mail.sh (needs the DNS record $MAIL_HOSTNAME → $PUBLIC_IPV4).
EOF
if [[ -f /run/reboot-required ]]; then
  cat <<EOF

The updates included a new kernel, so reboot once the new login works:
    reboot
Then log in again and continue with scripts/10-install-mail.sh.
EOF
fi
