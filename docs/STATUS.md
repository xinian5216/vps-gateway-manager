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
| Fresh server install | Squid detection (`squid-openssl`, ≥5 with TLS), `https_port … tls-cert=` (see §6), loopback-only plain port, GitHub destination ACL, per-client ACL file, final `deny all`, UFW integration, Certbot deploy hook, generated-config validation before any write, rollback on failed health check | **unit-tested**; not yet executed end-to-end against real Squid |
| Adoption | read-only discovery report, client import (node names from comments), destination import, `00-`-prefixed additive conf.d file with **no** deny rule, no reload/restart during adoption, byte-identical operator files, blanket-deny ordering check | **integration-tested** (see §2) |
| Client install | own Squid config/pid/logs/spool/unit, loopback-only listeners, `cache_peer … tls tls-cafile=`, `never_direct` for GitHub, everything else DIRECT, an unrelated `squid`/`xray`/`3x-ui` untouched | **unit-tested**; the *chain itself* (client Squid → TLS parent → GitHub) is **integration-tested** in `01-routing.sh` |
| Client environment | profile.d with NO_PROXY merge (existing entries preserved, deduped), sudoers validated with `visudo -cf` + `visudo -c`, GitHub-only git config with recorded previous values | **unit-tested** |
| Migration | Komari (only the 4 proxy vars + NO_PROXY; Endpoint/Token/ExecStart untouched; `EnvironmentFile=` refused; journal-based verification; automatic restore on failure), xray-manager, git, `/etc/environment` behind `--migrate-global-env`, unknown units reported and migrated only on request | **unit-tested**; not yet executed on a real client |
| Restore / uninstall | `ghproxyctl migrate restore`, `uninstall.sh client|server`, adopted servers are only *unmanaged* | **unit-tested** |
| Route proof | health checks read the Squid access log and assert `FIRSTUP_PARENT/…` for GitHub vs `HIER_DIRECT/…` for everything else | **integration-tested** (`01-routing.sh`) |
| CI | `shellcheck + unit tests`, `integration (real squid, Debian bookworm)`, `integration (real squid, Ubuntu 24.04)` | see §2 for the current state |
| Tests | 9 unit suites (ShellCheck clean, all green) + 3 integration suites + a service-manager shim | — |

## 2. Integration suite (real Squid) — current state

`tests/integration/` runs in CI in two containers (Debian bookworm, squid-openssl
5.7; Ubuntu 24.04, 6.14). Levels:

* `00-squid-capabilities.sh` — **verified** (real Squid, both versions):
  * `https_port … tls-cert=` terminates TLS and serves both a plain GET and
    CONNECT; `http_port … tls-cert=` stays **plaintext** (see §6)
  * `squid -k reconfigure` keeps the daemon alive; `http_port … ssl-bump` does
    not come up
  * a direct `kill -HUP` reloads a running daemon (SIGCGT/SigIgn evidence)
  * a reload does **not** pick up a *newly created* file in an `include` glob
    (a restart does) — this is why the tool escalates to a restart
  * `squid_reload` refuses a stale/foreign pid file and does not start a second
    instance
* `01-routing.sh` — **verified** (27 assertions, green on both versions):
  TLS handshake with a verified certificate, CONNECT over TLS, GitHub through
  the TLS parent (`FIRSTUP_PARENT` in the access log), everything else
  `HIER_DIRECT`, a listed source served, an unlisted source refused on both
  listeners, a non-GitHub destination refused, an untrusted parent certificate
  never producing a tunnel
* `02-adoption.sh` — **integration-tested but not yet a blocking gate**:
  adopting a *running* production proxy (additive changes only, operator files
  byte-identical, clients imported, no deny rule in the managed file, no reload
  during adoption, `client add` taking effect through a real reload/restart,
  a failed health check rolling back with the daemon and the files in agreement,
  no leftover Squid process). The suite is at **46-74 of 76 assertions**
  depending on the run; the remaining failures are in the reload/restart
  escalation, which is the one open item (§2.1). The CI step is not yet
  `continue-on-error`-free for the adoption run.

