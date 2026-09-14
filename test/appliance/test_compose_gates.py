# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — release gates over compose/: the container hardening gate (scripts/Test-ComposeHardening.py),
# the image pin gate (scripts/Test-ComposeImagePins.sh) and the nginx configuration. Each test plants one
# regression in a temporary copy of compose/ and asserts the gate fails. The r3 review vector
# (vectors/r3-allowlist-proof.docker-compose.yml, host paths via driver_opts bind, secrets file and a
# privileged post_start hook) must be rejected as a whole and per bypass.
# Requires the docker CLI with the compose plugin and PyYAML; missing prerequisites FAIL (gate_requirements).
#   python3 -m unittest discover -s test/appliance
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import uuid

import gate_requirements as req

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HARDENING = os.path.join(REPO, "scripts", "Test-ComposeHardening.py")
PINS = os.path.join(REPO, "scripts", "Test-ComposeImagePins.sh")
VECTOR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vectors", "r3-allowlist-proof.docker-compose.yml")
NGINX_IMAGE = "nginx:1.31.5-alpine@sha256:72ba65eb42c10344912a84ff42408db7d34f2feb642204570ab8fc5ffd29f1d3"


class ComposeGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        req.require(req.have_compose(), "the docker CLI with the compose plugin")
        req.require(req.have_yaml(), "PyYAML (python3-yaml)")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.compose_dir = os.path.join(self.tmp, "compose")
        shutil.copytree(os.path.join(REPO, "compose"), self.compose_dir)
        self.file = os.path.join(self.compose_dir, "docker-compose.yml")
        with open(self.file) as f:
            self.original = f.read()

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def plant(self, transform):
        text = transform(self.original)
        self.assertNotEqual(text, self.original, "plant did not change the compose file")
        with open(self.file, "w") as f:
            f.write(text)

    def hardening(self, compose_dir=None):
        return subprocess.run(["python3", HARDENING, compose_dir or self.compose_dir], capture_output=True, text=True)

    def assert_rejected(self, *fragments):
        r = self.hardening()
        self.assertEqual(r.returncode, 1, "gate did not fail:\n" + r.stdout + r.stderr)
        for fragment in fragments:
            self.assertIn(fragment, r.stderr)
        return r

    def service_block(self, name):
        m = re.search(r"(?ms)^  %s:\n.*?(?=^  [a-z][a-z0-9-]*:\n|^volumes:)" % re.escape(name), self.original)
        self.assertIsNotNone(m, name)
        return m.group(0)

    def replace_in_service(self, name, old, new):
        block = self.service_block(name)
        self.assertIn(old, block)
        return lambda text: text.replace(block, block.replace(old, new, 1), 1)

    def add_to_service(self, name, lines):
        return self.replace_in_service(name, "    restart: always\n", "    restart: always\n" + lines)

    # --- baseline --------------------------------------------------------------------------------
    def test_committed_compose_passes_the_hardening_gate(self):
        r = self.hardening()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("raw allowlist and rendered checks", r.stdout)

    # --- r3 review vector: s15b/allowlist-proof --------------------------------------------------
    def test_r3_review_vector_is_rejected_as_a_whole(self):
        vdir = os.path.join(self.tmp, "vector")
        os.makedirs(vdir)
        shutil.copy(VECTOR, os.path.join(vdir, "docker-compose.yml"))
        r = self.hardening(vdir)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("volume 'hostetc': driver,driver_opts not allowed", r.stderr)
        self.assertIn("service 'cloudgrange-api': key 'secrets' not allowed", r.stderr)
        self.assertIn("service 'cloudgrange-api': key 'post_start' not allowed", r.stderr)
        self.assertIn("top-level key 'secrets' not allowed", r.stderr)
        self.assertNotIn("hardening gate passed", r.stdout)

    def test_vector_named_volume_with_bind_driver_opts_is_rejected(self):
        self.plant(lambda t: self.add_to_service("grafana", "")(t).replace(
            "  grafana_data:\n", "  grafana_data:\n    driver: local\n    driver_opts:\n      type: none\n      o: bind\n      device: /etc\n", 1))
        self.assert_rejected("volume 'grafana_data': driver,driver_opts not allowed")

    def test_vector_secrets_file_outside_release_dir_is_rejected(self):
        self.plant(lambda t: self.add_to_service("cloudgrange-api", "    secrets:\n      - hostfile\n")(t)
                   + "secrets:\n  hostfile:\n    file: /etc/hostname\n")
        self.assert_rejected("top-level key 'secrets' not allowed", "service 'cloudgrange-api': key 'secrets' not allowed")

    def test_vector_configs_file_outside_release_dir_is_rejected(self):
        self.plant(lambda t: self.add_to_service("cloudgrange-api", "    configs:\n      - hostcfg\n")(t)
                   + "configs:\n  hostcfg:\n    file: /etc/passwd\n")
        self.assert_rejected("top-level key 'configs' not allowed", "service 'cloudgrange-api': key 'configs' not allowed")

    def test_vector_privileged_post_start_hook_is_rejected(self):
        self.plant(self.add_to_service("cloudgrange-api", "    post_start:\n      - command: [\"id\"]\n        user: root\n        privileged: true\n"))
        self.assert_rejected("service 'cloudgrange-api': key 'post_start' not allowed")

    # --- host paths ------------------------------------------------------------------------------
    def test_host_bind_etc_is_rejected(self):
        self.plant(self.replace_in_service("cloudgrange-api", "      - api_secrets:/etc/cloudgrange\n", "      - api_secrets:/etc/cloudgrange\n      - /etc:/hostetc:ro\n"))
        self.assert_rejected("service 'cloudgrange-api': host bind /etc not allowed")

    def test_long_syntax_host_bind_is_rejected(self):
        self.plant(self.replace_in_service("cloudgrange-api", "      - api_secrets:/etc/cloudgrange\n",
                                           "      - api_secrets:/etc/cloudgrange\n      - type: bind\n        source: /var/log\n        target: /hostlog\n        read_only: true\n"))
        self.assert_rejected("host bind /var/log not allowed")

    def test_relative_bind_escaping_the_release_dir_is_rejected(self):
        self.plant(self.replace_in_service("prometheus", "      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro\n", "      - ../../etc:/etc/prometheus/extra:ro\n"))
        self.assert_rejected("service 'prometheus': host bind ../../etc not allowed")

    def test_writable_release_dir_bind_is_rejected(self):
        self.plant(self.replace_in_service("prometheus", "      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro\n", "      - ./prometheus.yml:/etc/prometheus/prometheus.yml\n"))
        self.assert_rejected("service 'prometheus': bind ./prometheus.yml must be read-only")

    def test_volume_mapped_to_root_is_rejected(self):
        self.plant(self.replace_in_service("grafana", "      - grafana_data:/var/lib/grafana\n", "      - grafana_data:/\n"))
        self.assert_rejected("service 'grafana': mount at / not allowed")

    def test_external_volume_is_rejected(self):
        self.plant(lambda t: t.replace("  loki_data:\n", "  loki_data:\n    external: true\n", 1))
        self.assert_rejected("volume 'loki_data': external not allowed")

    def test_docker_socket_mount_is_caught(self):
        self.plant(self.replace_in_service("prometheus", "      - prometheus_data:/prometheus\n", "      - prometheus_data:/prometheus\n      - /var/run/docker.sock:/var/run/docker.sock\n"))
        self.assert_rejected("host bind /var/run/docker.sock not allowed")

    # --- composition keys -------------------------------------------------------------------------
    def test_include_is_rejected(self):
        self.plant(lambda t: t.replace("name: cloudgrange\n", "name: cloudgrange\ninclude:\n  - ../other/docker-compose.yml\n", 1))
        self.assert_rejected("top-level key 'include' not allowed")

    def test_extends_is_rejected(self):
        self.plant(self.add_to_service("grafana", "    extends:\n      file: ../other.yml\n      service: evil\n"))
        self.assert_rejected("service 'grafana': key 'extends' not allowed")

    def test_pre_stop_hook_is_rejected(self):
        self.plant(self.add_to_service("grafana", "    pre_stop:\n      - command: [\"id\"]\n"))
        self.assert_rejected("service 'grafana': key 'pre_stop' not allowed")

    def test_unknown_service_key_is_rejected(self):
        self.plant(self.add_to_service("grafana", "    sysctls:\n      net.ipv4.ip_forward: 1\n"))
        self.assert_rejected("service 'grafana': key 'sysctls' not allowed")

    def test_host_network_mode_is_rejected(self):
        self.plant(self.add_to_service("grafana", "    network_mode: host\n"))
        self.assert_rejected("service 'grafana': network_mode 'host' not allowed")

    # --- rendered hardening ------------------------------------------------------------------------
    def test_removing_the_api_hardening_block_is_caught(self):
        self.plant(self.replace_in_service("cloudgrange-api", "    <<: *hardening\n", ""))
        self.assert_rejected("cloudgrange-api: cap_drop ALL missing", "cloudgrange-api: security_opt no-new-privileges:true missing")

    def test_privileged_service_is_caught(self):
        self.plant(self.add_to_service("grafana", "    privileged: true\n"))
        self.assert_rejected("service 'grafana': key 'privileged' not allowed")

    def test_missing_healthcheck_is_caught(self):
        block = self.service_block("grafana")
        hc = re.search(r"(?ms)^    healthcheck:\n(?:^      .*\n)+", block).group(0)
        self.plant(lambda text: text.replace(block, block.replace(hc, ""), 1))
        self.assert_rejected("grafana: healthcheck missing or disabled")

    def test_extra_host_port_is_caught(self):
        self.plant(self.replace_in_service("cloudgrange-api", "    expose:\n      - \"8080\"\n", "    ports:\n      - \"8081:8080\"\n"))
        self.assert_rejected("service 'cloudgrange-api': host port 8081 not allowed")

    def test_relay_port_published_directly_is_caught(self):
        self.plant(self.replace_in_service("cloudgrange-relay", "    expose:\n      - \"8443\"\n", "    ports:\n      - \"8443:8443\"\n"))
        self.assert_rejected("service 'cloudgrange-relay': host port 8443 not allowed")

    def test_keycloak_on_uid_1000_is_caught(self):
        block = self.service_block("keycloak")
        user_line = re.search(r"(?m)^    user: .*\n", block).group(0)
        self.plant(lambda text: text.replace(block, block.replace(user_line, ""), 1))
        self.assert_rejected("keycloak must not run as uid 1000")

    # --- pin gate and nginx -----------------------------------------------------------------------
    def test_pin_gate_fails_on_an_invalid_compose_file(self):
        self.plant(lambda text: text.replace("name: cloudgrange\n", "name: cloudgrange\nname: duplicate\n", 1))
        r = subprocess.run(["bash", PINS, self.compose_dir], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PIN-GATE FAIL", r.stderr)

    def stamp_first_party(self, text):
        # What Set-FirstPartyImagePins.sh does at release time, with a placeholder digest (no pull needed).
        for svc in ("api", "portal", "relay"):
            old = "image: ghcr.io/cloudgrange/cloudgrange-%s:${CLOUDGRANGE_VERSION:-latest}\n" % svc
            self.assertIn(old, text)
            text = text.replace(old, "image: ghcr.io/cloudgrange/cloudgrange-%s:1.2.3@sha256:%s\n" % (svc, "a" * 64), 1)
        return text

    def pin_gate(self):
        return subprocess.run(["bash", PINS, self.compose_dir], capture_output=True, text=True)

    def test_pin_gate_passes_a_release_stamped_compose_file(self):
        self.plant(self.stamp_first_party)
        r = self.pin_gate()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("nginx:1.31.5-alpine@sha256:", r.stdout)

    def test_pin_gate_fails_on_a_moving_tag(self):
        # S01 planted regression: a vendor image on a moving tag (no digest) must fail the release gate.
        nginx_line = re.search(r"(?m)^    image: nginx:1\.31\.5-alpine@sha256:[0-9a-f]{64}\n", self.original).group(0)
        self.plant(lambda text: self.stamp_first_party(text).replace(nginx_line, "    image: nginx:latest\n", 1))
        r = self.pin_gate()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("PIN-GATE FAIL: not digest-pinned: nginx:latest", r.stderr)
        self.assertNotIn("nginx:latest", r.stdout)

    def test_pin_gate_fails_on_an_unstamped_first_party_image(self):
        # The committed compose uses ${CLOUDGRANGE_VERSION:-latest}; a bundle must never ship it unstamped.
        r = self.pin_gate()
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("PIN-GATE FAIL: not digest-pinned: ghcr.io/cloudgrange/cloudgrange-api:latest", r.stderr)

    def test_nginx_configuration_is_valid_and_publishes_only_agent_routes_on_8443(self):
        conf = os.path.join(REPO, "compose", "nginx", "nginx.conf")
        with open(conf) as f:
            text = f.read()
        server = re.search(r"(?ms)^    server \{\n        listen 8443 ssl;.*?^    \}\n", text)
        self.assertIsNotNone(server, "no TLS server on 8443")
        body = server.group(0)
        # Server-level locations only (8-space indent); nested ones are checked by the hardening gate's nginx stage.
        proxied = re.findall(r"(?m)^        location\s+(\S+\s+)?(\S+)\s*\{(?:(?!\n        (?:location|\})).)*?proxy_pass", body, re.S)
        self.assertEqual([p[1] for p in proxied], ["/lan/v1/agents/"], "8443 may only proxy the agent API")
        self.assertRegex(body, r"location / \{\s*return 404;")
        certs = os.path.join(self.tmp, "certs")
        os.makedirs(certs)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=gate",
                        "-keyout", os.path.join(certs, "cloudgrange.key"), "-out", os.path.join(certs, "cloudgrange.crt")],
                       check=True, capture_output=True)
        r = subprocess.run(["docker", "run", "--rm", "--network", "none",
                            "-v", conf + ":/etc/nginx/nginx.conf:ro", "-v", certs + ":/etc/nginx/certs:ro",
                            "--add-host", "cloudgrange-portal:127.0.0.1", "--add-host", "keycloak:127.0.0.1",
                            NGINX_IMAGE, "nginx", "-t"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    # --- nginx 8443 gate: method restriction and re-enrollment approvals ------------------------------
    LIMIT_EXCEPT = "            limit_except GET POST { deny all; }\n"
    APPROVALS_BLOCK = "            location ~* ^/lan/v1/agents/+reenrollment-approvals {\n                return 404;\n            }\n"

    def nginx_conf(self):
        return os.path.join(self.compose_dir, "nginx", "nginx.conf")

    def plant_nginx(self, old, new):
        with open(self.nginx_conf()) as f:
            text = f.read()
        self.assertIn(old, text, "nginx plant anchor missing")
        with open(self.nginx_conf(), "w") as f:
            f.write(text.replace(old, new, 1))

    def assert_nginx_rejected(self, fragment):
        r = self.hardening()
        self.assertEqual(r.returncode, 1, "gate did not fail:\n" + r.stdout + r.stderr)
        failures = [line for line in r.stderr.splitlines() if line.startswith("HARDENING-GATE FAIL (nginx): ")]
        self.assertTrue(any(fragment in line for line in failures), "expected nginx failure %r in:\n%s" % (fragment, r.stderr))

    def test_removing_limit_except_on_the_8443_agent_route_is_caught(self):
        self.plant_nginx(self.LIMIT_EXCEPT, "")
        self.assert_nginx_rejected("8443 /lan/v1/agents/: limit_except GET POST { deny all; } missing or changed")

    def test_widening_limit_except_on_the_8443_agent_route_is_caught(self):
        self.plant_nginx(self.LIMIT_EXCEPT, self.LIMIT_EXCEPT.replace("GET POST", "GET POST DELETE"))
        self.assert_nginx_rejected("limit_except GET POST { deny all; } missing or changed")

    def test_limit_except_that_allows_is_caught(self):
        self.plant_nginx(self.LIMIT_EXCEPT, self.LIMIT_EXCEPT.replace("deny all", "allow all"))
        self.assert_nginx_rejected("limit_except GET POST { deny all; } missing or changed")

    def test_removing_the_reenrollment_approvals_block_is_caught(self):
        self.plant_nginx(self.APPROVALS_BLOCK, "")
        self.assert_nginx_rejected("8443 /lan/v1/agents/: reenrollment-approvals must return 404")

    def test_case_sensitive_reenrollment_approvals_block_is_caught(self):
        self.plant_nginx(self.APPROVALS_BLOCK, self.APPROVALS_BLOCK.replace("~*", "~"))
        self.assert_nginx_rejected("reenrollment-approvals must return 404")

    def test_reenrollment_approvals_block_that_proxies_is_caught(self):
        self.plant_nginx(self.APPROVALS_BLOCK, self.APPROVALS_BLOCK.replace("return 404;", "proxy_pass $relay_upstream;"))
        self.assert_nginx_rejected("reenrollment-approvals must return 404")

    def test_relay_proxied_from_the_443_server_is_caught(self):
        self.plant_nginx("        # Portal health probe passthrough\n",
                         "        location /lan/ {\n            proxy_pass http://cloudgrange-relay:8443;\n        }\n\n        # Portal health probe passthrough\n")
        self.assert_nginx_rejected("cloudgrange-relay referenced outside the 8443 agent location")

    # --- nginx 8443 behaviour: the real nginx in front of a stub relay --------------------------------
    PROBES = [
        ("enroll", "POST", "/lan/v1/agents/enroll"),
        ("jobs", "GET", "/lan/v1/agents/a1/jobs"),
        ("delete", "DELETE", "/lan/v1/agents/enroll"),
        ("put", "PUT", "/lan/v1/agents/a1/jobs"),
        ("approvals", "POST", "/lan/v1/agents/reenrollment-approvals"),
        ("approvals_get", "GET", "/lan/v1/agents/reenrollment-approvals"),
        ("approvals_case", "POST", "/lan/v1/agents/ReEnrollment-Approvals"),
        ("approvals_trailing_slash", "POST", "/lan/v1/agents/reenrollment-approvals/"),
        ("approvals_encoded", "POST", "/lan/v1/agents/reenrollment%2Dapprovals"),
        ("approvals_double_slash", "POST", "/lan/v1/agents//reenrollment-approvals"),
        ("approvals_dot_segment", "POST", "/lan/v1/agents/./reenrollment-approvals"),
        ("approvals_traversal", "POST", "/lan/v1/agents/a1/../reenrollment-approvals"),
        ("metrics", "GET", "/metrics"),
        ("root", "GET", "/"),
    ]
    APPROVAL_PROBES = [name for name, _, _ in PROBES if name.startswith("approvals")]

    def probe_8443(self, conf):
        """Start the gateway nginx with `conf` and a stub relay on a private network; return {probe: (code, body)}."""
        tag = "cg8443-" + uuid.uuid4().hex[:10]
        certs = os.path.join(self.tmp, tag + "-certs")
        os.makedirs(certs)
        subprocess.run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1", "-subj", "/CN=gate",
                        "-keyout", os.path.join(certs, "cloudgrange.key"), "-out", os.path.join(certs, "cloudgrange.crt")],
                       check=True, capture_output=True)
        stub = os.path.join(self.tmp, tag + "-relay.conf")
        with open(stub, "w") as f:
            f.write('events {}\nhttp {\n  server {\n    listen 8443;\n'
                    '    location / { return 200 "relay:$request_method $request_uri"; }\n  }\n}\n')
        script = ["for i in $(seq 1 60); do curl -sk -o /dev/null https://gateway:8443/ && break; sleep 0.5; done"]
        for name, method, path in self.PROBES:
            script.append("printf '%s ' " + name + "; curl -sk --path-as-is -X " + method +
                          " -o /tmp/body -w '%{http_code}' 'https://gateway:8443" + path + "'; printf ' %s\\n' \"$(cat /tmp/body | tr '\\n' ' ')\"")
        try:
            subprocess.run(["docker", "network", "create", "--internal", tag], check=True, capture_output=True)
            subprocess.run(["docker", "run", "-d", "--name", tag + "-relay", "--network", tag, "--network-alias", "cloudgrange-relay",
                            "-v", stub + ":/etc/nginx/nginx.conf:ro", NGINX_IMAGE], check=True, capture_output=True)
            subprocess.run(["docker", "run", "-d", "--name", tag + "-gateway", "--network", tag, "--network-alias", "gateway",
                            "-v", conf + ":/etc/nginx/nginx.conf:ro", "-v", certs + ":/etc/nginx/certs:ro",
                            "--add-host", "cloudgrange-portal:127.0.0.1", "--add-host", "keycloak:127.0.0.1",
                            NGINX_IMAGE], check=True, capture_output=True)
            r = subprocess.run(["docker", "run", "--rm", "--network", tag, "--entrypoint", "sh", NGINX_IMAGE, "-c", "\n".join(script)],
                               capture_output=True, text=True, timeout=180)
            self.assertEqual(r.returncode, 0, r.stderr)
        finally:
            subprocess.run(["docker", "rm", "-f", tag + "-relay", tag + "-gateway"], capture_output=True)
            subprocess.run(["docker", "network", "rm", tag], capture_output=True)
        names = {name for name, _, _ in self.PROBES}
        results = {}
        for line in r.stdout.splitlines():
            parts = line.split(" ", 2)
            if len(parts) >= 2 and parts[0] in names:
                results[parts[0]] = (parts[1], parts[2].strip() if len(parts) > 2 else "")
        self.assertEqual(sorted(results), sorted(name for name, _, _ in self.PROBES), r.stdout)
        return results

    def test_8443_forwards_only_get_and_post_agent_calls_and_hides_reenrollment_approvals(self):
        r = self.probe_8443(os.path.join(REPO, "compose", "nginx", "nginx.conf"))
        self.assertEqual(r["enroll"], ("200", "relay:POST /lan/v1/agents/enroll"))
        self.assertEqual(r["jobs"], ("200", "relay:GET /lan/v1/agents/a1/jobs"))
        for name in ("delete", "put"):
            self.assertEqual(r[name][0], "403", (name, r[name]))
            self.assertNotIn("relay:", r[name][1])
        for name in self.APPROVAL_PROBES + ["metrics", "root"]:
            self.assertEqual(r[name][0], "404", (name, r[name]))
            self.assertNotIn("relay:", r[name][1], name)

    def test_8443_probe_sees_approvals_reach_the_relay_when_the_block_is_removed(self):
        self.plant_nginx(self.APPROVALS_BLOCK, "")
        r = self.probe_8443(self.nginx_conf())
        self.assertEqual(r["approvals"], ("200", "relay:POST /lan/v1/agents/reenrollment-approvals"))
        self.assertEqual(r["approvals_case"][0], "200")

    def test_8443_probe_sees_delete_reach_the_relay_when_limit_except_is_removed(self):
        self.plant_nginx(self.LIMIT_EXCEPT, "")
        r = self.probe_8443(self.nginx_conf())
        self.assertEqual(r["delete"], ("200", "relay:DELETE /lan/v1/agents/enroll"))


if __name__ == "__main__":
    unittest.main()
