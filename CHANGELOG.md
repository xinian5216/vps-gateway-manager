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
open. Two read-only adoption dry-runs against the real production host (Debian 13
/ Squid 6.13) were executed on 2026-09-21: the second passed, and the issues both
runs found are fixed and covered (see below).

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

### Fixed — found by the second real production dry-run (P0.2)
The second dry-run passed: Debian 13 / Squid 6.13, include tree, `https_port`,
certificate/key/TLS directory, all six exact clients, the inline `github_dst`
ACL with its four narrow destinations, UFW and the xray/x-ui ports were all
identified; exit code 0 and nothing was written or restarted. It then exposed
three smaller issues, all fixed:

* **Policy audit false positive (dangerous).** The check matched
  `http_access (allow|deny) all`, so the safe and expected
  `http_access deny all` terminator of every production configuration was
  reported as "blanket allow all - open proxy". The decision is now token by
  token (`squid_rule_allows_all`): only a literal `http_access allow all` fails,
  a `deny` rule never does, and a rule listing localhost/clients/CONNECT/domains
  is a normal restriction. A config whose final rule is not a deny still fails.
* **The discovery temporary file path was printed to the user.** The collector
  now returns silently, the report is read back through
  `server_discovery_print`, and the file is removed after the report (and on
  re-collection).
* **`systemctl list-timers` was suppressed under `--dry-run`**, so a host
  running `certbot.timer` showed an empty renewal-timer section. Read-only
  queries now run for real; mutating verbs (`reload`, `restart`, `start`,
  `stop`, `enable`, `disable`) remain blocked in dry-run mode.
* **Covered by:** unit suite `11-policy-audit.sh` (allow-all vs deny-all table,
  normal client/localhost rules, the two-deny production shape, the production
  fixture, `list-timers` executed vs mutating verbs suppressed, no temp path and
  no leaked temp file), plus new assertions in `10-adopt-production.sh` and
  `03-production-dry-run.sh` (timer discovered, no `open proxy`, no
  `policy audit produced warnings`, no bare `/tmp/tmp.*` line).

### Fixed — found by the first real Komari client dry-run (P0.3)
The first real client dry-run (Debian 12, dual stack, `komari-agent.service`
with a `proxy.conf` drop-in) exited 0 and modified nothing. It then exposed:

* **The Komari Token was printed in the dry-run report (security).** The report
  printed the raw `ExecStart` truncated with `cut -c1-120`, while the next line
  promised "Endpoint/Token: never displayed". Truncation is not redaction, and
  the token sits in the middle of the command line. The report now prints an
  allowlisted summary only (`ExecStart: detected (redacted)`,
  `Endpoint`/`Token`: `detected, value hidden`) and never prints the raw argv in
  any form. Other shown values pass through URL-credential redaction
  (`scheme://user:pass@host` -> `scheme://***@host`), following the
  "allowlist what may be printed" rule instead of blacklisting known secrets.
* **The dry-run claimed state it never wrote.** "current proxy references
  recorded in `/etc/vps-gateway-manager/state/`" was printed although only a
  temporary file was written and deleted. Dry-run now says "inspected
  (read-only; nothing persisted)"; no persistent state is claimed unless it was
  written.
* **The upstream whitelist pre-check was skipped in dry-run.** It is a read-only,
  TLS-verified GitHub request through the upstream (no `-k`, bounded timeout),
  so it now really runs and reports HTTP 200/403/407/000 explicitly. A failed
  probe fails the dry-run instead of passing silently. The whitelist itself is
  never modified locally; authorising an address stays a server-side action.
* **`curl` printing `000` and exiting non-zero produced `000000`** in the probe
  result (a fallback appended a second `000`); the value is sanitised to exactly
  one status code.
* **New: per-address-family upstream diagnostic** (`IPv4: PASS/FAIL/unavailable`,
  `IPv6: …`) plus a warning when a dual-stack host can reach the upstream over
  only one family: "Authorise both exact host addresses before migration, or
  explicitly configure the intended family." Exact `/32`/`/128` only - no
  `/24`, `/64` and no automatic server-side change.
* **Covered by:** unit suite `12-client-adopt-dry-run.sh` (real-shaped Komari
  host with dual stack, token flag forms and lengths, redaction, read-only
  wording, state dir absence, whitelist probe execution and failure handling,
  single-family warning), plus the credential-redaction helper tests.

### Fixed — found by the first formal production adoption (P0.4)
`install.sh server --adopt-existing` ran for real on the production host and
performed no reload/restart, but `ghproxyctl status` exposed:

* **Six clients sharing one operator ACL name collapsed into one row.** The
  inventory deduplicated by display name, so `allowed_clients` kept overwriting
  itself. Identity assignment is now one shared helper
  (`clients_unique_import_identity`) used by the adoption plan, the adoption
  import and `client reimport`: every distinct CIDR is preserved with a unique
  display name and acl_id; `clients_db_add` replaces a row only for the same
  CIDR and refuses a name/acl_id that belongs to a different address.
* **The managed file redefined the operator's destination ACL name.** Squid
  unions repeated `acl <name>` definitions, so the old file would have added the
  project's `.github.io` to the operator's own `github_dst` rules on the next
  reload. Adopted mode now keeps two explicit names:
  `operator_domain_acl_name` (recorded, never redefined) and `domain_acl_name` =
  `gsp_managed_github` (project-owned, defined in the managed file). A picker
  avoids a name already declared by the operator's configuration.
