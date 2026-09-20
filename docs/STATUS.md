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

| Area | What exists |
|------|-------------|
| Repository layout | `install.sh`, `uninstall.sh`, `bin/ghproxyctl`, `lib/`, `templates/`, `tests/`, `README.md`, `SECURITY.md`, `CHANGELOG.md`, `LICENSE` |
| Project identity | renamed to `vps-gateway-manager` everywhere: state dir `/etc/vps-gateway-manager`, unit `vps-gateway-manager-client.service`, `/etc/profile.d/vps-gateway-manager.sh`, `/etc/sudoers.d/vps-gateway-manager`, `/var/log|run|spool/vps-gateway-manager`, env prefix `VGM_*`; `ghproxyctl` keeps its name |
| Validation | exact `/32` and `/128` only, `/64`/`/0` refused, wildcards refused, shared CDN suffixes refused, strict upstream URL parsing (no credentials, no path) |
| Transaction engine | backup → atomic write → reload → health check → commit/rollback; TAB journal; reverse replay; restores files, directories, firewall rules, service actions |
| Fresh server install | Squid detection (`squid-openssl`, ≥5 with TLS), `http_port … tls-cert=`, loopback-only plain port, GitHub destination ACL, per-client ACL file, final `deny all`, UFW integration, Certbot deploy hook, generated-config validation before any write, rollback on failed health check |
| Adoption | read-only discovery report, client import (node names from comments), destination import, `00-`-prefixed additive conf.d file with **no** deny rule, no reload/restart, byte-identical operator files verified in tests, blanket-deny ordering check |
| Client install | own Squid config/pid/logs/spool/unit, loopback-only listeners, `cache_peer … tls tls-cafile=`, `never_direct` for GitHub, everything else DIRECT, no touching of an existing `squid`/`xray`/`3x-ui` |
| Client environment | profile.d with NO_PROXY merge (existing entries preserved, deduped), sudoers validated with `visudo -cf` + `visudo -c`, GitHub-only git config with recorded previous values |
| Migration | Komari (only the 4 proxy vars + NO_PROXY; Endpoint/Token/ExecStart untouched; `EnvironmentFile=` refused; journal-based verification; automatic restore on failure), xray-manager `download_proxy`, git, `/etc/environment` behind `--migrate-global-env`, unknown units reported and migrated only on request |
| Restore / uninstall | `ghproxyctl migrate restore`, `uninstall.sh client|server`, adopted servers are only *unmanaged* |
| Route proof | health checks read the Squid access log and assert `FIRSTUP_PARENT/...` for GitHub vs `HIER_DIRECT/...` for everything else |
| Tests | 9 unit suites + harness + 8 command stubs + policy greps |

## 2. PARTIAL — implemented, but not yet verified in the way production needs

1. **Integration suite (real Squid) — routing green, adoption in progress.**
   `tests/integration/` runs in CI on Debian bookworm (squid-openssl 5.7) and
   Ubuntu 24.04 (6.14):
   * `00-squid-capabilities.sh` — 11/11: pins which directive really terminates
     TLS and that `-k reconfigure` keeps the daemon alive
   * `01-routing.sh` — 27/27: TLS handshake with a verified certificate, CONNECT
     over TLS, GitHub through the TLS parent (`FIRSTUP_PARENT`), everything else
     `HIER_DIRECT`, a listed source served, an unlisted source refused on both
     listeners, an untrusted parent certificate never producing a tunnel
   * `02-adoption.sh` — 39/45 and **non-blocking**: adoption itself is verified
     (operator files byte-identical, clients imported, no deny rule in the
     managed file, no reload during adoption, client add takes effect and is
     served), but the last scenarios (a deliberately injected
     `http_access deny all` in the operator file, and the following
     `client remove`) fail in a **container without systemd**, where the reload
     falls back to `squid -k reconfigure`. A stale pid file makes that command
     start a *new* instance instead of signalling the running one, and the
     daemon stops answering. `squid_reload` now detects and warns about a PID
     change, but the container path needs a proper fix (see below).
