# Changelog

All notable changes to this project are documented here.
The project was renamed from `github-smart-proxy` to `vps-gateway-manager`
before the first release; `ghproxyctl` keeps its name because it is the GitHub
proxy control tool.

## [0.5.1] - 2026-09-24

Health-check accuracy and error reporting. No gateway reinstall, and no change
to an operator's Squid configuration, ACLs, firewall or certificates.

* **`Unknown source refused` no longer reports `FAIL 000000`.** `curl -w`
  already prints `000` when the connection fails; the check appended another
  `000`, and `000000` missed the transport-failure branch. Exit status and
  write-out are captured separately. A timeout, a refused connect, an empty
  write-out or a malformed token (including `000000`) is a **WARN**: the Squid
  ACL was not independently verified. A firewall drop looks exactly like that
  and is not reported as a Squid refusal or as a pass. HTTP 403/407 is a pass.
  Any 2xx is a fail, including when curl's own exit is non-zero. Any other
  HTTP status is a warning, not a pass. If the probe source is already an
  authorised client, the result is a warning and is not used as evidence
  about an unknown source.
* **`ghproxyctl status` and `ghproxyctl test` print the full table before
  exiting.** A failed check used to trip `set -e` before `hc_print`, so the
  operator saw only `aborted unexpectedly`. Both roles now print every check
  and a failure count, then exit non-zero. Warnings and skips stay non-failing
  (existing semantics) and the summary says they are not passes. An unexpected
  script abort still trips the existing EXIT guard and still rolls back an
  open transaction.
* **The adopted non-GitHub warning names its probe.** It is a loopback request
  to `example.com`. It does not test the public TLS listener, and it does not
  change the operator's destination policy.

## [0.5.0] - 2026-09-23

> First release. Everything below was verified by the four blocking CI jobs
> (`shellcheck + unit tests`, and the real-Squid suites 00–05 on Debian
> bookworm / Debian trixie / Ubuntu 24.04) plus the real-host evidence
> attributed in `docs/STATUS.md` §2.5.

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
* Fifteen unit suites covering validation (addresses, domains, URLs),
  bootstrap pinning, state, rendering, transactions, firewall, fresh server
  install, adoption, client install, migration, client upstream families —
  1,082 assertions, all passing (3 file-mode assertions run on Linux only).
* **Integration suite against a real Squid** (`tests/integration/`, blocking CI
  jobs on Debian bookworm with squid-openssl 5.7, Debian trixie with 6.13 and
  Ubuntu 24.04 with 6.14):
  * `00-squid-capabilities.sh` — which TLS listener directive actually works,
    and that `squid -k reconfigure` keeps the daemon alive (17 assertions)
  * `01-routing.sh` — TLS handshake with a verified certificate, CONNECT over
    TLS, GitHub through the TLS parent, everything else `HIER_DIRECT`, listed
    source served, unlisted source refused, untrusted parent certificate never
    produces a tunnel (28 assertions, green on all three Squid builds)
  * `02-adoption.sh` — adopting a *running* production proxy: additive changes
    only, operator files byte-identical, clients imported, `client add` takes
    effect through a real reload, rollback on failed checks (39/45 at the time
    and then non-blocking; the remaining cases were fixed afterwards and the
    suite is now **91/91 blocking**)
  * `03-production-dry-run.sh` — a production-shaped Debian 13 host with
    inline `dstdomain` ACLs (63 assertions)
  * `04-adoption-reconcile.sh` — formal adoption and the repair path against a
    real Squid (71 assertions)
  * `05-client-family.sh` — upstream family reliability: dual-stack healthy,
    IPv4/IPv6 blackholed, both broken, candidate failover, literal-peer TLS
    strictness (121 assertions)

### Known limitations
See [`docs/STATUS.md`](docs/STATUS.md) for the authoritative list. Highlights:
integration tests run against a real Squid in CI (Debian bookworm, Debian trixie
and Ubuntu 24.04) and already found several critical bugs. Real-host evidence
now includes the London client pilot (P0.5 installed and health-checked on the
second attempt, Komari migration completed after the health-check fix below —
user-provided logs) and user-confirmed deployments on a mainland-China VPS and a
Japan IPv6-only VPS. Still open end to end: a fresh server install with a real
Certbot issuance and renewal cycle, and an uninstall/restore rehearsal on a
scratch host. Two read-only adoption dry-runs against the real production host
(Debian 13 / Squid 6.13) were executed on 2026-09-21: the second passed, and the
issues both runs found are fixed and covered (see below).

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

