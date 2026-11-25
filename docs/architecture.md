# Architecture

How the mail server is put together, and why. Step-by-step procedures are in [runbook.md](runbook.md).

Examples use `example.com` and `example.org` as hosted domains, `mail.example.com` as the server's name, and the documentation addresses `203.0.113.10` / `2001:db8::10`.

## 1. Overview

One Ubuntu 26.04 server runs the classic open-source mail stack, installed from packages and configured by the scripts in this repository:

- **Postfix** sends and receives mail.
- **Dovecot** stores it and serves it to mail apps over IMAP.
- **Rspamd** filters spam and signs outgoing mail with DKIM.
- **nginx** serves two small files (the MTA-STS policy and Thunderbird's setup file) and the Let's Encrypt challenge.

There's no admin web interface. Everything is managed with `mailctl` over SSH.

```
Internet
  ├─ other mail servers ─────────── 25  (SMTP, in and out)
  ├─ your mail apps ─────────────── 993 (IMAP, reading), 465 (sending)
  └─ Let's Encrypt, Thunderbird setup, MTA-STS checks ── 80, 443
        │
        ▼  firewall: only 22, 25, 80, 443, 465, 993 open
mail.example.com  (Ubuntu 26.04)
  ├─ Postfix ──milter──▶ Rspamd (spam check, DKIM signing) ──▶ Valkey
  │     │                   └─ blocklist lookups ──▶ Unbound (local DNS resolver)
  │     └──LMTP──▶ Dovecot ──▶ /var/vmail (one Maildir per mailbox)
  ├─ nginx: ACME challenge, MTA-STS policy, Thunderbird autoconfig
  ├─ certbot: one Let's Encrypt certificate for all names
  ├─ fail2ban: blocks repeated failed logins
  ├─ nightly backup ── encrypted (restic) ──▶ S3 or any restic repository   (no downtime)
  └─ health checks ── alerts ──▶ ntfy / Telegram / email / webhook
```

## 2. Design decisions

| Topic | Decision | Why |
|---|---|---|
| Mail software | Postfix + Dovecot + Rspamd from packages | Proven for decades. Plain-text config. Ubuntu's security team patches Postfix and Dovecot. |
| Scope | Mail only: no webmail, calendar, contacts or admin UI | Less software to run, patch and expose. Calendar and contacts can stay with an existing provider. |
| Install method | Shell scripts, copied to the server and run as `root` | Readable before running, safe to re-run, nothing to install on your own machine. |
| Administration | `mailctl` over SSH; domains and aliases kept in plain text files | Nothing exposed beyond the mail ports. |
| Sending | Port 465 (TLS from the first byte) only, no 587 | One port to secure. RFC 8314 recommends implicit TLS, and common mail apps support it. |
| Reading | IMAP on 993 only. No POP3, no plain IMAP (143). | IMAP keeps mail in sync across devices. Fewer services exposed. |
| Certificates | Let's Encrypt via certbot, HTTP-01 challenge on port 80 | Needs no DNS-provider API. Port 80 serves only the challenge and redirects everything else. |
| Outbound IPv6 | Postfix prefers IPv4 (`smtp_address_preference = ipv4`) | A missing IPv6 reverse DNS is a common reason big providers reject mail. Prefer the address whose PTR is surely set. |
| DKIM | One RSA-2048 key per domain, generated and used by Rspamd; date-based selectors | Every receiver verifies RSA. Selectors like `s202601` make planned rotation simple. |
| Storage | Maildir: one file per message under `/var/vmail` | Plain files: easy to inspect, safe to back up live. |
| Backups | restic, nightly, encrypted on the server, while services run | No downtime. Encrypted before upload, so the storage provider can't read your mail. |
| DNS | Records entered by hand; `mailctl dns-records` prints them and checks them live | Works with any DNS provider, with no API credentials on the server. |
| Updates | `unattended-upgrades` for everything, including Rspamd's repository; reboot window configurable | No manual upgrade work. |

## 3. Components

| Component | Source | Role | Listens on |
|---|---|---|---|
| Postfix | Ubuntu | Receives on 25, accepts your sent mail on 465, delivers to other servers | 25, 465 |
| Dovecot (imapd, lmtpd, sieve) | Ubuntu | IMAP for your apps, the login check for Postfix, delivery into mailboxes, mail rules (Sieve) | 993, local sockets |
| Rspamd | Rspamd's official apt repository (Ubuntu's own package is older) | Spam filter, SPF/DKIM/DMARC checks, DKIM signing | 127.0.0.1 |
| Valkey | Ubuntu | Rspamd's learning data and rate limits (openly licensed Redis fork) | 127.0.0.1 |
| Unbound | Ubuntu | Local resolver for Rspamd's blocklist lookups; Spamhaus and others refuse queries from big public resolvers | 127.0.0.1 |
| nginx | Ubuntu | ACME challenge, MTA-STS policy, Thunderbird autoconfig | 80, 443 |
| certbot | Ubuntu | Gets and renews the certificate, then reloads the services | — |
| fail2ban | Ubuntu | Bans IPs after repeated failed logins (SSH, SMTP, IMAP) | — |
| restic | Ubuntu | Encrypted, deduplicated backups | — |
| ufw | Ubuntu | Firewall | — |

