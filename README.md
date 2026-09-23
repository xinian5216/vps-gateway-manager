# vps-gateway-manager

> A self-hosted network gateway manager for VPS egress, smart proxy routing,
> IPv6-only connectivity and secure infrastructure migration.
> The first supported gateway type is **GitHub Smart Proxy**.

**GitHub-only egress gateways for VPS fleets: one command to deploy, one command
to adopt, one command per client — with transactional changes, dry-run plans and
automatic rollback.**

`ghproxyctl` is the control tool: it manages a *gateway type* (currently
"GitHub proxy") on a server and smart-routing clients that send only GitHub
traffic through the gateway while everything else stays `DIRECT`.

```
             ┌──────────────── client VPS ─────────────────┐
  curl/git ──► 127.0.0.1:3129 (local Squid, loopback only)  │
             └───────────────┬─────────────────────────────┘
                             │  GitHub destinations only
                             ▼
             https://gh.example.com:8443  (TLS forward proxy, exact /32 & /128 clients)
                             │
                             ▼
                          GitHub
             everything else ────────────────────────────► DIRECT
```

* **Server**: Squid (`squid-openssl`) HTTPS forward proxy, Let's Encrypt via
  Certbot + Cloudflare DNS-01, per-client ACLs, per-client firewall rules,
  GitHub-only destination list.
* **Client**: its own Squid instance (own config, pid, logs, systemd unit) that
  routes GitHub through the remote gateway over TLS and everything else direct.
  Never touches an existing `squid`, `xray`, `3x-ui` or `tinyproxy` install.
* **Migration**: existing Komari agents, `xray-manager` download proxy settings,
  Git configuration and global environment files can be adopted automatically,
  with backups and a one-command restore.

> Documentation language: English first, Chinese quickstart at the end.
> Status of the implementation (what works, what is still open) is tracked in
> [`docs/STATUS.md`](docs/STATUS.md).

---

## Quickstart

### 1. New gateway server

```bash
sudo bash install.sh server \
  --domain gh.example.com \
  --port 8443 \
  --cf-credentials /root/.secrets/certbot/cloudflare.ini
```

The Cloudflare token is **never** passed on the command line: only a root-only
credentials file (directory `700`, file `600`) is accepted.

The installer verifies the result before it keeps it:

```
squid -k parse  ->  atomic replace  ->  reload  ->  health checks
   GitHub API / Raw / Release / TLS / "non-GitHub must be refused"
```

Any failing check rolls the whole change back.

### 2. Adopt an existing production proxy (no rewrite)

```bash
sudo bash install.sh server --adopt-existing --dry-run   # read-only report
sudo bash install.sh server --adopt-existing             # additive changes only
```

Adoption **never** rewrites your `squid.conf`, your whitelist file, your
certificates or your Certbot hook. It only adds:

* `/etc/vps-gateway-manager/` (state, inventory, backups)
* `/etc/squid/conf.d/00-vps-gateway-manager-clients.conf` (empty of clients at
  first, and deliberately free of any `http_access deny` rule)
* `/usr/local/lib/vps-gateway-manager/` + `/usr/local/sbin/ghproxyctl`

No reload and no restart happen during adoption; that only occurs when you
authorise a new client.

### 3. Authorise a client

```bash
sudo ghproxyctl client add 203.0.113.10 cn-bj-01
sudo ghproxyctl client add 2001:db8::1234 jp-v6-01
```

* IPv4 is normalised to `/32`, IPv6 to `/128`. A `/64` (or any other prefix) is
  refused — there is no shortcut that would turn this into an open proxy.
* The command prints the onboarding one-liner for that client, creates the exact
  firewall rule, validates the configuration, reloads Squid and health-checks it.

### 4. New client VPS

For a **pinned, reproducible** install, fetch the installer through the proxy
and pin the ref — `--ref v0.5.0` (a tag), a branch name or a full commit SHA:

```bash
curl --proxy https://gh.example.com:8443 \
  -fsSL https://raw.githubusercontent.com/xinian5216/vps-gateway-manager/v0.5.0/install.sh \
  -o /tmp/vps-gateway-manager.sh

sudo bash /tmp/vps-gateway-manager.sh client \
  --upstream https://gh.example.com:8443 \
  --upstream-family auto --ref v0.5.0
```

