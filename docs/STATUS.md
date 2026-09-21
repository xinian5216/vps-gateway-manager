# Implementation status

Snapshot taken when development was paused to hand the repository over.
Everything below is verified by `bash tests/run.sh unit` (9 suites,
**386 assertions, all passing**) plus `bash tests/check.sh` (syntax, ShellCheck,
policy greps — clean).

Legend: **DONE** = implemented and covered by unit tests ·
**PARTIAL** = implemented but not verified the way it must be before production ·
**TODO** = not started.

---

## 1. DONE — verified by unit tests

| Area | What exists | Verification level |
|------|-------------|--------------------|
| Repository layout | `install.sh`, `uninstall.sh`, `bin/ghproxyctl`, `lib/`, `templates/`, `tests/`, `.github/workflows/ci.yml`, `README.md`, `SECURITY.md`, `CHANGELOG.md`, `LICENSE` | implemented |
| Project identity | `vps-gateway-manager` everywhere: state dir `/etc/vps-gateway-manager`, unit `vps-gateway-manager-client.service`, `/etc/profile.d/vps-gateway-manager.sh`, `/etc/sudoers.d/vps-gateway-manager`, `/var/log|run|spool/vps-gateway-manager`, env prefix `VGM_*`; `ghproxyctl` keeps its name | implemented |
| Validation | exact `/32` and `/128` only, `/64`/`/0` refused, wildcards refused, shared CDN suffixes refused, strict upstream URL parsing | **unit-tested** |
| Transaction engine | backup → atomic write → reload → verify → health check → commit/rollback; TAB journal; reverse replay; restores files, directories, firewall rules, service actions; brings the daemon back if a reload killed it | **unit-tested** + integration (rollback scenario) |
| Fresh server install | Squid detection (`squid-openssl`, ≥5 with TLS), `https_port … tls-cert=` (see §6), loopback-only plain port, GitHub destination ACL, one file-backed source ACL, final `deny all`, UFW integration, Certbot deploy hook, generated-config validation before any write, rollback on failed health check | **unit-tested**; not yet executed end-to-end against real Squid |
| Adoption | read-only discovery report, client import (node names from comments), destination import, `00-`-prefixed additive conf.d file with **no** deny rule, no reload/restart during adoption, byte-identical operator files, blanket-deny ordering check | **integration-tested, 88/88 blocking** (see §2) |
| Client install | own Squid config/pid/logs/spool/unit, loopback-only listeners, `cache_peer … tls tls-cafile=`, `never_direct` for GitHub, everything else DIRECT, an unrelated `squid`/`xray`/`3x-ui` untouched | **unit-tested**; the *chain itself* (client Squid → TLS parent → GitHub) is **integration-tested** in `01-routing.sh` |
| Client environment | profile.d with NO_PROXY merge (existing entries preserved, deduped), sudoers validated with `visudo -cf` + `visudo -c`, GitHub-only git config with recorded previous values | **unit-tested** |
| Migration | Komari (only the 4 proxy vars + NO_PROXY; Endpoint/Token/ExecStart untouched; `EnvironmentFile=` refused; journal-based verification; automatic restore on failure), xray-manager, git, `/etc/environment` behind `--migrate-global-env`, unknown units reported and migrated only on request | **unit-tested**; not yet executed on a real client |
| Restore / uninstall | `ghproxyctl migrate restore`, `uninstall.sh client|server`, adopted servers are only *unmanaged* | **unit-tested** |
| Route proof | health checks read the Squid access log and assert `FIRSTUP_PARENT/…` for GitHub vs `HIER_DIRECT/…` for everything else | **integration-tested** (`01-routing.sh`) |
| CI | `shellcheck + unit tests`, `integration (real squid, Debian bookworm)`, `integration (real squid, Ubuntu 24.04)` | see §2 for the current state |
| Tests | 9 unit suites (ShellCheck clean, all green) + 3 integration suites + a service-manager shim | — |

## 2. Integration suite (real Squid) — current state

`tests/integration/` runs as a **blocking** CI gate in two containers (Debian
bookworm, squid-openssl 5.7; Ubuntu 24.04, 6.14). Latest run: all jobs green.

| Suite | Debian 5.7 | Ubuntu 6.14 | What it proves |
|-------|-----------|-------------|----------------|
| `00-squid-capabilities.sh` | 17/17 | 17/17 | which listener directive terminates TLS, reload semantics (incl. that a reload DOES pick up a newly created include file once the reconfigure cycle is confirmed), that a stale/foreign pid file is refused instead of starting a second instance |
| `01-routing.sh` | 28/28 | 28/28 | TLS handshake with a verified certificate, CONNECT over TLS, GitHub through the TLS parent (`FIRSTUP_PARENT`), everything else `HIER_DIRECT`, listed source served, unlisted source refused, non-GitHub refused, untrusted parent certificate never produces a tunnel |
| `02-adoption.sh` | 88/88 | 88/88 | adopting a *running* production proxy: additive only, operator files byte-identical, clients imported, one file-backed source ACL, two managed clients both served (AND-bug regression), removing one keeps the other, a strict operator file cannot shadow managed clients, reloads keep the daemon process, a failed health check rolls back with daemon/files/process table in agreement |