### Fixed — Komari migration health check false positive (found on the real London host after the P0.5 pilot)
* **`migrate komari` returned 1 and rolled back on a healthy agent.**
  `migrate_komari_verify()` treated *any* `i/o timeout` in the last 180 seconds
  as a proxy/TLS error — but Komari runs its own Ping/ICMP monitoring and logs
  `Ping i/o timeout` when a **monitored target** stops answering. The London
  node logged that line persistently across two PIDs (2778572, 2881150) while
  `WebSocket connected` showed the panel path healthy. Verification now
  distinguishes the two: a timeout loses its error verdict ONLY on a pure
  Ping/ICMP monitor line that says nothing about the websocket/proxy transport.
  Everything that is a real failure still fails and still rolls the migration
  back: `x509`, `proxyconnect`, `connection reset`, websocket
  fail/refus/1006/handshake, and every non-monitor `i/o timeout`. Nothing is
  ever treated as success unconditionally.
* **Verification now judges the post-restart process only.** The old window
  also covered the previous PID's logs and pre-restart errors. `migrate
  komari` records the restart time and the new `MainPID` and only analyses that
  process' journal lines (`journalctl --since` + the `[pid]` tag). Fail-safe by
  design: when the pid is unknown or the log format carries no pid tag, all
  lines are analysed — a real error can never hide behind the filter.
* Covered by unit suite `09-migrate.sh`: historical Ping timeouts pass; a
  post-restart Ping timeout with a connected WebSocket passes; a previous PID's
  real errors are out of scope; a `proxyconnect` failure, a non-ping transport
  timeout and a WebSocket handshake failure each still fail and roll back
  byte-for-byte.

### Fixed — release audit hardening
* **IPv6 validation was a charset check** (`is_ipv6`): `:::`, `1::2::3`,
  `12345::1`, `1:2:3:4:5:6:7` and even a lone `:` were accepted and could reach
  a client ACL. It is now a structural RFC 4291 validation (1–4 hex digits per
  group, at most one `::` run, exactly 8 groups, `::` compresses at least one,
  embedded IPv4 only as a valid final component).
* **A v4-mapped address crashed the expander silently.** `_ipv6_expand`
  evaluated `$((16#1.2.3.4))` on the `::ffff:1.2.3.4` tail: bash printed
  "value too great for base" on stderr and the test still reported PASS. The
  embedded IPv4 tail is now converted into two 16-bit groups first, every group
  is validated *before* any arithmetic, and the regression tests assert that
  stderr is empty — a bash error can no longer hide behind a passing assertion.
* **`--ref` could not install a tag or a commit.** The bootstrap always
  downloaded `archive/refs/heads/<ref>` and guessed the extracted directory, so
  `--ref v0.5.0` (and any SHA) failed. It now fetches a full commit SHA from
  `archive/<sha>.tar.gz`, tries a branch and then a tag
  (`refs/heads/...`, `refs/tags/...`), discovers the extracted directory
  (GitHub strips the leading `v` from tag names), and **fails loudly with the
  attempted URLs when the ref cannot be fetched — there is no silent fallback
  to `main`**.
* **`--force` could open a whole shared CDN platform.** `ghproxyctl domains add
  .amazonaws.com --force` passed the "allow broad" flag into the validator and
  would have authorised every bucket and endpoint behind the suffix. The policy
  is now three-tier and enforced in `validate_domain_entry`: a platform suffix
  or root and its multi-tenant service endpoints (`s3.amazonaws.com`, the
  regional `s3.*` forms) can never be allowed — no flag overrides that — while
  ONE exact resource host (a bucket, a distribution) stays available through
  the explicit `--force` approval. `domains remove` normalises without the
  platform policy so a legacy entry can always be deleted. The stale `[--exact]`
  and `[--allow-broad]` flag mentions are gone.
* **Three inconsistent default destination lists.** `gp_default_github_domains`
  (7 entries), `templates/github-domains.txt` (5 entries) and the template's
  provenance comment (7 entries) disagreed. All three now describe the same
  five seeded names; the suffix entries already cover the narrower hosts.
