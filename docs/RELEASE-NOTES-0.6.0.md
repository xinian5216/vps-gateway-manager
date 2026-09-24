# vps-gateway-manager 0.6.0

Unreleased. These notes describe the branch, not a published Release.

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
* A normal update replaces libraries, templates, `ghproxyctl` and release
  metadata. It does not call `install.sh server`, `install.sh client` or
  `server reconcile`.
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

On a host that already runs v0.5.1, the installed `ghproxyctl` does not yet
have `update`. Obtain this tree (a Release asset, once one exists, or a
copied checkout) and run the new entry. Example for a local tree:

```bash
cd /path/to/vps-gateway-manager-0.6.0
sudo env VGM_HOME="$PWD" bash bin/ghproxyctl update --source "$PWD" --allow-development
sudo bash bin/ghproxyctl version
```

`--allow-development` is required while `release.meta` says
`channel=development`. A published stable Release will not need it. Do not
run this against a production host until that Release exists and you have
explicitly chosen to pilot it.

`SHA256SUMS` checks download integrity. It does not by itself prove who
published the archive.

## Known limitations

* Direct upgrade from v0.5.0 or older is not validated.
* Rollback restores the management toolchain only.
* The non-GitHub warning on an adopted server is still a loopback probe. This
  release does not change that, and does not change operator policy.
* No production upgrade has been run.
