# Only this machine counts as "local". Rspamd's default also trusts all private networks, and
# local.d can only add to that list, so it is replaced here.
local_addrs = ["127.0.0.0/8", "::1"];
