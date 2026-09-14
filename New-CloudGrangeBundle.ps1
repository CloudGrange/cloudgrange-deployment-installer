#Requires -Version 7.0
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
# AB#1852 / AB#8129 — RETIRED.
#
# This script used to pull a hard-coded list of moving image tags (nginx:alpine, prom/prometheus:latest,
# ghcr.io/cloudgrange/*:latest, ...) into an offline bundle. That breaks the rule that every package
# version is exact and immutable, so it now refuses to run.
#
# Bundles are built by .github/workflows/release-bundle.yml, which:
#   - stamps first-party images as <repo>:<version>@sha256:<digest> (scripts/Set-FirstPartyImagePins.sh),
#   - fails unless EVERY image is digest-pinned (scripts/Test-ComposeImagePins.sh),
#   - adds the pinned Docker CE packages and the verified Ubuntu cloud image.

[CmdletBinding()]
param(
    [string]$Version    = '',
    [string]$OutputPath = '',
    [switch]$SkipUbuntu
)

Write-Error ("CG-BUNDLE-ERR-001: New-CloudGrangeBundle.ps1 is retired because it produced bundles with unpinned images. " +
    "Build bundles with .github/workflows/release-bundle.yml (digest-pinned images, pinned Docker CE packages).") -ErrorAction Stop
