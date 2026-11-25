# Runbook

Step-by-step procedures for installing and running the mail server.
- Commands run **on the server as `root`** unless marked "on your machine".
- The background is in [architecture.md](architecture.md).
- Examples use `example.com` (first domain), `example.org` (second domain), `mail.example.com` (the server), `203.0.113.10` and `2001:db8::10`. Use your own values.

**Contents**
- **What this setup decides, and what you decide.** Read this first.
- **Part 1: first installation.** Steps 0–10, in order. Each step ends with a check, so you know it worked before moving on.
- **Part 2: everyday tasks.**
- **Part 3: when something goes wrong.**

The first installation takes an afternoon. Most of the time goes into waiting for DNS changes to show up.

---

## What this setup decides, and what you decide

This isn't a configurable mail platform. It's one specific, tested setup. These choices are fixed, and changing them means editing the templates:

| Fixed choice | What it means for you |
|---|---|
| One Ubuntu 26.04 server, no containers | You need a VPS of your own with root access. Other releases ship different Dovecot versions. |
| Mail only | No webmail, calendar, contacts or admin web interface. You manage everything with `mailctl` over SSH. |
| IMAP on 993 and sending on 465, both TLS-only | No POP3, no port 143 or 587. Every current mail app supports this. |
| DNS records entered by hand | Works with any DNS provider. The server never holds DNS credentials. `mailctl dns-records` prints each record and checks it. |
| Let's Encrypt over port 80 | Port 80 must be reachable from the internet. |
| Sends over IPv4 first | Receives over IPv4 and IPv6. Prefers IPv4 when delivering, because a missing IPv6 reverse DNS is a common reason for rejected mail. |
| Personal scale | A few domains and mailboxes. No quotas, no catch-all, no per-user admin rights. |

These you decide, at the step shown:

