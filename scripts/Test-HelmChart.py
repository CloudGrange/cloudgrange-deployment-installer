#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9181 — local verification gate for charts/cloudgrange, run in WSL before merging
# chart changes or cutting a release. Deliberately NOT a GitHub Actions check: Actions
# minutes are billed personally and this repo's CI stays checks-light (the same policy
# already governing the Compose stack's scripts/Test-ComposeHardening.py, which this
# script mirrors in shape and fail-closed philosophy).
#
# Three stages, each must pass before the next runs:
#   1. `helm lint` against every values profile (single-node, multi-node, azure).
#   2. `helm template` against every values profile — catches rendering errors lint
#      alone won't, e.g. type errors inside `if`/`range` blocks that lint doesn't
#      evaluate for every branch.
#   3. A REAL k3d install of the single-node profile (the only one that's actually
#      deployable today — multi-node/azure are documented skeletons, AB#9190/AB#9187),
#      polling every pod for Ready. This is the stage that has caught every real bug
#      found during AB#9177-9180 development — hook-ordering failures, K8s admission
#      rejections, env-var interpolation bugs, CRD-validation ordering — none of which
#      helm lint or helm template alone would have caught. See AB#9177-9180 PR bodies
#      in cloudgrange-deployment-installer for the specific bugs this stage would have
#      caught before merge.
#
# Usage: Test-HelmChart.py [--skip-cluster]
#   --skip-cluster   Run only stages 1-2 (lint/template). Useful for a fast pre-commit
#                     check; the real cluster stage takes several minutes and needs
#                     k3d+helm+kubectl installed (this script does not install them —
#                     see charts/cloudgrange/README.md for the one-time WSL setup).
import argparse
import os
import subprocess
import sys
import time
import uuid

CHARTS_DIR = "charts"
CHART_PATH = "cloudgrange"
PROFILES = ["values-single-node.yaml", "values-multi-node.yaml", "values-azure.yaml"]
DEPLOYABLE_PROFILE = "values-single-node.yaml"
CERT_MANAGER_CHART = "vendor/cert-manager-v1.21.2.tgz"


def run(cmd, cwd=CHARTS_DIR, check=True, capture=True):
    print("+ " + " ".join(cmd))
    result = subprocess.run(cmd, cwd=cwd, capture_output=capture, text=True)
    if capture and result.stdout:
        print(result.stdout)
    if capture and result.stderr:
        print(result.stderr, file=sys.stderr)
    if check and result.returncode != 0:
        raise SystemExit(f"GATE FAIL: command failed ({result.returncode}): {' '.join(cmd)}")
    return result


def check_prereqs():
    for tool in ("helm", "kubectl", "k3d"):
        result = subprocess.run(["which", tool], capture_output=True, text=True)
        if result.returncode != 0:
            raise SystemExit(
                f"GATE FAIL: '{tool}' not found on PATH. See charts/cloudgrange/README.md "
                "for one-time WSL setup (k3d/helm/kubectl install)."
            )


def stage_lint():
    print("\n=== Stage 1: helm lint (all profiles) ===")
    for profile in PROFILES:
        run(["helm", "lint", CHART_PATH, "-f", f"{CHART_PATH}/{profile}"])
    print("Stage 1 PASSED.")


def stage_template():
    print("\n=== Stage 2: helm template (all profiles) ===")
    for profile in PROFILES:
        run(["helm", "template", "cgtest", CHART_PATH, "-f", f"{CHART_PATH}/{profile}"])
    print("Stage 2 PASSED.")


def stage_real_install():
    print("\n=== Stage 3: real k3d install (values-single-node.yaml) ===")
    cluster = f"cgverify-{uuid.uuid4().hex[:8]}"
    try:
        run(["k3d", "cluster", "create", cluster, "--wait", "--timeout", "120s"])
        kubeconfig = run(["k3d", "kubeconfig", "write", cluster], capture=True).stdout.strip()
        os.environ["KUBECONFIG"] = kubeconfig

        run(["helm", "install", "cert-manager", CERT_MANAGER_CHART,
             "--set", "crds.enabled=true", "--namespace", "cert-manager",
             "--create-namespace", "--wait", "--timeout", "3m"])

        run(["helm", "install", "cg", CHART_PATH, "-f", f"{CHART_PATH}/{DEPLOYABLE_PROFILE}",
             "--timeout", "4m", "--wait"], check=False)

        # Give the cluster a few seconds to settle, then check pod readiness directly
        # rather than trusting --wait's single pass/fail.
        #
        # NO per-pod exemptions below, ever. This gate used to classify any not-Ready
        # cloudgrange-portal pod as "known/expected ... not a chart defect" and still print
        # "Stage 3 PASSED". The portal was genuinely broken on Kubernetes the whole time
        # (a non-numeric image USER, which K8s cannot verify against runAsNonRoot), and this
        # exemption — plus matching ones in the installer's own two gates — is why it
        # reached a customer's real server with "install complete" printed over it.
        # A gate taught to ignore the component that is failing is worse than no gate.
        time.sleep(10)
        result = run(["kubectl", "get", "pods", "--no-headers"], check=False)
        lines = [l for l in result.stdout.splitlines() if l.strip()]

        # "READY" column is "N/M" — ready iff N == M, except Completed Jobs (0/1
        # Completed is expected there, not a failure).
        failures = []
        for line in lines:
            cols = line.split()
            name, ready, status = cols[0], cols[1], cols[2]
            if status == "Completed":
                continue
            n, m = ready.split("/")
            if n != m:
                failures.append(f"{name}: {ready} {status}")

        if failures:
            raise SystemExit(f"GATE FAIL: pods not Ready: {failures}")

        print("Stage 3 PASSED (every pod Ready).")
    finally:
        subprocess.run(["k3d", "cluster", "delete", cluster], capture_output=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--skip-cluster", action="store_true",
                         help="Run only lint+template, skip the real k3d install")
    args = parser.parse_args()

    stage_lint()
    stage_template()
    if not args.skip_cluster:
        check_prereqs()
        stage_real_install()
    else:
        print("\n(--skip-cluster passed — stage 3 real install skipped)")

    print("\nALL STAGES PASSED.")


if __name__ == "__main__":
    main()
