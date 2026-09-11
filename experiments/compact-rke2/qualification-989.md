# Existing-node interruption and resume — run 989

AB#8914, AB#8915 and AB#9072. [Pipeline 989](https://dev.azure.com/hybridcloudsolutions/CloudGrange/_build/results?buildId=989)
succeeded on 2026-09-11 using infrastructure
`a82d916198e02a4318fbb7398c7e63ab772dd8fc` and unchanged installed owner
`8819c5fd808ad5bca9dbeddc70cc6d36773dd5a3` under Linux PowerShell 7.4.19.

The separate probe invoked the original Plan, then used a child-process breakpoint
at line 155 immediately after the original installer persisted
`runtime_start_requested`. Child PID 215356 flushed a fault record and terminated
itself with exit 137 at 05:24:04.8103523Z. The parent verified its PID, source and
checkpoint hashes, request identity and absence of a completed bootstrap result.
It then invoked the unchanged Install once in a new evidence directory. Resume
took 4.865195 seconds and reached `node_ready` at 05:24:09.6838416Z.

The original Kubernetes node UID, boot ID, data volume UUID, disk marker and retained
ConfigMap marker were preserved. Installed source, runtime configuration and binary
hashes were unchanged; the service remained active. The operation guard records
execution 989 as verified. No earlier evidence or workloads were deleted.

Original result SHA256:
`06977efca0bd89a43e77a861c33895dd6790bcb800ec99d58792614868845468`.
Probe source SHA256:
`d1207b88b5cbc1ca6eb3db29f5804363e6d669c22ffc24e96a0d2c0ce6332d78`.
Original capsule: 82,205 bytes, SHA256
`ec35d60771bbda54beecaf89b7c92c01685ab9876c311842d9fb3a7a7cc2105b`,
immutable blob version `2026-09-11T05:24:10.3263490Z`. Exact-version readback and
the original file/source checks passed; duplicate creation returned 403.
Original pipeline ZIP SHA256:
`70ab081426f843e5a3e175d896cf41b50052ad55d6e677f2e0076ecce31847d7`.
It is attached to all three tasks and matched the ADO download byte for byte.

This qualifies interruption and resume on the existing node at one fully persisted
checkpoint. It does not test fresh installation, every bootstrap boundary, torn
checkpoint writes, storage/TLS/PKI contracts or application backup/recovery. Those
requirements and assembled M0/M1 acceptance remain open. Do not replay the successful
fault injection or reset its guard to bypass execution ownership.
