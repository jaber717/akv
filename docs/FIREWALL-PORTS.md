# Firewall ports (exact)

Declared in firewalld (`--permanent`, default zone or `FIREWALL_ZONE`; nothing is removed or opened broadly) and, because published container ports bypass firewalld's INPUT rules, additionally admitted per source in the `DOCKER-USER` chain (`akvorado-firewall.service`, comment `akvorado-platform`).

| Port | Proto | Purpose | Admitted sources | Variable |
|---|---|---|---|---|
| 443 | TCP | Web UI (Traefik, TLS, basic auth) | `WEB_ALLOWED_CIDRS` | `WEB_PORT` |
| 2055 | UDP | NetFlow v5/v9 (Cisco) | `FLOW_ALLOWED_CIDRS` | `PORT_NETFLOW` |
| 4739 | UDP | IPFIX | `FLOW_ALLOWED_CIDRS` | `PORT_IPFIX` |
| 6343 | UDP | sFlow | `FLOW_ALLOWED_CIDRS` | `PORT_SFLOW` |
| 8443 | TCP | ClickHouse HTTPS for Grafana (`grafana_ro`), bound to `CH_BIND` | `GRAFANA_ALLOWED_CIDRS` | `CH_PORT`, `CH_GRAFANA_ENABLE` |
| 10179 | TCP | BMP (only if `ENABLE_BMP=1`) | `BMP_ALLOWED_CIDRS` | |

**Never published:** Kafka (9092/9093), Valkey (6379), ClickHouse native (9000), HTTP (8123), interserver (9009), Akvorado internal ports. The acceptance run asserts that none of them listens on a host address.
**Outbound at install/update time:** `api.github.com:443` and `release-assets.githubusercontent.com:443` only ([GITHUB-ACCESS.md](GITHUB-ACCESS.md)). At run time with `GEOIP_MODE=none` (the bundle default) the stack needs no outbound access; exporters' SNMP polling needs UDP/161 to the exporters when `SNMP_ENABLED=yes`.
