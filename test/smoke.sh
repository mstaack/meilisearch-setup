#!/usr/bin/env bash
# End-to-end smoke test: runs install.sh inside a systemd-enabled Debian container,
# creates two instances, exercises meilictl, and checks Caddy routing + IP allowlist.
#
#   ./test/smoke.sh                 # Debian 12
#   BASE=ubuntu:24.04 ./test/smoke.sh
#
# Needs Docker. Builds a small systemd image from test/Dockerfile and runs it privileged.
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${BASE:-debian:12}"
IMAGE="meili-smoke:${BASE//[:\/]/-}"
NAME="meili-smoke-$$"

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> building $IMAGE from $BASE"
docker build -q -t "$IMAGE" --build-arg "BASE=$BASE" -f test/Dockerfile test >/dev/null

echo "==> starting $IMAGE"
docker run -d --privileged --name "$NAME" \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock \
  -v "$PWD:/src:ro" "$IMAGE" >/dev/null
# wait for systemd
booted=0
for _ in $(seq 1 30); do
  if docker exec "$NAME" systemctl is-system-running 2>/dev/null | grep -qE 'running|degraded'; then booted=1; break; fi
  sleep 1
done
[[ $booted == 1 ]] || { echo "systemd did not boot in the container"; docker logs "$NAME"; exit 1; }

docker exec -i "$NAME" bash -e -o pipefail <<'IN_CONTAINER'
must_fail() { if "$@" >/dev/null 2>&1; then echo "expected failure but succeeded: $*"; exit 1; fi; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null && apt-get install -y -qq curl >/dev/null

echo "==> install.sh (piped, like wget | bash) with first instance on http://localhost"
# Piped install downloads meilictl from REPO_URL; a file:// URL to the mounted repo emulates that.
cat /src/install.sh | bash -s -- --repo-url file:///src --domain http://localhost --name app1 --allow 127.0.0.1,private_ranges

echo "==> second instance, plain http on port 8081 so we can hit it without DNS"
meilictl create app2 --domain http://localhost:8081 --master-key testkey-testkey-testkey

echo "==> list / show"
meilictl list
meilictl show app1
meilictl show app2 | grep >/dev/null 'Allowed IPs:  everyone'

echo "==> routing through caddy (allowlist includes 127.0.0.1 -> 200)"
curl -fsS http://localhost/health | grep >/dev/null available
curl -fsS http://localhost:8081/health | grep >/dev/null available

echo "==> firewall + fail2ban"
test -f /etc/fail2ban/jail.d/meilictl.conf
test -f /etc/fail2ban/filter.d/caddy-meili.conf
fail2ban-client status caddy-meili | grep >/dev/null 'File list:.*access.log'
fail2ban-client status sshd >/dev/null
ufw status | grep -E >/dev/null '^Status: (active|inactive)'     # enabling may be impossible inside Docker
ufw show added | grep >/dev/null "allow 443/udp"
ufw show added | grep >/dev/null "allow 80/tcp"
# 12 requests without API key -> 401, all logged with remote_ip and matched by the filter
for _ in $(seq 1 12); do curl -s -o /dev/null http://localhost:8081/keys; done
sleep 1
grep -c '"status":401' /var/log/caddy/access.log | awk '$1 >= 12 {ok=1} END {exit !ok}'
meilictl security test-filter | grep -E >/dev/null 'Failregex: ([1-9][0-9]+|[1-9]) total'
meilictl security status | grep >/dev/null 'caddy-meili'
meilictl security ban 203.0.113.99
meilictl security bans | grep >/dev/null '203.0.113.99'
meilictl security unban 203.0.113.99
if meilictl security bans | grep -q '203.0.113.99'; then echo "unban failed"; exit 1; fi

echo "==> allowlist: remove our own IP -> 403"
meilictl allow app1 --clear
meilictl allow app1 203.0.113.9
code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost/health); [[ "$code" == 403 ]] || { echo "expected 403 got $code"; exit 1; }
meilictl allow app1 --remove 203.0.113.9
curl -fsS http://localhost/health | grep >/dev/null available
meilictl allow app1 | grep >/dev/null everyone

echo "==> invalid IP is rejected"
must_fail meilictl allow app1 999.1.1.1

