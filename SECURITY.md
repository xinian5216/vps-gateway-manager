# Security model

This project builds **GitHub-only egress gateways**. It is not a general-purpose
proxy, and every design decision below exists to keep it that way.

## 1. Who may use a gateway

* A client is authorised **only** by an explicit
  `ghproxyctl client add <ip> <name>`.
* The address is structurally validated first (RFC 4291 grammar for IPv6
  including the v4-mapped forms, dotted-quad rules for IPv4) and normalised to
  an exact host: IPv4 `/32`, IPv6 `/128`. A `/64`, `/48`, `/24`, `0.0.0.0/0` or
  `::/0` is refused with an explanation, and a malformed address can never
  reach an ACL. There is no "allow a subnet" shortcut.
* Squid's built-in default is *deny*: if no `http_access` rule matches, the
  request is rejected. The generated configuration additionally ends with an
  explicit `http_access deny all`.
* The plain HTTP proxy port (`3128` on the server, `3129` on a client) is bound
  to `127.0.0.1` / `::1` only, and that binding is verified after every change
  (`ghproxyctl test` fails if the port is reachable on a public address).
* A firewall drop and a Squid refusal are different facts. `Unknown source
  refused` passes only when the probe obtains HTTP 403 or 407 from Squid. If
  the probe never gets an HTTP response (timeout, connection refused, empty or
  malformed write-out), the check is a warning: UFW or another filter may have
  dropped the packet before Squid, and that is **not** evidence that the Squid
  ACL refused the source. A 2xx from a source that is not already authorised
  is a failure.

## 1.1 Management-tool updates

A normal update replaces the installed libraries, templates, `ghproxyctl` and
release metadata. It does not reinstall a Server or Client, and it does not
reload Squid or change operator config, ACLs, firewall rules or certificates.

* The default source is a non-draft, non-prerelease GitHub Release. A network
  failure does not fall back to `main`. TLS verification stays on. There is no
  `curl -k` path.
* `SHA256SUMS` checks that the download matches the file published next to it.
  It does not independently prove who published the Release. A signature would
  be a separate control, and this version does not claim to have one.
* The new tree is staged outside the live directory and switched only after
  that copy verifies. A crash leaves a phase marker; the next run restores the
  last known-good toolchain instead of treating a half-written tree as success.
* One mutation lock covers update, install, uninstall and the other write
  commands. `status`, `test` and `doctor` do not take it.
* Rollback restores a management-toolchain backup. It does not roll back later
  operator or client changes.

## 2. What a gateway may reach

* A **fresh** install only proxies names from the managed destination list
  (`/etc/vps-gateway-manager/github-domains.txt`), seeded from
  `templates/github-domains.txt`:
  `.github.com`, `.githubusercontent.com`, `.githubassets.com`, `ghcr.io`,
  `.github.io`. The health check fails if loopback can proxy a non-GitHub host.
* An **adopted** install does not rewrite the operator's destination policy.
  The non-GitHub warning probes **loopback** (`127.0.0.1:3128`) only. A 200
  there means the operator's localhost rules answered; it does not prove, and
  does not disprove, that an authorised client can reach the same host on the
  public TLS port. That public path is a separate check, made from an
  authorised client against port 8443, and this project does not change the
  operator's whitelist to silence the warning.
* Shared CDN platforms are refused by the validator in three tiers (enforced
  in `validate_domain_entry`; nothing bypasses the first two):
  1. a platform **suffix** — `.amazonaws.com`, `.s3.amazonaws.com`,
     `.cloudfront.net`, `.azureedge.net`, `.akamai.net`, `.fastly.net`,
     `.cloudflare.com`, `.googleapis.com`, `.windows.net`, … — can **never**
     be allowed, not even with `--force`;
  2. the platform **root** and its well-known **multi-tenant service
     endpoints** (`amazonaws.com`, `s3.amazonaws.com`, `s3.<region>.amazonaws.com`,
     `s3-accelerate.amazonaws.com`, `blob.core.windows.net`, …) can never be
     allowed either — one hostname there reaches every tenant of the platform;
  3. **one exact resource host** on such a platform (a bucket like
     `github-cloud.s3.amazonaws.com`, a distribution like
     `d111….cloudfront.net`) is refused by default and allowed only through
     the explicit `--force` approval: one hostname, no suffix coverage.
* Entries found in an operator's existing whitelist go through the same
  validator during adoption: shared-platform entries are reported and never
  imported. `ghproxyctl domains remove` validates syntax only, so a legacy
  entry that today's policy would refuse can always be deleted.
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
* Transaction backups live under `/etc/vps-gateway-manager/backups/<txn-id>/`
  with a journal (`journal.tsv`) recording every file, firewall rule and
  service action, so a rollback (or a manual restore) is reproducible; older
  transactions are pruned (the newest 20 are kept).
* Migration backups live under `/etc/vps-gateway-manager/migrations/backups/`
  and are **per-apply** — `<component>.bak` is overwritten by every apply of
  that component. An automatic rollback (and `ghproxyctl migrate restore`)
  therefore returns a component to its state before the latest apply; this is
  what makes a failed `migrate komari` byte-for-byte reversible.

## 6. Secrets

* Cloudflare API tokens are accepted only through a root-only file
  (directory `700`, file `600`); `--token …` does not exist.
* Komari endpoints and tokens are never printed and never modified. The unit's
  `Environment=` file is necessarily read in order to rewrite exactly the four
  proxy variables (plus the `NO_PROXY` merge); everything displayed goes
  through an allowlisted summary (`ExecStart: detected (redacted)`,
  `Endpoint`/`Token`: `detected, value hidden`) and URL-credential redaction,
  so no token-bearing line is ever echoed into a report or a log.
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