When the toolkit is not on disk yet, `install.sh` downloads it from the pinned
ref (`archive/refs/heads/<ref>`, `archive/refs/tags/<ref>` or
`archive/<sha>.tar.gz`). If that ref cannot be fetched the install **fails**
with the attempted URLs — it never silently falls back to `main`.

**Two-phase deployment (recommended):** install the client first, and migrate
services only after the local proxy passed its health checks.

```bash
# phase 1: local smart proxy + full health checks (no service config touched)
sudo bash /tmp/vps-gateway-manager.sh client --upstream https://gh.example.com:8443
sudo ghproxyctl test

# phase 2: migrate Komari (etc.) only when phase 1 is green
sudo ghproxyctl migrate komari
```

`--adopt-existing` performs both phases in one run with the same order.

### 5. Client that already uses the remote proxy

```bash
sudo bash install.sh client --upstream https://gh.example.com:8443 --adopt-existing --dry-run
sudo bash install.sh client --upstream https://gh.example.com:8443 --adopt-existing
```

Order of operations is fixed ("build first, tear down later"):

```
record -> backup -> install local proxy -> test API/Raw/Release/DIRECT/TLS
       -> only then migrate Komari / xray-manager / Git -> verify each service
```

A failed verification restores that component and leaves the old path working.

#### Upstream address family (`--upstream-family auto|4|6`)

```bash
--upstream-family auto    # default: probe IPv4 and IPv6, then choose
--upstream-family 4       # force the IPv4 path (still probe-verified)
--upstream-family 6       # force the IPv6 path (still probe-verified)
```

Before anything is installed, each family is probed **through the gateway**
with TLS verification: `200` usable, `403/407` reached but refused, `000`
transport unavailable (never "not authorised"). With `auto` and both families
usable the dual-stack hostname is kept; with exactly one usable family the
installer pins `cache_peer` to a **probe-verified address** of that family —
dead DNS candidates are failed over, the first candidate that really answers
200 wins — while `ssldomain=` keeps the certificate verified against the
logical upstream name, never the IP. Nothing usable aborts before any change
and before any migration.

When DNS or routing later changes, re-run the selection. It is transactional
and reloads only the local client Squid; migrations are never touched:

```bash
sudo ghproxyctl client upstream refresh        # add --dry-run to preview
sudo ghproxyctl status     # Upstream family IPv6 (pinned), Upstream peer ...
```

#### IPv6-only notes

* An IPv6-only host works end to end: the upstream is reached over AAAA and the
  peer is pinned to the verified IPv6 literal (the `cache_peer` spelling is
  decided by `squid -k parse`, never guessed).
* `--upstream-family 6` states the intent explicitly; `auto` reaches the same
  result when the IPv4 path is dead or absent.
* The local proxy listens on `::1` (and `127.0.0.1` when present) only.
* Server-side authorisation still needs the client's exact `/128`:
  `sudo ghproxyctl client add 2001:db8::1234 jp-v6-01`.
* Real-world reference: a Japan IPv6-only VPS runs this deployment (operator
  confirmation; see `docs/STATUS.md` §2.5 for the evidence level).

---

## `ghproxyctl`

```
ghproxyctl status                  role aware status + health checks
ghproxyctl test                    full verification, with route proof
ghproxyctl client list|add|remove  per-client authorisation (server)
ghproxyctl client forget|reimport  inventory-only drop / re-import (adopted)
ghproxyctl client upstream refresh re-probe and re-pin the upstream family/peer
ghproxyctl domains list|add|remove GitHub destination list (server)
ghproxyctl server reconcile        repair a previously adopted install (no reload)
ghproxyctl migrate scan|report|restore|service <unit>|komari|xray|git|env
ghproxyctl doctor                  environment diagnostics
ghproxyctl uninstall [client|server] [--purge]
```

Every mutating command supports `--dry-run`, and `--yes` for automation.

Route proof is real, not cosmetic: on a client the checks read the local Squid
access log and assert the hierarchy tag (`FIRSTUP_PARENT/...` for GitHub,
`HIER_DIRECT/...` for everything else).

---

## Requirements

| Role | Requirement |
|------|-------------|
| Server | Debian 12/13 or Ubuntu 22.04+ with `squid-openssl` (Squid ≥ 5 with TLS support) |
| Client | Debian/Ubuntu, `curl`, `ca-certificates`, git (optional), systemd |
| Both | root, outbound internet, TLS verification kept on at all times |

