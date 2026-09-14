#!/usr/bin/env python3
# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — Release gate: container hardening for compose/docker-compose.yml. Two stages, both fail closed:
#
#  1. Raw YAML allowlist, BEFORE `docker compose config` renders anything (so include/extends/hooks and
#     host paths are refused before Docker resolves them):
#       - top-level keys: name, services, volumes, networks and x-* extension fields only
#         (no include, secrets, configs, models, ...)
#       - per-service keys: an explicit allowlist (no extends, post_start, pre_stop, secrets, configs,
#         privileged, devices, sysctls, env_file, build, volumes_from, ...)
#       - named volumes are plain local volumes: no driver, driver_opts (e.g. type=none o=bind device=/etc),
#         external or name
#       - service mounts: a declared named volume, or a read-only bind of a file or directory INSIDE the
#         release directory (./...); no absolute, home-relative, variable or ../ host paths; nothing mounted
#         at /; long-syntax only type volume/bind without extra bind options
#       - networks: plain bridge networks only; network_mode only "none"
#       - host ports: only nginx 80, 443 and 8443
#  2. Rendered model checks (`docker compose config --format json`, anchors and merges resolved as Docker
#     applies them):
#       - cap_drop ALL, security_opt no-new-privileges:true, cap_add only from a per-service allowlist
#       - a healthcheck on every long-running service (the one-shot helper is allowlisted)
#       - no privileged, devices, host namespaces, network_mode host
#       - every bind source resolves inside the release directory and is read-only; volumes carry no
#         driver options; no rendered secrets/configs
#       - read-only root filesystem except the allowlist (portal and keycloak rewrite themselves at start)
#       - no explicit root user; keycloak not uid 1000 (the VM's sudo account)
#  3. nginx/nginx.conf, the LAN agent listener (parsed, comments ignored):
#       - exactly one server on 8443, TLS; only `location ^~ /lan/v1/agents/` proxies; `location / { return 404; }`
#       - that location has exactly `limit_except GET POST { deny all; }`
#       - it returns 404 for the operator-only relay route reenrollment-approvals, case-insensitively, without
#         proxying (approval stays local to the appliance)
#       - cloudgrange-relay is referenced nowhere else (not from the 443 server)
# Usage: Test-ComposeHardening.py <compose-dir>
import json
import os
import re
import subprocess
import sys

try:
    import yaml
except ImportError:  # fail closed: the raw allowlist cannot run without a YAML parser
    yaml = None

TOP_LEVEL_ALLOWED = {"name", "services", "volumes", "networks"}
SERVICE_KEYS_ALLOWED = {
    "image", "restart", "read_only", "tmpfs", "expose", "environment", "volumes", "depends_on",
    "healthcheck", "networks", "cap_drop", "cap_add", "security_opt", "command", "ports", "user",
    "network_mode",
}
REJECT_REASONS = {
    "include": "include pulls in files outside this gate",
    "extends": "extends pulls service definitions from elsewhere",
    "post_start": "lifecycle hooks can run privileged commands",
    "pre_stop": "lifecycle hooks can run privileged commands",
    "secrets": "secrets/configs can read host files",
    "configs": "secrets/configs can read host files",
    "models": "not used by this stack",
}
CAP_ADD_ALLOWED = {
    "nginx": {"CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"},
    "cloudgrange-portal": {"CHOWN", "SETUID", "SETGID", "NET_BIND_SERVICE"},
    "postgres": {"CHOWN", "DAC_OVERRIDE", "FOWNER", "SETUID", "SETGID"},
}
WRITABLE_ROOT_ALLOWED = {"cloudgrange-portal", "keycloak"}
ONE_SHOT_ALLOWED = {"healthcheck-tools"}
HOST_PORTS_ALLOWED = {"nginx": {"80", "443", "8443"}}
NETWORK_MODES_ALLOWED = {"none"}


def within(root, path):
    root = os.path.realpath(root)
    path = os.path.realpath(path)
    return path == root or path.startswith(root + os.sep)


