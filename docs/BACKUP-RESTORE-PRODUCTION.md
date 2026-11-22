# Backup, restore and disaster recovery (production) — what is recovered and what is not

`docs/backup-restore.md` describes the LAB release 1.0.0 (`scripts/backup.sh`: raw `flows` table + configuration only). The production platform replaces that with a **complete** backup. This page states the guarantees without rounding up.

## Completeness review

| Data | Backed up by `akvorado-platform backup`? | How | Recovery result |
|---|---|---|---|
| **Raw flows** (`default.flows`) | ✔ | ClickHouse native `BACKUP DATABASE default` (consistent per table) | exact: row count and byte sum verified against the figures recorded at backup time |
| **Rollups** `flows_1m0s`, `flows_5m0s`, `flows_1h0m0s` | ✔ (the LAB backup **missed them**) | same database backup | exact (`sum(Bytes)` verified; *row* counts may differ because the tables merge rows — they are SummingMergeTree). They cannot be rebuilt from the raw table: they are fed on insert by materialized views |
| `exporters` table, dictionaries, **all DDL** (tables, materialized views, TTLs) | ✔ | part of the database backup (metadata) | the restore recreates the schema from the backup; the orchestrator then reconciles it with the running version |
| ClickHouse users / profiles / quotas (`grafana_ro`, limits, the closed `default` account) | rendered from configuration | `install` regenerates them from `platform.env` + the `grafana-ro-password` secret | identical, provided the secret is restored |
| Akvorado configuration (inlet/outlet/console/orchestrator YAML) | ✔ (source of truth) | `platform.env` + `site/` files in `config.tar.gz`; the rendered files are reproducible | identical |
| Console database (saved filters created in the UI) | ✔ best effort | `console.sqlite` copied from the running container (consistent when idle; the configured saved filters live in `site/saved-filters.yaml` anyway) | restored by `restore` |
| **Secrets** (web password, `grafana-ro-password`, SNMP community, IPinfo token) and the **TLS private key** | only with `--include-secrets` | inside `config.tar.gz`, AES-256 encrypted when `BACKUP_GPG_PASSPHRASE_FILE` is set | `restore --bootstrap` puts them back on a new host. Without them you must supply them yourself |
| TLS certificate, CA certificate | ✔ (public parts) | `tls-public/` | restored by `--bootstrap` |
| **Kafka** log and consumer offsets | ✘ **by design** | Kafka is a ≤ 24 h transit buffer | see "What is lost" |
| GeoIP databases | ✘ | re-downloaded by the sidecar (or re-supplied for `GEOIP_MODE=files`) | AS/country columns of already stored flows are stored in the rows and survive |
| Docker images, Docker CE | ✘ | pulled by digest / offline bundle | identical (digests pinned) |

## What a backup set is

`NETFLOW_BACKUP_DIR/akvorado-platform-<stamp>-<label>/` (mode 0700) with `config.tar.gz[.gpg]`, `console.sqlite`, `manifest.txt` (versions, row counts and byte sums before/after the ClickHouse backup, SHA-256 of every file) and, last, the
`COMPLETE` marker; and `NETFLOW_BACKUP_DIR/clickhouse/ch-<stamp>-<label>/` — the native ClickHouse backup (written **directly to the backup volume** through a bind mount, never to the data disk). Retention: the newest `BACKUP_KEEP` regular sets
(default 4) and the newest 3 safety sets (`pre-upgrade`, `pre-restore`); a ClickHouse backup is deleted together with its set. A weekly timer (`akvorado-backup.timer`, Sunday 03:00 + random delay) creates the `scheduled` sets.
A set without `COMPLETE`, or one whose checksums do not match, is **refused** by `restore`.

## Guarantees

* **Point in time:** each table is backed up consistently; the tables are not frozen at exactly the same instant (flows arriving during a backup can land in the raw table and not yet in a rollup, or vice versa — a few seconds of traffic).
* **RPO:** everything stored in ClickHouse up to the moment the backup ran. Flows received afterwards are not in it. Default interval: 7 days — **shorten the timer for a tighter RPO** (a backup of a busy system takes time and space; the native backup is not incremental in this release).
* **RTO:** install (≈ 5–10 minutes with images pulled, less offline) + restore (proportional to the data; a few seconds for the test data).
* **Integrity:** the set's checksums are verified before anything changes; ClickHouse verifies the checksums of every data part while restoring; after restoring, the tool compares row counts and byte sums with the manifest and reports FAIL on a mismatch.

