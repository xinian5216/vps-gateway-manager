# Implementation status

Everything below is verified by `bash tests/run.sh unit` (15 suites,
**1,082 assertions, all passing** — 3 of them file-mode assertions that run on
Linux only) plus `bash tests/check.sh` (syntax, ShellCheck, policy greps —
clean). Real-host results are attributed explicitly in §2.5 and are never
counted as automated test evidence.

Legend: **DONE** = implemented and covered by unit tests ·
**PARTIAL** = implemented but not verified the way it must be before production ·
**TODO** = not started.

---

## 1. DONE — verified by unit tests

| Area | What exists | Verification level |
|------|-------------|--------------------|
| Repository layout | `install.sh`, `uninstall.sh`, `bin/ghproxyctl`, `lib/`, `templates/`, `tests/`, `.github/workflows/ci.yml`, `README.md`, `SECURITY.md`, `CHANGELOG.md`, `LICENSE` | implemented |
| Project identity | `vps-gateway-manager` everywhere: state dir `/etc/vps-gateway-manager`, unit `vps-gateway-manager-client.service`, `/etc/profile.d/vps-gateway-manager.sh`, `/etc/sudoers.d/vps-gateway-manager`, `/var/log|run|spool/vps-gateway-manager`, env prefix `VGM_*`; `ghproxyctl` keeps its name | implemented |
| Validation | exact `/32` and `/128` only, `/64`/`/0` refused, wildcards refused, shared CDN suffixes refused (three-tier policy: suffixes/roots/service endpoints never, exact resource hosts only with `--force`), structural RFC 4291 IPv6 validation with v4-mapped support, strict upstream URL parsing | **unit-tested** |
| Self-bootstrap | `--ref` accepts a branch, a tag (`v0.5.0`) or a full commit SHA; the extracted tree is discovered (never guessed); an unfetchable ref fails loudly with no fallback to `main` | **unit-tested** |
| Transaction engine | backup → atomic write → reload → verify → health check → commit/rollback; TAB journal; reverse replay; restores files, directories, firewall rules, service actions; brings the daemon back if a reload killed it | **unit-tested** + integration (rollback scenario) |
| Fresh server install | Squid detection (`squid-openssl`, ≥5 with TLS), `https_port … tls-cert=` (see §6), loopback-only plain port, GitHub destination ACL, one file-backed source ACL, final `deny all`, UFW integration, Certbot deploy hook, generated-config validation before any write, rollback on failed health check | **unit-tested**; not yet executed end-to-end against real Squid (see §3) |
| Adoption | read-only discovery report, client import (node names from comments), destination import, `00-`-prefixed additive conf.d file with **no** deny rule, no reload/restart during adoption, byte-identical operator files, blanket-deny ordering check | **integration-tested, 91/91 blocking** (see §2) + real production host (§2.3) |
| Client install | own Squid config/pid/logs/spool/unit, loopback-only listeners, `cache_peer … tls tls-cafile=`, `never_direct` for GitHub, everything else DIRECT, an unrelated `squid`/`xray`/`3x-ui` untouched | **unit-tested**; the *chain itself* (client Squid → TLS parent → GitHub) is **integration-tested** in `01-routing.sh` |
| Client upstream family | `--upstream-family auto\|4\|6`, per-family strict classification (200 / 403-407 / 000), probe-verified candidate pinning with failover, literal peer + `ssldomain=` TLS strictness, `ghproxyctl client upstream refresh` | **unit-tested** + **integration-tested** (`05-client-family.sh`, real Squid on three distros) |
| Client environment | profile.d with NO_PROXY merge (existing entries preserved, deduped), sudoers validated with `visudo -cf` + `visudo -c`, GitHub-only git config with recorded previous values | **unit-tested** |
| Migration | Komari (only the 4 proxy vars + NO_PROXY; Endpoint/Token/ExecStart untouched; `EnvironmentFile=` refused; post-restart journal verification with Ping/ICMP monitor noise excluded; automatic restore on failure), xray-manager, git, `/etc/environment` behind `--migrate-global-env`, unknown units reported and migrated only on request | **unit-tested** + real Komari node (§2.5: migration completed after the health-check fix) |
| Restore / uninstall | `ghproxyctl migrate restore`, `uninstall.sh client\|server`, adopted servers are only *unmanaged* | **unit-tested**; not yet executed on a real host (see §3) |
| Route proof | health checks read the Squid access log and assert `FIRSTUP_PARENT/…` for GitHub vs `HIER_DIRECT/…` for everything else | **integration-tested** (`01-routing.sh`) |
| CI | `shellcheck + unit tests`, `integration (real squid, Debian bookworm)`, `integration (real squid, Debian trixie)`, `integration (real squid, Ubuntu 24.04)` | see §2 for the current state |
| Tests | 15 unit suites (ShellCheck clean, all green) + 6 integration suites + a service-manager shim | — |

