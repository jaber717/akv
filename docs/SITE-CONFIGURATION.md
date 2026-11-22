# Site configuration — what you customise without touching the platform

Generic settings are rendered from templates; **your** site facts (exporter addresses, interface tables, your networks, saved filters) live in optional files in **`/etc/akvorado-platform/site/`**. Each file replaces the generic default of the same name;
The production platform keeps them apart: the generic configuration is rendered from templates, and **your** site facts live in optional files in **`/etc/akvorado-platform/site/`**. Each file replaces the generic default of the same name;
`install` renders them into `/opt/akvorado-platform/stack/config/site-*.yaml` and restarts the Akvorado services when something changed. The files are part of every backup (`config.tar.gz`).

| File in `/etc/akvorado-platform/site/` | Used for | Default when absent |
|---|---|---|
| `exporters-static.yaml` | **static metadata** for exporters without usable SNMP: names and interface tables (Akvorado drops flows that have no interface metadata). Queried before SNMP | no static provider |
| `networks.yaml` | your own networks → `SrcNetName/DstNetName/Role/Site` | `{}` |
| `sampling-rates.yaml` | sampling rate per exporter network when the exporter does not announce one | `::/0: <DEFAULT_SAMPLING_RATE>` (1 = unscaled) |
| `exporter-classifiers.yaml` | CEL rules that set site / tenant / role per exporter | the three labels from `SITE_NAME`, `TENANT_NAME`, `ROLE_NAME` |
| `interface-classifiers.yaml` | CEL rules that mark interfaces external/internal and name the provider | description prefix rule (`Transit:`, `IX:`, `PNI`, `PPPoE`) → external, everything else internal |
| `saved-filters.yaml` | console saved filters | seven generic filters (external/internal, TCP/UDP/ICMP) |

## Examples
`exporters-static.yaml`:
```yaml
---
203.0.113.10/32:
  name: edge-router-1
  default: {name: ifindex-unmapped, description: "no static mapping", speed: 1000}
  ifindexes:
    1: {name: Gi0/0, description: "Transit: ISP-A", speed: 10000, boundary: external}
    2: {name: Gi0/1, description: "LAN core",       speed: 10000, boundary: internal}
```
`sampling-rates.yaml`:
```yaml
---
203.0.113.10/32: 1        # unsampled
198.51.100.0/24: 100      # 1-in-100 sampled
::/0: 1
```
`networks.yaml`:
```yaml
---
10.0.0.0/8: {name: corporate, role: internal, site: hq}
```
`tests/rhel/site/exporters-static.yaml` is the minimal file used by the acceptance tests.

## SNMP
With `SNMP_ENABLED=yes` the outlet polls exporters (`communities` = the secret file `snmp-community`) for the exporter name and interface names/descriptions/speeds. It needs UDP/161 from this server to the exporters and a matching
read-only community on the device. Exporters that do not support it use `exporters-static.yaml`. The community is stored in the rendered `outlet.yaml` (mode 0640, root only) because Akvorado reads it from its configuration;
it is never in Git, in the environment file or in a non-encrypted backup.

## Exporter configuration
Vendor examples (Cisco IOS-XE, Huawei NetStream) are in `docs/exporter-examples.md`: send NetFlow v9 / IPFIX to `udp/2055` / `udp/4739`, sFlow v5 to `udp/6343` of this server, **from an address inside `FLOW_ALLOWED_CIDRS`**.

