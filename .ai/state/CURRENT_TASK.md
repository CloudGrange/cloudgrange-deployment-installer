# Current task — correct actual Linux preflight parsing

Branch feat/m0-compact-rke2-ab8913. Infrastructure run974 transferred and hashed the original runtime sources/packages, installed pinned PowerShell7.4.19 and invoked the Linux installer Plan. Plan failed before runtime/checkpoint creation because -split bound as a parameter on Invoke-ExperimentNative in the df/free-space expression. No RKE2 install/start occurred.

The corrected expression groups the command result before splitting. Test-PreflightParsing.ps1 executes the actual expression/100GiB predicate with native-output fixtures: the original failed with the same error; corrected LF/CRLF and insufficient-space cases passed. All six actual artifact-guard cases also passed. Package pins/topology are unchanged.

Next: publish this owner revision, pin it in the infrastructure config, and run Prepare to execute the corrected Linux Plan. Only a passing actual Plan permits Install. Original974 ZIPf2c682847d5019c85dac209faafa25129d1d6100455dbb71c1a983e7c84e2c24 and host logs are retained. Read-only host inspection confirmed temporary key absence. Upstream design/trust/recovery and all runtime/addon/reboot/blocked-egress/product acceptance remain required; full M0/M1 stays Active.