## 2. Integration suite (real Squid) — current state

`tests/integration/` runs as a **blocking** CI gate in three containers (Debian
bookworm, squid-openssl 5.7; **Debian trixie, Squid 6.13 — the production
version**; Ubuntu 24.04, 6.14). The authoritative green run for this release
candidate is the `release-prep` run of the release-candidate commit (all four
jobs — `shellcheck + unit` plus the three real-Squid matrices 00–05; the
concrete run id is recorded at release time). Earlier green runs:
35815767532 (`main`, the Komari health-check fix), 35810061493 (`main`, P0.5
merge), 35710452577 / 35712180529 (the P0.5 head and branch tip). The counts
below are per suite and identical on all three distros.

| Suite | Debian 5.7 | Debian 6.13 | Ubuntu 6.14 | What it proves |
|-------|-----------|-------------|-------------|----------------|
| `00-squid-capabilities.sh` | 17/17 | 17/17 | 17/17 | which listener directive terminates TLS, reload semantics (incl. that a reload DOES pick up a newly created include file once the reconfigure cycle is confirmed), that a stale/foreign pid file is refused instead of starting a second instance |
| `01-routing.sh` | 28/28 | 28/28 | 28/28 | TLS handshake with a verified certificate, CONNECT over TLS, GitHub through the TLS parent (`FIRSTUP_PARENT`), everything else `HIER_DIRECT`, listed source served, unlisted source refused, non-GitHub refused, untrusted parent certificate never produces a tunnel |
| `02-adoption.sh` | 91/91 | 91/91 | 91/91 | adopting a *running* production proxy: additive only, operator files byte-identical, clients imported, one file-backed source ACL, two managed clients both served (AND-bug regression), removing one keeps the other, a strict operator file cannot shadow managed clients, reloads keep the daemon process, a failed health check rolls back with daemon/files/process table in agreement |
| `03-production-dry-run.sh` | 63/63 | 63/63 | 63/63 | a production-shaped Debian 13 host (TLS listener, client ACLs and **inline** `dstdomain` ACLs in an included `conf.d` file, six exact clients, final `deny all`): the dry-run prints the full report, discovers the TLS listener through the include tree, imports every exact client and every narrow destination, and disturbs nothing — trusted TLS handshake before and after, unchanged daemon PID, exactly one Squid, no reload/restart, byte-identical files |
| `04-adoption-reconcile.sh` | 71/71 | 71/71 | 71/71 | **formal** adoption against a real Squid: six clients survive the import with unique names and acl_ids, the managed file uses a project-owned destination ACL and never redefines the operator's `github_dst`; after a reload an operator client still cannot reach a project-only destination (`.github.io`) while a managed client can; `ghproxyctl server reconcile` repairs a simulated legacy install with no reload/restart and byte-identical operator files, and is idempotent |
| `05-client-family.sh` | 121/121 | 121/121 | 121/121 | client upstream family reliability (P0.5) on a real Squid gateway with per-scenario TLS listeners: dual-stack healthy (hostname mode, full parent/direct routing), **IPv4 blackholed** and **IPv6 blackholed** (deterministic family selection with a probe-verified pinned peer; API/Raw/Release through the parent with no `HIER_NONE/000`; `upstream refresh` no-op + transactional change), **both broken** (fails before install AND before any migration - a fake Komari unit stays byte-identical), **candidate failover** (dead first DNS candidate skipped), and literal-peer TLS strictness (correct cert PASS; wrong name / self-signed / expired FAIL) |

