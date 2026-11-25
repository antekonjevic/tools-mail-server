#!/bin/sh
# Called by Dovecot (as user vmail) with the message on stdin.
exec /usr/bin/rspamc --connect 127.0.0.1:11334 learn_spam
