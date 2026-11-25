# A message was moved out of Junk: teach Rspamd it is not spam (unless it went to Trash).
require ["vnd.dovecot.pipe", "copy", "imapsieve", "environment", "variables"];

if environment :matches "imap.mailbox" "*" {
  set "mailbox" "${1}";
}

if string "${mailbox}" "Trash" {
  stop;
}

pipe :copy "learn-ham.sh";