| Decision | Options | Recommended | Step |
|---|---|---|---|
| Mail hostname and first domain | Any domain whose DNS you control | `mail.<your main domain>` | 1 |
| IPv6 | Set `PUBLIC_IPV6`, or leave it empty | Set it if the server has one and you can set its reverse DNS | 1 |
| Where backups go | Any restic repository: S3, S3-compatible storage, SFTP, a REST server | Storage with versioning, at another provider than the server | 8 |
| Where alerts go | ntfy, Telegram, email, webhook (several at once) | Two channels, at least one not sent through this server | 9 |
| Who watches from outside | A heartbeat service, your hosting provider's monitoring, any uptime monitor | At least one. A server that's down can't send alerts | 9 |
| More domains on the same server | Add them, or use a second server | Same server, unless the domains must not be linkable ([why](architecture.md#13-what-the-server-makes-public)) | 10 |
| When to tighten DMARC and MTA-STS | After the reports look clean | 2–4 weeks after go-live | Later |

---

## Part 1: First installation

### Step 0: Before you start

1. **Log in to the server as root with your SSH key** (on your machine):
   ```sh
   ssh root@203.0.113.10
   ```
   - **If the provider gave you a user such as `ubuntu` instead,** log in as that user and give root the same key:
     ```sh
     sudo install -D -m 600 ~/.ssh/authorized_keys /root/.ssh/authorized_keys
     ```
     If `ssh root@203.0.113.10` is still refused, the image turns root login off:
     1. Look for `PermitRootLogin no` in `/etc/ssh/sshd_config` and in the files in `/etc/ssh/sshd_config.d/`.
     2. Change it to `PermitRootLogin prohibit-password`.
     3. Run `sudo systemctl reload ssh`.
   - **Check that rsync is installed** on the server. Step 1 copies the project with it, and minimal images may not include it:
     ```sh
     command -v rsync || { apt update && apt install -y rsync; }
     ```
2. **Check outbound port 25.** Many providers block it. On the server:
   ```sh
   nc -4 -vz -w 5 gmail-smtp-in.l.google.com 25
   ```
   `succeeded` means it's open. If it times out, ask your provider to unblock it; without it the server can't deliver mail.

   Run this check on the server, not at home: most home internet providers block outbound port 25, so the same command from your own machine fails even when the server is fine.
3. **Open the ports at your hosting provider, if it has a firewall in front of the server.** It's often called a cloud firewall or security group.
   - Allow incoming TCP on 22, 25, 80, 443, 465 and 993.
   - The scripts set up the server's own firewall, but they can't change the provider's.
   - Without port 80, getting the certificate in step 3 fails.
4. **Create the server's DNS records** at your DNS provider, in the zone of your first domain:

   | Name | Type | Value |
   |---|---|---|
   | `mail.example.com` | A | `203.0.113.10` |
   | `mail.example.com` | AAAA | `2001:db8::10` (if the server has IPv6) |

   While you set things up, a short TTL such as 300 seconds lets corrections show up quickly. You can raise it later.

5. **Set reverse DNS (PTR)** for the server's IP addresses to `mail.example.com`. This is done at the hosting provider that owns the addresses, not at your DNS provider. Usually there's a "reverse DNS" field in their control panel; some providers do it on request. The IPv4 PTR is required before sending mail. IPv6 is recommended.

**Check (on your machine):**

```sh
dig +short A mail.example.com      # 203.0.113.10
dig +short -x 203.0.113.10         # mail.example.com.
dig +short AAAA mail.example.com   # 2001:db8::10       (if the server has IPv6)
dig +short -x 2001:db8::10         # mail.example.com.  (if the server has IPv6)
```

### Step 1: Configure and copy the project (on your machine)

```sh
git clone https://github.com/antekonjevic/tools-mail-server.git mailserver
cd mailserver
cp config/mailserver.env.example config/mailserver.env
$EDITOR config/mailserver.env
rsync -av --delete --exclude .git --exclude private/ --exclude '*.mobileconfig' ./ root@203.0.113.10:/opt/mailserver/
```

The clone gives you the latest `main`, which is tested on every change. To use a fixed release instead, check out its tag, e.g. `git checkout v1.2.0` (`git tag` lists them). "Upgrading to a new version" in part 2 covers both ways.

Set at least `MAIL_HOSTNAME`, `PRIMARY_DOMAIN`, `PUBLIC_IPV4` and `ADMIN_EMAIL`. Set `PUBLIC_IPV6` if the server has a public IPv6 address, and leave it empty if not. The scripts refuse to run with the example values.

Repeat the `rsync` whenever you change something. The server always runs the scripts from `/opt/mailserver`.

The excludes keep what is only yours off the server: `private/` (a git-ignored folder for your own notes, if you keep any) and Apple setup files you've downloaded.

### Step 2: Prepare and harden the server

```sh
ssh root@203.0.113.10
/opt/mailserver/scripts/00-host-setup.sh
```

The script does the following:
- Sets the hostname and the time zone (UTC).
- Installs updates.
- Adds 2 GB of swap.
- Turns off password login for SSH.
- Turns on the firewall.
- Turns on automatic security updates.

It refuses to run if `root` has no SSH key.

**Before closing your session**, check in a **new** terminal that `ssh root@203.0.113.10` still works.

**If the script ends with "reboot"**, the updates included a new kernel. Run `reboot`, wait a minute, and log in again. On a fresh server this is normal.

### Step 3: Install the mail software

```sh
/opt/mailserver/scripts/10-install-mail.sh
```

The script:
- Installs and configures Postfix, Dovecot, Rspamd, Valkey, Unbound, nginx, certbot and fail2ban.
- Gets the Let's Encrypt certificate.
- Checks that only the expected ports are open.

It stops with a clear message if `mail.example.com` doesn't resolve to the server yet.

**Check:** the script ends with "port … is listening" for 25, 465, 993, 80 and 443, and "The mail stack is installed". At this point the certificate covers only `mail.example.com`. The `mta-sts.` and `autoconfig.` names are added in step 5, once their DNS records exist.

### Step 4: First domain and mailbox

```sh
mailctl add-domain example.com
mailctl add-mailbox me@example.com
```

- `add-mailbox` prints a generated password **once**. Store it in your password manager.
- To choose the password yourself instead, use `--prompt`.
- The first mailbox of a domain also receives `postmaster@`, `abuse@` and `reports@` for that domain.
- Create the `ADMIN_EMAIL` mailbox first, because system mail goes there.

**Check:** `mailctl list` shows the domain with its DKIM selector, the mailbox, and the three aliases.

### Step 5: DNS records for the domain

```sh
mailctl dns-records example.com
```

The command prints every record to create, with a **now:** line showing whether it's live yet (`OK`, `MISSING` or `DIFFERENT`).

1. At your DNS provider, create **all records except MX**.
   - Most consoles want only the part before the domain as the record name, e.g. `_dmarc` or `s202601._domainkey`.
   - Enter TXT values as printed. The long DKIM key is already split into quoted pieces.
   - **If the domain already has a website or other HTTPS services, check the CAA record first.** It allows only Let's Encrypt to issue certificates for the domain and all its names. A website whose certificate comes from somewhere else would fail at its next renewal. On your machine, see who issued the website's certificate:
     ```sh
     echo | openssl s_client -connect example.com:443 -servername example.com 2>/dev/null | openssl x509 -noout -issuer
     ```
     If it isn't Let's Encrypt, add that certificate authority as a second value of the same CAA record. Common ones are `0 issue "amazon.com"` (AWS Certificate Manager, used by CloudFront), `0 issue "pki.goog"` (Google) and `0 issue "sectigo.com"`. Your provider's documentation names the right value. `mailctl dns-records` still shows `OK` with extra values.
2. Run `mailctl dns-records example.com` again until everything except MX shows `OK`. It asks a public resolver (1.1.1.1), so a new record can take a few minutes to show up.
3. Add the `mta-sts.` and `autoconfig.` names to the certificate:
   ```sh
   mailctl cert-update
   ```
4. Create the **MX** record last. From that moment the domain receives mail.

**Check (on your machine):**

```sh
curl https://mta-sts.example.com/.well-known/mta-sts.txt          # version: STSv1, mode: testing, mx: mail.example.com
curl -s https://autoconfig.example.com/mail/config-v1.1.xml | head -4   # XML naming example.com
dig +short MX example.com                                         # 10 mail.example.com.
```

Both `curl` commands must work without `-k`. That shows the certificate covers the new names.

### Step 6: Set up your mail apps

| | Incoming | Outgoing |
|---|---|---|
| Server | `mail.example.com` | `mail.example.com` |
| Port / security | 993, SSL/TLS | 465, SSL/TLS |
| Username | the full email address | the full email address |

- **Thunderbird:** enter the address and password; it finds the settings itself.
- **Apple Mail:**
  ```sh
  cd /root && mailctl apple-profile me@example.com
  ```
  Then, on your machine:
  ```sh
  scp 'root@203.0.113.10:/root/me@example.com.mobileconfig' .
  ```
  - **Mac:** double-click the file, then install it under **System Settings → General → Device Management**.
  - **iPhone/iPad:** send it with AirDrop, then go to **Settings → Profile Downloaded → Install**.
  - It shows as "Unverified" because it isn't signed. That's expected.
  - It asks for the password during installation.
- **iPhone and iPad** check IMAP accounts on a schedule rather than instantly. Macs and desktop apps get new mail immediately.

**Check:** the app shows the folders Inbox, Sent, Drafts, Junk, Trash, Archive and Reports, and a message you send to your own address arrives.

### Step 7: Go-live tests

Do these in order. Write real messages, with a few sentences of normal text. A message that only says "test" looks like spam to every filter.

1. **Send to and receive from a big provider**, e.g. Gmail. Mail in both directions should arrive within a minute.
   - **In Gmail, open the message and choose Show original.** At the top it should say `PASS` for SPF, DKIM and DMARC. Further down, the `Received` lines should show TLS, and neither your device's IP address nor your login name should appear anywhere in the headers.
   - **Your first mails may land in Gmail's spam folder even with everything passing.** A new domain and a new IP address have no reputation yet. Mark them "Not spam", and reply from Gmail to your own address; that helps too.
   - Repeat with Outlook.com and iCloud if you write to people there.
2. **mail-tester.com:** send a message to the address the site shows. The target is 10/10.
3. **internet.nl:** run the "Email" test for the domain. With this setup, all STARTTLS and certificate tests pass. Expect these to show red until you act on them, and none of them stops mail from working:
   - **DMARC:** the policy `p=none` counts as too weak. It turns green once you tighten it ("Later", below).
   - **DNSSEC and DANE:** not part of this setup. DNSSEC is switched on at your DNS provider, if it offers it.
   - **DKIM:** some DNS providers (AWS Route 53, for example) answer "no such name" for `_domainkey.example.com` itself, and internet.nl reads that as "no DKIM". Your real key, under `<selector>._domainkey`, still works; mail-tester and Gmail confirm it.
   - **"Phase out" notes** on key-exchange algorithms are recommendations, not failures.
4. **Register with the big providers**, so you can see how they rate your mail:
   - **Google Postmaster Tools** (https://postmaster.google.com): add the domain and prove you own it with the TXT record it shows. Charts appear only once you send a fair amount of mail to Gmail each day, so a personal server may never show any data. The registration is still worth having.
   - **Microsoft SNDS** (https://sendersupport.olc.protection.outlook.com/snds/): request access for the server's IPv4 address. The confirmation goes to `postmaster@` of the reverse-DNS domain, which this server already delivers to your mailbox. Open it and accept.
5. **A new IP needs a few weeks of normal mail to build reputation.** Keep marking early mails "Not junk" wherever they land in spam.

### Step 8: Backups

Any restic repository works: S3 or S3-compatible storage, SFTP, a restic REST server and more. Here's an AWS S3 example.

**8a. Create the storage (AWS example):**

1. **S3 → Create bucket.**
   - Pick a unique name and a nearby region.
   - Keep **Block all public access** on.
   - **Enable versioning.**
2. **Management → lifecycle rule**, applied to all objects:
   - Permanently delete noncurrent versions **30 days** after they become noncurrent.
   - Delete incomplete multipart uploads after **7 days**.
3. **IAM → create a user** with no console access.
   1. Attach this inline policy, replacing `BUCKET`:
      ```json
      {
        "Version": "2012-10-17",
        "Statement": [
          { "Effect": "Allow",
            "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
            "Resource": "arn:aws:s3:::BUCKET" },
          { "Effect": "Allow",
            "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
            "Resource": "arn:aws:s3:::BUCKET/*" }
        ]
      }
      ```
      The key can't delete old versions or change the bucket's settings. Even with root on the server, an attacker can't destroy backups older than the versioning window.
   2. Create an access key for this user.

**8b. Configure and run:**

1. **On your machine:** set `BACKUP_REPOSITORY` in `config/mailserver.env`, e.g. `s3:s3.eu-central-1.amazonaws.com/<bucket>/mailserver`. The region in the address must be the bucket's region. Then rsync again.
2. **On the server**, generate the backup password and store it in your password manager. Without it, the backups can't be read.
   ```sh
   openssl rand -base64 32
   ```
3. Run the backup install script once. The first time, it only creates `/etc/mailserver/secrets.env` and stops with "Secrets file created". That's expected.
   ```sh
   /opt/mailserver/scripts/20-install-backups.sh
   ```
4. Fill in the secrets file:
   ```sh
   nano /etc/mailserver/secrets.env
   ```
   - Set `RESTIC_PASSWORD`.
   - For S3, also set the access key.
   - Other restic backends take their own variables.
5. Run the script again. It initialises the repository, enables the nightly timer and makes the first backup.
   ```sh
   /opt/mailserver/scripts/20-install-backups.sh
   ```
   **Check:** it ends with a list of backups ("snapshots") that has one entry, and "backups run daily at …". In the storage console you'll see the repository's files under the path you chose. They are encrypted, so nothing in them is readable there.

**8c. Restore drill (do this once, before real mail matters):**

```sh
mailctl restore --verify             # test-restore settings, DKIM keys and a sample of mail
ls /var/vmail/example.com/me/Maildir/cur | head -3
rm /var/vmail/example.com/me/Maildir/cur/<one of the files>
mailctl restore --apply              # type 'restore' to confirm
```

Check in your mail app that the deleted message is back.

### Step 9: Monitoring and alerts

1. Run the monitoring install script once. The first time, it only creates `/etc/mailserver/alerts.env` and stops with "Alerts file created". That's expected.
   ```sh
   /opt/mailserver/scripts/30-install-monitoring.sh
   ```
2. Choose your channels in the alerts file, and set `ALERT_CHANNELS` to the ones you use:
   ```sh
   nano /etc/mailserver/alerts.env
   ```

   | Channel | Setup | Keep in mind |
   |---|---|---|
   | `ntfy` | Subscribe in the ntfy app to the same long random topic you put in `NTFY_URL` | Anyone who knows the topic can read the alerts, so make it long and random |
   | `telegram` | Create a bot with @BotFather, then fill in its token and your chat id | |
   | `email` | An address at another provider, in `ALERT_EMAIL_TO` | Sent by this server's own Postfix, so it can't report Postfix being down or outbound mail being blocked. At the receiving address, add a filter that never sends mail from `root@mail.example.com` to spam |
   | `webhook` | Any URL that accepts a JSON POST | |

   Email alone is a valid choice if you accept that gap. Add a second channel if you don't.
3. Run the script again. It sends a test alert and runs all checks once.
   ```sh
   /opt/mailserver/scripts/30-install-monitoring.sh
   ```
   **Check:** the test alert arrives on every channel, and each check prints `OK`. A `FAIL` is a real finding, and its message says what to look at.
4. **Watch the server from outside.** A server that's down, or has lost its network, can't send any alert. Pick at least one:
   - **A heartbeat:** create a check on https://healthchecks.io (period 5 min, grace 15 min) and put its URL in `HEARTBEAT_URL`. The server calls it every 5 minutes, and healthchecks.io alerts you when the calls stop.
   - **Your hosting provider's monitoring,** if it has any. Many offer a free ping or port check.
   - **Any uptime monitor that fetches a web page:** point it at `https://mta-sts.example.com/.well-known/mta-sts.txt` and expect the text `STSv1`. It answers only while the server, nginx and the certificate are all fine.
5. **Store everything you need for a rebuild in your password manager:** the mailbox passwords, `RESTIC_PASSWORD` and the backup access key from `/etc/mailserver/secrets.env`, and any alert tokens.

**The first installation is complete.** From now on, only the "Later" section below needs a date in your calendar.

### Step 10: More domains

```sh
mailctl add-domain example.org
mailctl add-mailbox someone@example.org
mailctl dns-records example.org
```

1. Create the records in the zone of `example.org`, all except MX.
2. Run `mailctl cert-update`.
3. Add the MX record.
4. Add the new mailbox to your mail apps (step 6).
5. Repeat the step 7 tests for this domain.

### Later: tighten the policies (2–4 weeks after go-live)

Put a date in your calendar. Until then, the domain asks receivers only to report, not to reject, so a mistake can't make your mail disappear.

Reports arrive in the **Reports** folder:
- **DMARC reports** come from Google, Microsoft and others, usually daily, as a zipped XML attachment. In each `<record>`, check that `<source_ip>` is your server's address and that `<dkim>` and `<spf>` say `pass`. Another IP address means something else sends mail as your domain: a newsletter service, a website contact form, or someone forging your address.
- **TLS reports** (TLS-RPT) come as JSON. `"total-failure-session-count": 0` means every server that delivered to you managed a secure connection.

**DMARC.** When the reports show only your server sending for a domain:
1. Change `p=none` to `p=quarantine` in its `_dmarc` record.
2. A few weeks later, change it to `p=reject`.

**MTA-STS.** When the TLS reports show no failures:
1. Set `MTA_STS_MODE=enforce` and a new `MTA_STS_ID` (e.g. today's date) in `config/mailserver.env`.
2. rsync to the server, then run `mailctl apply`.
3. Update the `_mta-sts` TXT record of **every** domain to the new id (`mailctl dns-records` shows it).

---

## Part 2: Everyday tasks

| Task | Command |
|---|---|
| Show everything | `mailctl list` |
| New domain | `mailctl add-domain example.net`, then its DNS records (step 5) |
| New mailbox | `mailctl add-mailbox name@example.net` |
| New alias | `mailctl add-alias sales@example.com me@example.com` |
| Alias to several mailboxes | `mailctl add-alias team@example.com me@example.com,someone@example.org` |
| Change where an alias goes | run `add-alias` again with the new target |
| Remove an alias | `mailctl remove-alias sales@example.com` |
| New password | `mailctl reset-password me@example.com` (or `--prompt`) |
| Remove a mailbox (keeps its mail) | `mailctl remove-mailbox name@example.net` |
| …and delete its mail | `mailctl remove-mailbox name@example.net --delete-mail` |
| Stop hosting a domain | remove its mailboxes and aliases, `mailctl remove-domain example.net`, then delete its DNS records |
| Check DNS of everything | `mailctl dns-records` |
| Apple setup file | `mailctl apple-profile name@example.com` |
| Backup now | `mailctl backup` |
| Health check now | `mailctl health` (services, ports, disk, queue) and `mailctl health daily` (certificate, blocklists, DNS, backups) |
| Test the alert channels | `mailctl test-alert` |

**Changing configuration:**
1. Edit `templates/` or `config/mailserver.env` on your machine.
2. Run the rsync from step 1.
3. Re-run `/opt/mailserver/scripts/10-install-mail.sh`.

All scripts are safe to re-run. Don't edit the generated files on the server (`/etc/postfix/main.cf`, `/etc/dovecot/dovecot.conf`, …); the next run overwrites them.

**Testing changes first (on your machine, needs Docker):**

```sh
tests/run.sh
```

### Upgrading to a new version

1. **On your machine, get the new version:**
   ```sh
   git pull                                     # if you follow main
   git fetch --tags && git checkout v1.2.0      # if you use releases
   ```
2. **See what changed** between your version and the new one:
   ```sh
   git log --oneline ORIG_HEAD..HEAD             # after git pull
   git log --oneline v1.1.0..v1.2.0              # between two releases
   ```
   Look for anything you have to do yourself, such as a new setting or a DNS change.
3. **Compare your settings with the example**, to spot new settings:
   ```sh
   diff <(grep -oE '^[A-Z0-9_]+=' config/mailserver.env.example | sort) \
        <(grep -oE '^[A-Z0-9_]+=' config/mailserver.env | sort)
   ```
   - A line starting with `<` is a setting your file doesn't have yet. Copy it from the example and set it.
   - A line starting with `>` is one the new version no longer uses.
4. **Recommended:** run `tests/run.sh`.
5. **Copy the new version to the server** with the rsync from step 1.
6. **On the server, re-run the install scripts.** They change only what differs.
   ```sh
   /opt/mailserver/scripts/00-host-setup.sh
   /opt/mailserver/scripts/10-install-mail.sh
   /opt/mailserver/scripts/20-install-backups.sh      # if backups are set up; it also makes a backup
   /opt/mailserver/scripts/30-install-monitoring.sh   # if monitoring is set up; it also sends a test alert
   ```
7. **Check that everything works:** run `mailctl health` and `mailctl health daily`, then send and receive a test message.

To go back, check out the previous version on your machine, then repeat steps 5 and 6.

### Rspamd web interface (optional)

It shows spam scores, learning statistics and recent messages. It's reachable only through SSH:
1. On your machine, open a tunnel:
   ```sh
   ssh -L 11334:127.0.0.1:11334 root@203.0.113.10
   ```
2. Open http://localhost:11334 in your browser.

---

## Part 3: When something goes wrong

**First look**

```sh
mailctl health                       # services, ports, disk, queue
mailctl health daily                 # certificate, blocklists, DNS, backups
journalctl -u postfix -u dovecot -u rspamd --since "1 hour ago"
less /var/log/rspamd/rspamd.log      # spam scores and learning
```

**Mail stuck in the queue**

```sh
postqueue -p                         # list
postqueue -f                         # retry everything now
postcat -q <QUEUE-ID>                # show one message
postsuper -d <QUEUE-ID>              # delete one message
```

**Someone was banned by fail2ban** (e.g. you mistyped a password several times):

```sh
fail2ban-client status dovecot
fail2ban-client set dovecot unbanip <IP>        # also: postfix-sasl, sshd
```

**Certificate.** It renews automatically 30 days before expiry. To test renewal:

```sh
certbot renew --dry-run
```

**Restore from backup**

```sh
mailctl restore --list                          # all backups
mailctl restore --to /root/restored <ID>        # copy a backup into a folder, to fetch single files
mailctl restore --apply [<ID>]                  # put mail, mailboxes, aliases and DKIM keys back
```

**Rebuild on a new server (disaster recovery)**

1. Create a new Ubuntu 26.04 server. If its IP addresses changed:
   - Update `PUBLIC_IPV4` and `PUBLIC_IPV6`.
   - Update the `mail` A/AAAA records and the reverse DNS (step 0).
   - The SPF values change too; `mailctl dns-records` will show them.
2. Steps 1–3 (configure and copy, `00-host-setup.sh`, `10-install-mail.sh`).
3. Recreate `/etc/mailserver/secrets.env` from your password manager (mode 600).
4. Restore **before** setting up backups again:
   ```sh
   mailctl restore --list
   mailctl restore --apply <ID of the last good backup>
   ```
   - This puts back mail, mailboxes with their passwords, domains, aliases and DKIM keys. The configuration stays the one `10-install-mail.sh` just installed from the repository.
   - Restic is installed automatically if it's missing.
   - Backups refuse to run on a server without mailboxes, so an empty backup can't replace the good one first.
5. Run `mailctl apply`, `mailctl cert-update`, `20-install-backups.sh` and `30-install-monitoring.sh`.

**Rotate a domain's DKIM key** (optional; e.g. yearly):

1. Generate a key with a new selector:
   ```sh
   rspamadm dkim_keygen -b 2048 -s s202701 -d example.com -k /var/lib/rspamd/dkim/example.com.s202701.key >/dev/null
   chown _rspamd:_rspamd /var/lib/rspamd/dkim/example.com.s202701.key
   chmod 640 /var/lib/rspamd/dkim/example.com.s202701.key
   ```
2. Change that domain's selector in `/etc/mailserver/domains`, then run `mailctl dns-records example.com`. Publish the new `_domainkey` record, but **don't run `mailctl apply` yet**.
3. Once the new record shows `OK`, run `mailctl apply`. Mail is now signed with the new key.
4. A week later, delete the old `_domainkey` record and the old key file.
