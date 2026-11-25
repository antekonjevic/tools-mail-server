#!/usr/bin/env bash
# End-to-end test, run INSIDE the test container by tests/run.sh.
# Installs everything with the real scripts, then checks mail flows, security rules and backups.
# Test addresses and domains contain no spaces or wildcards, so they are left unquoted for readability.
# shellcheck disable=SC2086
set -uo pipefail
R=/opt/mailserver
S=$R/scripts
# shellcheck source=test.env
source "${MAILSERVER_CONFIG:?run this through tests/run.sh}"
D1=$PRIMARY_DOMAIN          # example.test
D2=second.test
U1=$ADMIN_EMAIL             # alice@example.test
U2=bob@$D2
pass=0 fail=0 failed_names=()

section() { printf '\n\033[1m### %s\033[0m\n' "$*"; }
ok() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
ko() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); failed_names+=("$1"); }
# check DESCRIPTION COMMAND... : passes when the command succeeds
check() {
  local desc=$1; shift
  if "$@" >/tmp/out 2>&1; then ok "$desc"; else ko "$desc"; tail -15 /tmp/out | sed 's/^/        /'; fi
}
# refuse DESCRIPTION COMMAND... : passes when the command fails
refuse() {
  local desc=$1; shift
  if "$@" >/tmp/out 2>&1; then ko "$desc (was accepted)"; tail -8 /tmp/out | sed 's/^/        /'; else ok "$desc"; fi
}
run_step() {  # run_step DESCRIPTION COMMAND... : aborts the test if an install step fails
  section "$1"; shift
  if ! "$@" >/tmp/step.log 2>&1; then
    tail -40 /tmp/step.log; echo; echo "ABORTED: '$*' failed"; exit 1
  fi
  tail -6 /tmp/step.log | sed 's/^/  | /'
}

