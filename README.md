# akv — Akvorado NetFlow platform for RHEL 9 (installer and release assets)

Installs and runs an Akvorado (NetFlow / IPFIX / sFlow) collector with ClickHouse and Kafka on **RHEL 9.x, x86_64**, from this public repository only. No GitHub token is needed.

Everything the installer downloads comes from the release `v1.1.0-rc3` of this repository, over HTTPS to two hosts: `api.github.com` and `release-assets.githubusercontent.com`.
Every file is verified (size, SHA-256 from `SHA256SUMS`, GitHub's own asset digest); TLS verification is never disabled.

## 1. Check the server first (read-only: installs and changes nothing)
```
bash -c "$(curl -sS -H Accept:application/vnd.github.raw https://api.github.com/repos/jaber717/akv/contents/i?ref=v1.1.0-rc3)" x check
```

## 2. Install
```
bash -c "$(curl -sS -H Accept:application/vnd.github.raw https://api.github.com/repos/jaber717/akv/contents/i?ref=v1.1.0-rc3)"
```
Run both as your normal admin user (the installer uses `sudo` itself and passes your proxy settings on). It asks only for what cannot be detected: the router IP(s) that will send NetFlow, the networks allowed to open the web UI, and (optionally) an SNMP read-only community.
It never formats a disk: a dedicated data volume must already be mounted (or pass `--data-dir`). Re-running the same command is safe and keeps all data.

After installation: `akvorado-install health | update | rollback`.

## Behind a proxy / TLS inspection (FortiProxy and similar)
* A proxy is taken from `https_proxy`, then `/etc/environment`, `/etc/profile.d/*.sh`, `/etc/dnf/dnf.conf`, and then remembered in `/etc/akvorado-platform/network.env` (also used under `sudo`).
  If your shell needs one: `export https_proxy=http://PROXY:PORT` before the command. Proxy authentication: `--proxy http://USER@PROXY:PORT` (the password is asked, never stored).
* Corporate TLS-inspection CA: `--ca-file /path/ca.pem` (the CA is *added* to the system trust store for the installer; verification stays on).
* Downloads use 16 MiB `Range` requests with resume. If a proxy ignores `Range` or re-encodes the data, the installer stops and says so; `--allow-stream` is an explicit whole-file fallback.

## What is published here
`i` (installer), `preflight` (read-only check), `docs/`, and the release assets: the platform scripts, a signed local RPM repository (AlmaLinux 9.7 packages and Docker CE, signature-verified), the container images pinned by digest, `manifest.json` and `SHA256SUMS`.
No credentials, host names or network details of any environment are included (audited before publishing). Third-party components keep their own licenses: see `THIRD-PARTY.md`.

Status: **release candidate** — see `docs/STATUS.md` for exactly what has and has not been tested.
