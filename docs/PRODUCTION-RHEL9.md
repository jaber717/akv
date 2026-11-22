# Akvorado NetFlow platform on RHEL 9 — production installation guide

Akvorado **2026.10.0** (inlet, outlet, orchestrator, console) with ClickHouse **26.8.18.2**, Kafka **4.3.1**, Valkey **9.0**, Traefik **v3.7** and the IPinfo GeoIP sidecar, run with Docker CE under systemd on RHEL 9,
installed and operated by one command: `akvorado-platform`. The component versions are pinned in VERSIONS.env and production/compose/images.lock.

> **Status of the evidence** — [VALIDATION-RHEL9.md](VALIDATION-RHEL9.md). Full acceptance (clean install, idempotency, backup/restore, disaster recovery, upgrade/rollback, offline installation) was run on **RHEL 9.6**. Other RHEL 9.x releases are supported targets: `preflight` accepts any 9.x and checks the actual dependencies, but they were not individually validated.

## 1. Architecture

```
exporters ──udp 2055 (NetFlow v5/v9) · 4739 (IPFIX) · 6343 (sFlow)──▶ inlet ──▶ Kafka (1 day buffer) ──▶ outlet ──▶ ClickHouse ◀── console ◀── Traefik ◀─https:443 (basic auth)── users
                                                                          SNMP/static metadata, GeoIP ─┘     │  orchestrator (schema, config)     └─https:8443 (grafana_ro, read-only)── Grafana
host:  /data/netflow/{clickhouse,kafka}  (dedicated XFS)      /var/backups/netflow  (separate volume)       /opt/akvorado-platform  /etc/akvorado-platform
```
* Docker CE **29.8.2**, Compose **5.6.0** from `download.docker.com` with the **vendored, fingerprint-pinned key** (`060A61C51B558A7F742B77AAC52FEB6B621E9F35`); packages are version-locked.
* Every image runs **by digest** (`production/compose/images.lock`); the upstream compose files are used verbatim, the differences are in `production/compose/docker-compose-production.yml`.
* Only five host ports are published; everything else stays on the Docker network or the loopback (§3).

## 2. Server requirements

| Item | Requirement |
|---|---|
| OS | Red Hat Enterprise Linux **9.x** (any minor release; RHEL 8 and RHEL 10 are rejected by preflight), x86_64, SELinux **Enforcing**, firewalld **active**, NTP synchronised |
| CPU / RAM | profile `small`: 4 vCPU / 8 GiB · `medium`: 8 vCPU / 16 GiB · `large`: 16+ vCPU / 32+ GiB. `SIZING_PROFILE=auto` picks by RAM; it sets container memory limits and ClickHouse's own ceilings |
| Root filesystem | 20 GiB free (Docker images ≈ 3 GiB, logs capped at 3 × 10 MiB per container) |
| **Data filesystem** | a **dedicated mount point** (`NETFLOW_DATA_DIR`, default `/data/netflow`, XFS recommended) holding `clickhouse/` and `kafka/`. Minimum 30 GiB free (FAIL below), 100 GiB+ recommended. Sizing rule: *flows/day × retention days × ≈ 30–100 bytes* (the LAB measured 27 B per raw flow compressed) + 10 GiB that ClickHouse always keeps free + the Kafka buffer (≈ 24 h of uncompressed flows) |
| **Backup volume** | `NETFLOW_BACKUP_DIR` (default `/var/backups/netflow`) **must not be on the data filesystem** (preflight FAIL; `ALLOW_BACKUP_ON_DATA_FS=yes` only for tests) — a separate disk or an NFS/remote mount |
| Repositories | RHEL BaseOS + AppStream (subscription, Satellite or the installation ISO): `container-selinux`, `iptables-nft`, `jq`, `python3`, `checkpolicy`, `policycoreutils*`, `xfsprogs`, `python3-dnf-plugin-versionlock` … |
| Inbound | `443/tcp` (web, `WEB_ALLOWED_CIDRS`) · `2055/udp`, `4739/udp`, `6343/udp` (exporters, `FLOW_ALLOWED_CIDRS`) · `8443/tcp` (Grafana, `GRAFANA_ALLOWED_CIDRS`) · `10179/tcp` only if `ENABLE_BMP=1` |
| Outbound | online install: `download.docker.com`, `quay.io`, `registry-1.docker.io`, `ghcr.io` (443) · at run time: SNMP `161/udp` to the exporters (if `SNMP_ENABLED=yes`), `ipinfo.io:443` (if `GEOIP_MODE=ipinfo`), DNS, NTP |
| Certificate | one PEM certificate (+chain) and key; SAN must contain `NETFLOW_DOMAIN` — the same pair serves the web UI and ClickHouse HTTPS |

