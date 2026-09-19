# Security model

This project builds **GitHub-only egress gateways**. It is not a general-purpose
proxy, and every design decision below exists to keep it that way.

## 1. Who may use a gateway

* A client is authorised **only** by an explicit
  `ghproxyctl client add <ip> <name>`.
* The address is normalised to an exact host: IPv4 `/32`, IPv6 `/128`.
  A `/64`, `/48`, `/24`, `0.0.0.0/0` or `::/0` is refused with an explanation.
  There is no "allow a subnet" shortcut.
* Squid's built-in default is *deny*: if no `http_access` rule matches, the
  request is rejected. The generated configuration additionally ends with an
  explicit `http_access deny all`.
* The plain HTTP proxy port (`3128` on the server, `3129` on a client) is bound
  to `127.0.0.1` / `::1` only, and that binding is verified after every change
  (`ghproxyctl test` fails if the port is reachable on a public address).

## 2. What a gateway may reach

* Only names from the managed destination list
  (`/etc/vps-gateway-manager/github-domains.txt`), which is seeded from
  `templates/github-domains.txt`:
  `.github.com`, `.githubusercontent.com`, `.githubassets.com`, `ghcr.io`,
  `.github.io`.
* Broad, shared platform suffixes are **refused** by the validator, even when
  they appear in an operator's existing whitelist:
  `.amazonaws.com`, `.cloudfront.net`, `.azureedge.net`, `.akamai.net`,
  `.fastly.net`, `.cloudflare.com`, `.googleapis.com`, `.windows.net`, …
* If a GitHub release redirects to an additional host, the flow is:
  record the failing hostname → verify it is operated by GitHub → add the exact
  host with `ghproxyctl domains add <host>` → re-run `ghproxyctl test`.
  Never "add the CDN so the download works".

## 3. TLS

* The gateway terminates TLS with a Let's Encrypt certificate
  (`/etc/squid/tls/`, renewed by a Certbot deploy hook that copies the new
  material, validates it with `squid -k parse` and only then reloads).
* Clients connect to the gateway with `cache_peer … tls tls-cafile=…`; the
  certificate is verified against the system trust store (or `--upstream-ca`).
* Verification is **never** disabled: there is no `--insecure`, no `curl -k`,
  no `DONT_VERIFY_PEER`, no `tls-default-ca=off` anywhere in this repository,
  and `tests/check.sh` fails the build if such a pattern appears.

## 4. Firewall

* Only UFW is managed, and only additively: one exact rule per authorised client
  (`allow from <ip>/32 to any port 8443 proto tcp`).
* Rules created here carry the comment marker `gsp:<client>`; that marker is the
  only thing this project will ever delete. A rule without the marker is
  reported and left alone.
* Pre-existing rules are never modified, even when they are broader than
  necessary (for example `8443/tcp ALLOW Anywhere`). The tool warns about them
  and points out that Squid ACLs remain the authoritative gate.
* `ufw reset`, `ufw --force reset`, `ufw flush`, `iptables -F`,
  `nft flush ruleset` are blocked by a policy grep in `tests/check.sh`.
* On an adopted server the firewall is only touched when *this project* adds a
  client; adoption itself changes no firewall rule.

## 5. Change safety

Every mutating operation runs inside a transaction (`lib/txn.sh`):

```
backup -> generate candidate -> squid -k parse (in the real load order)
       -> atomic replace -> reload -> health check
       -> commit, or roll back everything on any failure
```

* The candidate client configuration is validated by building a temporary main
  configuration that includes it **exactly where it will live**, so ordering
  mistakes are caught before anything is replaced.
* The managed `conf.d` file is named `00-…` so that it is evaluated before a
  pre-existing whitelist file in the same directory, and it deliberately
  contains **no** `http_access deny` rule (a deny there would shadow the
  operator's existing clients on an adopted server).
* Reload is preferred over restart; the neighbouring services (`xray` on 443,
  `x-ui` on 4428) are never touched, and the installer refuses to take over a
  port that belongs to another process.
* Backups are kept under `/etc/vps-gateway-manager/backups/<timestamp>/` with a
  journal that records every file, firewall rule and service action, so a
  rollback (or a manual restore) is reproducible.

## 6. Secrets

* Cloudflare API tokens are accepted only through a root-only file
  (directory `700`, file `600`); `--token …` does not exist.
* Komari endpoints and tokens are never read, printed, or modified: only the
  four proxy variables and `NO_PROXY` are rewritten.
* State files are `0600` in a `0700` directory; logs contain no credentials.

## 7. Management plane

* There is no public enrollment API, no long-lived registration token and no web
  interface. The management plane is SSH + `ghproxyctl` on the box.
* Adding a client is always a deliberate, audited, two-step action:
  `ghproxyctl client add` on the server, `install.sh client` on the client.

## 8. Reporting a problem

Open an issue at
<https://github.com/xinian5216/vps-gateway-manager/issues> with the output of
`ghproxyctl doctor` and `ghproxyctl test` (both are read-only). Never paste a
token, a private key or a full `squid.conf` that contains client addresses you
do not want to publish.
