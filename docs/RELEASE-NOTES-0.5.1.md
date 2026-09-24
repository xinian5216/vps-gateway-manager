# vps-gateway-manager v0.5.1 — Release Notes

> Patch on v0.5.0. Health-check accuracy and error reporting only.
> It does not reinstall a gateway, and it does not change an operator's Squid
> configuration, client ACLs, firewall rules or certificates.
> It does not add the still-open verifications (fresh server install with a
> real Certbot issuance and renewal, or an uninstall/restore rehearsal).

## What changed

* **`Unknown source refused` no longer prints `FAIL 000000`.** A failed
  connect used to be reported as a Squid ACL failure because curl's own `000`
  was concatenated with a second `000`. A timeout, a refused connect, an empty
  write-out or a malformed token is now a **warning**: this probe did not
  reach Squid, so the Squid ACL was not independently verified. A firewall
  drop looks exactly like that and is not called a pass.
* **403 or 407** from a source that is not already authorised is still a pass.
  **Any 2xx** is a fail, even if curl's own exit is non-zero. Any other HTTP
  status is a warning, not a pass. A probe whose source is already an
  authorised client is a warning and is not used as evidence about unknown
  sources.
* **`ghproxyctl status` and `ghproxyctl test` print the whole table.** A failed
  check used to abort under `set -e` before the results were printed
  (`aborted unexpectedly`). Both the server and the client now print every
  check and the failure count, then exit non-zero. Warnings and skips do not
  fail the command, and the summary says they are not passes. An unexpected
  script abort still uses the existing EXIT guard and still rolls back an
  open transaction.
* The adopted **non-GitHub warning** now says it probed loopback only. It does
  not test the public TLS listener, and this release does not change the
  operator's destination policy. See `docs/STATUS.md` §2.6.

## Upgrade (management tool only)

On a host that already runs v0.5.0, replace the installed libraries and
`ghproxyctl`. This copies files; it does not reload Squid and does not rewrite
operator config.

```bash
# unpack the v0.5.1 tree, then, as root, on the server and on each client.
# VGM_HOME is required: without it gp_install_toolchain skips the copy and
# still returns 0.
cd /path/to/vps-gateway-manager-0.5.1

sudo env VGM_HOME="$PWD" bash -c '
set -e
. "$VGM_HOME/lib/common.sh"
gp_install_toolchain
test "$(cat /usr/local/lib/vps-gateway-manager/VERSION)" = "0.5.1"
'

sudo ghproxyctl version          # vps-gateway-manager 0.5.1
sudo ghproxyctl status           # full table, then a one-line summary
```

What to expect on the current adopted gateway, whose UFW drops unauthorised
sources before Squid:

```text
Unknown source refused WARN  source <ip>: Squid ACL not independently verified (curl exit 28, status 000). ...
health checks: 0 failed, N warning(s), M skipped (a warning or a skip is not a pass)
```

Exit code 0 when nothing FAILed. A real ACL hole (an unauthorised source
getting HTTP 2xx) still exits non-zero and still prints the rest of the table.

## Rollback

Restore the v0.5.0 copies of `/usr/local/lib/vps-gateway-manager` and
`/usr/local/sbin/ghproxyctl` from the host's own backup of those paths, or
repeat the upgrade command above from a v0.5.0 tree with `VGM_HOME` set to
that tree (and expect `VERSION` to read `0.5.0`). No Squid, ACL, firewall or
certificate change is involved, so nothing else needs restoring.
