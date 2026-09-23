# AGENTS.md

Bash-only infrastructure project. Shell libraries under `lib/`, templates under
`templates/`, an install/uninstall entry point, one CLI (`bin/ghproxyctl`), and a
test suite that runs both with stubs and against real Squid.

Truth for "is this verified?" lives in `docs/STATUS.md` (per-feature verification
level); `CHANGELOG.md` records what changed and why. Read those before claiming
anything works.

## Commands

```bash
bash tests/check.sh                 # static: bash -n, shellcheck, policy greps
bash tests/run.sh unit              # unit suites (any OS; Git Bash on Windows is fine)
bash tests/run.sh unit 03           # single file by substring
bash tests/run.sh integration       # needs Linux + root + squid-openssl + internet
```

* Local dev happens on Windows (Git Bash at `D:\software\Hermes\git\bin\bash.exe`).
  `shellcheck` is not on PATH there; `tests/check.sh` skips it silently, CI does not.
* CI (`.github/workflows/ci.yml`) has four jobs: `shellcheck + unit tests` and
  three real-Squid integration jobs — `integration (real squid, Debian
  bookworm)` (squid-openssl 5.7), `integration (real squid, Debian trixie)`
  (6.13, the production version) and `integration (real squid, Ubuntu 24.04)`
  (6.14). Each integration job runs `tests/integration/00-squid-capabilities.sh`
  and `01-routing.sh`, then `02-adoption.sh`, `03-production-dry-run.sh`,
  `04-adoption-reconcile.sh` and `05-client-family.sh` (02–05 with
  `if: always()` so an earlier failure does not hide later results).
* Never make a failing suite non-blocking, never add `continue-on-error`, never
  weaken or skip an assertion to get green. If a test fails, fix the cause.

## Development stage and production limits

* Current released milestone: **v0.5.0**. `VERSION`, `CHANGELOG.md` and the
  docs all carry the same version — keep them consistent. Development after
  the release proceeds from `main` through feature/release branches.
* Merging to `main`, creating a tag and publishing a GitHub Release always
  require explicit user authorization; never do any of the three on your own.
* Production hosts are out of bounds for anything mutating: never run
  `install.sh`, `uninstall.sh` or a mutating `ghproxyctl` command against a
  real host from this environment. The only sanctioned production interaction
  is a user-authorized read-only `--dry-run`, executed by the user.
* Never modify a production proxy, a Komari node or the gateway server "to try
  something". Fixes happen here, behind tests; production changes happen only
  after the user explicitly authorizes them.

## Constraints that are easy to break

* **One file-backed source ACL.** Squid *ANDs* the ACL names on a single
  `http_access` line, so `http_access allow client-a client-b domains` can never
  match. Clients live in `managed-clients.acl` (one exact `/32` or `/128` per
  line) referenced by a single `acl gsp_managed_clients src "…"` rule. Never
  generate per-client `acl gsp_c_*` names, never combine two source ACLs.
* **`https_port` for the public TLS listener.** `http_port … tls-cert=` is
  accepted by Squid but stays **plaintext** (`Accepting HTTP Socket connections`).
* **A reload is only done when confirmed.** `squid_wait_reconfigure_complete`
  requires a *new* `Reconfiguring Squid Cache` line after the recorded cache-log
  offset, no `FATAL`/`Bungled`, a listener accepting again, and the same PID.
  A delivered signal or a still-open port proves nothing. Never use
  `squid -k reconfigure` (a stale pid file makes it start a *second* instance);
  validate the PID via `/proc/<pid>/cmdline`, refuse a daemon that ignores SIGHUP.
* **Adopted hosts keep their own lifecycle.** On `mode=adopted`, a reload that
  cannot be confirmed rolls back; restarting requires `--restart-if-needed`.
  Never touch `xray` (443), `x-ui` (4428), the operator's squid.conf, whitelist,
  certificates or certbot hook.
* **Every mutation is transactional**: `txn_begin` → `txn_install_file` /
  `txn_backup_file` → checks → `txn_commit`, and a failed health check rolls back.
  Include *everything* you change (config, ACL file, `clients.db`, firewall, git
  config) or the rollback leaves the host inconsistent.
* **Respect `--dry-run`**: mutating helpers check `gp_dry_run`; `systemctl_cmd`
  suppresses mutating verbs. A dry-run must not reload, restart, write, or touch UFW.
* **No TLS bypass, ever**: no `curl -k`/`--insecure`, `DONT_VERIFY_PEER`,
  `tls-default-ca=off`. Also no blanket grants (`0.0.0.0/0`, `::/0`), no
  `ufw reset/flush`, no `iptables -F`. `tests/check.sh` fails the build on these.
  Legitimate mentions (detection code, docs) need a trailing `# policy-exempt`
  comment; `SECURITY.md` and `tests/` are excluded from those greps.