All integration jobs fail the workflow when any assertion fails; no step is
`continue-on-error`.

### 2.1 First real production dry-run (read-only)

On **2026-09-21** `install.sh server --adopt-existing --dry-run --verbose` was
executed read-only against the production host (**Debian 13 trixie, Squid 6.13
with OpenSSL**, TLS on 8443, loopback-only 3128, `include /etc/squid/conf.d/*.conf`).
No file, service or firewall rule was changed. It exposed a real bug: the report
printed only its title because the discovery report was never collected, the TLS
listener was searched for in the main `squid.conf` only, and the resulting
certificate lookup aborted the script silently under `set -e`. Fixed in
`467decb` and pinned by unit suite `10-adopt-production.sh`,
`tests/fixtures/production-debian13/` and integration suite
`03-production-dry-run.sh`.

**Second production dry-run: PASS after P0.1.** The host (Debian 13 / Squid
6.13) is now identified correctly: include tree, `https_port 8443` with
certificate/key/TLS directory, all six exact `/32` and `/128` clients, the
inline `github_dst` ACL with its four narrow destinations
(`.github.com`, `.githubusercontent.com`, `.githubassets.com`, `ghcr.io`), UFW,
and 443 = xray / 4428 = x-ui. Exit code 0, `/etc/vps-gateway-manager` not
created, managed conf.d and ACL files not created, Squid stayed active and the
listeners did not change.

That run then exposed three smaller issues (P0.2), all fixed and covered:

* the policy audit reported `http_access deny all` as a blanket
  `allow all` (open proxy) — a false positive on every production config;
* the discovery temporary file path was printed to the user;
* `systemctl list-timers` was suppressed under `--dry-run`, so `certbot.timer`
  did not appear in the renewal-timer section.

The production-shaped fixture now asserts the expected audit result
(`final http_access rule is a deny`, no `open proxy`, no `policy audit produced
warnings`) and the timer discovery, in both the unit suite and the real-Squid
integration suite.

### 2.2 First real Komari client dry-run (read-only)

The first real client dry-run was executed read-only on a Komari node (Debian 12
bookworm, dual stack, IPv4 `212.135.36.99` / IPv6 `2a06:a005:ad:fffd::89`,
`komari-agent.service` with a `proxy.conf` drop-in, no xray-manager, no Git
proxy, no `/etc/environment` proxy). It exited 0 and modified nothing; IPv4 could
not reach the upstream while IPv6 could, which the operator had already verified
by hand.

**Result: PASS after P0.3.** The dry-run now reports a redacted Komari section
(`ExecStart: detected (redacted)`, `Endpoint: detected, value hidden`,
`Token: detected, value hidden`), runs the remote whitelist probe for real
(TLS-verified, no `-k`, bounded timeout, explicit HTTP 200/403/407/000) and
prints a per-address-family upstream diagnostic
(`IPv4: PASS/FAIL/unavailable`, `IPv6: …`) with a warning when only one family
can reach the upstream. The IPv4/IPv6 split does not modify the server in any
way; the operator still authorises exact `/32` and `/128` addresses only.

P0.3 findings fixed (see §7): the raw Komari `ExecStart` (and with it the token)
was printed truncated instead of redacted; the dry-run claimed to have recorded
state in `state/` that it never wrote; the whitelist probe was skipped in
dry-run; and `curl` printing `000` and exiting non-zero produced `000000` in the
probe result.

### 2.3 First formal production adoption (P0.4) and the repair path

On **2026-09-21** `install.sh server --adopt-existing` was executed for real on
the production host (the same Debian 13 / Squid 6.13 machine). It performed no
reload and no restart; Squid stayed active and the listeners did not change.
`ghproxyctl status` then exposed three defects, all fixed and covered by tests:

* the six clients sharing one operator ACL name (`allowed_clients`) collapsed
  into a **single** inventory row — the database deduplicated by display name;
* the generated `conf.d` file redefined the operator's `github_dst` ACL, so the
  next reload would have added the project's `.github.io` to the **operator's
  own** allow rules (the daemon had not reloaded, so live access was unchanged);
