# Used locally by rspamc (spam learning) and, through an SSH tunnel, by the optional web UI.
# Requests from 127.0.0.1 need no password; nothing else can reach this port.
bind_socket = "127.0.0.1:11334";
