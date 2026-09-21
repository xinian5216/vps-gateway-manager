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
integration tests run against a real Squid in CI (Debian bookworm, Debian trixie
and Ubuntu 24.04) and already found several critical bugs; the end-to-end
verification on real hosts (Certbot issuance, IPv6-only, mainland China) is still
open. A read-only adoption dry-run against the real production host (Debian 13 /
Squid 6.13) was executed on 2026-09-21; the report bug it found is fixed and
covered (see below), and the second read-only dry-run is pending.

### Fixed — found by the first real production dry-run (Debian 13 / Squid 6.13)
* **The adoption dry-run printed only its title and returned to the shell.**
  Three causes: `server_adopt_report` printed a discovery report that was never
  collected; the TLS listener was looked up in the main `squid.conf` only, while
  the production host keeps `https_port` in `conf.d/github-whitelist.conf`; and
  the resulting certificate lookup (`openssl x509 -in /dev/null`, stderr already
  redirected) aborted the script under `set -e` without a message. The dry-run
  now collects and prints the full report, walks the effective configuration
  (main file + nested includes, globs in order) for listeners, and fails loudly
  with a non-zero exit when discovery or analysis cannot complete.
* **Inline `dstdomain` ACLs were mistaken for file paths.**
  `acl github_dst dstdomain .github.com` was treated as a reference to a file
  named `.github.com`, so no destination was imported. Destination discovery is
  typed now (`file` / `inline` / `regex`), reports the declaring file, handles
  several domains on one line and repeated definitions of the same ACL name
  (Squid ORs them — normal, not a duplicate), and imports validated inline
  entries into the managed list.
* **Covered by:** `tests/fixtures/production-debian13/` (Debian boilerplate +
  final deny + loopback ports in the main file; six exact clients, repeated and
  multi-value `src` lines, inline and multi-value `dstdomain` lines, a broad CDN
  entry and the TLS listener in `conf.d`), unit suite `10-adopt-production.sh`
  (full report contract, all clients/destinations, read-only, plus regressions
  for a missing TLS listener and a fatal analysis failure), integration suite
  `03-production-dry-run.sh` (real Squid: verified TLS handshake before and
  after, unchanged PID, no reload/restart, byte-identical files) and a new CI
  job on Debian trixie.

### Fixed — found by the integration suite
* **Squid ANDs ACL names in one `http_access` rule** (critical). The generated
  `http_access allow <client-a> <client-b> <domain-acl>` could never match, so a
  second managed client broke every managed client. The source ACL is now a
  single file-backed list (`managed-clients.acl`) whose entries are ORed, with a
  regression test that per-client ACL names are never combined (or generated).
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
* **Reloads are confirmed, not assumed.** A delivered signal (or a still-open
  port) proves nothing: `squid_wait_reconfigure_complete` now waits for a new
  `Reconfiguring Squid Cache` line after the recorded cache-log offset, requires
  no `FATAL`/`Bungled` in that window, waits for the listener to accept again,
  and re-checks the PID and that a daemon is running. This also corrected an
  earlier wrong conclusion: with a proper barrier a reload **does** pick up a
  newly created `include` file.
* **Rollback ordering and recovery.** The journal replays in reverse, so a
  recorded reload ran before the restored files were in place; the rollback now
  reloads once more at the end, and restarts the unit if the daemon is gone
  (Squid exits on a configuration error during a reload).
* **Silent aborts.** `install.sh` and `ghproxyctl` install an EXIT guard that
  rolls back and reports when the process ends non-zero with an open change.
* **Adopted servers keep their own lifecycle.** A reload that cannot be confirmed
  rolls the change back; a restart happens only with `--restart-if-needed`
  (never silently on an operator's production proxy).
* **The inventory is part of the transaction.** A rolled-back `client add` no
  longer leaves the client in `clients.db` (which would have reintroduced it on
  the next render).
* **Stale pid files.** `squid -k reconfigure` would start a *second* instance
  when the pid file is stale, and Squid refuses to start while a stale pid file
  exists; the reload path validates the pid against `/proc/<cmdline>`, refuses a
  daemon that ignores SIGHUP, and clears a provably stale pid file before a
  restart.