* `status` printed empty Squid fields (state write/load asymmetry) and a stale
  `backend=none` firewall (the live state was never detected).

The production host still carries the defective generated file. Until it is
repaired: no `ghproxyctl client add`, no `domains add/remove`, no manual
reload/restart and no client migration.

**Repair path.** `ghproxyctl server reconcile [--dry-run]` re-reads the operator
source ACL, rebuilds the adopted inventory rows with unique names and acl_ids
(the same shared helper as the adoption plan and `client reimport`), switches the
managed file to the project-owned destination ACL (`gsp_managed_github`) while
recording the operator's name separately, updates the state schema, validates
with `squid -k parse` and commits transactionally. It does **not** reload,
restart, touch the firewall or write any operator file; on the next
operator-chosen reload the operator ACLs behave exactly as before. After a
successful repair it also refreshes the installed toolchain
(`/usr/local/lib/vps-gateway-manager`, `/usr/local/sbin/ghproxyctl`) so running
`ghproxyctl` is the fixed version.
`tests/integration/04-adoption-reconcile.sh` proves this against a real Squid.

### 2.4 First real London client pilot (P0.5) — upstream family reliability

On **2026-09-22** the first formal client pilot ran on the London node (dual
stack; the IPv4 path to the upstream was blackholed, IPv6 healthy — verified
beforehand by a forced-IPv6 GitHub request through the upstream returning
HTTP 200; the server side had already passed P0.4 repair + reload with real
traffic). The installer started the local Squid 3129 and its health checks then
reported:

```text
GitHub API / GitHub Raw    FAIL  expected route 'parent' but log shows
                                  'HIER_NONE/-' (http=000)
GitHub Release             PASS  parent via FIRSTUP_PARENT/2607:8700:... (206)
```

The installer rolled back correctly (`local proxy installation failed; nothing
was migrated` — Komari untouched). This was **not** a transient network
fluctuation: with `cache_peer <dual-stack-hostname>` and one family blackholed,
Squid's peer connection path is not deterministic (it is not a per-request
Happy Eyeballs), so API/Raw failed while Release happened to fall on the
working family.

**Result: P0.5** replaces hostname peering in that situation with
deterministic, probe-verified selection (verified by unit `14` + integration
`05` on Squid 5.7 / 6.13 / 6.14):

* `--upstream-family auto|4|6` (default `auto`), persisted as
  `upstream_family` (configured) / `upstream_selected_family`
  (`4`|`6`|`dual`) / `upstream_peer_address` (pinned peer);
* strict classification per family: `200` usable, `403/407` **reached but
  refused**, `000` **transport unavailable** (never "not authorised");
* `auto` keeps the verified dual-stack hostname only when BOTH families are
  usable; one usable family is auto-selected and pinned to a candidate that
  really answered 200 (TLS-verified CONNECT probe per candidate, failover past
  dead ones); nothing usable aborts before any change;
* `cache_peer <peer-ip>` + `ssldomain=<logical-name>` keeps certificate
  verification against the upstream hostname; the IPv6 spelling is decided by
  `squid -k parse` and proven with real traffic;
* `ghproxyctl client upstream refresh` re-resolves and re-probes (no-op when
  unchanged, transactional update + reload + health check otherwise);
* health/status name the broken layer (`Upstream IPv4/IPv6` with the strict
  classification, `Selected family`/`Selected peer`);
* rollback restores the PRE-INSTALL system-squid unit state (the London rollback
  log had shown `systemctl enable squid` for a unit that had been absent).

**Second attempt on the real London node: SUCCESS (user-provided real-host
logs, 2026-09-22/23).** With the P0.5 code the client installed, the full
health check passed (the IPv4 path probed as TRANSPORT UNAVAILABLE, the IPv6
path PASS and auto-selected, the peer pinned to a candidate that really
answered 200 with TLS verified against the logical upstream name), and the
Komari migration completed after the health-check fix in §7.29 — the first
`migrate komari` attempt had returned 1 and rolled back cleanly, which is what
exposed the Ping/ICMP monitoring false positive. These are real-host logs
provided by the operator, not an automated test result (see §2.5).

### 2.5 Real-host evidence and its attribution

