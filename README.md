# meilisearch-setup

One-line installer and a small CLI (`meilictl`) to run **multiple Meilisearch
instances** on a Debian/Ubuntu server, each behind **Caddy** with automatic HTTPS
on its own domain.

```
                 ┌──────────────────────────── server ────────────────────────────┐
search.shop.com ─┤ Caddy :443 ─┬─> meilisearch@shop   127.0.0.1:7700  /var/lib/meilisearch/shop │
search.blog.com ─┤             └─> meilisearch@blog   127.0.0.1:7701  /var/lib/meilisearch/blog │
                 └────────────────────────────────────────────────────────────────┘
```

## Install

```sh
wget -qO- https://raw.githubusercontent.com/mstaack/meilisearch-setup/main/install.sh | sudo bash
```

Or install and create the first instance in one go:

```sh
wget -qO- https://raw.githubusercontent.com/mstaack/meilisearch-setup/main/install.sh \
  | sudo bash -s -- --domain search.example.com --email you@example.com
```

No domain? Get valid HTTPS on the server's public IP instead:

```sh
wget -qO- https://raw.githubusercontent.com/mstaack/meilisearch-setup/main/install.sh \
  | sudo bash -s -- --ip --email you@example.com
```

Installer options (each also works as an environment variable):

| Flag               | Env var            | Meaning                                                    |
| ------------------ | ------------------ | ---------------------------------------------------------- |
| `--domain <d>`     | `MEILI_DOMAIN`     | create a first instance served on this domain              |
| `--ip [addr]`      | `MEILI_IP`         | ...or with no domain: HTTPS on the server's public IP (auto-detected) |
| `--name <n>`       | `MEILI_NAME`       | name of that instance (default `default`)                  |
| `--master-key <k>` | `MEILI_MASTER_KEY` | master key for it (default: random)                        |
| `--allow <ips>`    | `MEILI_ALLOW`      | only allow these client IPs/CIDRs, block everyone else     |
| `--email <e>`      | `ACME_EMAIL`       | e-mail for Let's Encrypt (recommended)                     |
| `--version <v>`    | `MEILI_VERSION`    | Meilisearch version, e.g. `v1.15.2` (default: latest)      |
| `--repo-url <u>`   | `MEILI_SETUP_URL`  | where `meilictl` is downloaded from (also for self-update) |
| `--skip-caddy`     | `SKIP_CADDY=1`     | don't install Caddy (instances stay on 127.0.0.1)          |
| `--skip-firewall`  | `SKIP_FIREWALL=1`  | don't set up ufw                                            |
| `--skip-fail2ban`  | `SKIP_FAIL2BAN=1`  | don't set up fail2ban                                       |

The installer is idempotent, re-running it only adds what is missing.
Ports 80 and 443 must be reachable and the domains must point at the server.

> **Forking?** Change `mstaack` in the repo URLs of `install.sh` and `bin/meilictl`
> to your GitHub user/org so `install.sh` and `meilictl self-update` know where
> to fetch from. Or pass `--repo-url` / set it later with `meilictl config repo-url`.

## Usage