def check_bind_source(compose_dir, source, where, bad):
    if not source.startswith("./") or ".." in source.split("/") or "$" in source:
        bad("%s: host bind %s not allowed (only read-only paths inside the release directory, ./...)" % (where, source))
        return False
    if not within(compose_dir, os.path.join(compose_dir, source)):
        bad("%s: bind %s resolves outside the release directory" % (where, source))
        return False
    return True


def check_raw(compose_dir):
    violations = []

    def bad(msg):
        violations.append(msg)

    path = os.path.join(compose_dir, "docker-compose.yml")
    if yaml is None:
        return ["PyYAML is required for the raw allowlist check (apt install python3-yaml)"]
    try:
        with open(path) as f:
            doc = yaml.safe_load(f)
    except Exception as err:  # noqa: BLE001 - any parse failure fails the gate
        return ["cannot parse %s: %s" % (path, err)]
    if not isinstance(doc, dict):
        return ["%s is not a mapping" % path]

    for key in doc:
        if str(key).startswith("x-"):
            continue
        if key not in TOP_LEVEL_ALLOWED:
            bad("top-level key '%s' not allowed%s" % (key, (": " + REJECT_REASONS[key]) if key in REJECT_REASONS else ""))

    declared_volumes = set()
    for name, spec in (doc.get("volumes") or {}).items():
        declared_volumes.add(name)
        if spec not in (None, {}):
            keys = sorted(spec) if isinstance(spec, dict) else [str(spec)]
            bad("volume '%s': %s not allowed (only plain named volumes; no driver, driver_opts, external or name)" % (name, ",".join(keys)))

    for name, spec in (doc.get("networks") or {}).items():
        if spec not in (None, {}) and spec != {"driver": "bridge"}:
            bad("network '%s': only a plain bridge network is allowed" % name)

    services = doc.get("services")
    if not isinstance(services, dict) or not services:
        bad("no services defined")
        return violations
    for sname, svc in services.items():
        if not isinstance(svc, dict):
            bad("service '%s' is not a mapping" % sname)
            continue
        for key in svc:
            if key not in SERVICE_KEYS_ALLOWED:
                bad("service '%s': key '%s' not allowed%s" % (sname, key, (": " + REJECT_REASONS[key]) if key in REJECT_REASONS else ""))
        if "network_mode" in svc and svc["network_mode"] not in NETWORK_MODES_ALLOWED:
            bad("service '%s': network_mode '%s' not allowed" % (sname, svc["network_mode"]))
        for entry in svc.get("volumes") or []:
            where = "service '%s'" % sname
            if isinstance(entry, str):
                parts = entry.split(":")
                source, target = parts[0], (parts[1] if len(parts) > 1 else parts[0])
                options = parts[2].split(",") if len(parts) > 2 else []
                if target.rstrip("/") == "":
                    bad("%s: mount at / not allowed" % where)
                if source.startswith((".", "/", "~", "$")) or "/" in source or "$" in source:
                    if check_bind_source(compose_dir, source, where, bad) and "ro" not in options:
                        bad("%s: bind %s must be read-only" % (where, source))
                elif source not in declared_volumes:
                    bad("%s: volume '%s' is not declared at top level" % (where, source))
            elif isinstance(entry, dict):
                extra = set(entry) - {"type", "source", "target", "read_only"}
                if extra:
                    bad("%s: mount options %s not allowed" % (where, ",".join(sorted(extra))))
                target = str(entry.get("target", ""))
                if target.rstrip("/") == "":
                    bad("%s: mount at / not allowed" % where)
                mtype = entry.get("type")
                source = str(entry.get("source", ""))
                if mtype == "volume":
                    if source not in declared_volumes:
                        bad("%s: volume '%s' is not declared at top level" % (where, source))
                elif mtype == "bind":
                    if check_bind_source(compose_dir, source, where, bad) and entry.get("read_only") is not True:
                        bad("%s: bind %s must be read-only" % (where, source))
                else:
                    bad("%s: mount type '%s' not allowed" % (where, mtype))
            else:
                bad("%s: unsupported volume entry %r" % (where, entry))
        for tmp in svc.get("tmpfs") or []:
            if str(tmp).split(":")[0].rstrip("/") == "":
                bad("service '%s': tmpfs at / not allowed" % sname)
        for port in svc.get("ports") or []:
            published = str(port).split(":")[0] if not isinstance(port, dict) else str(port.get("published", ""))
            if published not in HOST_PORTS_ALLOWED.get(sname, set()):
                bad("service '%s': host port %s not allowed" % (sname, published))
    return violations


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