Evidence levels used here: **CI** (automated, blocking) · **real-host logs**
(executed on a production/pilot host with output reviewed in this work) ·
**user verbal confirmation** (reported working by the operator; no logs
reviewed here — never counted as a test result).

| Host | What was verified | Evidence level |
|------|-------------------|----------------|
| production gateway (Debian 13 / Squid 6.13) | two read-only adoption dry-runs (2026-09-21), formal adoption + `server reconcile` repair, real traffic with the operator ACLs | real-host logs (executed from this work), §2.1–2.3 |
| London Komari node (dual stack, IPv4 path blackholed) | P0.5 client install + full health check; Komari migration to the local proxy (after the §7.29 fix) | **user-provided real-host logs** (2026-09-22/23) |
| mainland-China VPS | client deployment | **user verbal confirmation** — no logs reviewed here |
| Japan IPv6-only VPS | client deployment on an IPv6-only host | **user verbal confirmation** — no logs reviewed here |

Nothing in this table substitutes for §2: the three real-Squid containers are
the only **automated** verification of the proxy behaviour.

## 3. PARTIAL — implemented, but not verified the way production needs

1. **`ufw` behaviour** is tested against a stub with a faithful rule database.
   Real `ufw delete <number>` / comment-marker semantics still deserve one
   manual confirmation on a scratch VM.