```sh
sudo meilictl create shop --domain search.shop.com          # new instance, random key
sudo meilictl create shop --ip                              # no domain: https://<public-ip>
sudo meilictl create shop --ip 203.0.113.7                  # explicit IP
sudo meilictl create blog --domain search.blog.com --allow 203.0.113.7,10.0.0.0/8
meilictl list
meilictl show shop                                          # domain, URL, port, master key, status

sudo meilictl start|stop|restart shop      # or --all
sudo meilictl enable|disable shop          # at boot
meilictl status [shop]
meilictl logs shop -f

sudo meilictl set-domain shop search.example.com,search2.example.com
sudo meilictl set-domain shop --ip                         # switch to IP-only HTTPS
meilictl ip                                                # public IPv4 that --ip would use
sudo meilictl set-key shop                 # rotate master key (or: set-key shop <new-key>)
meilictl keys shop                         # list API keys (default search/admin keys)

meilictl allow shop                        # show allowlist
sudo meilictl allow shop 203.0.113.7 2001:db8::/32 private_ranges
sudo meilictl allow shop --remove 203.0.113.7
sudo meilictl allow shop --clear           # everyone may connect again

sudo meilictl snapshot shop                # -> /var/lib/meilisearch/shop/snapshots
sudo meilictl dump shop                    # -> /var/lib/meilisearch/shop/dumps

sudo meilictl update                       # all instances -> latest Meilisearch
sudo meilictl update v1.15.2               # ...or a specific version
meilictl update --check
meilictl versions
sudo meilictl self-update

sudo meilictl remove blog                  # keeps data
sudo meilictl remove blog --purge -y       # deletes data

sudo meilictl edit shop                    # add extra MEILI_* options, then restart
meilictl security status                   # ufw rules, fail2ban jails, current bans
sudo meilictl security bans|ban <ip>|unban <ip>
meilictl caddy validate|reload|logs
sudo meilictl caddy render                 # rewrite all site files after a self-update
sudo meilictl config email you@example.com
```

Domains may be `host.example.com`, several comma-separated hosts, a bare IPv4
address, or `http://host` for plain HTTP without a certificate (handy for testing).

### HTTPS without a domain (IP only)

