#!/usr/bin/env bash
# Runbook step 9: health checks every 5 minutes and daily, with alerts to the channels in
# /etc/mailserver/alerts.env. Safe to re-run.
# Usage: scripts/30-install-monitoring.sh
source "$(dirname "$0")/lib/common.sh"
require_root
load_config

# First run: only create the alerts file. That's an expected stop, not an error.
if [[ ! -f $ALERTS_FILE ]]; then
  install -m 0600 "$REPO_DIR/config/alerts.env.example" "$ALERTS_FILE"
  step "Alerts file created"
  cat <<EOF
$ALERTS_FILE was created from the example; nothing else was set up yet.
Choose your alert channels in it:
    nano $ALERTS_FILE
Then run this script again.
EOF
  exit 0
fi
chmod 0600 "$ALERTS_FILE"

step "Timers"
for unit in mailserver-health.service mailserver-health.timer mailserver-health-daily.service mailserver-health-daily.timer; do
  render "systemd/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now mailserver-health.timer mailserver-health-daily.timer >/dev/null 2>&1
info "checks run every 5 minutes, plus daily at 06:00 UTC"

step "Test alert"
"$REPO_DIR/scripts/ops/notify.sh" "Test alert" "Monitoring is set up on $MAIL_HOSTNAME. If you can read this, this channel works." ||
  warn "the test alert did not reach any channel; check $ALERTS_FILE"

step "Running the checks once"
"$REPO_DIR/scripts/ops/healthcheck.sh" frequent --verbose
"$REPO_DIR/scripts/ops/healthcheck.sh" daily --verbose

step "Done"
cat <<EOF
Monitoring is set up. Any FAIL above is a real finding: the same message says what to check.
A server that's down can't send alerts, so also watch it from outside (docs/runbook.md, step 9).
EOF
