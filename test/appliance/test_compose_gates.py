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
        proxied = re.findall(r"(?m)^\s*location\s+(\S+\s+)?(\S+)\s*\{(?:(?!\n\s*location).)*?proxy_pass", body, re.S)
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


if __name__ == "__main__":
    unittest.main()
