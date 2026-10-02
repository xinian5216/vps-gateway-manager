# vps-gateway-manager 0.6.1

This release adds exact-IP selectors to `ghproxyctl client remove`.

## What changed

Managed clients can be removed by name, bare IPv4/IPv6, or an exact `/32` or
`/128` CIDR. For example, on the gateway:

```bash
sudo ghproxyctl client remove 2a06:a005:ad:fffd::89
```

Equivalent IPv6 spellings resolve to the stored client identity, so removal
uses the original ACL entry and firewall marker. Existing name/ACL-identifier
lookup takes priority. An IP matching multiple inventory rows is refused;
choose an explicit name from `ghproxyctl client list`. Unknown addresses and
source ranges are refused before any change. `--dry-run` previews removal.

Adopted clients remain protected: edit the source grant in the original ACL
file, confirm Squid reloaded successfully, then run `client forget <name>`.
`forget` alone does not revoke access.

## Upgrade

On a host running v0.6.0:

```bash
sudo ghproxyctl update --version v0.6.1
ghproxyctl version
```

This updates the management toolchain. The update itself does not reinstall
Squid, change client authorisations or operator configuration, or reload the
service. Executing `client remove` afterwards is a separate operation that
revokes that managed client's authorisation.

The upgrade floor remains v0.5.1. That version has no installed `update`
command: download the `vps-gateway-manager-v0.6.1.tar.gz` asset and its adjacent
`SHA256SUMS`, extract it, and run the new tool against the extracted tree:

```bash
tar -xzf vps-gateway-manager-v0.6.1.tar.gz
cd vps-gateway-manager-v0.6.1
sudo env VGM_HOME="$PWD" bash bin/ghproxyctl update --source "$PWD"
sudo bash bin/ghproxyctl version
```

## Verification

The shipped management code matches baseline
`0b4cdb6ea9db69f924ca1c3528d996a5e30bd3ff`, verified by
[CI run 37017456240](https://github.com/xinian5216/vps-gateway-manager/actions/runs/37017456240):
all 19 unit suites and the real-Squid suites 00–07 on Debian bookworm, Debian
trixie and Ubuntu 24.04 passed, with no failed or skipped assertions.

Release preparation changes version metadata, documentation and release/update
tests. Its own complete CI must pass before publication. Those tests include
upgrades from the published v0.6.0 and v0.5.1 toolchains. Release artifacts carry
an internal file manifest plus an outer `SHA256SUMS` covering the archive.

This release has not been deployed or validated on a production host. Existing
real-host acceptance in `docs/STATUS.md` §2.7 belongs to v0.6.0.