Rspamd's optional web UI stays on `127.0.0.1:11334`. You can reach it through an SSH tunnel.

## 4. Names and addresses

### Hostnames

| Name | Points to | Used for |
|---|---|---|
| `mail.example.com` (`MAIL_HOSTNAME`) | A/AAAA of the server | The server: MX target, IMAP, SMTP, TLS certificate. The PTRs point back to this name. |
| `mta-sts.<domain>` | CNAME `mail.example.com` | MTA-STS policy for each domain |
| `autoconfig.<domain>` | CNAME `mail.example.com` | Thunderbird automatic setup for each domain |

One certificate covers the mail hostname plus `mta-sts.` and `autoconfig.` for every domain whose DNS already points to the server. `mailctl cert-update` adds names once their DNS exists.

### Mailboxes and aliases

- **Mailboxes** are virtual users: there's no system account per mailbox. The login is the full address, and the password hash (ARGON2ID) is in `/etc/dovecot/users`.
- **The first mailbox of a domain** automatically receives that domain's `postmaster@`, `abuse@` and `reports@` mail. A Sieve rule files mail to `reports@` of a hosted domain (DMARC and TLS reports) into a `Reports` folder.
- **Plus-addressing** is on: `me+anything@example.com` arrives in `me@example.com`. There's no catch-all.
- **Sending:** a login may send only from its own address and the aliases that deliver to it, including aliases on another hosted domain.
  - Postfix checks the envelope sender.
  - Rspamd checks the From header that recipients see (`templates/rspamd/rspamd.local.lua`).
  - Both use the same generated table, `/etc/postfix/sender_login`.
- **System mail** (root, cron) goes to `ADMIN_EMAIL`.
- **Source of truth:** `/etc/mailserver/domains`, `/etc/mailserver/aliases` and `/etc/dovecot/users`. `mailctl` edits them and regenerates the Postfix tables, the DKIM selector map and the web files.

## 5. DNS records

### For the server (once)

| Name | Type | Value |
|---|---|---|
| `mail.example.com` | A | `203.0.113.10` |
| `mail.example.com` | AAAA | `2001:db8::10` (only if the server has IPv6) |
| `mail.example.com` | TXT | `"v=spf1 a -all"`. Covers the server's own name, which receivers check when it introduces itself (HELO). |
| PTR of `203.0.113.10` | at the hosting provider | `mail.example.com`. **Required before sending.** |
| PTR of `2001:db8::10` | at the hosting provider | `mail.example.com` (recommended, if the server has IPv6) |

IPv6 is optional. With `PUBLIC_IPV6` empty, the scripts ask for no AAAA or IPv6 PTR record, leave `ip6:` out of SPF, and set Postfix to IPv4 only.

### For each domain

`mailctl dns-records <domain>` prints the exact set, including the DKIM key, and shows whether each record is already live.

| Name | Type | Value |
|---|---|---|
| `<domain>` | TXT | `"v=spf1 ip4:203.0.113.10 ip6:2001:db8::10 ~all"` |
| `<selector>._domainkey.<domain>` | TXT | the RSA public key (printed by the script, split into quoted pieces) |
| `_dmarc.<domain>` | TXT | `"v=DMARC1; p=none; rua=mailto:reports@<domain>"`. Raise to `quarantine`, then `reject`, after a few clean weeks. |
| `mta-sts.<domain>` | CNAME | `mail.example.com` |
| `_mta-sts.<domain>` | TXT | `"v=STSv1; id=<MTA_STS_ID>"` |
| `_smtp._tls.<domain>` | TXT | `"v=TLSRPTv1; rua=mailto:reports@<domain>"` |
| `autoconfig.<domain>` | CNAME | `mail.example.com` |
| `_imaps._tcp.<domain>` | SRV | `0 1 993 mail.example.com` |
| `_submissions._tcp.<domain>` | SRV | `0 1 465 mail.example.com` |
| `<domain>` | CAA | `0 issue "letsencrypt.org"`. Only Let's Encrypt may issue certificates for the domain and all its names. If a website or another service on the domain gets its certificate elsewhere (e.g. AWS Certificate Manager for CloudFront), add that authority as a second value, or that certificate's next renewal fails. |
| `<domain>` | MX | `10 mail.example.com`. **Add it last**; mail starts arriving once it exists. |