2. **Certificate material**: `--cert-source` and the Certbot deploy hook are
   implemented and unit-tested; no real `certbot` run has been executed (no
   credentials in this environment), and a *public* CA (Let's Encrypt) has not
   been exercised end to end (CI uses a private test CA installed in the
   container trust store). Issuance **and a renewal cycle** remain unverified.
3. **Fresh server install against real Squid** (certificate + `https_port` +
   reload + health checks end to end) is not yet an integration test.
4. **`--migrate-global-env` end to end** is unit-tested only.
5. **`only-v6` scenario**: a Japan IPv6-only VPS runs the client successfully
   (user verbal confirmation, 2026-09-23 — no logs reviewed here), and P0.5's
   family selection pins an IPv6 peer that really answered a probe. There is no
   automated IPv6-only test.
6. **Mainland-China scenario**: a CN VPS runs the client successfully (user
   verbal confirmation — no logs reviewed here). The onboarding one-liner
   downloads *through* the gateway, so `raw.githubusercontent.com` is
   reachable. There is no automated CN test.
7. **GitHub Release asset hosts**: the destination list covers
   `.githubusercontent.com` and `.githubassets.com`; no live release download has
   been exercised, so an extra redirect host would need
   `ghproxyctl domains add <exact-host>` (procedure documented).
8. **The restart escalation path** (reload → confirmed cycle → restart fallback)
   is exercised by the service-manager shim, but the *adopted* policy (refuse
   without `--restart-if-needed`) has not been triggered by a real
   unconfirmable reload; it is unit-tested at the policy level.
9. **Uninstall / restore** (`uninstall.sh client|server`, `ghproxyctl migrate
   restore`) is unit-tested — including byte-for-byte rollback of a failed
   install and of a failed migration — but has not been rehearsed on a real
   host.

## 4. TODO — not started

1. **The remaining real-host verifications**: a fresh server install end to end
   with a real Certbot issuance and renewal cycle on a scratch VPS, and an
   uninstall/restore rehearsal on a scratch VPS. (Already done: the production
   gateway adoption + repair, §2.3; the London client pilot, §2.4–2.5.)
2. **Documentation**: `docs/DOMAINS.md` (provenance of every allowed host),
   `docs/TROUBLESHOOTING.md`, `docs/RUNBOOK.md` (server/client/uninstall/
   rollback procedures, plus the reload-vs-restart rule and the "server-side
   `client add` first" ordering for onboarding), `tests/README.md`.
3. **Convenience features** deliberately left out of v1: systemd timer for a
   periodic `ghproxyctl test`, `ghproxyctl client rotate`, Prometheus/JSON
   output, `--json` for status.
4. **Automated coverage for the only-v6 and mainland-China paths** (the real
   runs in §2.5 are operator evidence, not tests).

## 5. Open defects / risks

1. **`hc_upstream_whitelist_check` aborts adoption** when the remote gateway has
   not authorised the client's egress IP yet. Intentional (it prevents a
   half-migrated host), but it means the server-side `ghproxyctl client add`
   must happen first — to be documented in the runbook.
2. **`ghproxyctl client remove` refuses for adopted clients** (it will not
   rewrite a file it does not own). Operators edit their own ACL file and then
   run `ghproxyctl client forget <name>` — to be documented in the runbook.
3. **No `--json`/machine-readable output** yet, so orchestration from another
   tool has to parse human text.
4. **Reload result detection depends on the cache log**: the barrier needs a
   readable `cache_log` with a `Reconfiguring Squid Cache` line. If a host
   suppresses reconfigure logging, the tool reports that it cannot confirm the
   reload (and, on an adopted server, rolls back) — deliberately conservative.
5. **Migration backups are per-apply**: `migrations/backups/<name>.bak` is
   overwritten by every apply of a component, so `migrate restore` — and an
   automatic rollback — returns that component to its state before the *last*
   apply, not before the first. Deliberate for transactional rollback
   (documented in SECURITY.md §5); worth knowing before re-running a migration
   twice in a row.

## 6. Reload semantics verified with real Squid (why the code looks like it does)

1. `https_port <port> tls-cert=…` **terminates TLS** and serves CONNECT;
   `http_port <port> tls-cert=…` is accepted but stays **plaintext**
   (`Accepting HTTP Socket connections`). The gateway template therefore uses
   `https_port`, and `hc_tls_verify` requires a real, verified peer certificate.
2. A configuration error during a reload makes Squid **exit**
   (`FATAL: Bungled … Terminated abnormally`), so candidates are always
   `squid -k parse`-validated before they are installed, and a rollback brings
   the daemon back if it is gone.
3. **A delivered signal is not proof of a completed reload.** Squid closes and
   re-opens its listeners while reconfiguring, and a probe sent too early sees
   the old configuration - which is exactly what produced the earlier (wrong)
   conclusion that a reload cannot pick up a new `include` file. With the
   completion barrier in place (`squid_wait_reconfigure_complete`: a *new*
   `Reconfiguring Squid Cache` line after the recorded cache-log offset, no
   `FATAL`/`Bungled`, listener accepting again, same PID, daemon alive) a reload
   **does** pick up newly created `conf.d` files, as the documentation says.
4. A stale or foreign pid file must never be used: `squid -k reconfigure` would
   start a *second* instance that fights over the listening ports (and Squid then
   refuses to start at all while a stale pid file exists). The reload path
   validates the pid (`/proc/<pid>/cmdline` must be a squid for that
   configuration), refuses a daemon that ignores SIGHUP, clears a provably stale
   pid file before a restart, and never uses `squid -k reconfigure`.
5. Squid **ANDs** the ACL names on one `http_access` line. Several per-client
   source ACLs in one rule means "a source that is both", i.e. nothing. The
   source ACL is therefore a single file-backed ACL whose entries are ORed.

## 7. Bugs found and fixed by testing and real-host use (so far)

1. **`https_port`, not `http_port`, for the TLS listener** (critical). Squid
   accepts `http_port <port> tls-cert=…` but keeps the listener **plaintext**;
   the gateway hop would have been unencrypted.
2. **Squid ANDs ACL names in one `http_access` rule** (critical). The generated
   `http_access allow <client-a> <client-b> <domain-acl>` could never match, so
   with two or more clients every managed client was denied. The source ACL is
   now a single file-backed list.
3. **`hc_tls_verify` false positive**: `openssl s_client` prints
   `Verify return code: 0 (ok)` even when the handshake failed, so a plaintext
   listener was reported healthy.
4. **Reload race / false confirmation**: the health check ran right after the
   signal and treated "the port still answers" as success. Reloads are now
   confirmed through the cache log with a proper completion barrier.
5. **Rollback ordering**: the journal replays in reverse, so a recorded reload
   ran before the restored files were in place; the rollback now reloads once
   more at the end and restarts the unit if the daemon died.
6. **Silent aborts**: `install.sh`/`ghproxyctl` now install an EXIT guard that
   rolls back and reports when the process ends non-zero with an open change.
7. **Adopted servers keep their own destination policy**: the "non-GitHub must
   be refused" check is informational on an adopted server, a hard failure only
   on a fresh install this project owns.
8. **Inventory was outside the transaction**: a rolled-back `client add` left the
   client in `clients.db`, so the next render reintroduced it. The inventory is
   now part of the transaction.
9. **A failed rollback could leave the proxy down**: Squid exits on a
   configuration error during a reload, so the rollback path now verifies a
   daemon is running and restarts the unit when needed.
10. **Stale/foreign pid files** could make `squid -k reconfigure` start a second
    instance, and Squid refuses to start while a stale pid file exists; both are
    handled explicitly now.
11. **Test-harness bugs**: leaked Squid processes (PIDs recorded inside a command
    substitution), test domain not resolvable for the health checks, the test CA
    not trusted like Let's Encrypt is, a service-manager shim whose restarted
    daemon could not bind the ports, and a probe whose config rewrite produced a
    bungled file (misread as a SIGHUP problem).
12. **The policy audit treated `http_access deny all` as an open proxy** (false
    positive on every production configuration). The check now decides token by
    token: only a literal `http_access allow all` is dangerous. Found by the
    second real production dry-run.
13. **The discovery temporary file path was printed to the user.** The collector
    no longer prints it, the report is read back through `server_discovery_print`,
    the file is removed after the report (and on re-collection).
14. **`systemctl list-timers` was suppressed under `--dry-run`**, so a host
    running `certbot.timer` showed an empty renewal-timer section. Read-only
    queries (`list-timers`) now run for real; mutating verbs remain blocked and
    are covered by a unit test.
15. **The Komari Token was printed in the client dry-run report** (P0.3). The
    report showed the raw `ExecStart`, truncated with `cut -c1-120` - truncation
    is not redaction, and the token sits in the middle of the line. The report
    now prints only an allowlisted summary (`ExecStart: detected (redacted)`,
    `Endpoint`/`Token`: `detected, value hidden`); the raw argv is never printed
    in any form. Values shown elsewhere pass through URL-credential redaction.
16. **The dry-run claimed state it never wrote** (P0.3): it said "current proxy
    references recorded in `/etc/vps-gateway-manager/state/`" while only writing
    and deleting a temporary file. The wording is now "inspected (read-only;
    nothing persisted)" in dry-run, and no path under `state/` is claimed.