* **Never run** `install.sh server --adopt-existing` (or any install/uninstall)
  against a real host, and never modify a production proxy or Komari node. Only the
  read-only `--dry-run` is sanctioned, and only by the user.

## Code conventions

* All filesystem paths are built on `$GP_ROOT` (empty on a real host, a sandbox in
  tests). Use the helpers (`gp_state_dir`, `gp_squid_conf_d`, `gp_domains_file`,
  `gp_managed_clients_acl`, `gp_p`, …); hardcoding `/etc/...` breaks the sandbox.
* Logging goes through `log_info/log_warn/log_err/log_ok/log_debug/log_dry/die`;
  never `echo` for status. `audit <phase> <message>` appends to the audit trail.
* State files are `key=value` handled by `conf_get`/`conf_set`/`conf_del`, mode
  `0600`, under `/etc/vps-gateway-manager`. `clients.db` is a TAB-separated file
  with 7 fields: `name`, `cidr`, `created`, `source` (`ghproxyctl`|`adopted`),
  `acl_file`, `note`, `acl_id`. The display name is preserved; `acl_id` is the
  squashed identifier used in firewall markers.
* Squid config comes from `templates/`, rendered with
  `render_template <name> KEY=value …` where the template uses `@@KEY@@`.
* Entry points stay thin: `install.sh` / `uninstall.sh` parse arguments, source the
  libraries in order (`common net txn squid firewall health server server-ops
  client migrate`) and dispatch. Put logic in `lib/`.
* Project identity is `vps-gateway-manager` (state dir, unit names, paths, `VGM_*`
  env prefix). The old name `github-smart-proxy` must not reappear. `ghproxyctl`
  intentionally keeps its name — it is the GitHub proxy control tool.
* Enable strict mode in entry points (`set -euo pipefail`) and keep functions
  effective under it: capture the exit status instead of relying on `x && y` as the
  last statement of a loop (that makes the whole pipeline fail under `set -e`).

## Testing layers

* Unit suites (`tests/unit/*.sh`) run without root using command stubs from
  `tests/stubs/` and a `GP_ROOT` sandbox. They set `GP_SKIP_NET_CHECKS=1`, which
  skips listener waits — never assert real network behaviour there.
* Integration suites (`tests/integration/*.sh`) use the **real** squid binary, the
  harness in `tests/integration/lib.sh`, and a service-manager shim
  (`tests/integration/stubs/systemctl`) that performs real `reload` (SIGHUP) and
  real `restart` on the recorded daemon. `integ_require` exits 0 when the host
  cannot run them (not Linux, not root, no squid, no internet).
* Assert **behaviour**, not configuration text: Squid access-log hierarchy
  (`FIRSTUP_PARENT/…` vs `HIER_DIRECT/…`), TLS verification, listener state, HTTP
  status through the proxy, and the process table (no second Squid). `grep` on a
  config file alone is not a test.
* Harness details that matter: `assert_contains` is a literal substring match (use
  `assert_matches_line` for regexes); permission/mode assertions belong in
  `assert_file_mode_linux` (skipped on non-Linux); a denied CONNECT reports HTTP
  `000`, so probe source ACLs with `http://` URLs where Squid's own 403 is visible.

### Layered test policy (default)

Do NOT run the full local test matrix on every patch:

* **While developing** (every patch, locally): `bash -n` + ShellCheck (the
  policy greps via `tests/check.sh`), then ONLY the unit suites directly
  affected by the change. Never run the real-Squid integration locally.
* **After pushing the feature branch**: GitHub Actions owns the Linux / real
  Squid / three-distro verification. During a small-patch phase, drive the
  iteration from the integration suite the change targets (e.g. client
  upstream-family work → `05-client-family.sh`) — without trimming the suite
  set in CI to do so.
* **At milestone end, before merging to main**: run the complete matrix once —
  `shellcheck + all unit`, then Debian bookworm 00–05, Debian trixie 00–05 and
  Ubuntu 24.04 00–05. ONLY a SHA whose complete CI is green may be merged or
  used for a production pilot.
* Never buy time by weakening assertions, skipping failing cases or adding
  `continue-on-error`. Once GitHub has fully verified a commit, do not re-run
  the same full matrix locally "to be safe".

## Windows / PowerShell notes

Shell quoting is mangled when a command passes through PowerShell: multi-line
heredocs, `git commit -m` with special characters and nested quotes fail or are
silently altered. Write the content to a file (or a small `.sh` script) and
reference it, e.g. `git commit -F <file>`. Prefer the file tools over long inline
shell commands.