SPF uses `~all` rather than `-all` because DMARC does the enforcing. This avoids rejecting forwarded mail that still carries a valid DKIM signature.

## 6. Network and ports

| Port | Service | Public | Notes |
|---|---|---|---|
| 22 | SSH | Yes, rate-limited | Key only; password login off |
| 25 | Postfix SMTP | Yes | Mail from and to other servers |
| 465 | Postfix submission (TLS) | Yes | Your apps send here; login required |
| 993 | Dovecot IMAP (TLS) | Yes | Your apps read here |
| 80 | nginx | Yes | Only `/.well-known/acme-challenge/`; everything else redirects to HTTPS |
| 443 | nginx | Yes | Only the MTA-STS policy and each domain's autoconfig file; everything else returns 404 |
| 11332–11334, 6379, 53 | Rspamd, Valkey, Unbound | No | Bound to 127.0.0.1 |
| 110, 143, 587, 995, 4190 | — | No | Never configured; the firewall blocks them too |

## 7. Mail flow

**Inbound:**
1. Another server connects to port 25.
2. Postfix accepts only addresses it hosts. Relaying for others is refused.
3. Rspamd checks SPF, DKIM, DMARC, blocklists and content.
   - A score of 15 or more is rejected while the sender is still connected, so it gets an error back.
   - A score of 6 or more is delivered with a spam header.
4. Postfix hands the message to Dovecot over LMTP.
5. A Sieve rule files spam into **Junk** and reports into **Reports**. Everything else goes to the Inbox.

**Outbound:**
1. The app logs in on port 465. Dovecot checks the password for Postfix.
2. Postfix checks that the login owns the envelope sender. Rspamd checks that it owns the address in the From header, and rejects the message if not.
3. The `Received` line with the device's IP address is removed.
4. Rspamd adds the DKIM signature for the From address's domain.
5. Postfix delivers directly, preferring IPv4.

**Spam learning:**
- Moving a message into Junk teaches Rspamd "spam"; moving it out (except to Trash) teaches "not spam". This runs through a Dovecot IMAPSieve rule that pipes the message to `rspamc`.
- Rspamd also learns automatically from very clear cases.
- Greylisting is off, because it delays legitimate mail.

**Trust:** Rspamd treats only the server itself (127.0.0.1, ::1) as local. Its default also trusts all private networks; that's replaced in `templates/rspamd/override.d/options.inc`.

**TLS:**
- Offered on port 25.
- Required on 465 and 993.
- Used for outbound delivery whenever the receiving server supports it.
- On every port the server accepts (25, 465, 993, 443): TLS 1.2 and 1.3 only; with TLS 1.2, only ciphers with forward secrecy and authenticated encryption (AES-GCM, ChaCha20), in the server's order; key exchange over elliptic curves only. This is Mozilla's "intermediate" profile without finite-field Diffie-Hellman, and it passes internet.nl's mail test. It's defined once, in `scripts/lib/common.sh`. Outbound delivery keeps Postfix's broader defaults, so mail still reaches older servers.
- MTA-STS tells other servers to require TLS when they deliver to you. Start in `testing` mode, then switch to `enforce`.

## 8. Mail app settings

| | Incoming | Outgoing |
|---|---|---|
| Server | `mail.example.com` | `mail.example.com` |
| Protocol / port | IMAP, 993 | SMTP, 465 |
| Security | SSL/TLS | SSL/TLS |
| Username | full email address | full email address |

- **Thunderbird** finds these settings itself through `autoconfig.<domain>` and the SRV records.
- **Apple Mail:** `mailctl apple-profile <address>` creates a `.mobileconfig` file.
  - It contains no password; the device asks for it.
  - It's unsigned, so the device shows "Unverified".

## 9. Backups

**Nightly at `BACKUP_TIME` (UTC), while everything keeps running:**
1. `restic backup` sends only the changes, encrypted on the server.
2. `restic forget` keeps 7 daily, 4 weekly and 6 monthly backups (configurable). Pruning runs weekly.
3. Every Sunday, `restic check` verifies part of the stored data. On the 1st of each month, a restore test puts the settings, the DKIM keys and 10 random messages into a scratch directory and checks them. It doesn't restore all mail, so it can't fill the disk.
4. A failure triggers an alert. Success records a timestamp that the daily health check watches.

**Included:**