echo "==> master key rotation"
key1=$(meilictl show app1 | awk '/Master key/ {print $3}')
meilictl set-key app1 >/dev/null 2>&1
key2=$(meilictl show app1 | awk '/Master key/ {print $3}')
[[ "$key1" != "$key2" ]]
curl -fsS -H "Authorization: Bearer $key2" http://127.0.0.1:7700/keys | grep >/dev/null '"results"'
meilictl keys app1 | grep >/dev/null '"results"'

echo "==> set-domain"
meilictl set-domain app2 http://localhost:8082
curl -fsS http://localhost:8082/health | grep >/dev/null available
must_fail meilictl set-domain app2 http://localhost   # taken by app1

echo "==> IP-only HTTPS: bare IP gets a Let's Encrypt short-lived tls block (ACME will fail for 127.0.0.1, that is expected)"
meilictl create app3 --domain 127.0.0.1 --port 7710 --master-key testkey-testkey-testkey-3 2>&1 | grep >/dev/null 'not a public IP'
grep -q 'profile shortlived' /etc/caddy/meilisearch.d/app3.caddy
grep -q '^127.0.0.1 {' /etc/caddy/meilisearch.d/app3.caddy
meilictl caddy validate
meilictl show app3 | grep 'URL:' | grep >/dev/null 'https://127.0.0.1'
meilictl show app3 | grep >/dev/null 'short-lived IP certificate'
meilictl set-domain app3 http://localhost:8083
if grep -q 'profile shortlived' /etc/caddy/meilisearch.d/app3.caddy; then echo "tls block should be gone"; exit 1; fi
curl -fsS http://localhost:8083/health | grep >/dev/null available
meilictl set-domain app3 --ip 127.0.0.2 2>&1 | grep >/dev/null "short-lived"
grep -q "^127.0.0.2 {" /etc/caddy/meilisearch.d/app3.caddy
# an "https://IP/" URL given as domain is normalized to the bare IP and still gets the tls block
meilictl set-domain app3 https://127.0.0.3/ >/dev/null
grep -q "^127.0.0.3 {" /etc/caddy/meilisearch.d/app3.caddy
grep -q 'profile shortlived' /etc/caddy/meilisearch.d/app3.caddy
meilictl show app3 | grep 'Domain:' | grep >/dev/null ' 127.0.0.3$'
# caddy render normalizes old stored values
sed -i 's|^MEILICTL_DOMAIN=.*|MEILICTL_DOMAIN=https://127.0.0.4|' /etc/meilisearch/instances/app3.env
meilictl caddy render | grep >/dev/null "normalized domain 'https://127.0.0.4' -> '127.0.0.4'"
grep -q "^127.0.0.4 {" /etc/caddy/meilisearch.d/app3.caddy
meilictl remove app3 --purge -y
meilictl ip | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$'

echo "==> stop / start / restart"
meilictl stop app2
must_fail curl -fsS http://127.0.0.1:7701/health
meilictl start app2
meilictl restart --all
curl -fsS http://127.0.0.1:7701/health | grep >/dev/null available

echo "==> snapshot + dump"
meilictl snapshot app1
meilictl dump app1
ls /var/lib/meilisearch/app1/snapshots/*.snapshot /var/lib/meilisearch/app1/dumps/*.dump >/dev/null

echo "==> update to an older version (downgrade) is refused only by meilisearch itself; test --check"
meilictl update --check
meilictl versions

echo "==> self-update via local repo, then re-render all sites"
meilictl self-update
meilictl caddy render | grep >/dev/null 're-rendered 2 Caddy site(s), caddy restarted'
curl -fsS http://localhost/health | grep >/dev/null available

echo "==> caddy validate and config"
meilictl caddy validate
meilictl config email ops@example.com
grep -q 'email ops@example.com' /etc/caddy/Caddyfile
meilictl caddy validate

echo "==> re-running install.sh is idempotent"
bash /src/install.sh --repo-url file:///src --domain http://localhost --name app1 >/dev/null
meilictl list | grep -c '^app' | grep >/dev/null '^2$'

echo "==> remove with purge"
meilictl remove app2 --purge -y
[[ ! -e /etc/meilisearch/instances/app2.env ]]
[[ ! -e /etc/caddy/meilisearch.d/app2.caddy ]]
[[ ! -e /var/lib/meilisearch/app2 ]]
meilictl caddy validate

echo
echo "ALL SMOKE TESTS PASSED"
IN_CONTAINER
