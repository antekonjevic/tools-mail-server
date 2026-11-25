# Contributing

Issues and pull requests are welcome. The project stays small on purpose, so please read the principles before proposing a feature.

## Principles

- **Proven components, configured directly.** Postfix, Dovecot, Rspamd and standard Ubuntu packages, with plain-text configuration in `templates/`. No all-in-one mail suites, admin web interfaces or containers on the server.
- **Personal scale.** A few domains and mailboxes. Features for large or multi-tenant setups are out of scope.
- **Mail only.** No webmail, calendar or contacts.
- **Readable before running.** Shell scripts someone can read in one sitting. Anything downloaded is verified (see how the Rspamd key is pinned in `scripts/10-install-mail.sh`).
- **Safe to re-run.** Every install script and `mailctl` command can run again without harm, and changes only what differs.
- **Ubuntu 26.04 only.** The Dovecot configuration is written for Dovecot 2.4.

## How the pieces fit

- `config/mailserver.env` holds the settings. `render` in `scripts/lib/common.sh` fills them into `templates/`, and the install scripts write the results to `/etc`.
- Domains, mailboxes and aliases are state on the server, in `/etc/mailserver` and `/etc/dovecot/users`. `mailctl apply` (`scripts/admin/apply.sh`) turns them into the Postfix tables, the Rspamd maps, the Sieve rule and the web files.
- [docs/architecture.md](docs/architecture.md) explains the design and the reasons for it.

## Making a change

1. **Change** `templates/` or `scripts/`.
2. **Test it.** Add or update a check in `tests/e2e.sh` for the behaviour you changed. A bug fix should come with a check that fails without the fix.
3. **Document it.**
   - `README.md` describes what you get.
   - `docs/architecture.md` describes how it works and why.
   - `docs/runbook.md` has the steps.
   - If existing servers need to do something, such as add a setting, change DNS or re-run a script, say so in the pull request.
4. **Run the checks** (both need Docker):
   ```sh
   tests/run.sh       # full install and end-to-end test, about 10 minutes
   grep -rlE '^#!/(usr/)?bin/(env )?(ba)?sh' scripts tests templates | sort |
     xargs docker run --rm -v "$PWD:/mnt:ro" -w /mnt koalaman/shellcheck:v0.11.0
   ```
   CI runs the same two checks on every pull request.
5. **Open a pull request.** Say what changed, why, and how you tested it.

## Style

- **Scripts:**
  - Bash, sourcing `scripts/lib/common.sh`, which sets `set -Eeuo pipefail`.
  - Quote variables.
  - Use the shared helpers: `info`, `warn`, `die`, `render`, `install_file`.
- **Messages and docs:** plain English and short sentences. Error messages say what to do next.
- **Examples use reserved names only.** Never a real domain, IP address or person.
  - In docs: `example.com`, `example.org`, `example.net`, `203.0.113.0/24` and `2001:db8::/32`.
  - In tests: `.test` domains and `192.0.2.0/24`.
- **No secrets in the repository.** They live in `/etc/mailserver` on the server.

## Reporting a bug

Open an issue with:
- what you ran
- what happened: the output, plus `mailctl health` and the relevant `journalctl` lines (replace your domains and IP addresses if you prefer)
- the Ubuntu version, and the package versions if relevant

Security problems go through [SECURITY.md](SECURITY.md) instead.
