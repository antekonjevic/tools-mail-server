# Test machine: Ubuntu 26.04 with systemd, close to a fresh VPS. Used by tests/run.sh only.
FROM ubuntu:26.04
ENV container=docker DEBIAN_FRONTEND=noninteractive
# The last step removes /usr/sbin/policy-rc.d: Docker's Ubuntu image has it to stop installed
# packages from starting their services, and a real server doesn't.
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus ca-certificates curl openssh-server iproute2 iptables kmod \
      python3 libxml2-utils \
 && ssh-keygen -A \
 && install -d -m 0700 /root/.ssh \
 && echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYTESTKEYTESTKEYTESTKEYTESTKEYTEST test-only' > /root/.ssh/authorized_keys \
 && apt-get clean && rm -rf /var/lib/apt/lists/* \
 && rm -f /usr/sbin/policy-rc.d
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