def check_rendered(model, compose_dir):
    violations = []
    for top in ("secrets", "configs"):
        if model.get(top):
            violations.append("rendered top-level %s not allowed" % top)
    for vname, vspec in (model.get("volumes") or {}).items():
        extra = set(vspec or {}) - {"name"}
        if extra:
            violations.append("volume '%s': %s not allowed" % (vname, ",".join(sorted(extra))))
    services = model.get("services") or {}
    if not services:
        return violations + ["no services rendered"]
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
        for key in ("privileged", "devices", "post_start", "pre_stop", "secrets", "configs", "volumes_from", "sysctls"):
            if svc.get(key):
                bad("%s not allowed" % key)
        for ns in ("pid", "ipc", "uts", "userns_mode", "cgroup"):
            if str(svc.get(ns, "")).lower() == "host":
                bad("%s: host" % ns)
        if str(svc.get("network_mode", "")).lower() == "host":
            bad("network_mode: host")
        for vol in svc.get("volumes") or []:
            vtype = vol.get("type", "")
            source = str(vol.get("source", ""))
            if str(vol.get("target", "")).rstrip("/") == "":
                bad("mount at / not allowed")
            if vtype == "bind":
                if not within(compose_dir, source):
                    bad("host bind %s outside the release directory" % source)
                elif not vol.get("read_only"):
                    bad("bind %s must be read-only" % source)
            elif vtype != "volume":
                bad("mount type %s not allowed" % vtype)
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


AGENT_LOCATION = ["^~", "/lan/v1/agents/"]
APPROVALS_PATHS = [
    "/lan/v1/agents/reenrollment-approvals",
    "/lan/v1/agents/ReEnrollment-Approvals",
    "/lan/v1/agents/REENROLLMENT-APPROVALS/",
    "/lan/v1/agents/reenrollment-approvals/extra",
]
AGENT_PATHS_ALLOWED = ["/lan/v1/agents/enroll", "/lan/v1/agents/a1/jobs", "/lan/v1/agents/a1/heartbeat"]


def nginx_parse(text):
    """Parse nginx.conf into [(directive, [args], children-or-None)]. Raises ValueError on bad structure."""
    tokens = []
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c.isspace():
            i += 1
        elif c == "#":
            while i < n and text[i] != "\n":
                i += 1
        elif c in "{};":
            tokens.append(("p", c))
            i += 1
        elif c in "\"'":
            j, buf = i + 1, []
            while j < n and text[j] != c:
                if text[j] == "\\" and j + 1 < n:
                    buf.append(text[j + 1])
                    j += 2
                    continue
                buf.append(text[j])
                j += 1
            if j >= n:
                raise ValueError("unterminated quote")
            tokens.append(("w", "".join(buf)))
            i = j + 1
        else:
            j = i
            while j < n and not text[j].isspace() and text[j] not in "{};":
                j += 1
            tokens.append(("w", text[i:j]))
            i = j

    def block(pos, nested):
        items = []
        while pos < len(tokens):
            if tokens[pos] == ("p", "}"):
                if not nested:
                    raise ValueError("unbalanced '}'")
                return items, pos + 1
            words = []
            while pos < len(tokens) and tokens[pos][0] == "w":
                words.append(tokens[pos][1])
                pos += 1
            if pos >= len(tokens) or not words:
                raise ValueError("unexpected end of directive")
            if tokens[pos] == ("p", ";"):
                items.append((words[0], words[1:], None))
                pos += 1
            elif tokens[pos] == ("p", "{"):
                children, pos = block(pos + 1, True)
                items.append((words[0], words[1:], children))
            else:
                raise ValueError("unexpected '}' after %s" % words[0])
        if nested:
            raise ValueError("missing '}'")
        return items, pos

    return block(0, False)[0]


def nginx_walk(items):
    for item in items or []:
        yield item
        yield from nginx_walk(item[2])


