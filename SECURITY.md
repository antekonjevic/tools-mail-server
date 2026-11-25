# Security policy

## Reporting a vulnerability

Please report security problems privately, not in a public issue. Use **Report a vulnerability** on the repository's **Security** tab (GitHub's private vulnerability reporting).

Include:
- what you found and what an attacker could do with it
- how to reproduce it, ideally with `tests/run.sh` or a few commands on a test server
- the version (release tag or commit) you looked at

You'll get an answer as soon as possible. Once a fix is ready, it's published here, with a note on what servers need to do. You're credited unless you'd rather not be.

## Scope

**In scope:** everything in this repository, meaning the install scripts, `mailctl`, the configuration templates and the defaults they set. For example, a way to:
- relay mail through the server
- log in without the right password, or read another mailbox
- send as an address the login doesn't own
- reach a service that should only listen locally
- leak secrets, mail or personal details

**Out of scope here:** bugs in Postfix, Dovecot, Rspamd, nginx, Ubuntu or other software the scripts install. Please report those to the project concerned. If the configuration here makes such a bug easier to exploit, that part is in scope.

## Supported versions

Fixes go into the latest release only. To upgrade, follow "Upgrading to a new version" in [docs/runbook.md](docs/runbook.md).
