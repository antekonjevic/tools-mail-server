# A message was moved or copied into Junk: teach Rspamd it is spam.
require ["vnd.dovecot.pipe", "copy", "imapsieve"];

pipe :copy "learn-spam.sh";