`--ip` (or a bare IPv4 address as the domain) serves the instance at
`https://<ip>` with a real, browser-trusted certificate. Let's Encrypt issues
[IP address certificates](https://letsencrypt.org/2026/01/15/6day-and-ip-general-availability)
only with its `shortlived` profile, so the certificate is valid for about six
days and Caddy renews it automatically every few days. The generated site looks
like this:

```
203.0.113.7 {
    tls {
        issuer acme https://acme-v02.api.letsencrypt.org/directory {
            profile shortlived
        }
    }
    reverse_proxy 127.0.0.1:7700
}
```

Requirements: the IP must be public and ports 80/443 reachable on it, Caddy
2.10.2 or newer (the installer installs the current release), and the server
must stay online so renewals keep working. Private/NAT-only addresses cannot
get a certificate. IPv6-only addresses are not supported by `meilictl` yet.

If the browser shows a self-signed "Caddy Local Authority" certificate instead
(Firefox: `SEC_ERROR_BAD_SIGNATURE`), the site file lacks the `tls` block, for
example because it was created by an older `meilictl` or the domain was stored
as `https://<ip>`. Fix it with `sudo meilictl self-update && sudo meilictl caddy
render` (this restarts Caddy, which is required for the issuer switch to take
effect), then check `meilictl caddy logs` for the certificate issuance.

### IP allowlist

`meilictl allow <name> <ip>...` restricts an instance to the given client IPs.
It is enforced by Caddy (`remote_ip` matcher); everyone else gets `403`.
Accepted values are single addresses, CIDRs (`10.0.0.0/8`, `2001:db8::/32`)
and the keyword `private_ranges`. An empty list means open to everyone.

The check uses the TCP peer address. If traffic reaches Caddy through another
proxy (Cloudflare, a load balancer), configure `trusted_proxies` in Caddy and
the allowlist will not work as-is.

### Firewall and fail2ban

The installer sets up **ufw** with `deny incoming` / `allow outgoing` and opens
only the SSH port(s) it detects from the running `sshd`, plus 80/tcp, 443/tcp
and 443/udp (HTTP/3). Meilisearch itself only listens on 127.0.0.1, so nothing
else needs to be open. Re-running the installer updates the rules.

**fail2ban** runs two jails (config in `/etc/fail2ban/jail.d/meilictl.conf`):

| Jail          | Watches                          | Bans after                  |
| ------------- | -------------------------------- | --------------------------- |
| `sshd`        | systemd journal                  | 5 failed logins in 10 min   |
| `caddy-meili` | `/var/log/caddy/access.log`      | 10 × 401/403 in 10 min      |

Bans last 1 hour and double for repeat offenders (up to a week). Every managed
Caddy site writes a JSON access log to `/var/log/caddy/access.log` (rotated by
Caddy at 20 MB, 5 files). 401/403 responses mean a wrong or missing Meilisearch
API key, or a client outside the instance's IP allowlist, so a misconfigured
client of yours can get itself banned after 10 attempts: `sudo meilictl
security unban <ip>` fixes that, and you can whitelist it permanently by adding
it to `ignoreip` in `/etc/fail2ban/jail.local`. `meilictl security status`
shows the firewall and all jails at a glance.

### Updating Meilisearch

`meilictl update` downloads the new binary to `/opt/meilisearch/versions/<ver>/`,
takes a snapshot of every running instance (skip with `--no-snapshot`), stops
them, switches the `/usr/local/bin/meilisearch` symlink and starts them again.
Instances run with `MEILI_EXPERIMENTAL_DUMPLESS_UPGRADE=true`, so Meilisearch
(v1.12+) migrates the database in place. Downgrades only work if the database
format is compatible; otherwise restore from the snapshot.

## What lands on the server

| Path                                    | Purpose                                              |
| --------------------------------------- | ---------------------------------------------------- |
| `/usr/local/bin/meilictl`               | the CLI                                              |
| `/usr/local/bin/meilisearch`            | symlink to the active version                        |
| `/opt/meilisearch/versions/<ver>/`      | downloaded binaries                                  |
| `/etc/meilisearch/meilictl.conf`        | `REPO_URL`, `ACME_EMAIL`                             |
| `/etc/meilisearch/instances/<name>.env` | per-instance config (systemd `EnvironmentFile`)      |
| `/var/lib/meilisearch/<name>/`          | `data.ms`, `dumps/`, `snapshots/`                    |
| `/etc/systemd/system/meilisearch@.service` | hardened template unit, runs as user `meilisearch` |
| `/etc/caddy/Caddyfile`                  | managed if it was missing/stock, otherwise an `import` line is appended |
| `/etc/caddy/meilisearch.d/<name>.caddy` | one Caddy site per instance                          |
| `/var/log/caddy/access.log`             | JSON access log of all instances (fail2ban input)    |
| `/etc/fail2ban/jail.d/meilictl.conf`, `filter.d/caddy-meili.conf` | fail2ban jails            |

Each instance listens on `127.0.0.1:77xx` (first free port from 7700) and is
only reachable through Caddy. The env file is `root:meilisearch 0640` because it
contains the master key.

## Backups

Snapshots and dumps land in the instance's data directory. Back up
`/var/lib/meilisearch/<name>/snapshots` (or `dumps`) plus
`/etc/meilisearch/instances/<name>.env`. See the Meilisearch docs on
[snapshots](https://www.meilisearch.com/docs/learn/data_backup/snapshots) and
[dumps](https://www.meilisearch.com/docs/learn/data_backup/dumps) for restoring.

## Uninstall

```sh
for i in $(meilictl list | awk 'NR>1 {print $1}'); do sudo meilictl remove "$i" --purge -y; done
sudo rm -rf /etc/meilisearch /opt/meilisearch /var/lib/meilisearch \
  /usr/local/bin/meilisearch /usr/local/bin/meilictl \
  /etc/systemd/system/meilisearch@.service /etc/caddy/meilisearch.d
sudo systemctl daemon-reload
sudo apt-get remove caddy        # if you no longer need Caddy
```

## Development

```sh
make lint    # shellcheck via Docker
make test    # end-to-end smoke test in a systemd Debian container (Docker, privileged)
```

`test/smoke.sh` builds a small systemd image (`test/Dockerfile`, Debian 12 by default)
and runs the installer inside it, creates two
instances, and exercises create/list/show/allow/set-key/set-domain/start/stop/
snapshot/dump/update/self-update/remove. Set `BASE=ubuntu:24.04`
to test on Ubuntu.
