# vps-gateway-manager 0.6.0

Release candidate prepared for publication. The stable artifact is built and
checked; the v0.6.0 Tag and the GitHub Release are not created yet and wait
for explicit authorization. These notes describe what will be released.

This is a management-tool release. It does not reinstall a gateway, and it
does not change Squid, ACLs, firewall rules or certificates.

## What changed

* `install.sh` with no arguments, on a terminal, detects the host. A new
  machine gets an install wizard. An installed Server or Client gets the
  manager, and is not asked to pick a role again.
* `ghproxyctl menu`, `update`, `update check`, `update rollback`, `update
  recover` and `update history` use the same update engine as the menu.
* Server and Client share that engine. The role only changes the pre-check
  and the protected files verified afterwards.
* A normal update replaces libraries, templates, `ghproxyctl`,
  `bin/vgm-bootstrap` and release metadata, and proves the result against the
  release manifest. It does not call `install.sh server`, `install.sh client`
  or `server reconcile`.
* The default discovery target is the latest stable GitHub Release. It is not
  `main`. A failed lookup does not install something else.
* Local `--source` (directory or tarball) is supported and still requires
  `VERSION`, `release.meta` and `SHA256SUMS`.
* An interrupted update is detected on the next run. v0.6.0 restores the
  previous known-good toolchain; it does not try to resume a half-written
  switch.
* A new health FAIL after the switch restores the previous toolchain. A
  warning does not.
* Validated upgrade floor: v0.5.1. Older versions are refused.

## Upgrade

Validated floor is v0.5.1. On a host that runs v0.5.1 the installed
`ghproxyctl` has no `update` yet, so obtain the 0.6.0 release artifact
(`vps-gateway-manager-v0.6.0.tar.gz`, with `SHA256SUMS` beside it) and run the
tool from it. Example for the extracted tree:

```bash
tar -xzf vps-gateway-manager-v0.6.0.tar.gz
cd vps-gateway-manager-v0.6.0
sudo env VGM_HOME="$PWD" bash bin/ghproxyctl update --source "$PWD"
sudo bash bin/ghproxyctl version
```

`--source` accepts the extracted directory or the tarball itself. A tarball is
verified against the `SHA256SUMS` beside it; a directory carries its own
`SHA256SUMS`. The release artifact is labelled `stable` and needs no
`--allow-development`; only a development tree does.

`SHA256SUMS` checks integrity. It does not by itself prove who published the
archive. Upgrading a production host remains an operator decision.

## Verification

* Automated: CI run 36019472468 for the code baseline
  `719e837bccbe8827fb0bbae890bebc506042a3ae` — all four Linux jobs green
  (shellcheck + 19 unit suites, and the real-Squid suites 00–07 on Debian
  bookworm, Debian trixie and Ubuntu 24.04).
* Real hosts: user-provided acceptance on a client, the gateway and two
  servers, plus rollback and crash-recovery drills on one retired client
  (`docs/STATUS.md` §2.7).

## Known limitations

* Direct upgrade from v0.5.0 or older is not validated; those versions are
  refused at the upgrade floor.
* Rollback restores the management toolchain only.
* The non-GitHub warning on an adopted server is still a loopback probe. This
  release does not change that, and does not change operator policy.
* Real-host upgrade results are user-provided acceptance
  (`docs/STATUS.md` §2.7), not automated tests. Crash recovery has been
  drilled on a real client host only — not on a server.
* The v1.0.0 → v0.5.1 replacement used to convert one retired Debian client
  was experimental. It is not a supported upgrade path.
