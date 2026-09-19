#!/usr/bin/env bash
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — the merge gate for cloudgrange-deployment-installer. Runs every suite this repo has and
# exits non-zero on ANY failure. There is no "pre-existing failure" exemption: main must be 100%
# green, and every PR must leave it that way.
#
# What it runs:
#   1. test/lint-pins.sh                      the pinning gate (no `latest`, every pin present)
#   2. scripts/Test-ComposeHardening.py       compose hardening
#   3. scripts/Test-SshTransportOptions.py    every ssh/scp call is bounded
#   4. test/appliance (python unittest)       the release-gate suites, as root, nothing skipped
#   5. test/Invoke-InstallerSourceQualification.ps1   parser + PSScriptAnalyzer + BOM schema, and
#                                             the Pester 5 unit suites with -RequireNoSkipped
#
# Prerequisites: root (the python gates FAIL rather than skip without it — see
# test/appliance/gate_requirements.py), a reachable Docker engine with the compose plugin, PyYAML,
# and network access to the PowerShell Gallery the first time each container runs.
#
# CLOUDGRANGE_TEST_ALLOW_SKIP is for a developer's own machine and must never be set here: it turns a
# missing prerequisite into a skipped release gate. The gate refuses to run with it set.
#
# PowerShell runs in a container (5): WSL has no pwsh, and the Pester suites must run as a
# NON-root user with passwordless sudo — as root, five of them skip themselves, and -RequireNoSkipped
# then fails. On Windows, run that script directly with pwsh 7 instead.
#
# Usage: sudo -E scripts/test-all.sh          (Linux or WSL, bash 4+)
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
pwsh_image="${CLOUDGRANGE_PWSH_IMAGE:-mcr.microsoft.com/powershell:7.4-ubuntu-22.04}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fail() { echo "test-all: FAIL: $*" >&2; exit 1; }
step() { echo; echo "=== test-all: $*"; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root (sudo -E scripts/test-all.sh): the release-gate tests fail rather than skip without it"
[[ -z "${CLOUDGRANGE_TEST_ALLOW_SKIP:-}" ]] || fail "CLOUDGRANGE_TEST_ALLOW_SKIP is set: release gates must never be skipped here"
command -v python3 >/dev/null || fail "python3 not found"
python3 -c 'import yaml' 2>/dev/null || fail "PyYAML not installed (apt-get install -y python3-yaml)"
command -v docker >/dev/null && docker info >/dev/null 2>&1 || fail "no Docker engine reachable"
docker compose version >/dev/null 2>&1 || fail "the docker compose plugin is required by the compose gates"

step "pinning gate"
bash test/lint-pins.sh

step "compose hardening"
python3 scripts/Test-ComposeHardening.py compose

step "ssh transport gate"
python3 scripts/Test-SshTransportOptions.py .

step "appliance and release-gate tests (python unittest, as root)"
python3 -m unittest discover -s test/appliance -v

step "PowerShell source qualification and Pester suites (in $pwsh_image)"
# Invoke-InstallerSourceQualification.ps1 runs the parser, PSScriptAnalyzer, the release-BOM schema
# cases AND test/Invoke-InstallerPester.ps1, with -RequireNoSkipped when CI=true on Linux — which is
# exactly this gate's contract, so CI=true is set here. It runs as a non-root user with passwordless
# sudo because five Pester tests skip themselves when the run is root, and a skipped test fails the gate.
docker run --rm -e CI=true -v "$repo_root:/src" -w /src "$pwsh_image" bash -c '
  set -e
  apt-get update -qq >/dev/null && apt-get install -y -qq sudo >/dev/null
  pwsh -NoProfile -Command "
    Set-PSRepository PSGallery -InstallationPolicy Trusted
    Install-Module PSScriptAnalyzer -RequiredVersion 1.25.0 -Force -Scope AllUsers
    Install-Module Pester -RequiredVersion 5.7.1 -Force -Scope AllUsers -SkipPublisherCheck" >/dev/null
  id -u cgtest >/dev/null 2>&1 || useradd -m cgtest
  echo "cgtest ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/cgtest
  sudo -u cgtest --preserve-env=CI pwsh -NoProfile -Command "./test/Invoke-InstallerSourceQualification.ps1 -EvidenceDirectory /tmp/source-qualification"'

echo
echo "test-all: PASS"