### 2.1 Open item: the reload → restart escalation

Verified: a reload cannot apply a *new* configuration file, and a restart
applies it. Implementing that escalation exposed a harness problem (the
service-manager shim restarted the daemon into a state where it did not serve)
rather than a product problem — the shim now waits for the ports to be released,
retries the start and verifies the listener. This needs one more green CI run
before the adoption suite can become a blocking gate.

Everything else in the adoption flow is verified.

## 3. PARTIAL — implemented, but not verified the way production needs

1. **`ufw` behaviour** is tested against a stub with a faithful rule database.
   Real `ufw delete <number>` / comment-marker semantics still deserve one
   manual confirmation on a scratch VM.
2. **Certificate material**: `--cert-source` and the Certbot deploy hook are
   implemented and unit-tested; no real `certbot` run has been executed (no
   credentials in this environment), and a *public* CA (Let's Encrypt) has not
   been exercised end to end (CI uses a private test CA installed in the
   container trust store).
3. **`only-v6` scenario** is designed (loopback-only listeners, `cache_peer` by
   name so AAAA is used, `[::1]` listener when IPv6 loopback exists) but not
   executed on an IPv6-only host.
4. **Mainland-China scenario** is designed (the onboarding one-liner downloads
   *through* the gateway, so `raw.githubusercontent.com` is reachable) but not
   executed on a CN VPS.
5. **GitHub Release asset hosts**: the destination list covers
   `.githubusercontent.com` and `.githubassets.com`; no live release download has
   been exercised, so an extra redirect host would need
   `ghproxyctl domains add <exact-host>` (procedure documented).
6. **Fresh server install against real Squid** (certificate + `https_port` +
   health checks end to end) is not yet an integration test.
7. **`--migrate-global-env` end to end** is unit-tested only.

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

1. **Reload → restart escalation needs one green CI run** (§2.1). It is the only
   known open functional item.
2. **`hc_upstream_whitelist_check` aborts adoption** when the remote gateway has
   not authorised the client's egress IP yet. Intentional (it prevents a
   half-migrated host), but it means the server-side `ghproxyctl client add`
   must happen first — to be documented in the runbook.
3. **`ghproxyctl client remove` refuses for adopted clients** (it will not
   rewrite a file it does not own). Operators edit their own ACL file and then
   run `ghproxyctl client forget <name>` — to be documented in the runbook.
4. **No `--json`/machine-readable output** yet, so orchestration from another
   tool has to parse human text.
5. **Adoption does not reload**, by design. Because a reload cannot pick up a
   newly created configuration file, the **first `client add` after adoption
   restarts Squid once** (verified by the capability probe). This should be
   stated in the adoption report and the runbook.

## 6. Reload semantics discovered with real Squid (why the code looks like it does)

1. `https_port <port> tls-cert=…` **terminates TLS** and serves CONNECT;
   `http_port <port> tls-cert=…` is accepted but stays **plaintext**
   (`Accepting HTTP Socket connections`). The gateway template therefore uses
   `https_port`, and `hc_tls_verify` requires a real, verified peer certificate.
2. A **configuration error during a reload makes Squid exit**
   (`FATAL: Bungled … Terminated abnormally`), so candidates are always
   `squid -k parse`-validated before they are installed, and a rollback brings
   the daemon back if it is gone.
3. Squid re-reads the configuration files it knew about; a file created *after*
   the daemon started (the managed `conf.d` file of a freshly adopted server) is
   **not** picked up by a reload. The tool therefore verifies the daemon's
   effective configuration through the cache manager and escalates to a restart
   when a reload cannot apply the change.
4. A stale or foreign pid file must never be used: `squid -k reconfigure` would
   start a *second* instance that fights over the listening ports. The reload
   path validates the pid (`/proc/<pid>/cmdline` must be a squid for that
   configuration), refuses a daemon that ignores SIGHUP, and never uses
   `squid -k reconfigure`.

## 7. Bugs found and fixed by the integration suite (so far)

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