## 3. Ports and who may reach them

| Port | Service | Published on | Admitted by |
|---|---|---|---|
| 443/tcp | Traefik (web UI, TLS ≥ 1.2, HSTS, basic auth) | `WEB_BIND` (default all) | `WEB_ALLOWED_CIDRS` |
| 2055, 4739, 6343 /udp | inlet | all addresses | `FLOW_ALLOWED_CIDRS` |
| 8443/tcp | ClickHouse HTTPS (user `grafana_ro` only) | **one** address `CH_BIND` | `GRAFANA_ALLOWED_CIDRS` **and** the account's own `networks` restriction |
| 8080/tcp | Traefik private entrypoint (unauthenticated APIs) | `127.0.0.1` only | — |
| 9000, 8123, 9092/9093, 6379 | ClickHouse native/HTTP, Kafka, Valkey | **never published** | Docker network only |

Docker's published ports bypass firewalld's input rules, so admission is enforced in the `DOCKER-USER` chain by `akvorado-firewall.service` (rules are rebuilt from the environment file at every boot; they match only *original-direction DNAT'd* packets,
otherwise the DROP would also swallow the replies of admitted TCP connections). firewalld additionally declares the ports. **Both were tested functionally**: an allowed source gets through, a source outside the list is dropped (counters rise).

## 4. What you must prepare

1. The **certificate and key** (PEM) and, for a private CA, the CA certificate.
2. Secret files (root, mode 600) in `/etc/akvorado-platform/secrets/`:
   * `snmp-community` — **required** when `SNMP_ENABLED=yes` (6–64 characters; `public`/`private` are refused in production). Use SNMPv2c only with a private community on a trusted management network.
   * `web-password`, `grafana-ro-password` — **generated by the installer** if absent (never printed). Give `grafana-ro-password` to the Grafana platform (`clickhouse-password` there).
   * `ipinfo-token` — optional own IPinfo token; without it Akvorado's shared public token is used (WARN).
3. The **environment file** from `env/production.env.example` (non-secret).
4. Optional **site files** — exporter metadata, local networks, sampling rates, classifiers, saved filters: [SITE-CONFIGURATION.md](SITE-CONFIGURATION.md).
5. A formatted and mounted data disk, e.g. `mkfs.xfs /dev/sdb && mount /dev/sdb /data/netflow` (+ `/etc/fstab`).

## 5. Install — the minimal command sequence

```bash
tar xzf akvorado-platform-1.0.1-rhel9-offline.tar.gz && cd akvorado-platform-1.0.1      # or a checkout of tag v1.0.1 (docs/GITHUB-ACCESS.md)
sudo install -d -m 0700 /etc/akvorado-platform/secrets
sudo install -m 0600 /dev/stdin /etc/akvorado-platform/secrets/snmp-community <<< 'a-private-community'
cp env/production.env.example /root/akvorado.env && vi /root/akvorado.env                # domain, CIDRs, paths, certificate files
sudo bin/akvorado-platform preflight --env-file /root/akvorado.env                       # read-only; fix every FAIL
sudo bin/akvorado-platform install   --env-file /root/akvorado.env                       # Docker CE, images, stack, firewall, units, verification
sudo akvorado-platform verify                                                            # any time later
```

`install` does: preflight (stops on FAIL, changes nothing) → prerequisites → Docker CE (pinned, signed, version-locked, `daemon.json` with `selinux-enabled: true` and capped logs) → data/backup directories with SELinux labels
(`container_file_t`) → secrets and CA trust → SELinux module `netflow-docker-socket` (Traefik → Docker API, `connectto` only) → images pulled **by digest** (or loaded from the offline bundle and checked by image ID) → renders the
stack (`/opt/akvorado-platform/stack`) → firewalld ports and `DOCKER-USER` rules → systemd units (`akvorado-stack`, `akvorado-firewall`, `akvorado-disk-guard.timer`, `akvorado-backup.timer`) → `docker compose up -d --wait`
→ full verification. It is **idempotent** (re-running re-converges; services restart only when their configuration changed) and an interrupted run resumes.

Web UI: `https://<NETFLOW_DOMAIN>/`, user `WEB_USER`, password in `/etc/akvorado-platform/secrets/web-password`. Point the exporters at the collector ports; the first rows appear in the console within seconds.
*Behaviour to know:* Akvorado 2026.10.0's outlet keeps the newest partial batch until more flows arrive (or the outlet stops); on a busy network this is invisible, on a nearly idle one the last few flows can lag. See [KAFKA-STORAGE.md](KAFKA-STORAGE.md).

