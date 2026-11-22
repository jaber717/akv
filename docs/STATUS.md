# Status of this release

Release candidate. The table is updated with every release; "not tested" means exactly that.

| Item | State |
| --- | --- |
| Installer logic (token-free, proxy/CA, chunked resume, Range/encoding detection, saved settings) | tested against a mock GitHub and failing proxies (55 checks) |
| Preflight (read-only) | tested against a mock GitHub and failing proxies (25 checks) |
| Real install end to end on RHEL 9 | in progress: a clean-VM install on RHEL 9.6 is being run before this candidate is promoted |
| Real RHEL 9.7 production host | not tested |
| Behind a real TLS-inspecting FortiProxy | not tested |
| Huawei NetStream/IPFIX decoding with a real Huawei router | not tested |
