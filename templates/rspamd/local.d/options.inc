# Use the local Unbound resolver: blocklist providers such as Spamhaus refuse queries
# that come through big public resolvers.
dns {
  nameserver = ["127.0.0.1:53"];
}
