# Current task — preparatory Compact RKE2 experiment

Branch feat/m0-compact-rke2-ab8913, isolated worktree D:/tmp/cloudgrange-tppoc-lab-2026-09-10/installer-rke2, based on freshly fetched origin/main dc36006. Existing main/planning worktrees preserved.

experiments/compact-rke2 contains pinned RKE2/airgap inputs, a PS7 Linux Plan/Install/Verify experiment, artifact guard tests and explicit acceptance limits. Actual source parses; six artifact guard cases passed and both full original vendor archives passed the actual validator. No Linux execution or task closure yet.

The tppoc Linux management VM boot qualification succeeded in infrastructure pipeline968. Next connect this exact installer source to the existing tppoc pipeline through a pinned ADO mirror checkout, install the pinned PowerShell7.4.19 package via the already qualified SSH path, deliver/hash original archives and sources, run Plan then Install, and inspect actual node/Canal/Traefik behavior. Do not use the archived Docker installer. Upstream topology/trust/backup contract, full experiment measurements, reboot/interruption and blocked-egress tests remain required. Original M0/M1 goal unchanged.

Published source19dbfa83389180715bb2ebfe75c6e0324c91b486 in installer draftPR2 and ADO mirror refs/heads/tppoc-rke2-installer-source. Linux execution remains pending.