Verified environments: the CI matrix runs the full suite against a real Squid
on **Debian bookworm (Squid 5.7), Debian trixie (6.13) and Ubuntu 24.04
(6.14)**; production/pilot deployments run on Debian 13 (server), and Debian 12
client nodes including a dual-stack node with a blackholed IPv4 path and an
IPv6-only node (see `docs/STATUS.md` §2.5 for what is automated evidence and
what is operator confirmation).

`gh.xinian5216.com` in this documentation is an **example**. Every command takes
`--upstream https://your-gateway:port`.

---

## Repository layout

```
install.sh            entry point: server | client (self-bootstrapping, pinnable)
uninstall.sh          remove / unmanage
bin/ghproxyctl        control tool
lib/                  common, net, txn, squid, firewall, health,
                      server, server-ops, client, migrate
templates/            squid configs, systemd unit, sudoers, domain list
tests/                check.sh, run.sh, lib.sh, stubs/, unit/ (15 suites),
                      integration/ (6 suites, real Squid)
docs/STATUS.md        implementation status and open work
docs/RELEASE-NOTES-0.5.0.md  release notes (draft, for the GitHub Release)
```

---

## Testing

* **Unit**: 15 suites, 1,082 assertions — run anywhere
  (`bash tests/run.sh unit`), fully sandboxed (`GP_ROOT` + command stubs).
* **Integration**: 6 suites, 391 assertions against a **real Squid** on three
  distros (`bash tests/run.sh integration`, Linux + root) — routing proof, TLS
  strictness, adoption, family selection, rollback.
* **Static**: `bash tests/check.sh` — `bash -n`, ShellCheck, and policy greps
  that block TLS bypasses, destructive firewall commands and blanket grants.
* Layered policy: locally only static checks + the affected unit suites; the
  complete matrix runs in GitHub Actions on every push.

---

## Safety model (short version)

* clients: exact `/32` | `/128` only (structural address validation — no
  malformed address can reach an ACL), explicit `ghproxyctl client add`
* destinations: GitHub-operated names only. Shared CDN platforms are refused
  in three tiers: a platform suffix (`.amazonaws.com`, `.cloudfront.net`, …),
  its root and its multi-tenant service endpoints (`s3.amazonaws.com`, …) can
  **never** be allowed — `--force` included. One exact resource host (a
  bucket, a distribution) needs the explicit `--force` approval.
* the plain proxy port is bound to loopback only and verified after every change
* `ufw reset`, `ufw flush`, `iptables -F` are blocked by a policy check in
  `tests/check.sh`; rules this project did not create are never deleted
* TLS verification is never disabled; there is no `--insecure`/`-k` code path
* every change is backed up, journalled and reversible

See [`SECURITY.md`](SECURITY.md) for the full model.

---

## 中文速览

* **新服务器**：`sudo bash install.sh server --domain gh.example.com --cf-credentials <仅 root 可读的凭据文件>`
* **接管现有代理**：`sudo bash install.sh server --adopt-existing --dry-run`（只读）→ 确认后去掉 `--dry-run`
* **新增客户端授权**：`sudo ghproxyctl client add <IP> <名称>`（自动输出客户端安装命令；IPv4 精确 `/32`、IPv6 精确 `/128`）
* **新客户端**：推荐两阶段——先 `sudo bash install.sh client --upstream https://gh.example.com:8443`
  跑通健康检查，再单独 `sudo ghproxyctl migrate komari` 迁移服务
* **固定版本安装**：`--ref v0.5.0`（Tag）、分支名或完整 commit SHA 均可；获取失败会直接报错，不会悄悄回退到 `main`
* **双栈 / 单栈上游**：`--upstream-family auto|4|6`，安装前逐地址族探测并固定到**探测可用**的上游地址（TLS 仍按域名校验）；
  DNS 或路由变化后执行 `sudo ghproxyctl client upstream refresh`
* **已有客户端迁移**：`--adopt-existing` 会自动迁移 Komari / xray-manager / Git，先建后拆，失败自动回滚
* **状态与自检**：`sudo ghproxyctl status`、`sudo ghproxyctl test`、`sudo ghproxyctl doctor`
* **回滚**：`sudo ghproxyctl migrate restore`、`sudo bash uninstall.sh client|server`

所有改动都是事务化的：备份 → 校验 → 原子替换 → reload → 健康检查，失败自动回滚。
当前进度与未完成项见 [`docs/STATUS.md`](docs/STATUS.md)。

---

## License

MIT — see [LICENSE](LICENSE).