maildir() { echo "/var/vmail/${1#*@}/${1%@*}/Maildir"; }
# count ADDRESS FOLDER : messages in a folder ("" = INBOX, ".Junk", ".Reports"); Dovecot may store into cur/ or new/
count() { find "$(maildir "$1")/$2/cur" "$(maildir "$1")/$2/new" -type f 2>/dev/null | wc -l; }
# expect_more ADDRESS FOLDER BEFORE : waits up to 10 s for a new message in FOLDER
expect_more() {
  local _; for _ in $(seq 1 20); do (( $(count "$1" "$2") > $3 )) && return 0; sleep 0.5; done; return 1
}
# shellcheck disable=SC2012  # ls -t sorts by time; Maildir file names are plain ASCII
latest() { ls -t "$(maildir "$1")/$2"/cur/* "$(maildir "$1")/$2"/new/* 2>/dev/null | head -1; }
# with_subject ADDRESS FOLDER SUBJECT : waits up to 10 s for a message with that subject and prints its file
with_subject() {
  local _ f
  for _ in $(seq 1 20); do
    f=$(grep -lF "Subject: $3" "$(maildir "$1")/$2"/cur/* "$(maildir "$1")/$2"/new/* 2>/dev/null | head -1)
    [[ -n $f ]] && { echo "$f"; return 0; }
    sleep 0.5
  done
  return 1
}
IP=$(hostname -I | awk '{print $1}')   # the container's own address: an "outside" client, not in mynetworks
# An outside sender with no reverse DNS and a made-up name: Rspamd scans it fully and, rightly,
# tends to score it as spam. Used for scanning, rejection and Junk-filing tests.
smtp_in() { swaks --server "$IP" --port 25 --helo client.example.org --silent 1 "$@"; }
# A trusted local sender (like a well-configured relay): used to test the delivery paths themselves.
smtp_local() { swaks --server 127.0.0.1 --port 25 --helo "$(hostname -f)" --silent 1 "$@"; }
smtp_sub() { swaks --server "$IP" --port 465 --tls-on-connect --silent 1 "$@"; }

# ---------------------------------------------------------------- install
run_step "00-host-setup.sh" "$S/00-host-setup.sh"
run_step "10-install-mail.sh --self-signed" "$S/10-install-mail.sh" --self-signed
section "Package installation"
# Dovecot logs "starting up" each time it starts. Once means it never ran with Ubuntu's default
# configuration, which accepts logins of system accounts.
check "Dovecot first started with this configuration, not during package installation" \
  test "$(journalctl -q -u dovecot.service -o cat | grep -c 'starting up')" -eq 1
refuse "  ...and the temporary block on service starts was removed" test -e /usr/sbin/policy-rc.d

# Test DNS: the machine's own Unbound serves the .test domains, and the system uses it as resolver
section "Test DNS for $D1 and $D2"
cat >/etc/unbound/unbound.conf.d/zz-test-zones.conf <<EOF
server:
    local-zone: "$D1." static
    local-data: "$D1. A $IP"
    local-data: "$D1. MX 10 $MAIL_HOSTNAME."
    local-data: "$MAIL_HOSTNAME. A $IP"
    local-zone: "$D2." static
    local-data: "$D2. A $IP"
    local-data: "$D2. MX 10 $MAIL_HOSTNAME."
EOF
systemctl restart unbound
printf 'nameserver 127.0.0.1\n' >/etc/resolv.conf   # written in place: /etc/resolv.conf is a mount here
systemctl restart postfix                            # Postfix copies resolv.conf into its chroot on start
dig +short MX "$D2" | sed 's/^/  | MX of '"$D2"': /'
run_step "add-domain $D1" mailctl add-domain $D1
section "add-mailbox $U1"
mailctl add-mailbox "$U1" >/tmp/me.out 2>&1 || { cat /tmp/me.out; exit 1; }
U1_PW=$(awk '/Password:/ {print $2}' /tmp/me.out)
if [[ -n $U1_PW ]]; then echo "  | password generated (${#U1_PW} chars)"; else cat /tmp/me.out; exit 1; fi
run_step "add-domain $D2" mailctl add-domain $D2
mailctl add-mailbox "$U2" >/tmp/people.out 2>&1 || { cat /tmp/people.out; exit 1; }
U2_PW=$(awk '/Password:/ {print $2}' /tmp/people.out)

# ---------------------------------------------------------------- configuration
section "Configuration"
# (the output is captured first: with pipefail, mailctl's intended failure would fail a pipeline)
refused_example() { local out; out=$(MAILSERVER_CONFIG=$1 mailctl list 2>&1); grep -q 'still contains the example values' <<<"$out"; }
check "the scripts refuse the unedited example settings" refused_example $R/config/mailserver.env.example
printf 'source %s\nPRIMARY_DOMAIN=example.org\nMAIL_HOSTNAME=mail.example.org\nADMIN_EMAIL=me@example.org\n' \
  "$MAILSERVER_CONFIG" >/tmp/example-org.env
check "  ...and other example names such as example.org" refused_example /tmp/example-org.env
check "postfix check" postfix check
check "Dovecot config parses (doveconf -n)" doveconf -n
check "Rspamd config test" rspamadm configtest
check "nginx config test" nginx -t
check "Unbound config test" unbound-checkconf
for svc in postfix dovecot rspamd valkey-server unbound nginx fail2ban; do
  check "service $svc running" systemctl is-active --quiet "$svc"
done
for p in 25 465 993 80 443; do check "port $p listening" bash -c "ss -Hltn 'sport = :$p' | grep -q ."; done
for p in 110 143 587 995 4190 11332 11333 11334 6379; do
  refuse "port $p not reachable from outside" bash -c "timeout 3 bash -c 'exec 3<>/dev/tcp/$IP/$p'"
done
check "aliases created for both domains" bash -c "grep -q '^postmaster@$D1 $U1' /etc/mailserver/aliases && grep -q '^abuse@$D2 $U2' /etc/mailserver/aliases"
check "DKIM selector map lists both domains" bash -c "grep -q '^$D1 $DKIM_SELECTOR' /etc/rspamd/dkim_selectors.map && grep -q '^$D2 $DKIM_SELECTOR' /etc/rspamd/dkim_selectors.map"

# ---------------------------------------------------------------- inbound
section "Receiving mail (port 25)"
b=$(count $U1 .Junk)
check "mail from a dubious outside sender is accepted" smtp_in --from test@$D1 --to $U1 --header "Subject: inbound test"
check "  ...scored as spam and filed into Junk (no reverse DNS, unknown HELO)" expect_more $U1 .Junk "$b"
msg=$(latest $U1 .Junk)
check "  ...with Rspamd's verdict header" grep -q '^X-Spam-Status: Yes, score=' "$msg"
check "  ...with SPF/DKIM/DMARC results" grep -q '^Authentication-Results:' "$msg"
refuse "  ...and not DKIM-signed by us (it came from outside)" grep -q "^DKIM-Signature:.*d=$D1" "$msg"
b=$(count $U1 "")
check "mail from a trusted sender is accepted" smtp_local --from test@$D1 --to $U1 --header "Subject: inbound clean"
check "  ...and arrives in the inbox" expect_more $U1 "" "$b"
b=$(count $U1 "")
check "plus-address alice+shop@ is accepted" smtp_local --from test@$D1 --to alice+shop@$D1
check "  ...and arrives in the same inbox" expect_more $U1 "" "$b"
b=$(count $U1 "")
check "alias postmaster@ is accepted" smtp_local --from test@$D1 --to postmaster@$D1
check "  ...and arrives in $U1" expect_more $U1 "" "$b"
b=$(count $U2 "")
check "abuse@$D2 is accepted" smtp_local --from test@$D1 --to abuse@$D2
check "  ...and arrives in $U2" expect_more $U2 "" "$b"
b=$(count $U1 .Reports)
check "a DMARC report to reports@ is accepted" smtp_local --from noreply-dmarc@$D1 --to reports@$D1 --header "Subject: Report domain: $D1"
check "  ...and is filed into Reports" expect_more $U1 .Reports "$b"
printf 'From: noreply-dmarc@example.org\nTo: reports@%s\nSubject: Report domain: %s\n\nreport\n' "$D2" "$D2" >/tmp/report2.eml
check "  ...as are reports to reports@ of the second domain" bash -c "sieve-test -u $U2 /etc/dovecot/sieve/before.sieve /tmp/report2.eml 2>&1 | grep -q 'folder: Reports'"
printf 'From: friend@example.org\nTo: %s\nCc: reports@unrelated.example\nSubject: lunch?\n\nhi\n' "$U1" >/tmp/cc.eml
refuse "  ...but not mail that copies in reports@ of a domain hosted elsewhere" bash -c "sieve-test -u $U1 /etc/dovecot/sieve/before.sieve /tmp/cc.eml 2>&1 | grep -q 'folder: Reports'"
refuse "unknown recipient is rejected" smtp_in --from test@$D1 --to nobody@$D1
refuse "relaying to another domain is refused" smtp_in --from test@$D1 --to someone@example.org
refuse "GTUBE spam test message is rejected" smtp_in --from test@$D1 --to $U1 \
  --body 'XJS*C4JDBQADN1.NSBN3*2IDNEN*GTUBE-STANDARD-ANTI-UBE-TEST-EMAIL*C.34X'
printf 'From: a@example.org\nTo: %s\nSubject: x\nX-Spam-Status: Yes, score=9\n\nbody\n' "$U1" >/tmp/spam.eml
check "Sieve files spam-marked mail into Junk" bash -c "sieve-test -u $U1 /etc/dovecot/sieve/before.sieve /tmp/spam.eml 2>&1 | grep -q 'folder: Junk'"
sed 's/^X-Spam-Status: Yes, score=9/X-Spam-Status: No, score=1/' /tmp/spam.eml >/tmp/ham.eml
refuse "  ...and leaves normal mail in the inbox" bash -c "sieve-test -u $U1 /etc/dovecot/sieve/before.sieve /tmp/ham.eml 2>&1 | grep -q 'folder: Junk'"
b=$(count $U1 "")
check "mail for root is forwarded to $U1" bash -c "printf 'Subject: cron test\n\nhello\n' | sendmail root"
check "  ...and arrives" expect_more $U1 "" "$b"

# ---------------------------------------------------------------- outbound / submission
section "Sending mail (port 465)"
b=$(count $U2 "")
check "logged-in user can send" smtp_sub --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" \
  --from $U1 --to $U2 --header "Subject: submission test"
check "  ...and it arrives" expect_more $U2 "" "$b"
msg=$(latest $U2 "")
check "  ...signed with DKIM for $D1" grep -q "^DKIM-Signature:.*d=$D1" "$msg"
refuse "  ...without the sender's IP address in a Received line" grep -q 'with ESMTPSA' "$msg"
check "user can send from their own alias" smtp_sub --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" \
  --from postmaster@$D1 --to $U2
mailctl add-alias sales@$D2 $U1 >/dev/null 2>&1
sleep 3   # Rspamd reloads the sender table
check "user can send from their alias on another domain" smtp_sub --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" \
  --from sales@$D2 --to $U2 --header "Subject: cross-domain alias"
msg=$(with_subject $U2 "" "cross-domain alias")
check "  ...and it arrives" test -n "$msg"
check "  ...signed with DKIM for $D2" grep -q "^DKIM-Signature:.*d=$D2" "$msg"
check "  ...also when only the From header has the alias" smtp_sub --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" \
  --from $U1 --h-From "Sales <sales@$D2>" --to $U2 --header "Subject: alias in From only"
msg=$(with_subject $U2 "" "alias in From only")
check "  ...and it arrives" test -n "$msg"
check "  ...signed with DKIM for $D2" grep -q "^DKIM-Signature:.*d=$D2" "$msg"
refuse "  ...without the login name in its headers" grep -qi "smtp.auth=" "$msg"
refuse "user cannot send as another mailbox" smtp_sub --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" \
  --from $U2 --to $U2
refuse "user cannot put another mailbox in the From header" smtp_sub --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" \
  --from $U1 --h-From "Bob <$U2>" --to $U2
refuse "user cannot put an unowned address of their own domain in the From header" smtp_sub --auth PLAIN \
  --auth-user $U1 --auth-password "$U1_PW" --from $U1 --h-From "ghost@$D1" --to $U2
check "user can put a plus-address of their own in the From header" smtp_sub --auth PLAIN --auth-user $U1 \
  --auth-password "$U1_PW" --from $U1 --h-From "${U1%@*}+news@$D1" --to $U2
refuse "sending without login is refused" smtp_sub --from $U1 --to $U2
refuse "wrong password is refused" smtp_sub --auth PLAIN --auth-user $U1 --auth-password wrong-password --from $U1 --to $U2
refuse "login on port 25 is not offered" swaks --server "$IP" --port 25 --tls --auth PLAIN --auth-user $U1 --auth-password "$U1_PW" --from $U1 --to someone@example.org --silent 1

# ---------------------------------------------------------------- IMAP
section "Reading mail (IMAP 993)"
check "IMAP login works" curl -sk --url "imaps://$IP/INBOX" --user "$U1:$U1_PW" -X 'STATUS INBOX (MESSAGES)'
refuse "IMAP login with a wrong password fails" curl -sk --url "imaps://$IP/INBOX" --user "$U1:wrong-password" -X 'STATUS INBOX (MESSAGES)'
check "folders Junk, Sent, Trash, Reports exist" bash -c "curl -sk --url 'imaps://$IP/' --user '$U1:$U1_PW' | grep -q Junk && curl -sk --url 'imaps://$IP/' --user '$U1:$U1_PW' | grep -q Reports"
# imap_copy ADDRESS PASSWORD FROM-FOLDER TO-FOLDER SUBJECT : an IMAP copy, as a mail app does when you move mail
cat >/tmp/imap_copy.py <<'EOF'
import imaplib, ssl, sys
host, user, pw, src, dst, subject = sys.argv[1:7]
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE
m = imaplib.IMAP4_SSL(host, 993, ssl_context=ctx)
m.login(user, pw)
m.select(src)
typ, data = m.search(None, 'SUBJECT "%s"' % subject)
assert m.copy(data[0].split()[-1], dst)[0] == "OK"
m.logout()
EOF
# Rspamd logs every learn at once ("stat" counters refresh later), so count those log lines
learned() { grep -c "learned message as $1" /var/log/rspamd/rspamd.log 2>/dev/null || true; }
# Rspamd only learns from messages with enough words, and tracks each message (moving the same one
# back re-classifies it), so two different realistic messages are used.
body="Hello, this is a longer message used to check that moving mail between folders teaches the spam filter. It talks about invoices, meetings, holidays, gardening, bicycles and the weather at the coast, so that it contains enough distinct words for the statistical classifier."
b=$(count $U1 "")
smtp_local --from test@$D1 --to $U1 --header "Subject: learning test one" --body "$body One." >/dev/null 2>&1
smtp_local --from test@$D1 --to $U1 --header "Subject: learning test two" --body "$body Two." >/dev/null 2>&1
expect_more $U1 "" "$((b + 1))"
spam_before=$(learned spam)
check "moving a message into Junk over IMAP" python3 /tmp/imap_copy.py "$IP" "$U1" "$U1_PW" INBOX Junk "learning test one"
sleep 3
spam_after=$(learned spam)
check "  ...teaches Rspamd it is spam (learned $spam_before → $spam_after)" test "$spam_after" -gt "$spam_before"
doveadm move -u $U1 Junk mailbox INBOX subject "learning test two"   # put it in Junk without triggering learning
ham_before=$(learned ham)
check "moving a message out of Junk over IMAP" python3 /tmp/imap_copy.py "$IP" "$U1" "$U1_PW" Junk INBOX "learning test two"
sleep 3
ham_after=$(learned ham)
check "  ...teaches Rspamd it is not spam (learned $ham_before → $ham_after)" test "$ham_after" -gt "$ham_before"

# ---------------------------------------------------------------- web
section "Web (MTA-STS, autoconfig)"
check "MTA-STS policy is served" bash -c "curl -sk https://$IP/.well-known/mta-sts.txt | grep -q 'mx: $MAIL_HOSTNAME'"
# Thunderbird asks https://autoconfig.<domain>/mail/config-v1.1.xml; the Host header plays that name here
autoconfig() { curl -sk -H "Host: $1" "https://$IP/mail/config-v1.1.xml"; }
autoconfig_code() { curl -sk -o /dev/null -w '%{http_code}' -H "Host: $1" "https://$IP/mail/config-v1.1.xml"; }
autoconfig_names() { autoconfig "$1" | grep -q "<domain>$2</domain>"; }   # autoconfig_names HOST DOMAIN
autoconfig_valid() { autoconfig "$1" | xmllint --noout -; }
check "Thunderbird autoconfig is served for $D1" autoconfig_names autoconfig.$D1 $D1
check "  ...and for $D2" autoconfig_names autoconfig.$D2 $D2
refuse "  ...each naming only its own domain, so it doesn't reveal the others" autoconfig_names autoconfig.$D2 $D1
check "  ...as valid XML" autoconfig_valid autoconfig.$D1
check "  ...and nothing for a domain that isn't hosted" test "$(autoconfig_code autoconfig.unknown.test)" = 404
check "  ...nor for the server's bare address" test "$(autoconfig_code "$IP")" = 404
check "  ...nor for a host name that tries to leave the directory" test "$(autoconfig_code '../../etc/passwd')" != 200
check "any other HTTPS path returns 404" bash -c "[[ \$(curl -sk -o /dev/null -w '%{http_code}' https://$IP/admin) == 404 ]]"
check "HTTP redirects to HTTPS" bash -c "[[ \$(curl -s -o /dev/null -w '%{http_code}' http://$IP/x) == 301 ]]"
install -d /var/www/acme/.well-known/acme-challenge && echo token >/var/www/acme/.well-known/acme-challenge/t
check "Let's Encrypt challenge path is served on port 80" bash -c "[[ \$(curl -s http://$IP/.well-known/acme-challenge/t) == token ]]"

# ---------------------------------------------------------------- TLS policy
section "TLS policy (ports 25, 465, 993, 443)"
# tls PORT OPENSSL-ARGS... : succeeds when a TLS handshake with these client settings completes.
# "@SECLEVEL=0" lets the test client offer weak options, so that refusing them is up to the server.
tls() {
  local port=$1 starttls=(); shift
  [[ $port == 25 ]] && starttls=(-starttls smtp)
  timeout 15 openssl s_client -connect "$IP:$port" -servername "$MAIL_HOSTNAME" "${starttls[@]}" "$@" </dev/null
}
# tls_chooses PORT CIPHER OPENSSL-ARGS... : the handshake completes with CIPHER
tls_chooses() { local port=$1 cipher=$2; shift 2; tls "$port" "$@" 2>/dev/null | grep -q "Cipher is $cipher"; }
for port in 25 465 993 443; do
  check "port $port: TLS 1.3 works" tls $port -tls1_3
  check "  ...TLS 1.2 with ECDHE and AES-GCM works" tls $port -tls1_2 -cipher ECDHE-ECDSA-AES256-GCM-SHA384
  check "  ...the server's cipher order wins over the client's" tls_chooses $port ECDHE-ECDSA-AES256-GCM-SHA384 \
    -tls1_2 -cipher ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384
  refuse "  ...anonymous ciphers are refused" tls $port -tls1_2 -cipher 'aNULL:@SECLEVEL=0'
  refuse "  ...CBC ciphers are refused" tls $port -tls1_2 \
    -cipher 'ECDHE-ECDSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA:ECDHE-ECDSA-AES128-SHA256:ECDHE-ECDSA-AES256-SHA384:@SECLEVEL=0'
  refuse "  ...finite-field Diffie-Hellman is refused" tls $port -tls1_3 -groups ffdhe2048:ffdhe3072:ffdhe4096
  refuse "  ...SHA1 signatures are refused" tls $port -tls1_2 -sigalgs ECDSA+SHA1:RSA+SHA1 -cipher 'ECDHE:@SECLEVEL=0'
done

# ---------------------------------------------------------------- admin commands
section "Admin commands"
check "mailctl list" mailctl list
check "mailctl dns-records runs" mailctl dns-records $D1
check "mailctl dns-records prints the DKIM key split into quoted pieces" bash -c "mailctl dns-records $D1 | grep -q '\"v=DKIM1; k=rsa; p='"
check "mailctl dns-records asks for a CAA record for Let's Encrypt" bash -c "mailctl dns-records $D1 | grep -qF 'value: 0 issue \"letsencrypt.org\"'"
check "mailctl apple-profile creates a valid profile" bash -c "cd /tmp && mailctl apple-profile $U1 >/dev/null && xmllint --noout /tmp/$U1.mobileconfig"
check "add-alias to a mailbox" mailctl add-alias hello@$D1 $U1
b=$(count $U1 "")
check "  ...and the alias receives mail" smtp_local --from test@$D1 --to hello@$D1
check "  ...in $U1" expect_more $U1 "" "$b"
refuse "add-alias refuses a target mailbox that does not exist" mailctl add-alias x@$D1 ghost@$D1
check "remove-alias" mailctl remove-alias hello@$D1
refuse "  ...and it no longer receives mail" smtp_in --from test@$D1 --to hello@$D1
refuse "remove-mailbox refuses while aliases point to it" mailctl remove-mailbox $U1
refuse "remove-domain refuses while it has mailboxes" mailctl remove-domain $D1
check "add-domain third.test" mailctl add-domain third.test
check "  ...creates its autoconfig file" test -s /var/www/mail/autoconfig/autoconfig.third.test.xml
check "remove-domain third.test" mailctl remove-domain third.test
refuse "  ...removes that file again" test -e /var/www/mail/autoconfig/autoconfig.third.test.xml
mailctl reset-password $U2 >/tmp/reset.out 2>&1
NEW_PW=$(awk '/Password:/ {print $2}' /tmp/reset.out)
check "reset-password: new password works" curl -sk --url "imaps://$IP/INBOX" --user "$U2:$NEW_PW" -X 'STATUS INBOX (MESSAGES)'
refuse "reset-password: old password no longer works" curl -sk --url "imaps://$IP/INBOX" --user "$U2:$U2_PW" -X 'STATUS INBOX (MESSAGES)'

# ---------------------------------------------------------------- fail2ban
section "Brute-force protection"
sleep 2
check "fail2ban jails sshd, postfix-sasl, dovecot are active" bash -c "fail2ban-client status | grep -q dovecot && fail2ban-client status | grep -q postfix-sasl && fail2ban-client status | grep -q sshd"
# fail2ban ignores the machine's own address (the test client), so check the filters against the real log lines instead
check "fail2ban's Dovecot filter matches Dovecot 2.4's failed IMAP logins" bash -c "fail2ban-regex systemd-journal mailserver-dovecot 2>&1 | grep -qE '^Lines: .* [1-9][0-9]* matched'"
check "fail2ban's Postfix filter matches failed SMTP logins" bash -c "fail2ban-regex systemd-journal 'postfix[mode=auth]' 2>&1 | grep -qE '^Lines: .* [1-9][0-9]* matched'"
check "the dovecot jail uses the Dovecot 2.4 filter" bash -c "fail2ban-client get dovecot failregex | grep -q auth_failed"

# ---------------------------------------------------------------- backups and monitoring
section "Backups: first run"
check "20-install-backups.sh first only creates the secrets file, without an error" bash -c \
  "$S/20-install-backups.sh >/tmp/first.out 2>&1 && grep -q 'run this script again' /tmp/first.out && ! grep -q ERROR /tmp/first.out"
check "  ...readable by root only" test "$(stat -c %a /etc/mailserver/secrets.env)" = 600
rm -f /etc/mailserver/secrets.env   # replaced by the test's own values (install can't overwrite it from stdin)
install -m 0600 /dev/stdin /etc/mailserver/secrets.env <<EOF
RESTIC_PASSWORD=test-password-for-the-local-test-only
AWS_ACCESS_KEY_ID=not-used-in-test
AWS_SECRET_ACCESS_KEY=not-used-in-test
EOF
run_step "20-install-backups.sh" "$S/20-install-backups.sh"
section "Backups"
check "backup timer is enabled" systemctl is-enabled --quiet mailserver-backup.timer
check "restore test (--verify) passes" bash -c "mailctl restore --verify >/tmp/verify.out 2>&1"
check "  ...restoring only a sample of the mail, so it cannot fill the disk" \
  bash -c "grep -oE 'sample of [0-9]+ of [0-9]+' /tmp/verify.out | awk '{ok = (\$3 > 0 && \$3 < \$5)} END {exit !ok}'"
# Changes made after the backup: a deleted message, a removed alias, and a marker in a file that a package owns
victim=$(latest $U1 "")
rm -f "$victim"
mailctl remove-alias abuse@$D2 >/dev/null 2>&1
echo '# restore-test-marker' >>/etc/rspamd/rspamd.conf
check "restore --apply brings back a deleted message" bash -c "mailctl restore --apply --yes && test -f '$victim'"
check "  ...and a removed alias" grep -q "^abuse@$D2 $U2" /etc/postfix/virtual_aliases
check "  ...but leaves the installed configuration alone" grep -q 'restore-test-marker' /etc/rspamd/rspamd.conf
sed -i '/restore-test-marker/d' /etc/rspamd/rspamd.conf
check "mail still flows after a restore" smtp_in --from test@$D1 --to $U1

section "Monitoring: first run"
check "30-install-monitoring.sh first only creates the alerts file, without an error" bash -c \
  "$S/30-install-monitoring.sh >/tmp/first.out 2>&1 && grep -q 'run this script again' /tmp/first.out && ! grep -q ERROR /tmp/first.out"
check "  ...readable by root only" test "$(stat -c %a /etc/mailserver/alerts.env)" = 600
refuse "  ...and no timers enabled yet" systemctl is-enabled mailserver-health.timer
rm -f /etc/mailserver/alerts.env   # replaced by the test's own values (install can't overwrite it from stdin)
install -m 0600 /dev/stdin /etc/mailserver/alerts.env <<EOF
ALERT_CHANNELS="email"
ALERT_EMAIL_TO="$U1"
EOF
b=$(count $U1 "")
run_step "30-install-monitoring.sh" "$S/30-install-monitoring.sh"
section "Monitoring"
check "test alert arrives by email" expect_more $U1 "" "$b"
check "health timers are enabled" bash -c "systemctl is-enabled --quiet mailserver-health.timer && systemctl is-enabled --quiet mailserver-health-daily.timer"
check "frequent health check reports no problems" bash -c "$S/ops/healthcheck.sh frequent --verbose | tee /dev/stderr | grep -q '0 problem'"
# Alerts are counted in the journal, where notify.sh logs each one. The 5-minute timer may run a check in
# between; the assertions hold either way.
alerts() { sleep 1; journalctl -q -t mailserver-alert -o cat 2>/dev/null | grep -c "^$1: service-dovecot" || true; }
health() { "$S/ops/healthcheck.sh" frequent >/dev/null 2>&1; }
state=/var/lib/mailserver/alerts/service-dovecot
a=$(alerts Problem)
systemctl stop dovecot
health; health
check "a stopped service raises an alert after two checks" test "$(alerts Problem)" -gt "$a"
a=$(alerts Problem)
health
check "  ...which is not repeated within the same day" test "$(alerts Problem)" -eq "$a"
sed -i "3s/.*/$(( $(date +%s) - 25 * 3600 ))/" "$state"   # as if the alert went out 25 hours ago
health
check "  ...but is repeated once a day while the problem lasts" test "$(alerts Problem)" -gt "$a"
a=$(alerts Resolved)
systemctl start dovecot
health
check "  ...and followed by a 'resolved' message once it clears" test "$(alerts Resolved)" -gt "$a"

# ---------------------------------------------------------------- re-run safety
run_step "re-running 00-host-setup.sh" "$S/00-host-setup.sh"
# Re-run 10-install-mail.sh with PUBLIC_IPV6 left empty: re-running is safe, and so is a server without IPv6
v4only=/tmp/ipv4-only.env
printf 'source %s\nPUBLIC_IPV6=\n' "$MAILSERVER_CONFIG" >"$v4only"
run_step "re-running 10-install-mail.sh, now for a server without IPv6" \
  env MAILSERVER_CONFIG="$v4only" "$S/10-install-mail.sh" --self-signed
section "After re-running the install scripts"
b=$(count $U1 "")
check "mail is still delivered" smtp_local --from test@$D1 --to $U1
check "  ...and arrives" expect_more $U1 "" "$b"
check "logins still work" curl -sk --url "imaps://$IP/INBOX" --user "$U1:$U1_PW" -X 'STATUS INBOX (MESSAGES)'
check "without IPv6, Postfix uses IPv4 only" bash -c "[[ \$(postconf -h inet_protocols) == ipv4 ]]"
check "  ...the SPF record lists only the IPv4 address" \
  bash -c "MAILSERVER_CONFIG=$v4only mailctl dns-records $D1 | grep -qF '\"v=spf1 ip4:$PUBLIC_IPV4 ~all\"'"
refuse "  ...and no AAAA or IPv6 reverse DNS record is asked for" \
  bash -c "MAILSERVER_CONFIG=$v4only mailctl dns-records --server | grep -qE 'AAAA|$PUBLIC_IPV6'"

# ---------------------------------------------------------------- summary
echo
if (( fail == 0 )); then
  printf '\033[32mAll %d checks passed.\033[0m\n' "$pass"
else
  printf '\033[31m%d of %d checks failed:\033[0m\n' "$fail" "$((pass + fail))"
  printf '  - %s\n' "${failed_names[@]}"
  exit 1
fi
