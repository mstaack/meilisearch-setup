#!/usr/bin/env bash
# Meilisearch + Caddy installer for Debian/Ubuntu.
#
#   wget -qO- https://<repo-url>/install.sh | sudo bash
#   wget -qO- https://<repo-url>/install.sh | sudo bash -s -- --domain search.example.com --email you@example.com
#
# Options (or environment variables):
#   --domain <d>      MEILI_DOMAIN      create a first instance served on this domain
#   --ip [addr]       MEILI_IP          ...or without a domain: valid HTTPS on the server's public IP
#                                       (Let's Encrypt short-lived IP certificate; addr defaults to auto-detect)
#   --name <n>        MEILI_NAME        name of that first instance (default: "default")
#   --master-key <k>  MEILI_MASTER_KEY  master key of that instance (default: random)
#   --allow <ips>     MEILI_ALLOW       only allow these client IPs/CIDRs (comma-separated), block all others
#   --email <e>       ACME_EMAIL        e-mail for Let's Encrypt (recommended)
#   --version <v>     MEILI_VERSION     Meilisearch version to install (default: latest)
#   --repo-url <u>    MEILI_SETUP_URL   where meilictl is downloaded from / self-update
#   --skip-caddy      SKIP_CADDY=1      do not install/configure Caddy
#   --skip-firewall   SKIP_FIREWALL=1   do not install/configure ufw (SSH, 80, 443 allowed; rest denied)
#   --skip-fail2ban   SKIP_FAIL2BAN=1   do not install/configure fail2ban (sshd + caddy-meili jails)
#
# Re-running the installer is safe: it only (re)installs what is missing.
set -euo pipefail

REPO_URL="${MEILI_SETUP_URL:-https://raw.githubusercontent.com/mstaack/meilisearch-setup/main}"
DOMAIN="${MEILI_DOMAIN:-}"
if [[ -z "$DOMAIN" && -n "${MEILI_IP:-}" ]]; then
  case "$MEILI_IP" in 1 | true | yes | auto) DOMAIN=ip ;; *) DOMAIN=$MEILI_IP ;; esac
fi
INSTANCE_NAME="${MEILI_NAME:-default}"
MASTER_KEY="${MEILI_MASTER_KEY:-}"
ALLOW="${MEILI_ALLOW:-}"
EMAIL="${ACME_EMAIL:-}"
MEILI_TARGET_VERSION="${MEILI_VERSION:-latest}"
SKIP_CADDY="${SKIP_CADDY:-0}"
SKIP_FIREWALL="${SKIP_FIREWALL:-0}"
SKIP_FAIL2BAN="${SKIP_FAIL2BAN:-0}"

MEILI_USER="meilisearch"
DATA_DIR="/var/lib/meilisearch"
CONF_DIR="/etc/meilisearch"
UNIT_FILE="/etc/systemd/system/meilisearch@.service"

if [[ -t 1 ]]; then BLU=$'\e[34m' GRN=$'\e[32m' YEL=$'\e[33m' RED=$'\e[31m' BLD=$'\e[1m' RST=$'\e[0m'
else BLU='' GRN='' YEL='' RED='' BLD='' RST=''; fi
info() { echo "${BLU}==>${RST} $*"; }
ok()   { echo "${GRN} ✔${RST} $*"; }
warn() { echo "${YEL} !${RST} $*" >&2; }
die()  { echo "${RED} ✘${RST} $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN=${2:-}; shift 2 ;;
    --ip) if [[ -n "${2:-}" && "$2" != -* ]]; then DOMAIN=$2; shift 2; else DOMAIN=ip; shift; fi ;;
    --name) INSTANCE_NAME=${2:-}; shift 2 ;;
    --master-key) MASTER_KEY=${2:-}; shift 2 ;;
    --allow) ALLOW=${2:-}; shift 2 ;;
    --email) EMAIL=${2:-}; shift 2 ;;
    --version) MEILI_TARGET_VERSION=${2:-}; shift 2 ;;
    --repo-url) REPO_URL=${2%/}; shift 2 ;;
    --skip-caddy) SKIP_CADDY=1; shift ;;
    --skip-firewall) SKIP_FIREWALL=1; shift ;;
    --skip-fail2ban) SKIP_FAIL2BAN=1; shift ;;
    -h | --help) sed -n "2,22p" "$0" 2>/dev/null || true; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

# ------------------------------------------------------------ preflight ----
[[ $EUID -eq 0 ]] || die "run as root, e.g.:  wget -qO- <url>/install.sh | sudo bash -s -- [options]"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  case " ${ID:-} ${ID_LIKE:-} " in
    *debian* | *ubuntu*) ok "detected ${PRETTY_NAME:-$ID}" ;;
    *) [[ "${FORCE:-0}" == 1 ]] || die "unsupported OS '${ID:-unknown}' (Debian/Ubuntu only; set FORCE=1 to try anyway)" ;;
  esac
