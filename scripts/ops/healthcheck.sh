#!/usr/bin/env bash
# Health checks, run by systemd timers. Each problem is alerted once, repeated daily while it
# lasts, and followed by a "resolved" message when it clears.
# Usage: healthcheck.sh frequent|daily [--verbose]
source "$(dirname "$0")/../lib/common.sh"
require_root
load_config
load_alerts

mode=${1:-frequent}
verbose=0
[[ ${2:-} == "--verbose" ]] && verbose=1
alert_dir="$VAR_DIR/alerts"
install -d -m 0700 "$alert_dir"
problems=0

# report CHECK-ID STATUS(ok|fail) MESSAGE [CONFIRMATIONS]
# CONFIRMATIONS: how many failing runs in a row before alerting (default 1)
# A failing check keeps three lines in $alert_dir/<id>: failing runs in a row, "pending" or
# "alerted", and when the last alert went out (seconds since 1970).
report() {
  local id=$1 status=$2 msg=$3 need=${4:-1} state="$alert_dir/$1" count=0 phase=pending alerted_at=0 now
  now=$(date +%s)
  if [[ -f $state ]]; then
    { read -r count; read -r phase; read -r alerted_at; } <"$state" || true
    count=${count:-0} phase=${phase:-pending}
    # State files from before the alert time was stored: use the file's time instead
    alerted_at=${alerted_at:-$(stat -c %Y "$state")}
  fi
  if [[ $status == ok ]]; then
    ((verbose)) && printf '  %sOK%s    %s\n' "$C_GRN" "$C_OFF" "$msg"
    if [[ -f $state ]]; then
      if [[ $phase == alerted ]]; then
        "$REPO_DIR/scripts/ops/notify.sh" "Resolved: $id" "$msg" || true
      fi
      rm -f "$state"
    fi
    return 0
  fi
  problems=$((problems + 1))
  ((verbose)) && printf '  %sFAIL%s  %s\n' "$C_RED" "$C_OFF" "$msg"
  count=$((count + 1))
  # Alert on the first confirmed failure, then again once a day while it lasts
  if (( count >= need )) && { [[ $phase != alerted ]] || (( now - alerted_at >= 86400 )); }; then
    "$REPO_DIR/scripts/ops/notify.sh" "Problem: $id" "$msg" || true
    phase=alerted alerted_at=$now
  fi
  printf '%s\n%s\n%s\n' "$count" "$phase" "$alerted_at" >"$state"
}

# Checks the listening socket rather than connecting, so the logs don't fill with aborted logins
port_open() { ss -Hltn "sport = :$1" | grep -q .; }

frequent_checks() {
  local unit port pct mount queue count oldest age
  for unit in postfix dovecot rspamd valkey-server unbound nginx fail2ban; do
    if systemctl is-active --quiet "$unit"; then
      report "service-$unit" ok "$unit is running"
    else
      report "service-$unit" fail "$unit is not running. Check: systemctl status $unit" 2
    fi
  done
  for port in 25 465 993 443; do
    if port_open "$port"; then
      report "port-$port" ok "port $port answers"
    else
      report "port-$port" fail "nothing is listening on port $port" 2
    fi
  done
  for mount in / "$VMAIL_DIR"; do
    pct=$(df --output=pcent "$mount" | tail -1 | tr -dc '0-9')
    if (( pct < DISK_ALERT_PERCENT )); then
      report "disk-${mount//\//_}" ok "disk at $mount is ${pct}% full"
    else
      report "disk-${mount//\//_}" fail "disk at $mount is ${pct}% full (limit ${DISK_ALERT_PERCENT}%)"
    fi
  done
  queue=$(postqueue -j 2>/dev/null || true)
  count=$(jq -s 'length' <<<"$queue")
  oldest=$(jq -s 'map(.arrival_time) | min // 0' <<<"$queue")
  age=0
  (( oldest > 0 )) && age=$(( ($(date +%s) - oldest) / 60 ))
  if (( count <= QUEUE_ALERT_COUNT && age <= QUEUE_ALERT_AGE_MINUTES )); then
    report mail-queue ok "mail queue: $count message(s), oldest ${age} min"
  else
    report mail-queue fail "mail queue: $count message(s), oldest ${age} min. Check: postqueue -p" 3
  fi
}