2. **TLS parent chaining is proven** for Squid 5.7 and 6.14 (client
   `cache_peer … tls tls-cafile=… ssldomain=…` → GitHub through the parent).
   What is still untested is a *public* CA (Let's Encrypt) end to end, because CI
   uses a private test CA installed into the container trust store.
3. **Certificate material.** `--cert-source` and the Certbot deploy hook are
   implemented and unit-tested, but no real `certbot` run has been executed
   (no credentials available here). The hook's `squid -k parse` guard is tested;
   the actual issuance path is not.
4. **`ufw` behaviour** is tested against a stub with a faithful rule database.
   Real `ufw delete <number>` / comment-marker semantics still deserve one
   manual confirmation on a scratch VM.
5. **`only-v6` scenario** is designed (loopback-only listeners, `cache_peer` by
   name so AAAA is used, `[::1]` listener when IPv6 loopback exists) but not
   executed on an IPv6-only host.
6. **Mainland-China scenario** is designed (the onboarding one-liner downloads
   *through* the gateway, so `raw.githubusercontent.com` is reachable) but not
   executed on a CN VPS.
7. **GitHub Release asset hosts.** The destination list covers
   `.githubusercontent.com` and `.githubassets.com`; if a specific release
   redirects to an extra host, the documented procedure is
   `ghproxyctl domains add <exact-host>`. No live release download has been
   exercised yet.

### 2.1 Open item with a clear next step

The container reload path (`squid -k reconfigure` without systemd) must either
be made robust (e.g. verify the pid file points at the *running* daemon before
using it, and fall back to `squid -k restart` when it does not) or the adoption
suite must run against a real systemd (a VM, not a container job). Everything
else in the adoption flow is already verified.

## 3. TODO — not started

1. **CI workflow** (`.github/workflows/ci.yml`): shellcheck + `tests/run.sh unit`
   on every push, and the integration job from item 2.1 in a Debian container.
   The tests are ready to run; the workflow file is not written.
2. **Integration test suites**: `tests/integration/*.sh` (routing, TLS, adoption
   with a real Squid, only-v6, rollback against a real service).
3. **Production dry-run** on `gh.xinian5216.com`: `install.sh server
   --adopt-existing --dry-run` has never been executed against the real host
   (no SSH access from the development machine). The read-only report and the
   plan are implemented; they need one run on the real server.
4. **Client dry-run / real migration** on a non-critical Komari node, then a
   staged rollout.
5. **Documentation**: `docs/DOMAINS.md` (provenance of every allowed host),
   `docs/TROUBLESHOOTING.md`, `docs/RUNBOOK.md` (server/client/uninstall/
   rollback procedures), `tests/README.md`.
6. **Convenience features** deliberately left out of v1: systemd timer for a
   periodic `ghproxyctl test`, `ghproxyctl client rotate`, Prometheus/JSON
   output, `--json` for status.

## 4. Known defects / risks to look at first

These are real findings from the test suite, not hypotheticals:

1. **Container reload path (see 2.1)** — the only open functional item.
2. **`hc_upstream_whitelist_check` aborts adoption** when the remote gateway has
   not authorised the client's egress IP yet. That is intentional (it prevents a
   half-migrated host), but it means the server-side `ghproxyctl client add`
   must happen first — document it in the runbook.
3. **`ghproxyctl client remove` refuses for adopted clients** (it will not
   rewrite a file it does not own). Operators must edit their own ACL file and
   then run `ghproxyctl client forget <name>`. Intentional, but it needs to be
   in the runbook.
4. **Naming**: the repository folder is `vps-gateway-manager`; the state
   directory, unit names and every path inside the project use the new name.
5. **No `--json`/machine-readable output** yet, so orchestration from another
   tool has to parse human text.

## 5. Suggested order for the next session

1. Fix the container reload path (see 2.1): verify that the pid file points at
   the running daemon before using `squid -k reconfigure`, and fall back to a
   restart when it does not. Then make `02-adoption.sh` blocking in CI.
2. Add the remaining integration scenarios: an `install.sh server` fresh install
   against real Squid (with a real reload and a real health check), an IPv6-only
   listener/upstream run, and `/etc/environment` migration via
   `--migrate-global-env`.
3. Real-host dry-runs, in this order:
   * `install.sh server --adopt-existing --dry-run` on the production gateway
     (read-only: Squid version, listeners, certificates, hook, ACLs, UFW and
     every existing client)
   * `install.sh client --upstream … --adopt-existing --dry-run` on one
     non-critical Komari node
4. Only after both dry-runs are reviewed: real adoption, then a staged client
   rollout (one node, observe, then the rest).
5. Then the remaining docs (RUNBOOK, DOMAINS, TROUBLESHOOTING) and the periodic
   `ghproxyctl test` timer.

## 6. Bugs found and fixed by the integration suite (this session)

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