| Path | Contents |
|---|---|
| `/var/vmail` | All mail |
| `/etc/mailserver` (except `secrets.env`) | Domains, aliases, alert settings |
| `/etc/dovecot` | Config and the mailbox/password-hash file |
| `/var/lib/rspamd/dkim` | DKIM private keys. Losing them means new keys and new DNS records. |
| `/etc/postfix`, `/etc/rspamd`, `/etc/nginx`, `/var/www/mail` | Config, for reference only. It's reproducible from the repo. |
| `/etc/letsencrypt` | Certificates, for reference only. A new server gets its own. |
| `/var/lib/valkey` | Rspamd's learning data |

`mailctl restore --apply` puts back only the mail and the server's state: `/var/vmail`, `/etc/mailserver`, `/etc/dovecot/users`, the DKIM keys and `/var/lib/valkey`.
- The configuration stays the one installed from the repository.
- Restoring old copies of files that packages own would be risky: dpkg treats them as locally changed and keeps them through later upgrades.
- The rest of the backup can be fetched with `mailctl restore --to <dir>`.

The OS and software aren't backed up; the install scripts recreate them. The backup password (`RESTIC_PASSWORD`) must be kept outside the server too, for example in a password manager, or the backups can't be read after losing the server.

**Safeguards:**
- A server with no mailboxes refuses to back up. On a rebuilt server, this stops an empty backup from becoming "latest" before you've restored.
- **Protecting backups if the server is compromised:**
  - Give the backup key access to one bucket only.
  - Turn on bucket versioning, with a lifecycle rule that deletes old versions after e.g. 30 days.
  - Don't allow the key to delete object versions.

  Then an attacker with root on the server can't destroy older backups. The runbook has an AWS example.

## 10. Monitoring and alerts

| Check | How often | Alert when |
|---|---|---|
| Postfix, Dovecot, Rspamd, Valkey, Unbound, nginx, fail2ban running; ports 25/465/993/443 listening | 5 min | Fails twice in a row |
| Disk usage | 5 min | Over `DISK_ALERT_PERCENT` |
| Mail queue | 5 min | More than `QUEUE_ALERT_COUNT` messages, or the oldest older than `QUEUE_ALERT_AGE_MINUTES` |
| TLS certificate | Daily | Fewer than `CERT_ALERT_DAYS` left (certbot renews at 30) |
| Blocklists (Spamhaus ZEN, Barracuda, SpamCop, PSBL) | Daily | Listed |
| DNS records of the server and every domain | Daily | Missing or different |
| Last successful backup | Daily | Older than `BACKUP_ALERT_HOURS` |
| Pending reboot, failed systemd units | Daily | Yes |
| Heartbeat to an external service (optional) | 5 min | The external service alerts when calls stop |

- **Channels** are set in `/etc/mailserver/alerts.env`: ntfy, Telegram, email or a webhook, and several can be on at once.
- **Repeats:** each problem is alerted once, then once a day while it lasts, plus a "resolved" message when it clears.
- **The email channel** goes through the server's own Postfix, so it can't report Postfix being down or outbound mail being blocked. Pair it with another channel, or accept that gap knowingly.
- **A server that's down can't report itself.** Cover that from outside: a heartbeat service (e.g. healthchecks.io), your hosting provider's monitoring, or any uptime monitor that fetches `https://mta-sts.<domain>/.well-known/mta-sts.txt`.

## 11. Updates

- `unattended-upgrades` installs Ubuntu security updates and updates from Rspamd's stable repository every day.
- It reboots at `REBOOT_TIME` (UTC) only when an update requires it.
- `needrestart` restarts services after library updates.
- Config files the scripts manage are kept when a package ships a new default (`--force-confold`), so updates never stall waiting for an answer.

## 12. Secrets

| Secret | Where |
|---|---|
| Mailbox passwords | Generated once and shown to you; only ARGON2ID hashes are stored, in `/etc/dovecot/users` |
| Backup password, backup storage credentials | `/etc/mailserver/secrets.env` (root, mode 600). Keep a copy outside the server. |
| Alert tokens | `/etc/mailserver/alerts.env` (root, mode 600) |

The repository holds only `*.example` files. `.gitignore` excludes `config/mailserver.env`, the `private/` notes folder and any local copies of secrets.

## 13. What the server makes public

**All domains on one server can be seen to belong together:**
- Every domain's MX record names the mail hostname (`mail.example.com`), and with it the primary domain. So do the SPF records, which list the server's IP addresses.
- The TLS certificate lists the `mta-sts.` and `autoconfig.` names of every domain whose DNS points to the server.
  - Anyone who connects to ports 25, 443, 465 or 993 can read it.
  - Public Certificate Transparency logs keep each certificate permanently, including names of domains you've stopped hosting.
