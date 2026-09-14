#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1852 / AB#8129 — RETIRED.
#
# This script used to pull a hard-coded list of moving image tags (nginx:alpine, prom/prometheus:latest,
# ghcr.io/cloudgrange/*:latest, ...) into an offline bundle. That breaks the rule that every package
# version is exact and immutable, so it now refuses to run.
#
# Bundles are built reproducibly by scripts/New-ReleaseBundle.sh, run on demand from one main commit by
# .github/workflows/release-bundle.yml (docs/releases/reproducible-build.md). The build:
#   - stamps first-party images as <repo>:<version>@sha256:<digest> (scripts/Set-FirstPartyImagePins.sh),
#   - fails unless EVERY image is digest-pinned (scripts/Test-ComposeImagePins.sh),
#   - adds the Docker CE packages and Ubuntu cloud image, verified against the pins in release/.

[CmdletBinding()]
param(
    [string]$Version    = '',
    [string]$OutputPath = '',
    [switch]$SkipUbuntu
)

Write-Error ("CG-BUNDLE-ERR-001: New-CloudGrangeBundle.ps1 is retired because it produced bundles with unpinned images. " +
    "Build bundles with scripts/New-ReleaseBundle.sh or the on-demand .github/workflows/release-bundle.yml (see docs/releases/reproducible-build.md).") -ErrorAction Stop