daily_checks() {
  local cert end days rev list result d key name type want status stamp age
  cert="/etc/letsencrypt/live/$MAIL_HOSTNAME/cert.pem"
  if [[ -r $cert ]]; then
    end=$(date -d "$(openssl x509 -in "$cert" -noout -enddate | cut -d= -f2)" +%s)
    days=$(( (end - $(date +%s)) / 86400 ))
    if (( days > CERT_ALERT_DAYS )); then
      report cert-expiry ok "TLS certificate valid for $days more days"
    else
      report cert-expiry fail "TLS certificate expires in $days days. Check: certbot renew --dry-run"
    fi
  else
    report cert-expiry fail "TLS certificate not found at $cert"
  fi

  # Blocklists, queried through the local resolver (Spamhaus refuses big public resolvers)
  rev=$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$PUBLIC_IPV4")
  listed=()
  for list in zen.spamhaus.org b.barracudacentral.org bl.spamcop.net psbl.surriel.com; do
    result=$(dig +short +time=3 +tries=2 @127.0.0.1 "$rev.$list" A 2>/dev/null || true)
    # 127.255.255.x means the query itself was refused, not a listing
    if grep -qE '^127\.0\.0\.' <<<"$result"; then listed+=("$list"); fi
  done
  if ((${#listed[@]} == 0)); then
    report blocklists ok "$PUBLIC_IPV4 is on no checked blocklist"
  else
    report blocklists fail "$PUBLIC_IPV4 is listed on: ${listed[*]}. Look it up on the list's website for the reason and delisting."
  fi

  # DNS: every hosted domain's records, and the server's own
  local bad=()
  while IFS='|' read -r key name type want; do
    status=$(check_record "$key" "$name" "$type" "$want")
    [[ $status == OK* ]] || bad+=("$type $name: $status")
  done < <(expected_server_records | grep -v '^ptr6|'; while read -r d; do expected_domain_records "$d"; done < <(list_domains))
  if ((${#bad[@]} == 0)); then
    report dns ok "all DNS records are as expected"
  else
    report dns fail "DNS records differ from what is expected:"$'\n'"$(printf '%s\n' "${bad[@]}")"$'\n'"Check: mailctl dns-records"
  fi

  # Backups (only once backups are set up)
  if systemctl is-enabled --quiet mailserver-backup.timer 2>/dev/null; then
    stamp="$VAR_DIR/last-backup-ok"
    if [[ -f $stamp ]]; then
      age=$(( ($(date +%s) - $(stat -c %Y "$stamp")) / 3600 ))
    else
      age=9999
    fi
    if (( age <= BACKUP_ALERT_HOURS )); then
      report backup-age ok "last successful backup ${age} h ago"
    else
      report backup-age fail "no successful backup for ${age} h. Check: journalctl -u mailserver-backup"
    fi
  fi

  # A pending reboot should be handled by the automatic reboot at REBOOT_TIME within a day
  if [[ -f /run/reboot-required && -n $(find /run/reboot-required -mmin +1500 2>/dev/null) ]]; then
    report reboot fail "a reboot has been pending for over a day; automatic reboots may not be working"
  else
    report reboot ok "no overdue reboot"
  fi

  if systemctl --failed --quiet --no-legend | grep -q .; then
    report failed-units fail "failed systemd units: $(systemctl --failed --no-legend --plain | awk '{print $1}' | paste -sd' ' -)"
  else
    report failed-units ok "no failed systemd units"
  fi
}

case $mode in
  frequent) frequent_checks
            if [[ -n ${HEARTBEAT_URL:-} ]]; then curl -fsS -m 10 "$HEARTBEAT_URL" >/dev/null || warn "heartbeat failed"; fi ;;
  daily)    daily_checks ;;
  *)        die "Usage: healthcheck.sh frequent|daily [--verbose]" ;;
esac

((verbose)) && echo && info "$problems problem(s) found"
exit 0