else
  die "cannot read /etc/os-release"
fi
command -v systemctl >/dev/null 2>&1 || die "systemd is required"

# ----------------------------------------------------------- packages ----
info "installing base packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends curl ca-certificates gnupg openssl jq iproute2 >/dev/null
ok "packages installed"

# ---------------------------------------------------------- user, dirs ----
if ! id -u "$MEILI_USER" >/dev/null 2>&1; then
  useradd --system --home-dir "$DATA_DIR" --no-create-home --shell /usr/sbin/nologin --user-group "$MEILI_USER"
  ok "created system user $MEILI_USER"
fi
install -d -m 750 -o "$MEILI_USER" -g "$MEILI_USER" "$DATA_DIR"
install -d -m 755 "$CONF_DIR" "$CONF_DIR/instances" /opt/meilisearch/versions

# ------------------------------------------------------- systemd unit ----
cat >"$UNIT_FILE" <<'UNIT'
[Unit]
Description=Meilisearch instance %i
Documentation=https://www.meilisearch.com/docs
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=meilisearch
Group=meilisearch
EnvironmentFile=/etc/meilisearch/instances/%i.env
WorkingDirectory=/var/lib/meilisearch/%i
ExecStart=/usr/local/bin/meilisearch
Restart=on-failure
RestartSec=3
LimitNOFILE=65536

# Hardening
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadWritePaths=/var/lib/meilisearch/%i

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
ok "installed $UNIT_FILE"

# ------------------------------------------------------------ meilictl ----
install_meilictl() {
  local src=""
  # Running from a local checkout? (BASH_SOURCE is empty when piped into bash)
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "$(dirname "${BASH_SOURCE[0]}")/bin/meilictl" ]]; then
    src="$(dirname "${BASH_SOURCE[0]}")/bin/meilictl"
    install -m 755 "$src" /usr/local/bin/meilictl
    ok "installed meilictl from local checkout"
  else
    local tmp
    tmp=$(mktemp)
    curl -fsSL "$REPO_URL/bin/meilictl" -o "$tmp" || die "could not download $REPO_URL/bin/meilictl (set --repo-url)"
    bash -n "$tmp" || die "downloaded meilictl is not valid bash"
    install -m 755 "$tmp" /usr/local/bin/meilictl
    rm -f "$tmp"
    ok "installed meilictl from $REPO_URL"
  fi
}
install_meilictl

# global config (kept if it already exists)
[[ -f "$CONF_DIR/meilictl.conf" ]] || {
  printf 'REPO_URL="%s"\nACME_EMAIL="%s"\n' "$REPO_URL" "$EMAIL" >"$CONF_DIR/meilictl.conf"
}
[[ -n "$EMAIL" ]] && meilictl config email "$EMAIL" >/dev/null 2>&1 || true

# --------------------------------------------------------- meilisearch ----
info "installing Meilisearch ($MEILI_TARGET_VERSION)"
meilictl update "$MEILI_TARGET_VERSION" --no-snapshot

# --------------------------------------------------------------- caddy ----
if [[ "$SKIP_CADDY" != 1 ]]; then
  if command -v caddy >/dev/null 2>&1; then
    ok "Caddy already installed ($(caddy version 2>/dev/null | cut -d' ' -f1))"
  else
    info "installing Caddy from the official apt repository"
    install -d -m 755 /usr/share/keyrings
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      >/etc/apt/sources.list.d/caddy-stable.list
    chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -qq
    apt-get install -y -qq caddy >/dev/null
    ok "Caddy installed ($(caddy version 2>/dev/null | cut -d' ' -f1))"
  fi
  meilictl caddy init
  # existing instances pick up template changes (access log, tls block) on re-runs
  if [[ -n "$(ls /etc/meilisearch/instances/*.env 2>/dev/null)" ]]; then
    meilictl caddy render
  fi
else
  warn "skipping Caddy (--skip-caddy); instances will only listen on 127.0.0.1"
fi

