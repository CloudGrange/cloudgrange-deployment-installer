#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Release gate: container hardening for compose/docker-compose.yml. Renders the file with
# `docker compose config --format json` (so YAML anchors and merges are resolved exactly as Docker
# applies them) and fails (exit 1) on any violation:
#   - every service: cap_drop contains ALL, security_opt contains no-new-privileges:true
#   - cap_add only from the per-service allowlist below
#   - every long-running service has a healthcheck (not disabled); one-shot helpers are allowlisted
#   - no privileged, devices, pid/ipc/uts/userns host namespaces, network_mode host, or docker.sock /
#     /var/run / / (root) bind mounts
#   - read_only root filesystem except the allowlist (portal and keycloak rewrite themselves at start)
#   - host ports only on nginx, only 80 and 443
#   - no service runs as uid 0 by explicit user, and keycloak does not use uid 1000 (the VM's sudo user)
# Usage: Test-ComposeHardening.py <compose-dir>
import json
import os
import subprocess
import sys

CAP_ADD_ALLOWED = {
    "nginx": {"CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"},
    "cloudgrange-portal": {"CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"},
    "postgres": {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID"},
}
WRITABLE_ROOT_ALLOWED = {"cloudgrange-portal", "keycloak"}
ONE_SHOT_ALLOWED = {"healthcheck-tools"}
HOST_PORTS_ALLOWED = {"nginx": {"80", "443"}}
FORBIDDEN_MOUNT_SOURCES = ("/var/run/docker.sock", "/run/docker.sock", "/var/run", "/run", "/")


def render(compose_dir):
    env = dict(os.environ)
    env.setdefault("CLOUDGRANGE_HOSTNAME", "hardening-gate.invalid")
    proc = subprocess.run(
        ["docker", "compose", "-f", os.path.join(compose_dir, "docker-compose.yml"), "config", "--format", "json"],
        capture_output=True, text=True, env=env)
    if proc.returncode != 0:
        errors = "\n".join(l for l in proc.stderr.splitlines() if "level=warning" not in l)
        raise SystemExit("HARDENING-GATE FAIL: docker compose config failed:\n" + errors)
    return json.loads(proc.stdout)


def check(model):
    violations = []
    services = model.get("services") or {}
    if not services:
        return ["no services rendered"]
    for name, svc in sorted(services.items()):
        def bad(msg):
            violations.append("%s: %s" % (name, msg))
        cap_drop = {c.upper().replace("CAP_", "") for c in (svc.get("cap_drop") or [])}
        if "ALL" not in cap_drop:
            bad("cap_drop ALL missing")
        cap_add = {c.upper().replace("CAP_", "") for c in (svc.get("cap_add") or [])}
        extra = cap_add - CAP_ADD_ALLOWED.get(name, set())
        if extra:
            bad("cap_add not allowlisted: %s" % ",".join(sorted(extra)))
        if "no-new-privileges:true" not in [s.replace("=", ":").replace(" ", "") for s in (svc.get("security_opt") or [])]:
            bad("security_opt no-new-privileges:true missing")
        restart = str(svc.get("restart", ""))
        one_shot = name in ONE_SHOT_ALLOWED and restart in ("no", "")
        hc = svc.get("healthcheck")
        if not one_shot and (not hc or hc.get("disable") or not hc.get("test") or hc.get("test") == ["NONE"]):
            bad("healthcheck missing or disabled")
        if name in ONE_SHOT_ALLOWED and not one_shot:
            bad("allowlisted one-shot helper must use restart: \"no\"")
        if svc.get("privileged"):
            bad("privileged")
        if svc.get("devices"):
            bad("devices mapped")
        for ns in ("pid", "ipc", "uts", "userns_mode", "cgroup"):
            if str(svc.get(ns, "")).lower() == "host":
                bad("%s: host" % ns)
        if str(svc.get("network_mode", "")).lower() == "host":
            bad("network_mode: host")
        for vol in svc.get("volumes") or []:
            source = str(vol.get("source", "")) if isinstance(vol, dict) else str(vol).split(":")[0]
            vtype = vol.get("type", "") if isinstance(vol, dict) else ""
            if vtype == "bind" or source.startswith("/"):
                normalized = source.rstrip("/") or "/"
                if normalized in FORBIDDEN_MOUNT_SOURCES or "docker.sock" in normalized:
                    bad("forbidden host mount %s" % source)
        if name not in WRITABLE_ROOT_ALLOWED and not svc.get("read_only"):
            bad("read_only root filesystem missing")
        for port in svc.get("ports") or []:
            published = str(port.get("published", "")) if isinstance(port, dict) else str(port)
            if published and published not in HOST_PORTS_ALLOWED.get(name, set()):
                bad("host port %s not allowed" % published)
        user = str(svc.get("user", ""))
        if user.split(":")[0] in ("0", "root"):
            bad("runs as root by explicit user")
        if name == "keycloak" and user.split(":")[0] in ("", "1000"):
            bad("keycloak must not run as uid 1000 (the VM's sudo account); set a dedicated uid")
    return violations


def main(argv):
    if len(argv) != 2:
        print("usage: Test-ComposeHardening.py <compose-dir>", file=sys.stderr)
        return 2
    model = render(argv[1])
    violations = check(model)
    if violations:
        for v in violations:
            print("HARDENING-GATE FAIL: " + v, file=sys.stderr)
        return 1
    print("hardening gate passed: %d services" % len(model["services"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