* **`status` printed empty Squid fields and a stale firewall.** The state round
  trip now restores `squid_bin/version/flavor/pkg`, and `gp_status_server` calls
  the read-only `fw_detect`, so a running UFW is reported as
  `backend=ufw active=… ipv6=…` next to `(managed=…)`.
* **New repair path for already-adopted hosts:** `ghproxyctl server reconcile
  [--dry-run]` re-reads the operator source ACL, rebuilds the adopted rows,
  regenerates the managed file with the project ACL, updates the state schema,
  validates with `squid -k parse` and commits transactionally — without reload,
  restart, firewall change or any write to operator files. It is idempotent and
  refreshes the installed toolchain so `ghproxyctl` is the fixed version.
* Covered by unit suite `13-formal-adopt-reconcile.sh` (formal adoption, six
  preserved clients, unique identities, ACL isolation, state round trip, live
  status, dry-run/repair/idempotent reconcile) and integration suite
  `04-adoption-reconcile.sh` (real Squid: an operator client cannot reach
  `.github.io` while a managed client can, before and after a simulated legacy
  install is repaired).

### Fixed — found by the first real London client pilot (P0.5)

The first formal client pilot (London) failed after starting the local proxy:
GitHub API/Raw reported `HIER_NONE/- (http=000)` while Release passed through
the parent, and the installer correctly rolled back ("local proxy installation
failed; nothing was migrated" - Komari untouched). Root cause: the node has a
blackholed IPv4 path and a healthy IPv6 path, and `cache_peer
<dual-stack-hostname>` is NOT deterministic when one family is broken (Squid's
peer connection logic is not a per-request Happy Eyeballs). This was not a
transient fluctuation and is not fixed by retries, longer timeouts or
happy-eyeballs tuning.

* **Deterministic upstream family selection** (`auto`/`4`/`6`, CLI
  `--upstream-family`, default `auto`): before anything is installed each
  family is probed through the upstream and classified strictly - 200 usable,
  403/407 "reached but refused", 000 "transport unavailable" (never "not
  authorised"). auto with both families usable keeps the verified dual-stack
  hostname; exactly one usable family is auto-selected and PINNED to a verified
  peer; nothing usable aborts before any change and before any migration.
* **Probe-verified peer addresses**: for a pinned family every DNS candidate is
  probed individually with curl's own HTTPS-proxy behaviour (`--proxy` to the
  LOGICAL upstream hostname, `--resolve` pinning the connection to the
  candidate, `--proxy-cacert`, reading `%{http_connect}`/`%{http_code}`) - TLS
  verification runs against the upstream name, never the IP - and the first
  candidate that really answers 200 wins - DNS order alone is never trusted, so
  a dead first candidate fails over to the working one.
* **Literal peer with strict TLS**: the generated config uses
  `cache_peer <peer-ip>` with `ssldomain=<logical-hostname>`, so the
  certificate keeps being verified against the upstream's name. The IPv6
  `cache_peer` spelling is decided by `squid -k parse` (never guessed) and
  proven with real traffic on all three CI distros. No `-k`, no `--insecure`,
  no `DONT_VERIFY_*`.
* **`ghproxyctl client upstream refresh [--dry-run]`**: re-resolves the
  recorded family, re-probes the candidates, is a no-op when nothing changed
  and otherwise updates the configuration transactionally (render ->
  `squid -k parse` -> reload the local client Squid -> full health check, with
  rollback on failure). Komari and every other migration are never touched.
* **Health checks name the broken layer**: `Upstream IPv4` / `Upstream IPv6`
  records carry the strict classification (000 = TRANSPORT UNAVAILABLE,
  403/407 = REACHED BUT REFUSED), `Selected family` / `Selected peer` show what
  was chosen, and `ghproxyctl status` prints the pinned family and peer next to
  the logical TLS name.
* **Rollback restores the PRE-INSTALL system-squid state**: the package
  side-effect cleanup used to journal `systemctl enable squid` as its undo, so
  the London rollback enabled a unit that had been absent before the install.
  The pre-state (enabled+inactive / disabled+inactive / active / absent) is now
  captured and restored exactly, with unit tests for all four states.
* **The local proxy's own rollback is now equally strict** (found by the new
  rollback tests): the journal had recorded *undo* verbs (so a rollback
  re-enabled and re-started the just-installed proxy - the engine records
  FORWARD actions and inverts them) and the state writes (`role`, `version`,
  `client.conf`, destination list) were not journaled at all. A failed install
  now leaves the host exactly as unconfigured as it was - service state, local
  Squid config, unit, profile, sudoers, state and spool are all restored.
* Probe classification also covers `-verify_return_error` aborting the
  handshake on expired or wrong-name certificates: a TLS failure is never
  misreported as a transport failure.
* Covered by unit suite `14-client-family.sh` (classification, candidate
  failover, TLS-name pinning, state schema, refresh no-op/change/rollback) and
  integration suite `05-client-family.sh` against real Squid 5.7 / 6.13 / 6.14:
  dual healthy, IPv4 blackholed, IPv6 blackholed, both broken (fails before
  install AND before any migration), candidate failover, and literal-peer TLS
  strictness (correct / wrong-name / self-signed / expired).

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
