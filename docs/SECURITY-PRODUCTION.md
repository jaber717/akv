# Security model — production (RHEL 9)

## Controls the platform sets up and then checks (`akvorado-platform verify`)

| Area | Control | Check |
|---|---|---|
| Supply chain | Docker CE from `download.docker.com` with the **vendored, fingerprint-pinned key**, `gpgcheck=1`, `includepkgs`, version-locked; every container image run **by digest** (`production/compose/images.lock`); offline: RPMs re-verified with `rpm -K`, images verified by ID | pins, `docker image inspect`, `versionlock` |
| SELinux | host must be **Enforcing** (preflight FAIL otherwise); Docker daemon `selinux-enabled: true` → containers are confined (`container_t`); data/backup directories labelled `container_file_t`; one minimal custom module `netflow-docker-socket` (Traefik → Docker API, `connectto` only); AVC denials of confined containers since boot are a FAIL | `getenforce`, `ausearch -m avc`, `daemon.json` |
| Network exposure | firewalld active; **source admission per published port** (`*_ALLOWED_CIDRS`, required, no defaults) enforced in `DOCKER-USER` and rebuilt at boot; ClickHouse HTTPS published on **one address** only; Kafka, Valkey, ClickHouse native/HTTP **never published**; Traefik's private entrypoint on `127.0.0.1` | `ss`, `iptables -S DOCKER-USER` (order allow→DROP), tested allowed/denied |
| Transport | web UI **TLS ≥ 1.2 + HSTS**, basic auth (apr1 hash in a 0600 file); ClickHouse HTTPS with the same certificate; certificate checked in preflight (expiry, key match, SAN, chain); TLS 1.0/1.1 refused | `curl --tls-max 1.1` must fail |
| Authentication | web UI behind Traefik basic auth (a generated 24-character password); ClickHouse `default` account (no password) **restricted to the loopback and the Docker network**; `grafana_ro` is `readonly=2`, restricted to the Grafana address(es), limited rows/memory/time/queries, `SELECT` on the five Akvorado tables and five `system` views only, no access management | refused from outside; `EXECUTE AS grafana_ro` denial tests (INSERT, CREATE, SYSTEM, `system.users`) |
| Secrets | files under `/etc/akvorado-platform/secrets` (0700 dir, 0600 files, root); the SNMP community is the one secret that must live in a rendered config file (`outlet.yaml`, 0640 root, container runs as root); nothing in Git, `platform.env`, process arguments or logs | modes and owners |
| Data at rest | `NETFLOW_DATA_DIR/clickhouse` and `/kafka` mode 0700, owned by the container uids; backup dir 0750/0700; TLS key 0400 owned by uid 101 (the ClickHouse container user) | modes |
| Least privilege | containers have memory limits and no extra capabilities (ClickHouse `SYS_NICE` as upstream); logs capped; Docker socket mounted **read-only** into Traefik only | `docker inspect` |
| Auditing | install/upgrade/restore/rollback/backup logs in `/var/log/akvorado-platform/` | |

## Known limitations (stated, not hidden)
1. **The Akvorado containers run as root inside the container** (upstream image) — confinement is by SELinux (`container_t`), the unprivileged Docker defaults and the network model, not by a non-root user.
2. **Docker socket access for Traefik** is a standing risk (a compromised Traefik could use the API); it is mounted read-only and allowed by a minimal SELinux rule, but Traefik is internet-facing only to the admitted CIDRs. Replacing the Docker provider by a static Traefik configuration would remove it — a design change not made here.
3. **ClickHouse data and backups are not encrypted at rest.** Use an encrypted filesystem/volume if required; `config.tar.gz` is encrypted when `BACKUP_GPG_PASSPHRASE_FILE` is set.
4. **NetFlow/IPFIX/sFlow and SNMPv2c have no authentication or encryption.** Admission is by source CIDR; spoofing inside an admitted network is possible. Keep exporters on a management network.
5. The web UI has **one shared basic-auth account**; there is no per-user identity in Akvorado (`Remote-User` is fixed). Use an upstream SSO proxy if you need per-user audit.
6. The shared IPinfo token shipped by Akvorado is public; set your own in `secrets/ipinfo-token`.
7. The Docker signing key has no expiry date; if Docker rotates it, update `vendor/docker/RPM-GPG-KEY-docker` and `DOCKER_GPG_FPR` from a verified source.
8. Release assets and tags are **not signed** ([GITHUB-ACCESS.md](GITHUB-ACCESS.md)).

## Credential rules
* No credential is passed on a command line. Nothing generates or rotates credentials of the exporters, the LAB, or Grafana.
* Rotate: web password (delete `secrets/web-password`, run `install`: a new one is generated and hashed into Traefik's file), `grafana-ro-password` (same; then update the Grafana platform's `clickhouse-password` and run its `rotate-secrets`), SNMP community (edit the secret, `install`).
