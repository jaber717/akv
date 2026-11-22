# Compatibility, upgrade paths and rollback

## Matrix
| Component | 1.1.0 |
|---|---|
| OS | RHEL 9.x x86_64, SELinux Enforcing, firewalld. CI-tested on AlmaLinux 9.7 (binary compatible). **Real RHEL 9.7: not yet validated** |
| Akvorado / ClickHouse / Kafka / Valkey / Traefik | 2026.10.0 / 26.8.18.2 / 4.3.1 / 9.0 / v3.7 (images pinned by digest in `production/compose/images.lock`) |
| Docker CE / Compose | 29.8.2 / 5.6.0 (RPMs from the release's repository; version-locked) |
| Raw-flow retention / Kafka retention | `RETENTION_RAW_DAYS` (default 14) / `KAFKA_RETENTION_HOURS` (24); rollups 1m/5m/1h: `RETENTION_1M_DAYS` 30, `RETENTION_5M_DAYS` 90, `RETENTION_1H_DAYS` 365 |

## Upgrade paths
Defined in `compat/upgrade-paths.txt`, copied into each release's `manifest.json` (`compat.upgrade_from`, `compat.schema_change`) and enforced by `akvorado-install update` **before anything is downloaded**.

| From | To | Schema change |
|---|---|---|
| 1.0.1 | 1.1.0 | no (application versions identical; only delivery changed) |

Notes for 1.0.1 → 1.1.0: a 1.0.1 host installed with `PACKAGE_SOURCE=registry` is switched to the bundle mode by the update (persisted in `platform.env`); the already-loaded images are verified by layer digest and reused. This exact path was **not** executed in CI (no pipeline can create a 1.0.1 installation without Docker Hub/Quay); the upgrade engine itself was exercised with a successor built from the same release (see VALIDATION-RHEL9.md).

## What an upgrade does
Pre-flight (read-only) → verified backup (`pre-upgrade` set) → configuration snapshot → versions recorded in `release.json` (`last_upgrade`) → upgrade → full verification → **automatic rollback** when verification fails.

## Rollback
`sudo akvorado-install rollback` restores the previous release, its rendered configuration and its systemd units from the snapshot taken by the last upgrade; the previously loaded images are still present. Data is not touched.
`rollback --with-data` additionally restores the verified pre-upgrade backup (loses flows received since the upgrade).
**No rollback across an irreversible schema migration is promised:** when a release declares `schema_change=yes` in its manifest and notes, code-only rollback is unsupported and only `--with-data` is valid. 1.1.0 declares `schema_change=no`.
