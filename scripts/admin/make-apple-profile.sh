#!/usr/bin/env bash
# Create an Apple configuration profile (.mobileconfig) that adds a mailbox to Apple Mail on
# Mac, iPhone or iPad. The profile contains no password; the device asks for it.
# Usage: mailctl apple-profile <address> [output-file]
source "$(dirname "$0")/../lib/common.sh"
load_config

[[ $# -ge 1 ]] || die "Usage: mailctl apple-profile <address> [output-file]"
a=$(lower "$1")
valid_address "$a" || die "'$a' is not a valid address."
out=${2:-$PWD/$a.mobileconfig}

# Reverse-DNS identifier, e.g. com.example.mail
reverse=$(awk -F. '{for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? "." : "")}' <<<"$PRIMARY_DOMAIN")
id="$reverse.mail.$a"
uuid() { tr '[:lower:]' '[:upper:]' </proc/sys/kernel/random/uuid; }

cat >"$out" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>PayloadContent</key>
  <array>
    <dict>
      <key>EmailAccountDescription</key>
      <string>$a</string>
      <key>EmailAccountType</key>
      <string>EmailTypeIMAP</string>
      <key>EmailAddress</key>
      <string>$a</string>
      <key>IncomingMailServerAuthentication</key>
      <string>EmailAuthPassword</string>
      <key>IncomingMailServerHostName</key>
      <string>$MAIL_HOSTNAME</string>
      <key>IncomingMailServerPortNumber</key>
      <integer>993</integer>
      <key>IncomingMailServerUseSSL</key>
      <true/>
      <key>IncomingMailServerUsername</key>
      <string>$a</string>
      <key>OutgoingMailServerAuthentication</key>
      <string>EmailAuthPassword</string>
      <key>OutgoingMailServerHostName</key>
      <string>$MAIL_HOSTNAME</string>
      <key>OutgoingMailServerPortNumber</key>
      <integer>465</integer>
      <key>OutgoingMailServerUseSSL</key>
      <true/>
      <key>OutgoingMailServerUsername</key>
      <string>$a</string>
      <key>OutgoingPasswordSameAsIncomingPassword</key>
      <true/>
      <key>PayloadDescription</key>
      <string>Mail account $a</string>
      <key>PayloadDisplayName</key>
      <string>$a</string>
      <key>PayloadIdentifier</key>
      <string>$id.account</string>
      <key>PayloadType</key>
      <string>com.apple.mail.managed</string>
      <key>PayloadUUID</key>
      <string>$(uuid)</string>
      <key>PayloadVersion</key>
      <integer>1</integer>
      <key>PreventAppSheet</key>
      <false/>
      <key>PreventMove</key>
      <false/>
      <key>SMIMEEnabled</key>
      <false/>
    </dict>
  </array>
  <key>PayloadDescription</key>
  <string>Adds the mail account $a. You will be asked for its password.</string>
  <key>PayloadDisplayName</key>
  <string>Mail: $a</string>
  <key>PayloadIdentifier</key>
  <string>$id</string>
  <key>PayloadOrganization</key>
  <string>${a#*@}</string>
  <key>PayloadRemovalDisallowed</key>
  <false/>
  <key>PayloadType</key>
  <string>Configuration</string>
  <key>PayloadUUID</key>
  <string>$(uuid)</string>
  <key>PayloadVersion</key>
  <integer>1</integer>
</dict>
</plist>
EOF

info "created $out"
cat <<EOF
Copy it to your Mac:
    scp root@$MAIL_HOSTNAME:$out .
Mac: double-click it, then open System Settings → General → Device Management (or Profiles) and install.
iPhone: AirDrop it from the Mac, then Settings → Profile Downloaded → Install.
It shows as "Unverified" because it is not signed; that is expected.
EOF