## What is lost (read this before relying on it)

1. Flows that arrived **after** the last backup, if the data disk is lost.
2. **Kafka content and replay.** Flows that had reached Kafka but not yet been consumed by the outlet are lost with the Kafka disk. Kafka does retain them while the outlet or ClickHouse is down (verified: the topic offsets advance while the outlet is stopped and the backlog is consumed when it returns), **but whether the outlet then stores them is not guaranteed by Akvorado 2026.10.0 as observed**: in repeated tests between 0 and 30 of 30 flows sent during an outlet outage were stored afterwards (the outlet resumes from committed offsets only for partitions it had already consumed, and keeps its newest batch in memory). Do not treat the 24 h Kafka buffer as a lossless replay log.
3. **The outlet's in-memory batch.** After a **crash** (`kill -9`, power loss) the newest, not yet flushed batch is lost (observed: 9 of 30 flows when the outlet was killed immediately after a burst). A graceful stop or restart flushes it (observed during upgrade and restore).
4. UI-created saved filters made after the last backup; manual changes to files under `/opt/akvorado-platform/stack` (they are regenerated — change `platform.env` / `site/` instead).
5. Anything on the backup volume if the backup volume is on the same disk as the data — which is why this is a preflight FAIL, and why a copy **off the server** is part of the procedure.

## Procedures

### A. Back up
```bash
sudo akvorado-platform backup                      # database + config (no secrets)
sudo akvorado-platform backup --include-secrets    # + secrets and TLS key; set BACKUP_GPG_PASSPHRASE_FILE to encrypt config.tar.gz
# copy BOTH the set and its ClickHouse directory off the server, e.g.
rsync -a /var/backups/netflow/ backup-host:/srv/backups/netflow/
```

### B. Restore on the same server (damaged data)
```bash
sudo akvorado-platform restore /var/backups/netflow/akvorado-platform-<stamp>-manual --yes
```
Verify the set → take a `pre-restore` safety backup → stop inlet/outlet/console/orchestrator → drop the `default` database → `RESTORE DATABASE default` → compare counts/sums → restore the console database → start everything → full `verify`.
`--config-only` restores only the configuration; `--no-safety-backup` skips the safety backup (not recommended).
**Tested:** raw table and one rollup truncated, restore from the set, counts and byte sums matched, ingestion continued.

### C. Rebuild a lost server (bare host)
1. Prepare the host (§2 of [PRODUCTION-RHEL9.md](PRODUCTION-RHEL9.md): RHEL repositories, the data disk mounted, the backup volume mounted with the backup sets and the `clickhouse/` directory).
2. With a set made using `--include-secrets`:
   ```bash
   sudo bin/akvorado-platform restore /path/akvorado-platform-<stamp>-manual --bootstrap     # puts platform.env, secrets, site files, TLS and CA files back
   sudo bin/akvorado-platform install                                                          # Docker CE, images, empty schema, firewall, units
   sudo akvorado-platform restore /path/akvorado-platform-<stamp>-manual --yes                 # the data
   ```
   Without secrets in the set: recreate `platform.env`, the secret files and the certificate yourself (the same `grafana-ro-password` keeps Grafana working), then `install` and `restore`.
3. `akvorado-platform verify`; point the exporters at the new address if it changed.
**Tested:** the whole platform (containers, volumes, images, `/opt`, `/etc`, the data directory, the TLS files) was destroyed; the three commands rebuilt it and the row counts, byte and packet sums were identical afterwards.

### D. Undo an upgrade
`akvorado-platform rollback` returns to the configuration snapshot and image pins from before the upgrade (data untouched). `rollback --with-data` additionally restores the database from the `pre-upgrade` set — **rows written since the upgrade are lost**.
See [PRODUCTION-RHEL9.md](PRODUCTION-RHEL9.md) §7 and the validation record for the tested upgrade 2026.8.1 → 2026.10.0 including an automatic rollback of a failing upgrade.

## Hygiene
* Keep at least one set made with `--include-secrets` **and** its passphrase off the server.
* Restore a set onto a scratch host at least once per quarter; never point a test collector at production exporters or a test Grafana at production ClickHouse.
* ClickHouse data and backups are **not encrypted at rest** by this platform: use an encrypted filesystem/volume if your policy requires it.
