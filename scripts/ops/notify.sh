#!/usr/bin/env bash
# Send an alert to every channel listed in /etc/mailserver/alerts.env.
# Usage: notify.sh <title> <message>
source "$(dirname "$0")/../lib/common.sh"
load_alerts

[[ $# -eq 2 ]] || die "Usage: notify.sh <title> <message>"
title=$1
message=$2
host=$(hostname -f 2>/dev/null || hostname)
logger -t mailserver-alert -- "$title: $message" 2>/dev/null || true

need() { [[ -n ${!1:-} ]] || { warn "$1 is empty in $ALERTS_FILE"; return 1; }; }

send_ntfy() {
  need NTFY_URL || return 1
  local auth=()
  [[ -n ${NTFY_TOKEN:-} ]] && auth=(-H "Authorization: Bearer $NTFY_TOKEN")
  curl -fsS -m 20 "${auth[@]}" -H "Title: [$host] $title" --data-binary "$message" "$NTFY_URL" >/dev/null
}

send_telegram() {
  need TELEGRAM_BOT_TOKEN && need TELEGRAM_CHAT_ID || return 1
  curl -fsS -m 20 "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
    --data-urlencode "chat_id=$TELEGRAM_CHAT_ID" \
    --data-urlencode "text=[$host] $title"$'\n'"$message" >/dev/null
}

send_email() {
  need ALERT_EMAIL_TO || return 1
  printf 'From: Mail server <root@%s>\nTo: %s\nSubject: [%s] %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
    "$host" "$ALERT_EMAIL_TO" "$host" "$title" "$message" | /usr/sbin/sendmail -t -i
}

send_webhook() {
  need WEBHOOK_URL || return 1
  jq -n --arg t "$title" --arg m "$message" --arg h "$host" '{title: $t, message: $m, host: $h}' |
    curl -fsS -m 20 -H 'Content-Type: application/json' --data-binary @- "$WEBHOOK_URL" >/dev/null
}

if [[ -z ${ALERT_CHANNELS// /} ]]; then
  warn "no alert channels configured in $ALERTS_FILE; logged only: $title"
  exit 0
fi

sent=0 failed=0
for channel in $ALERT_CHANNELS; do
  case $channel in
    ntfy|telegram|email|webhook) ;;
    *) warn "unknown alert channel '$channel' in $ALERTS_FILE"; failed=$((failed + 1)); continue ;;
  esac
  if "send_$channel"; then
    sent=$((sent + 1))
  else
    failed=$((failed + 1)); warn "alert channel '$channel' failed"
  fi
done

if (( failed )); then
  info "alert sent to $sent channel(s); $failed failed"
else
  info "alert sent to $sent channel(s)"
fi
(( sent > 0 ))
