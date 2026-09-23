# vps-gateway-manager v0.5.0 — Release Notes

> Verification basis: GitHub Actions run 35835417289 — the four blocking jobs
> (static + unit: 15 suites, 1,082 passed / 0 failed / 0 skipped; real-Squid
> suites 00–05: 391 passed / 0 failed / 0 skipped each on Debian bookworm /
> Debian trixie / Ubuntu 24.04) — plus the attributed real-host evidence in
> `docs/STATUS.md` §2.5.

## Highlights

* **One command to deploy, one to adopt, one per client.** A GitHub-only TLS
  egress gateway (Squid + Let's Encrypt) and smart-routing clients that send
  only GitHub traffic through it; everything else stays `DIRECT`.
* **Transactional everything.** Backup → `squid -k parse` → atomic replace →
  confirmed reload → health checks → commit, or an automatic byte-for-byte
  rollback. Adopted servers are additive-only and keep their own lifecycle.
* **Deterministic upstream selection (P0.5).** `--upstream-family auto|4|6`
  probes each address family through the gateway before anything is installed,
  pins `cache_peer` to a probe-verified address (with DNS-candidate failover)
  and keeps TLS verification against the logical upstream name
  (`ssldomain=`). `ghproxyctl client upstream refresh` re-selects after
  DNS/routing changes — transactionally, touching only the local client Squid.
* **Safe migrations.** Komari / xray-manager / Git / environment adoption with
  "build first, tear down later" ordering, redacted reporting (no token-bearing
  line is ever printed), post-restart verification that ignores Komari's own
  Ping/ICMP monitoring noise while still failing on real proxy/TLS/WebSocket
  faults — and an automatic rollback per component when a verification fails.
* **Pinned installs.** `--ref` accepts a branch, a tag (`v0.5.0`) or a full
  commit SHA; the toolkit archive is fetched from the matching GitHub archive
  path and an unfetchable ref fails loudly — never a silent fallback to `main`.
* **Hardened address and domain policy.** Structural RFC 4291 IPv6 validation
  (v4-mapped included) so no malformed address can enter an ACL; shared CDN
  platforms refused in three tiers — a platform suffix, its root and its
  multi-tenant service endpoints can never be allowed (`--force` included),
  while one exact resource host needs explicit `--force` approval.

## Supported environments

* Server: Debian 12/13 or Ubuntu 22.04+ with `squid-openssl` (Squid ≥ 5 with
  TLS); Client: Debian/Ubuntu with curl, ca-certificates, systemd.
* CI-verified against real Squid 5.7 (Debian bookworm), 6.13 (Debian trixie,
  the production version) and 6.14 (Ubuntu 24.04).
* Deployed in production/pilot: the Debian 13 gateway, dual-stack Debian 12
  clients (including one with a blackholed IPv4 path) and an IPv6-only client.
  Attribution and evidence levels: `docs/STATUS.md` §2.5.

## Install / upgrade

```bash
# pinned download through the gateway
curl --proxy https://gh.example.com:8443 \
  -fsSL https://raw.githubusercontent.com/xinian5216/vps-gateway-manager/v0.5.0/install.sh \
  -o /tmp/vps-gateway-manager.sh

# new client (two-phase: proxy + health checks first, Komari afterwards)
sudo bash /tmp/vps-gateway-manager.sh client \
  --upstream https://gh.example.com:8443 --upstream-family auto --ref v0.5.0
sudo ghproxyctl test
sudo ghproxyctl migrate komari

# existing adoption / upgrade of an installed host
sudo bash /tmp/vps-gateway-manager.sh client --upstream https://gh.example.com:8443 \
  --adopt-existing --dry-run        # read-only plan first
sudo ghproxyctl client upstream refresh   # after upstream DNS/routing changes
```

Upgrading an already-installed host re-runs the installer for the new ref (the
toolchain under `/usr/local/lib/vps-gateway-manager` is refreshed); adopted
servers can run `sudo ghproxyctl server reconcile` (no reload) to repair the
generated file and refresh the toolchain.

## Security properties

* Clients are exact `/32` / `/128` hosts only (structurally validated); no
  subnet shortcut exists.
* GitHub-only destinations; shared CDN platforms refused in three tiers (see
  above) and `--force` can never open a whole platform.
* TLS verification is never disabled: no `curl -k`, no `--insecure`,
  no `DONT_VERIFY_PEER` anywhere — enforced by a policy grep in `tests/check.sh`.
* Only UFW is managed, additively, and only rules tagged `gsp:<client>` are
  ever deleted; `ufw reset/flush`, `iptables -F` are blocked by policy greps.
* Secrets: Cloudflare tokens only via a root-only file (no `--token`); Komari
  endpoints/tokens never printed or modified; state files `0600` in `0700`.
* Every change is journalled and reversible (`backups/<txn-id>/`,
  `migrations/backups/`).

## Known limitations

* A fresh server install has not been exercised end to end with a real Certbot
  issuance and renewal cycle (unit-tested; CI uses a private test CA).
* `uninstall.sh` and `migrate restore` are unit-tested (byte-for-byte rollback)
  but not yet rehearsed on a real host.
* `ufw delete <n>` / comment-marker semantics deserve one manual confirmation;
  the restart escalation path is policy-tested only.
* IPv6-only and mainland-China deployments have operator confirmation only —
  no automated coverage yet.
* Reload confirmation needs a readable `cache_log` (`Reconfiguring Squid Cache`
  lines); on a host that suppresses them the tool refuses to claim a reload
  succeeded (deliberately conservative).

## Rollback

* Per change: automatic — any failed check rolls the transaction back
  (files, firewall rules and service actions restored; the daemon is brought
  back if a reload killed it).
* Per migration: `sudo ghproxyctl migrate restore` returns every migrated
  component to its pre-apply state (Komari included).
* Per host: `sudo bash uninstall.sh client|server` removes this project's
  files and rules (`--purge` for state and backups too); adopted servers are
  only *unmanaged* — the operator's Squid configuration, certificates and
  clients are never rewritten or removed.
