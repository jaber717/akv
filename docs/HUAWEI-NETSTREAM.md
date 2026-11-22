# Huawei WAN router onboarding (NetStream v9 / IPFIX) — plan, one interface first

**Nothing here is applied automatically.** Router configuration is applied only by you, after the exact router model and VRP version are known (command syntax differs between NE/AR/CE/S series and VRP versions).

## What to collect (read-only commands on the router)
`display version` (model, VRP version) · `display current-configuration | include netstream` (existing NetStream) · `display ip interface brief` · `display interface <wan-interface>` (note the **ifIndex**: `display snmp-agent mib-view`/interface detail) · `display cpu-usage` · `display ip routing-table 0.0.0.0` (which interface carries the default route).

## Collector facts
* Send **NetStream v9** or **IPFIX** to `<server-ip>` UDP **2055** (v5/v9) or **4739** (IPFIX). The source address must be inside `FLOW_ALLOWED_CIDRS` (the router IP you gave the installer).
* Sampling: if you sample on the router, the interval is announced in the template (Akvorado uses it); if the router does not announce it, set the same value in `/etc/akvorado-platform/site/sampling-rates.yaml` (`<router-ip>/32: <N>`), otherwise volumes are understated by N.
* Interface names: either SNMP read-only from the server to the router (`SNMP_ENABLED=yes`) or the static table `/etc/akvorado-platform/site/exporters-static.yaml` (ifIndex → name, speed, `boundary: external` for the WAN link). Flows without interface metadata are discarded by Akvorado.

## Safe first deployment
1. One WAN interface, **inbound** first, sampled (for example 1:100 to 1:1000 on a busy link).
2. No change to BGP/OSPF/static routes/NAT/firewall policy/forwarding paths; NetStream only observes.
3. Watch `display cpu-usage` for 10 minutes; if CPU or forwarding is affected, remove the NetStream lines on that interface (rollback = the inverse commands you wrote down before applying).
4. Verify on the server: Akvorado web UI → Visualize: dimensions *Source address*, *Destination address*, *Exporter*, *Input interface*; filter on the exporter; check **Top Talkers**, **conversations** (source+destination+ports) and bytes/bandwidth.
5. Add the outbound direction or a second interface only after step 4 looks right.

Send the model, VRP version and the outputs above and the exact commands for your router will be written for that version.
