#!/usr/bin/env bash
# Runs the whole installation and an end-to-end mail test in a local Ubuntu 26.04 container.
# Needs Docker. Nothing touches the real server or real DNS.
# Usage: tests/run.sh [--keep]     --keep leaves the container running for inspection
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
name=mailserver-test
image=mailserver-test:26.04
hostname=$(bash -c "source '$repo/tests/test.env'; echo \$MAIL_HOSTNAME")

docker build -q -t "$image" "$repo/tests" >/dev/null
docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" --hostname "$hostname" \
  --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --tmpfs /run --tmpfs /run/lock \
  -v "$repo":/opt/mailserver:ro \
  "$image" >/dev/null

# Wait for systemd to finish booting
for _ in $(seq 1 30); do
  state=$(docker exec "$name" systemctl is-system-running 2>/dev/null || true)
  [[ $state == running || $state == degraded ]] && break
  sleep 1
done

status=0
docker exec -e MAILSERVER_CONFIG=/opt/mailserver/tests/test.env "$name" \
  bash /opt/mailserver/tests/e2e.sh || status=$?

if [[ ${1:-} == "--keep" ]]; then
  echo "Container '$name' left running. Shell: docker exec -it $name bash"
else
  docker rm -f "$name" >/dev/null
fi
exit "$status"
