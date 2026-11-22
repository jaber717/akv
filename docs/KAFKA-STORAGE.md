# Kafka storage on the dedicated data disk — evaluation and result

## Finding in the LAB (release 1.0.0, unchanged)
`.env` documents `NETFLOW_KAFKA_DATA_DIR=/var/lib/clickhouse/kafka-data`, but the LAB compose overlay never mounts it: Kafka writes to the Docker **named volume** `akvorado_akvorado-kafka`, i.e. under `/var/lib/docker/volumes` on the
**root filesystem** (finding F1 in `docs/live-inventory.md`). "Everything on the data disk" was therefore not true for Kafka. The LAB was **not** changed.

## Production design
`production/compose/docker-compose-production.yml` replaces the volume with a bind mount of **`NETFLOW_KAFKA_DIR`** (default `<NETFLOW_DATA_DIR>/kafka`) on `/var/lib/kafka/data`:

* the directory is created `0700`, owner uid/gid **1000** (the `appuser` of the `apache/kafka` image), labelled `container_file_t`; `verify` checks that the running container really has this mount and prints the backing device;
* Kafka remains a single-broker KRaft node, topic `flows-v5`, 8 partitions, replication factor 1, retention `KAFKA_RETENTION_HOURS` (24 h) — it is a transit buffer, not an archive;
* set `NETFLOW_KAFKA_DIR` to a path on **another** volume if you prefer the buffer not to share space with ClickHouse (see the trade-off below).

## Tests (isolated RHEL 9.6 VM, XFS data disk `/dev/sdb`, synthetic NetFlow v9 / IPFIX / sFlow)

| Test | Result |
|---|---|
| Kafka data lives on the data disk | `findmnt -T /data/netflow/kafka` → `/dev/sdb xfs`; container mount `/data/netflow/kafka → /var/lib/kafka/data` ✔ |
| Kafka container restart | topic, partitions and log-end offsets identical before/after (`flows-v5:4:1 … 6:2 … 7:1`) ✔ |
| Outlet stopped, 30 flows sent, outlet started | Kafka retained the packets (offsets advanced) and the consumer lag returned to 0; **the number of flows then stored varied between runs (0 to 30 of 30)** — treat the Kafka buffer as best-effort, not as a lossless replay log ⚠ |
| ClickHouse stopped, flows sent, ClickHouse started | the inlet kept writing to Kafka and the backlog was consumed; stored counts varied between runs (10 to 30 of 30) ⚠ |
| Outlet `SIGKILL` immediately after a burst | **part of the burst was lost** (9 of 30 in the run): flows already consumed from Kafka but not yet flushed to ClickHouse live only in the outlet's memory ✘ (documented limitation) |
| Platform destroyed and rebuilt from backup | Kafka starts empty; no replay is expected or needed ✔ |

## Trade-offs to decide knowingly
* **Shared disk:** if the data filesystem fills up, ClickHouse *and* Kafka stop. The disk guard (outlet stopped at 95 % use, resumed below 85 %) protects ClickHouse; Kafka keeps buffering for up to its retention while the outlet is frozen — size the disk for that, or put Kafka on its own volume.
* **uid 1000:** the files are owned by numeric uid 1000, which on a host is normally the first interactive user. The directory is mode `0700`, so only that uid and root can read the flow records, but a login user with uid 1000 would be that uid: do not create one on a collector host.
* **Not backed up:** by design (≤ 24 h buffer). Details in [BACKUP-RESTORE-PRODUCTION.md](BACKUP-RESTORE-PRODUCTION.md).
* **Batch behaviour of Akvorado 2026.10.0 (observed):** the outlet holds the newest partial batch until further flows arrive or it stops gracefully, so on an almost idle network the last flows can appear late; this is upstream behaviour, not configuration.