# ------------------------------------------------------------ firewall ----
ssh_ports() { # effective sshd port(s), default 22
  local p
  p=$( (sshd -T 2>/dev/null || true) | awk '$1 == "port" {print $2}' | sort -u | tr '\n' ' ')
  [[ -n "${p// /}" ]] || p=$(grep -iE '^[[:space:]]*Port[[:space:]]+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | sort -u | tr '\n' ' ')
  [[ -n "${p// /}" ]] || p=22
  echo "$p"
}

if [[ "$SKIP_FIREWALL" != 1 ]]; then
  info "configuring firewall (ufw)"
  command -v ufw >/dev/null 2>&1 || apt-get install -y -qq ufw >/dev/null
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in $(ssh_ports); do ufw allow "$p/tcp" comment 'SSH' >/dev/null; done
  ufw allow 80/tcp comment 'Caddy HTTP (ACME, redirect to HTTPS)' >/dev/null
  ufw allow 443/tcp comment 'Caddy HTTPS' >/dev/null
  ufw allow 443/udp comment 'Caddy HTTP/3' >/dev/null
  if ufw status | grep -q '^Status: active'; then
    ufw reload >/dev/null && ok "ufw already active, rules updated (SSH $(ssh_ports| xargs), 80, 443)"
  elif ufw --force enable >/dev/null 2>&1; then
    ok "ufw enabled: deny incoming except SSH ($(ssh_ports | xargs)), 80/tcp, 443/tcp, 443/udp"
  else
    warn "could not enable ufw (unsupported environment?); rules are saved, enable later with: ufw enable"
  fi
else
  warn "skipping firewall (--skip-firewall)"
fi

# ------------------------------------------------------------ fail2ban ----
if [[ "$SKIP_FAIL2BAN" != 1 ]]; then
  info "configuring fail2ban"
  command -v fail2ban-client >/dev/null 2>&1 || apt-get install -y -qq fail2ban >/dev/null
  install -d -m 750 -o caddy -g caddy /var/log/caddy 2>/dev/null || install -d -m 750 /var/log/caddy
  [[ -e /var/log/caddy/access.log ]] || { touch /var/log/caddy/access.log; chown caddy:caddy /var/log/caddy/access.log 2>/dev/null || true; }
  cat >/etc/fail2ban/filter.d/caddy-meili.conf <<'F2B_FILTER'
# fail2ban filter for the Caddy JSON access log written by meilictl-managed sites.
# Matches requests answered with 401/403: wrong/missing Meilisearch API key, or a
# client outside an instance's IP allowlist.
[Definition]
failregex = ^.*"remote_ip":"<HOST>".*"status":(?:401|403)[,}].*$
ignoreregex =
datepattern = ^.*"ts":"%%Y-%%m-%%dT%%H:%%M:%%S.%%f%%z"
F2B_FILTER
  cat >/etc/fail2ban/jail.d/meilictl.conf <<'F2B_JAIL'
# Managed by the meilisearch-setup installer. Local overrides: /etc/fail2ban/jail.local
[DEFAULT]
backend = systemd
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.maxtime = 1w

[sshd]
enabled = true

[caddy-meili]
enabled = true
port = http,https
filter = caddy-meili
logpath = /var/log/caddy/access.log
backend = auto
maxretry = 10
findtime = 10m
bantime = 1h
F2B_JAIL
  systemctl enable fail2ban >/dev/null 2>&1 || true
  systemctl restart fail2ban
  sleep 1
  if fail2ban-client status caddy-meili >/dev/null 2>&1; then
    ok "fail2ban running with jails: $(fail2ban-client status | sed -n 's/.*Jail list:[[:space:]]*//p')"
  else
    warn "fail2ban did not start cleanly, check: journalctl -u fail2ban -n 30"
  fi
else
  warn "skipping fail2ban (--skip-fail2ban)"
fi

# ------------------------------------------------------ first instance ----
if [[ -n "$DOMAIN" ]]; then
  if meilictl show "$INSTANCE_NAME" >/dev/null 2>&1; then
    ok "instance '$INSTANCE_NAME' already exists, skipping creation"
  else
    echo
    meilictl create "$INSTANCE_NAME" --domain "$DOMAIN" ${MASTER_KEY:+--master-key "$MASTER_KEY"} ${ALLOW:+--allow "$ALLOW"}
  fi
fi

# -------------------------------------------------------------- summary ----
echo
echo "${BLD}Done.${RST} meilictl $(meilictl version | awk '{print $2}') / Meilisearch $(meilictl version | sed 's/.*meilisearch //; s/)//')"
echo
if [[ -z "$DOMAIN" ]]; then
  echo "Create your first instance:"
  echo "  ${BLD}sudo meilictl create myapp --domain search.example.com${RST}   # with a domain"
  echo "  ${BLD}sudo meilictl create myapp --ip${RST}                            # no domain, HTTPS on the public IP"
fi
echo "Useful commands:"
echo "  meilictl list                    meilictl show <name>"
echo "  meilictl set-domain <name> <d>   meilictl set-key <name>"
echo "  meilictl update                  meilictl logs <name> -f"
echo "  meilictl security status         meilictl security unban <ip>"
echo "  meilictl help"
[[ "$SKIP_CADDY" == 1 ]] || echo
[[ "$SKIP_CADDY" == 1 ]] || echo "Make sure ports 80 and 443 are open and your domains point to this server."
exit 0