17. **The upstream whitelist pre-check was skipped in dry-run** (P0.3). It is a
    read-only, TLS-verified GitHub request through the upstream, so it now runs
    in dry-run too and reports 200/403/407/000 explicitly; a failed probe makes
    the dry-run exit non-zero instead of silently succeeding. The whitelist
    itself is never modified - that stays a server-side operator action.
18. **`curl` printing `000` and exiting non-zero produced `000000`** in the
    client probe results (P0.3), because a fallback appended a second `000`.
    The probe value is now sanitised to exactly one status code.
19. **Several adopted clients sharing one ACL name collapsed into one row**
    (P0.4, broke the first formal adoption). `clients_db_add` deduplicated by
    display name, so six addresses of `allowed_clients` overwrote each other.
    `clients_unique_import_identity` now assigns unique display names and
    acl_ids and is shared by the adoption plan, the adoption import and
    `client reimport`; the database replaces a row only for the same CIDR and
    refuses a name/acl_id that belongs to a different address.
20. **The managed file redefined the operator's destination ACL** (P0.4). Squid
    unions repeated `acl <name>` definitions, so defining `github_dst` with the
    project list would have extended the operator's own rules with `.github.io`
    on the next reload. The managed file now defines a project-owned ACL
    (`gsp_managed_github`), the operator name is recorded separately
    (`operator_domain_acl_name`) and is never redefined.
21. **`status` lost the detected Squid and the live firewall** (P0.4).
    `server_state_load` restored neither `squid_bin/version/flavor/pkg` (so the
    Squid line printed empty) and `gp_status_server` never called `fw_detect`
    (so a running UFW was reported as `backend=none`). Both are fixed and pinned
    by a state round-trip test and a status test.
22. **A stale recorded Squid binary path broke validation** (P0.4).
    `squid_parse` used the recorded path even when it no longer existed; it now
    re-detects the binary when the path is not executable.