def returns_404(children):
    return any(d == "return" and a[:1] == ["404"] for d, a, _ in children or [])


def check_nginx(compose_dir):
    violations = []
    bad = violations.append
    path = os.path.join(compose_dir, "nginx", "nginx.conf")
    try:
        with open(path) as f:
            tree = nginx_parse(f.read())
    except (OSError, ValueError) as e:
        return ["nginx.conf: %s" % e]
    servers = [c for d, _, c in nginx_walk(tree) if d == "server" and c is not None]
    lan = [s for s in servers if any(d == "listen" and a and a[0].rsplit(":", 1)[-1] == "8443" for d, a, _ in s)]
    if len(lan) != 1:
        return ["8443: expected exactly one server listening on 8443, found %d" % len(lan)]
    server = lan[0]
    if not any(d == "listen" and a and a[0].rsplit(":", 1)[-1] == "8443" and "ssl" in a[1:] for d, a, _ in server):
        bad("8443: the listener must be TLS (listen 8443 ssl)")
    locations = [(a, c) for d, a, c in server if d == "location" and c is not None]
    proxied = [" ".join(a) for a, c in locations if any(d == "proxy_pass" for d, _, _ in nginx_walk(c))]
    if proxied != [" ".join(AGENT_LOCATION)]:
        bad("8443: only 'location %s' may proxy; proxying locations: %s" % (" ".join(AGENT_LOCATION), proxied))
    if not any(a == ["/"] and returns_404(c) for a, c in locations):
        bad("8443: 'location / { return 404; }' missing")
    agent = [c for a, c in locations if a == AGENT_LOCATION]
    agent_items = set()
    if not agent:
        bad("8443: 'location %s' missing" % " ".join(AGENT_LOCATION))
    else:
        children = agent[0]
        agent_items = {id(item) for item in nginx_walk(children)}
        limits = [(a, c) for d, a, c in children if d == "limit_except"]
        if (len(limits) != 1 or sorted(m.upper() for m in limits[0][0]) != ["GET", "POST"]
                or [(d, a) for d, a, _ in limits[0][1] or []] != [("deny", ["all"])]):
            bad("8443 /lan/v1/agents/: limit_except GET POST { deny all; } missing or changed")
        blocked = False
        for d, a, c in children:
            if d != "location" or c is None or len(a) != 2 or a[0] != "~*" or not returns_404(c):
                continue
            if any(d2 in ("proxy_pass", "limit_except") for d2, _, _ in nginx_walk(c)):
                continue
            try:
                rx = re.compile(a[1], re.I)
            except re.error:
                continue
            if all(rx.search(p) for p in APPROVALS_PATHS) and not any(rx.search(p) for p in AGENT_PATHS_ALLOWED):
                blocked = True
        if not blocked:
            bad("8443 /lan/v1/agents/: reenrollment-approvals must return 404 (case-insensitive "
                "'location ~* ^/lan/v1/agents/+reenrollment-approvals { return 404; }' inside the agent location)")
    for item in nginx_walk(tree):
        if any("cloudgrange-relay" in arg for arg in item[1]) and id(item) not in agent_items:
            bad("cloudgrange-relay referenced outside the 8443 agent location: %s %s" % (item[0], " ".join(item[1])))
    return violations


def main(argv):
    if len(argv) != 2:
        print("usage: Test-ComposeHardening.py <compose-dir>", file=sys.stderr)
        return 2
    compose_dir = os.path.realpath(argv[1])
    violations = check_raw(compose_dir)
    if violations:
        for v in violations:
            print("HARDENING-GATE FAIL (allowlist): " + v, file=sys.stderr)
        return 1
    violations = check_nginx(compose_dir)
    if violations:
        for v in violations:
            print("HARDENING-GATE FAIL (nginx): " + v, file=sys.stderr)
        return 1
    model = render(compose_dir)
    violations = check_rendered(model, compose_dir)
    if violations:
        for v in violations:
            print("HARDENING-GATE FAIL: " + v, file=sys.stderr)
        return 1
    print("hardening gate passed: %d services (raw allowlist and rendered checks; nginx 8443 agent route)" % len(model["services"]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
