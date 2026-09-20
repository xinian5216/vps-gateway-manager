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

1. **Integration tests exist now** (`tests/integration/`, real squid-openssl in
   CI on Debian bookworm and Ubuntu 24.04) and they already found one critical
   bug: `http_port … tls-cert=` does **not** terminate TLS, `https_port` does
   (see the changelog entry and `tests/integration/00-squid-capabilities.sh`).
   Still to cover there: adoption of a running proxy (`02-adoption.sh`, written
   but not yet green), IPv6-only clients and a mainland-China VPS run.
2. **TLS parent chaining is proven** for Squid 5.7 and 6.14: a client Squid with
   `cache_peer … tls tls-cafile=… ssldomain=…` really reaches GitHub through the
   TLS parent (the client access log shows `FIRSTUP_PARENT/…` and the gateway log
   shows the CONNECT), and a parent certificate that does not verify is refused.
   What is still untested is a *public* CA (Let's Encrypt) end to end, because CI
   uses a private test CA.
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

1. **`cache_peer … tls` (see 2.2)** — the highest technical risk in the design.
   Verify before any production client migration.
2. **`hc_upstream_whitelist_check` aborts adoption** when the remote gateway has
   not authorised the client's egress IP yet. That is intentional (it prevents a
   half-migrated host), but it means the server-side `ghproxyctl client add`
   must happen first — document it in the runbook.
3. **`ghproxyctl client remove` refuses for adopted clients** (it will not
   rewrite a file it does not own). Operators must edit their own ACL file and
   then run `ghproxyctl client forget <name>`. Intentional, but it needs to be
   in the runbook.
4. **Naming**: the local working copy is still in a directory called
   `github-smart-proxy`; the repository content, the state directory and every
   path inside are renamed. Only the folder name on the development machine
   remains.
5. **No `--json`/machine-readable output** yet, so orchestration from another
   tool has to parse human text.

## 5. Suggested order for the next session

1. Write `.github/workflows/ci.yml` (shellcheck + unit) and let it go green —
   this also validates the tests on Linux, since development happened on
   Windows/Git Bash where file modes cannot be asserted.
2. Write `tests/integration/01-routing.sh`: real `squid-openssl`, parent + client
   pair on loopback, real `curl`, assert 200/403 and the access-log hierarchy
   tags. This closes gap 2.1 and answers the `cache_peer … tls` question (2.2).
3. If TLS-parent chaining works, proceed to the real-host dry-runs:
   `server --adopt-existing --dry-run` on `gh.xinian5216.com`, then one
   non-critical Komari node with `client --adopt-existing --dry-run`.
4. Only after both dry-runs are reviewed: real adoption, then a staged client
   rollout (one node, observe, then the rest).