## 6. Configuration reference (`env/production.env.example`)

| Group | Variables |
|---|---|
| identity | `NETFLOW_DOMAIN`, `SITE_NAME`, `TENANT_NAME`, `ROLE_NAME` |
| storage | `NETFLOW_DATA_DIR`, `NETFLOW_KAFKA_DIR` (optional own volume), `NETFLOW_BACKUP_DIR`, `ALLOW_BACKUP_ON_DATA_FS`, `BACKUP_KEEP`, `BACKUP_GPG_PASSPHRASE_FILE` |
| web | `WEB_BIND`, `WEB_PORT`, `WEB_TLS`, `WEB_ALLOW_INSECURE_HTTP`, `WEB_USER`, `NETFLOW_TLS_CERT_FILE`, `NETFLOW_TLS_KEY_FILE`, `NETFLOW_TLS_CA_FILE`, `WEB_ALLOWED_CIDRS` |
| collectors | `FLOW_ALLOWED_CIDRS`, `PORT_NETFLOW`, `PORT_IPFIX`, `PORT_SFLOW`, `ENABLE_BMP`, `BMP_ALLOWED_CIDRS`, `DEFAULT_SAMPLING_RATE` |
| enrichment | `SNMP_ENABLED`, `GEOIP_MODE` (`ipinfo` \| `files` \| `none`), `IPINFO_DATABASES` |
| Grafana access | `CH_GRAFANA_ENABLE`, `CH_BIND`, `CH_PORT`, `GRAFANA_ALLOWED_CIDRS` |
| retention | `RETENTION_RAW_DAYS` (14), `RETENTION_1M_DAYS` (30), `RETENTION_5M_DAYS` (90), `RETENTION_1H_DAYS` (365), `KAFKA_RETENTION_HOURS` (24) |
| sizing / sources | `SIZING_PROFILE`, `PACKAGE_SOURCE` (`registry` \| `bundle`), `BUNDLE_DIR`, `SECRETS_DIR` |

Changing a value: edit the file, run `akvorado-platform install --env-file <file>` again. Retention changes are applied by the orchestrator to the tables' TTL (tested: 14 → 7 → 14 days, `verify` checks the live TTL).

## 7. Day-2 operations

| Task | Command |
|---|---|
| Verify everything (PASS/WARN/FAIL, exit ≠ 0 on FAIL) | `akvorado-platform verify` |
| Summary (services, disk, row counts, last backup) | `akvorado-platform status` |
| Backup now (weekly timer does it too) | `akvorado-platform backup [--include-secrets]` |
| Restore | `akvorado-platform restore <backup-set> --yes` — see [BACKUP-RESTORE-PRODUCTION.md](BACKUP-RESTORE-PRODUCTION.md) |
| Upgrade to the pins of a newer release | unpack it, `sudo bin/akvorado-platform upgrade` (backup + snapshot first, automatic rollback) |
| Roll back | `akvorado-platform rollback [--with-data]` |
| Disk guard | automatic every 5 min: at ≥ 95 % data-disk use the outlet is stopped (flows queue in Kafka), restarted below 85 % |
| Logs | `/var/log/akvorado-platform/`, `docker compose logs <service>` in `/opt/akvorado-platform/stack` |

## 8. Troubleshooting

| Symptom | Check |
|---|---|
| `preflight`: data directory is not a mount point | mount the dedicated filesystem (or `ALLOW_DATA_ON_ROOT=yes` for a test host only) |
| a TCP port answers locally but not from the network | `iptables -L DOCKER-USER -v -n` — the source must match the `*_ALLOWED_CIDRS`; DROP counters show refused connections |
| flows arrive (`inlet` metrics) but not in ClickHouse | the exporter has no interface metadata: Akvorado drops such flows. Enable SNMP on the exporter or add `site/exporters-static.yaml`; check `docker compose logs akvorado-outlet` |
| `geoip` unhealthy | the container cannot reach `ipinfo.io` — use `GEOIP_MODE=files` or `none` on isolated servers |
| ClickHouse container restarting | `docker compose logs clickhouse` — most often a file in `docker/clickhouse` or `docker/tls` unreadable by uid 101 (re-run `install`, it re-renders with the right owners) |
| Grafana datasource health FAIL | name/certificate (`NETFLOW_DOMAIN` in the SAN, CA trusted on the Grafana host), and Grafana's address in `GRAFANA_ALLOWED_CIDRS` |