- Recipients see the mail hostname and the server's IP address in the `Received` line their own server adds, whichever domain the mail is from.

If two domains must not be linkable, host them on separate servers.

**What isn't revealed:**
- **The other domains.** Thunderbird's autoconfig file for a domain names only that domain. DMARC and TLS reports for a domain go to `reports@` of that same domain.
- **Your device's IP address.** It's removed from mail you send.
- **Your list of mailboxes.** It can't be listed. Postfix turns off `VRFY`. As on any server that rejects unknown recipients, a single guessed address can be tested. Rejecting unknown recipients avoids sending bounces to forged senders.

## 14. Repository layout

```
config/
  mailserver.env.example     copy to mailserver.env (git-ignored) and edit
  secrets.env.example        → /etc/mailserver/secrets.env on the server
  alerts.env.example         → /etc/mailserver/alerts.env on the server
templates/                   config files, with ${VARIABLES} filled from mailserver.env
  postfix/  dovecot/  rspamd/  nginx/  unbound/  fail2ban/  letsencrypt/  host/  systemd/
scripts/
  00-host-setup.sh           hostname, swap, SSH hardening, firewall, automatic updates, logging
  10-install-mail.sh         packages, config, certificate, checks
  20-install-backups.sh      restic repository, nightly timer, first backup
  30-install-monitoring.sh   health-check timers, test alert
  mailctl                    admin command (installed as /usr/local/sbin/mailctl)
  admin/  ops/  lib/         mailctl subcommands, backup/restore/health/notify, shared helpers
tests/
  run.sh                     full install + end-to-end test in a local Ubuntu 26.04 container
docs/
.github/workflows/           CI: shellcheck and tests/run.sh
private/                     optional, git-ignored: your own notes (not copied to the server)
```

**Server-side state** that isn't in the repository but is included in backups:
- `/etc/mailserver/{domains,aliases,secrets.env,alerts.env}`
- `/etc/dovecot/users`
- `/var/lib/rspamd/dkim`
- `/var/vmail`

## 15. Tested and known limits

`tests/run.sh` covers the whole install and about 170 checks in an Ubuntu 26.04 container. Versions tested: Postfix 3.10, Dovecot 2.4.2, Rspamd 4.3, Valkey 9.0, Unbound 1.24, nginx 1.28, certbot 4.0, fail2ban 1.1, restic 0.18.

**On a real server.** The full runbook has been followed on a fresh Ubuntu 26.04 VPS with IPv4 and IPv6, from step 0 to step 9. The results:
- **Gmail, in both directions:** SPF, DKIM and DMARC `PASS`, delivered over TLS 1.3. No client IP address or login name in the headers.
- **mail-tester.com:** 10/10.
- **internet.nl:** every STARTTLS, cipher and certificate test passes. Still red, as expected: DNSSEC, DANE, DMARC while it is `p=none`, and, with DNS providers that answer "no such name" for `_domainkey.<domain>`, its DKIM test.
- **Backups:** a nightly backup to AWS S3. A message was deleted, and `mailctl restore --apply` brought it back.
- **Alerts:** a test alert by email, and every health check `OK`.

A new domain on a new IP address can still land in Gmail's spam folder for its first mails, with everything passing. That's reputation, not configuration, and it improves with a few weeks of normal mail.

Findings the configuration accounts for:
- **fail2ban:** its stock Dovecot filter doesn't match Dovecot 2.4's failed-login lines. `templates/fail2ban/mailserver-dovecot.conf` adds one that does.
- **newaliases:** it doesn't expand `$default_database_type`, so `hash:` is spelled out.
- **Postfix unit name:** on 26.04 it's `postfix.service`, not `postfix@-`.
- **Dovecot storage:** new mail goes straight into `cur/`. This only matters to scripts that count files.

**Limits:**
- **Ubuntu 26.04 only.** The Dovecot config is written for 2.4.
- **One server.** There's no high availability; senders retry for days, so short outages lose no mail.
- **Infrastructure the scripts can't check:** outbound port 25 must be allowed, and the hosting provider must let you set reverse DNS.
- **Only on a real server:** Let's Encrypt issuance and real deliverability. See the go-live tests in the runbook.
- **Not included:** DNSSEC/DANE, outbound MTA-STS checking (`postfix-mta-sts-resolver`), and sending DMARC reports to other domains.
- **With email as the only alert channel,** a stopped Postfix or blocked outbound mail goes unreported, because the alert itself would need Postfix. See [Monitoring and alerts](#10-monitoring-and-alerts).
