# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — release gates over compose/: the container hardening gate (scripts/Test-ComposeHardening.py) and
# the image pin gate (scripts/Test-ComposeImagePins.sh). Each test plants one regression in a temporary copy
# of compose/ and asserts the gate fails. Requires the docker CLI with the compose plugin.
#   python3 -m unittest discover -s test/appliance
import os
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HARDENING = os.path.join(REPO, "scripts", "Test-ComposeHardening.py")
PINS = os.path.join(REPO, "scripts", "Test-ComposeImagePins.sh")


def have_compose():
    try:
        return subprocess.run(["docker", "compose", "version"], capture_output=True).returncode == 0
    except FileNotFoundError:
        return False


@unittest.skipUnless(have_compose(), "docker compose is required")
class ComposeGateTests(unittest.TestCase):
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

    def hardening(self):
        return subprocess.run(["python3", HARDENING, self.compose_dir], capture_output=True, text=True)

    def service_block(self, name):
        m = re.search(r"(?ms)^  %s:\n.*?(?=^  [a-z][a-z0-9-]*:\n|^volumes:)" % re.escape(name), self.original)
        self.assertIsNotNone(m, name)
        return m.group(0)

    def replace_in_service(self, name, old, new):
        block = self.service_block(name)
        self.assertIn(old, block)
        return lambda text: text.replace(block, block.replace(old, new, 1), 1)

    def test_committed_compose_passes_the_hardening_gate(self):
        r = self.hardening()
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_removing_the_api_hardening_block_is_caught(self):
        self.plant(self.replace_in_service("cloudgrange-api", "    <<: *hardening\n", ""))
        r = self.hardening()
        self.assertEqual(r.returncode, 1)
        self.assertIn("cloudgrange-api: cap_drop ALL missing", r.stderr)
        self.assertIn("cloudgrange-api: security_opt no-new-privileges:true missing", r.stderr)

    def test_privileged_service_is_caught(self):
        self.plant(self.replace_in_service("grafana", "    restart: always\n", "    restart: always\n    privileged: true\n"))
        r = self.hardening()
        self.assertEqual(r.returncode, 1)
        self.assertIn("grafana: privileged", r.stderr)

    def test_docker_socket_mount_is_caught(self):
        self.plant(self.replace_in_service("prometheus", "      - prometheus_data:/prometheus\n", "      - prometheus_data:/prometheus\n      - /var/run/docker.sock:/var/run/docker.sock\n"))
        r = self.hardening()
        self.assertEqual(r.returncode, 1)
        self.assertIn("prometheus: forbidden host mount /var/run/docker.sock", r.stderr)

    def test_missing_healthcheck_is_caught(self):
        block = self.service_block("grafana")
        hc = re.search(r"(?ms)^    healthcheck:\n(?:^      .*\n)+", block).group(0)
        self.plant(lambda text: text.replace(block, block.replace(hc, ""), 1))
        r = self.hardening()
        self.assertEqual(r.returncode, 1)
        self.assertIn("grafana: healthcheck missing or disabled", r.stderr)

    def test_extra_host_port_is_caught(self):
        self.plant(self.replace_in_service("cloudgrange-api", "    expose:\n      - \"8080\"\n", "    ports:\n      - \"8081:8080\"\n"))
        r = self.hardening()
        self.assertEqual(r.returncode, 1)
        self.assertIn("cloudgrange-api: host port 8081 not allowed", r.stderr)

    def test_keycloak_on_uid_1000_is_caught(self):
        block = self.service_block("keycloak")
        user_line = re.search(r"(?m)^    user: .*\n", block).group(0)
        self.plant(lambda text: text.replace(block, block.replace(user_line, ""), 1))
        r = self.hardening()
        self.assertEqual(r.returncode, 1)
        self.assertIn("keycloak must not run as uid 1000", r.stderr)

    def test_pin_gate_fails_on_an_invalid_compose_file(self):
        self.plant(lambda text: text.replace("name: cloudgrange\n", "name: cloudgrange\nname: duplicate\n", 1))
        r = subprocess.run(["bash", PINS, self.compose_dir], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("PIN-GATE FAIL", r.stderr)


if __name__ == "__main__":
    unittest.main()
