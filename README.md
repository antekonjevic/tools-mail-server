# Self-hosted mail server for Ubuntu 26.04

Shell scripts that turn a fresh Ubuntu 26.04 VPS into a complete mail server for your own domains. It uses the proven open-source stack: Postfix, Dovecot and Rspamd. Everything is plain-text configuration in this repository, installed by scripts you can read before you run them, and tested end to end in a local container.

It's built for **personal use**: a few domains and mailboxes, read and sent from normal mail apps (Apple Mail, Thunderbird, …).

## Is this for you?

This is one specific, tested setup, not a platform with options for every case. It's a good fit if:
- you want your own mail on your own server, for yourself and maybe a few others
- you're comfortable with SSH and copying commands into a terminal
- you're fine adding DNS records by hand at your DNS provider
- mail apps are enough, with no webmail

It's not the right tool for newsletters or bulk mail, for hosting mail for customers, or if you want a web admin interface. For those, look at all-in-one products such as mailcow or Mail-in-a-Box.

Some things are fixed, such as Ubuntu 26.04, TLS-only ports and sending over IPv4 first. Others you choose along the way: IPv6, where backups go, where alerts go, and who watches the server from outside. The [runbook](docs/runbook.md#what-this-setup-decides-and-what-you-decide) lists both, with a recommended choice for each.

## What you get

- **Several domains and mailboxes on one server**, plus aliases and plus-addressing (`you+shop@example.com`).
- **Good deliverability out of the box:**
  - SPF, DKIM (RSA-2048) and DMARC.
  - MTA-STS and TLS reporting.
  - Reverse-DNS checks.
  - The exact DNS records for each domain, with a live check of which ones are in place.
- **Spam filtering with Rspamd.** Spam goes to Junk. Moving mail into or out of Junk teaches the filter.
- **Locked down:**
  - IMAP and SMTP over TLS only (ports 993 and 465). No POP3, no plain-text logins.
  - Firewall, SSH key-only login, and fail2ban, including a filter for Dovecot 2.4's log format.
  - Each login may send only from its own addresses, in both the envelope and the From header.
  - Your device's IP address is removed from mail you send.
- **Automatic setup for mail apps:**
  - Thunderbird configures itself from the address and password.
  - Apple Mail gets a generated setup file (`.mobileconfig`).
- **Nightly encrypted backups** with restic, to S3 or any restic backend, with no downtime. Restore commands, a restore drill and a monthly restore test.
- **Monitoring and alerts** to ntfy, Telegram, email or a webhook:
  - services, ports, disk, mail queue, certificate expiry
  - blocklists, DNS records, backup age
  - an optional external heartbeat
- **Hands-off maintenance.** Ubuntu security updates, and updates from Rspamd's repository, install automatically, with a reboot window you choose.
- **One admin command, `mailctl`,** for domains, mailboxes, aliases, passwords, DNS records, certificates, backup and restore.

There's no webmail, calendar or contacts, and no admin web interface. These are deliberate choices: fewer moving parts and less exposed to the internet.

All domains on one server can be seen to belong together: they share the mail hostname and one TLS certificate. If two of your domains must not be linkable, give them separate servers. [What the server makes public](docs/architecture.md#13-what-the-server-makes-public) has the details.

## Requirements

- **A fresh Ubuntu 26.04 VPS** with a public IPv4 address (IPv6 optional) and about 2 GB of RAM or more.
- **SSH login as root with a key.** Some providers give you a user such as `ubuntu` instead. Step 0 of the [runbook](docs/runbook.md) shows how to let root log in with the same key.
- **Outbound port 25 open.** Some providers block it; check with `nc -4 -vz gmail-smtp-in.l.google.com 25` on the server.
- **Incoming ports 22, 25, 80, 443, 465 and 993 open at your hosting provider**, if it has a firewall in front of the server (often called a cloud firewall or security group). The scripts set up the server's own firewall.
- **Reverse DNS (PTR)** for the server's IP, set by your hosting provider to the mail hostname, e.g. `mail.example.com`.
- **Domains whose DNS you can edit.** The records are entered by hand at any DNS provider.
- **On your own machine:** git, ssh, rsync and dig.
  - A Mac includes them.
  - On Linux, install any that are missing. dig is in the `bind9-dnsutils` or `bind-utils` package.
  - On Windows, use WSL.
- Optional: somewhere to store backups (an S3 bucket or any other restic repository).
- Optional, for running the tests: Docker on your own machine.

Only Ubuntu 26.04 is supported. The Dovecot configuration targets Dovecot 2.4, and other releases ship different versions.

## Quick start

First do step 0 of the [runbook](docs/runbook.md): root login, port 25, the provider's firewall, and the server's DNS and reverse DNS.

Then, on your own machine:

```sh
git clone https://github.com/antekonjevic/tools-mail-server.git mailserver && cd mailserver
cp config/mailserver.env.example config/mailserver.env
$EDITOR config/mailserver.env            # hostname, domain, IP addresses, admin address
rsync -av --delete --exclude .git --exclude private/ --exclude '*.mobileconfig' ./ root@203.0.113.10:/opt/mailserver/
```

On the server, as root:

```sh
/opt/mailserver/scripts/00-host-setup.sh      # hardening, firewall, automatic updates
/opt/mailserver/scripts/10-install-mail.sh    # mail stack + Let's Encrypt certificate
mailctl add-domain example.com
mailctl add-mailbox me@example.com            # prints a generated password once
mailctl dns-records example.com               # the DNS records to create, MX last
```

Then set up backups (`20-install-backups.sh`) and monitoring (`30-install-monitoring.sh`). Both stop after their first run so you can fill in a settings file; that's expected, and the message says what to do next.

**[docs/runbook.md](docs/runbook.md)** walks through every step, including DNS, mail app setup, go-live tests, backups, restore and recovery. **[docs/architecture.md](docs/architecture.md)** explains how it fits together and why.

## Everyday use

```sh
mailctl list                                   # domains, mailboxes, aliases
mailctl add-alias hello@example.com me@example.com
mailctl reset-password me@example.com
mailctl apple-profile me@example.com           # Apple Mail setup file
mailctl health                                 # run the health checks now
mailctl backup                                 # back up now
mailctl help                                   # everything else
```

All install scripts are safe to re-run. To change the configuration:
1. Edit a file in `templates/` or `config/mailserver.env`.
2. Copy the repo to the server again.
3. Re-run `scripts/10-install-mail.sh`.

## Testing

```sh
tests/run.sh          # needs Docker; add --keep to leave the container running
```

This installs everything with the real scripts in a local Ubuntu 26.04 container under systemd, then runs about 170 checks:
- delivery, plus-addressing and aliases
- spam filing and spam learning
- sending, DKIM signing and the sender rules
- relay and login refusals, and closed ports
- web endpoints, the admin commands and fail2ban filters
- the TLS policy on every port
- backup and restore, alerts
- re-running the install scripts, and a server without IPv6

It uses reserved `.test` domains and touches no real server or DNS. Let's Encrypt and real-world deliverability can only be checked on a real server (see the go-live tests in the runbook).

**On a real server,** following the runbook from start to finish, the result was:
- SPF, DKIM and DMARC `PASS` at Gmail, in both directions
- 10/10 on mail-tester.com
- every STARTTLS and certificate test passing on internet.nl
- a working restore from backup

The details, and what internet.nl still shows red and why, are in [architecture.md](docs/architecture.md#15-tested-and-known-limits).

## Project layout

```
config/       mailserver.env.example (copy to mailserver.env), secrets and alert examples
scripts/      00–30 install steps, mailctl, admin/ and ops/ commands, lib/
templates/    Postfix, Dovecot, Rspamd, nginx, Unbound, fail2ban, systemd and host config
tests/        local end-to-end test (Docker)
docs/         architecture and runbook
.github/      CI: shellcheck and the end-to-end test on every push and pull request
private/      optional, git-ignored: your own notes; never published or copied to the server
```

Secrets never live in the repository. They go in `/etc/mailserver/secrets.env` and `alerts.env` on the server, and both are git-ignored if a copy ends up here.

## Status

Under active development, and kept current with Ubuntu 26.04 LTS and Rspamd's stable releases.
- **How to upgrade a running server:** "Upgrading to a new version" in [docs/runbook.md](docs/runbook.md).
- **Contributing:** issues and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).
- **Security problems:** report them privately, as described in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