Both integration jobs fail the workflow when any assertion fails; the adoption
step is **not** `continue-on-error`.

## 3. PARTIAL — implemented, but not verified the way production needs

1. **`ufw` behaviour** is tested against a stub with a faithful rule database.
   Real `ufw delete <number>` / comment-marker semantics still deserve one
   manual confirmation on a scratch VM.
2. **Certificate material**: `--cert-source` and the Certbot deploy hook are
   implemented and unit-tested; no real `certbot` run has been executed (no
   credentials in this environment), and a *public* CA (Let's Encrypt) has not
   been exercised end to end (CI uses a private test CA installed in the
   container trust store).
3. **Fresh server install against real Squid** (certificate + `https_port` +
   reload + health checks end to end) is not yet an integration test.
4. **`--migrate-global-env` end to end** is unit-tested only.
5. **`only-v6` scenario** is designed (loopback-only listeners, `cache_peer` by
   name so AAAA is used, `[::1]` listener when IPv6 loopback exists) but not
   executed on an IPv6-only host.
6. **Mainland-China scenario** is designed (the onboarding one-liner downloads
   *through* the gateway, so `raw.githubusercontent.com` is reachable) but not
   executed on a CN VPS.
7. **GitHub Release asset hosts**: the destination list covers
   `.githubusercontent.com` and `.githubassets.com`; no live release download has
   been exercised, so an extra redirect host would need
   `ghproxyctl domains add <exact-host>` (procedure documented).
8. **The restart escalation path** (reload → confirmed cycle → restart fallback)
   is exercised by the service-manager shim, but the *adopted* policy (refuse
   without `--restart-if-needed`) has not been triggered by a real
   unconfirmable reload; it is unit-tested at the policy level.

## 4. TODO — not started

1. **Production dry-runs** on `gh.xinian5216.com` and one non-critical Komari
   node (read-only). No production host has been touched from this work.
   The commands are in the repository README and in §7 below.
2. **Documentation**: `docs/DOMAINS.md` (provenance of every allowed host),
   `docs/TROUBLESHOOTING.md`, `docs/RUNBOOK.md` (server/client/uninstall/
   rollback procedures, plus the reload-vs-restart rule and the "server-side
   `client add` first" ordering for onboarding), `tests/README.md`.
3. **Convenience features** deliberately left out of v1: systemd timer for a
   periodic `ghproxyctl test`, `ghproxyctl client rotate`, Prometheus/JSON
   output, `--json` for status.
4. **`only-v6` and mainland-China runs** on real hosts.

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

## 7. Bugs found and fixed by the integration suite (so far)

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

1. **`http_port … tls-cert=` is not a TLS listener** (critical). Squid accepts
   the option, logs *"Accepting HTTP Socket connections"* and keeps the port
   plaintext; the gateway hop would have been unencrypted. The template now uses
   `https_port`, and `tests/integration/00-squid-capabilities.sh` pins it on
   Squid 5.7 and 6.14.
2. **Health-check TLS false positive**: `openssl s_client` prints
   `Verify return code: 0 (ok)` even when the handshake failed, so a plaintext
   listener was reported healthy. The check now requires a real, verified
   peer certificate.
3. **Reload race**: the health check ran immediately after the reload, and Squid
   closes/reopens its listeners while reconfiguring, so a good change could be
   rolled back by a spurious "connection refused". `wait_for_port` now waits for
   a real TCP connect (via curl) before the checks run.
4. **Rollback ordering**: the journal replays in reverse, so a recorded reload
   ran before the files were restored, leaving the daemon on a configuration
   that no longer matched the disk. The rollback now reloads once more at the end.
5. **Silent aborts**: `install.sh`/`ghproxyctl` now install an EXIT guard that
   rolls back and reports if the process ends non-zero with an open transaction.
6. **Adopted servers kept their own policy**: the "non-GitHub must be refused"
   check is now informational on an adopted server (an operator's config may
   legitimately allow loopback to reach anything) and a hard failure only on a
   fresh install we own.
7. **Reload replaced the daemon**: a stale pid file makes
   `squid -k reconfigure` start a new instance instead of signalling the running
   one; `squid_reload` now detects a PID change and warns.
8. **Test-harness bugs**: leaked Squid processes (PIDs recorded inside a command
   substitution), test domain not resolvable for the health checks, and the test
   CA not trusted like Let's Encrypt is on a real host.
