# Runtime footprint — original run988

AB#8915/AB#9072. [Pipeline988](https://dev.azure.com/hybridcloudsolutions/CloudGrange/_build/results?buildId=988)
Succeeded on2026-09-11 at infrastructure
`72d9fe93244d5971a6b951078c0a66074bf867e7`. Installed owner source remains
`8819c5fd808ad5bca9dbeddc70cc6d36773dd5a3`; Linux PowerShell remains7.4.19.
The separate probe measured the existing runtime and retained test pods without
restarting services, installing workloads or changing runtime configuration.

| Observation | Original result |
| --- | --- |
| Samples/window | 31 samples over300.4861176seconds |
| Actual sample times | 2026-09-11T04:54:50.7378459Z through04:59:50.6674001Z |
| Minimum Linux MemAvailable | 31,610,462,208bytes /29.4395GiB |
| Maximum aggregate CPU busy share | 4.0767%, excluding idle/iowait; guest time not double-counted |
| Data volume | 4,384,899,072bytes used before and after;251,280,891,904bytes available |
| System volume | 6,185,676,800bytes used before;6,185,783,296bytes after |
| Runtime service | Active/running throughout; same main process80516 |
| Node | Same UID222629df-709e-4707-87c3-2b3f6939b2d2; all31 Ready/no memory/disk/PID-pressure observations passed |
| Boot | Same245d1bae-3cbb-4bd9-98c3-95d57d882b0a |
| Installed inputs | Original checkpoint, runtime configuration and executable hashes preserved |
| Pods | 24 before/after:14Running,8Succeeded,2Failed; no observed container restart deltas |

The two Failed pods are backend/client in cg-network-probe-982. They were already
Failed before this measurement and remained unchanged. This observation does not
establish their original failure cause. The original status data is retained;
the result is not an all-pods-healthy claim. Node and pod metrics endpoint output,
raw service accounting, CPU/memory/load samples and initial/final pod/filesystem
records are retained. No production sizing or long-duration stability claim is made.

Original result is1,783,136bytes, SHA256
`4ac49affba54b0f56f67265e867a0f6a1cb8feb07491e66f87be96aacdf06563`.
Probe source SHA256 is
`572a2ec8739540f80d141b8703da37953d270b179cd7bedc4f82aaada2776392`.
The2,378,195-byte private capsule has SHA256
`8f8c34d1db93e6d026bc9aef4e2a8673714ea054d4b779074984216999e37d79`
and blob version2026-09-11T04:59:51.9147007Z. Duplicate upload returned403;
exact-version readback, source/execution identities and original file hashes passed.
The original pipeline ZIP has SHA256
`09844f62da18eced6a3ab99ed68014f1a039cbc778b59b67186eb05289b18590`;
it is attached to8915/9072 and its ADO download matched those bytes.

Reproduce only when a new measurement is needed: use the reviewed infrastructure
FootprintProbe action, original owner commit and a distinct execution. Existing
evidence is preserved; the five-minute sample set must not be relabeled as a
load, interrupted-bootstrap, application recovery or full M0/M1 test.

The [teardown/promotion procedure](teardown-and-promotion.md) is documented.
No teardown occurred. Interrupted/partial bootstrap, full storage/TLS/PKI and
assembled product recovery remain outstanding. Both requested clusters remain
absent pending the scoped FailoverClusters runtime decision.