23. **`cache_peer <dual-stack-hostname>` is not deterministic when one family is
    blackholed** (P0.5, broke the first London client pilot): GitHub API/Raw
    got `HIER_NONE/000` while Release passed. Fixed by pre-install family
    selection (`auto|4|6`) with probe-verified candidate pinning
    (`upstream_peer_address`) and `ssldomain=` keeping the logical TLS name;
    `client upstream refresh` handles later DNS/path changes.
24. **The rollback unconditionally enabled the system squid unit** (P0.5).
    The package side-effect cleanup journaled `systemctl enable squid` as its
    undo, so a failed install left a unit enabled that had been absent or
    disabled before. The pre-install state (enabled/disabled/active/absent) is
    now captured and restored exactly, with tests for all four states.
25. **A one-family failure was reported as an authorisation warning** (P0.5).
    "Authorise both exact host addresses" was printed whenever exactly one
    family passed — including when the other family was a 000 transport
    failure. Classification is now strict: 000 = TRANSPORT UNAVAILABLE,
    403/407 = REACHED BUT REFUSED (with the server-side fix), 200 = PASS.
26. **A TLS failure could be misreported as transport** (P0.5). When
    `-verify_return_error` aborts the handshake (expired or wrong-name
    certificate) there may be no final `Verify return code:` line; the probe
    now classifies any verify-error output as CERTIFICATE VERIFICATION FAILED
    and only a handshake with no verification output at all as transport.
27. **The client service journal recorded undo verbs, so a rollback re-enabled
    and re-started the local proxy** (P0.5, found by the new rollback tests).
    The engine records FORWARD actions and inverts them (`server-ops` does it
    correctly), but `client_start_service` journaled `disable`/`stop` after
    enabling/starting — a failed install left the proxy enabled and running
    with its files deleted. It now records `enable`/`start` (and only journals
    `enable` when the unit was not enabled before).
28. **Client state writes were not journaled** (P0.5). `role`, `version`,
    `client.conf` and the destination list survived a rollback via plain
    writes; they are now transactional (and the log/spool/runtime directories
    are backed up instead of only `rmdir`-ed when empty), so a failed install
    leaves the host exactly as unconfigured as it was.
29. **Komari's Ping/ICMP monitoring was mistaken for a proxy failure** (found
    on the real London host after the P0.5 pilot). `migrate_komari_verify`
    treated *any* `i/o timeout` as a proxy/TLS error and judged a 180s window
    that included the previous PID's logs, so `migrate komari` rolled back a
    healthy agent (`Ping i/o timeout` is Komari monitoring a target; the panel
    path was proven by `WebSocket connected`). Ping/ICMP monitor lines are now
    excluded — only when they say nothing about the websocket/proxy transport —
    verification judges only the post-restart process (restart timestamp +
    `MainPID`, fail-safe when either is unknown), and every real failure class
    (x509 / proxyconnect / reset / websocket failures and non-monitor
    timeouts) still fails and rolls back.
30. **IPv6 validation was a charset check, and the v4-mapped form crashed the
    expander silently** (release audit). `:::`, `1::2::3`, `12345::1`,
    `1:2:3:4:5:6:7` and a lone `:` were accepted as IPv6, and `::ffff:1.2.3.4`
    made bash evaluate `$((16#1.2.3.4))` — the error went to stderr while the
    test still reported PASS. Both the grammar and the test (which now asserts
    clean stderr) are fixed.
31. **`install.sh --ref` could not pin a tag or a commit** (release audit). The
    bootstrap only knew `archive/refs/heads/<ref>` and guessed the extracted
    directory name (`repo-$ref`), while GitHub strips the leading `v` from tag
    archives and names commit archives by SHA.
32. **`ghproxyctl domains add --force` could allow a whole shared CDN
    platform** (release audit). The flag bypassed the platform check entirely,
    so `.amazonaws.com` or `.cloudfront.net` would have been authorised. The
    policy is now enforced: platform suffixes/roots and multi-tenant service
    endpoints (`s3.amazonaws.com`, regional `s3.*`) are refused unconditionally,
    and `--force` approves only ONE exact resource host.
