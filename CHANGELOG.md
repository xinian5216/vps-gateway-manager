# Changelog

All notable changes to this project are documented here.
The project was renamed from `github-smart-proxy` to `vps-gateway-manager`
before the first release; `ghproxyctl` keeps its name because it is the GitHub
proxy control tool.

## [Unreleased]

### Added — Phase 1: foundation + fresh server install
* `install.sh` / `uninstall.sh` entry points with a self-bootstrapping
  one-liner (downloads the toolkit when only `install.sh` is present).
* `lib/common.sh`: logging, dry-run gates, path anchoring (`GP_ROOT` sandbox),
  atomic writes, key/value state, managed-file registry, audit log, template
  rendering.
* `lib/net.sh`: strict address/domain/URL validation — IPv4 `/32`, IPv6 `/128`,
  no wildcards, refusal of shared CDN suffixes.
* `lib/txn.sh`: transaction engine (backup → install → commit/rollback) with a
  TAB-separated journal, reverse replay, and restore of files, directories,
  firewall rules and service actions.
* `lib/squid.sh`, `lib/firewall.sh`: Squid detection/validation/reload,
  read-only inspection of an existing installation, and additive UFW handling
  with `gsp:<client>` markers.
* `lib/health.sh`: health checks with **route proof** (Squid access-log
  hierarchy tags), TLS verification, and "non-GitHub must be refused".
* `lib/server.sh`, `lib/server-ops.sh`: fresh install (Squid + Let's Encrypt +
  Certbot hook + ACLs + firewall), per-client ACL management, destination list
  management, uninstall/unmanage.
* Templates: `server-squid.conf`, `client-squid.conf`, `client.service`,
  `sudoers.conf`, `github-domains.txt`.
* `bin/ghproxyctl`: status, test, doctor, client, domains, migrate, uninstall.

### Added — Phase 2: adoption of an existing production proxy
* `install.sh server --adopt-existing [--dry-run]`: read-only discovery of
  Squid version/unit/listeners/ACLs/certificates/Certbot hook/UFW/neighbours,
  client import (with node names taken from trailing comments), destination list
  import, and a printed plan of what will and will not be touched.
* Adoption is additive only: no reload, no restart, no rewrite of the
  operator's files; the generated `conf.d` file carries no deny rule and is
  named `00-…` so it loads first.
* `squid_check_managed_ordering`: detects a blanket deny that would shadow the
  managed file, using a full load-order expansion of the configuration.

### Added — Phase 3/4: client smart routing and client adoption
* `install.sh client --upstream …`: dedicated Squid instance (own config, pid,
  logs, spool dir, systemd unit), loopback-only listeners, `cache_peer … tls`
  to the gateway, `never_direct` for GitHub, everything else `DIRECT`.
* `/etc/profile.d/vps-gateway-manager.sh` with NO_PROXY **merging** (existing
  entries are preserved and deduplicated).
* `/etc/sudoers.d/vps-gateway-manager`, validated with `visudo -cf` before
  installation and `visudo -c` afterwards.
* GitHub-only Git configuration (`http.https://github.com.proxy`), never a
  global `http.proxy`, with the previous value recorded for restore.
* `install.sh client --adopt-existing`: build-first-tear-down-later flow with a
  remote whitelist pre-check, then per-component migration and verification.

### Added — Phase 5: migration of existing components
* Komari agent: rewrites only the four proxy variables and merges `NO_PROXY`;
  Endpoint, Token and ExecStart are never modified; refuses to migrate units
  that use `EnvironmentFile=`; verifies `is-active` plus journal evidence
  (WebSocket v2, no `x509`/`proxyconnect`/`timeout`/`reset`) and restores the
  previous drop-in on failure.
* `xray-manager`: `/etc/xray-manager/download_proxy` (never created without
  confirmation).
* Git configuration for `root` and the invoking user.
* `/etc/environment` and `profile.d`: reported only, and migrated only with the
  explicit `--migrate-global-env`.
* Unknown systemd units: reported as `manual-review`, migrated only on explicit
  request (`ghproxyctl migrate service <unit>`).
* `ghproxyctl migrate scan|report|restore`.

### Added — Phase 6: tests
* `tests/check.sh`: `bash -n`, ShellCheck, and policy greps (destructive
  firewall commands, TLS bypass, blanket grants).
* `tests/lib.sh` + `tests/stubs/`: sandbox (`GP_ROOT`) with deterministic stubs
  for systemctl, ufw, squid, curl, openssl, visudo, id, getent, runuser, ss, ip.
* Nine unit suites covering validation, state, rendering, transactions,
  firewall, fresh server install, adoption, client install, migration — 386
  assertions, all passing.
* **Integration suite against a real Squid** (`tests/integration/`, CI jobs on
  Debian bookworm with squid-openssl 5.7 and Ubuntu 24.04 with 6.14):
  * `00-squid-capabilities.sh` — which TLS listener directive actually works,
    and that `squid -k reconfigure` keeps the daemon alive (11 assertions)
  * `01-routing.sh` — TLS handshake with a verified certificate, CONNECT over
    TLS, GitHub through the TLS parent, everything else `HIER_DIRECT`, listed
    source served, unlisted source refused, untrusted parent certificate never
    produces a tunnel (27 assertions, green on both Squid versions)
  * `02-adoption.sh` — adopting a *running* production proxy: additive changes
    only, operator files byte-identical, clients imported, `client add` takes
    effect through a real reload, rollback on failed checks (39/45, still
    non-blocking; see `docs/STATUS.md` §2.1)

### Known limitations
See [`docs/STATUS.md`](docs/STATUS.md) for the authoritative list. Highlights:
integration tests run against a real Squid in CI (Debian bookworm and Ubuntu
24.04) and already found one critical bug; the end-to-end verification on real
hosts (production dry-runs, Certbot issuance, IPv6-only, mainland China) is
still open.

### Fixed — found by the integration suite
* **`https_port`, not `http_port`, for the TLS listener** (critical). Squid
  accepts `http_port <port> tls-cert=…` but keeps the listener **plaintext**
  (`Accepting HTTP Socket connections at …:8443`), which would have made the
  gateway hop unencrypted. `https_port` terminates TLS and accepts both a plain
  GET and CONNECT. Pinned by
  `tests/integration/00-squid-capabilities.sh` on Squid 5.7 and 6.14.
* **`hc_tls_verify` false positive.** `openssl s_client` prints
  `Verify return code: 0 (ok)` even when the handshake failed, so a plaintext
  listener used to be reported as healthy. The check now requires an actual,
  verified peer certificate.
* **Reload race.** Squid closes and reopens its listeners while reconfiguring;
  the health check could hit that window, see connection refused, and roll back
  a good change. The service wait now requires a real TCP connect.
* **Rollback ordering.** The journal replays in reverse, so a recorded reload
  ran before the restored files were in place. The rollback now reloads once
  more at the end, so the daemon always matches the disk.
* **Silent aborts.** `install.sh` and `ghproxyctl` install an EXIT guard that
  rolls back and reports when the process ends non-zero with an open transaction.
* **Adopted servers keep their own destination policy.** The "non-GitHub must be
  refused" check is informational on an adopted server and a hard failure only
  on a fresh install this project owns.
* **A reload must not replace the daemon.** A stale pid file makes
  `squid -k reconfigure` start a new instance instead of signalling the running
  one; `squid_reload` now detects and warns about a PID change.
