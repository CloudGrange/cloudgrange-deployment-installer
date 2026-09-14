# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — guest-side install scripts:
#   - the hv-kvp-daemon UMask=0077 drop-in is written, with the right content, before the daemon is enabled or
#     started, by Install-DockerCe.ps1, first boot and generalize, and generalize refuses to build without it;
#   - /opt/cloudgrange is root-owned and not group/world-writable wherever root services execute from it
#     (Deploy-DockerCompose.ps1 and generalize), and the ownership step really produces that state;
#   - bootstrap-realm-admin.sh deletes the kcadm master-realm session file on success and on failure;
#   - gate prerequisites fail instead of skipping unless CLOUDGRANGE_TEST_ALLOW_SKIP=1.
# CLOUDGRANGE_REPO_UNDER_TEST points the tests at a different checkout (planted regressions).
import os
import re
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest

import gate_requirements as req

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("CLOUDGRANGE_REPO_UNDER_TEST", os.path.dirname(os.path.dirname(HERE)))
DROPIN_PATH = "/etc/systemd/system/hv-kvp-daemon.service.d/10-cloudgrange-umask.conf"
DROPIN_WRITE = "printf '[Service]\\nUMask=0077\\n' > " + DROPIN_PATH


def read(rel):
    with open(os.path.join(REPO, rel), encoding="utf-8") as f:
        return f.read().replace("\r\n", "\n")


class KvpUmaskDropInTests(unittest.TestCase):
    SCRIPTS = {
        "scripts/Install-DockerCe.ps1": r"systemctl (enable|restart) hv-kvp-daemon\.service",
        "appliance/cloudgrange-firstboot.sh": r"systemctl enable --now hv-kvp-daemon\.service",
        "appliance/cloudgrange-generalize.sh": r"systemctl enable hv-kvp-daemon\.service",
    }

    def test_every_script_writes_the_dropin_before_enabling_or_starting_the_daemon(self):
        for rel, start_pattern in self.SCRIPTS.items():
            with self.subTest(script=rel):
                text = read(rel)
                self.assertIn(DROPIN_WRITE, text, "%s does not write the UMask drop-in" % rel)
                start = re.search(start_pattern, text)
                self.assertIsNotNone(start, "%s does not enable/start hv-kvp-daemon" % rel)
                self.assertLess(text.index(DROPIN_WRITE), start.start(), "%s starts the daemon before writing the drop-in" % rel)
                reload_after = text.find("systemctl daemon-reload", text.index(DROPIN_WRITE))
                self.assertTrue(0 <= reload_after < start.start(), "%s must daemon-reload between the drop-in and the daemon start" % rel)

    def test_the_dropin_content_sets_umask_0077(self):
        root = tempfile.mkdtemp()
        try:
            target = root + DROPIN_PATH
            os.makedirs(os.path.dirname(target))
            subprocess.run(["bash", "-c", DROPIN_WRITE.replace(DROPIN_PATH, target)], check=True)
            with open(target) as f:
                lines = [l.strip() for l in f if l.strip()]
            self.assertEqual(lines, ["[Service]", "UMask=0077"])
        finally:
            shutil.rmtree(root, ignore_errors=True)

    def test_generalize_refuses_to_build_without_the_dropin(self):
        text = read("appliance/cloudgrange-generalize.sh")
        self.assertRegex(text, r"grep -qx 'UMask=0077' " + re.escape(DROPIN_PATH) + r" \|\| \{[^}]*exit 1")
        self.assertRegex(text, r"systemctl show -p UMask --value hv-kvp-daemon\.service\)\" = \"0077\" \] \|\| \{[^}]*exit 1")


class ComposeDirOwnershipTests(unittest.TestCase):
    OWNERSHIP = "chown -R root:root"

    def test_deploy_hands_the_compose_dir_to_root_before_root_services_run(self):
        text = read("scripts/Deploy-DockerCompose.ps1")
        bash = text[text.index("$bashDeploy = @\""):text.index("\"@", text.index("$bashDeploy = @\""))]
        own = bash.find(self.OWNERSHIP + " $composeDir")
        self.assertGreaterEqual(own, 0, "deploy script does not chown the compose dir to root")
        self.assertIn("chmod -R go-w $composeDir", bash)
        self.assertLess(own, bash.index("systemctl restart cloudgrange.service"))
        self.assertLess(own, bash.index("systemctl restart cloudgrange-realm-admin.service"))
        self.assertNotRegex(text, r"chown cloudgrange:cloudgrange \$composeDir", "the compose dir must not be handed to cloudgrange")

    def test_generalize_ships_a_root_owned_compose_dir_and_verifies_it(self):
        text = read("appliance/cloudgrange-generalize.sh")
        self.assertIn(self.OWNERSHIP + " \"$COMPOSE_DIR\"", text)
        self.assertIn("chmod -R go-w \"$COMPOSE_DIR\"", text)
        self.assertRegex(text, r"find \"\$COMPOSE_DIR\" \\\( ! -user root -o -perm /022 \\\)")

    def test_the_ownership_step_leaves_nothing_writable_by_cloudgrange(self):
        req.require(req.is_root(), "root (to chown a test tree)")
        root = tempfile.mkdtemp()
        try:
            d = os.path.join(root, "cloudgrange")
            os.makedirs(os.path.join(d, "keycloak"))
            for rel, mode in (("docker-compose.yml", 0o664), ("keycloak/bootstrap-realm-admin.sh", 0o775)):
                p = os.path.join(d, rel)
                open(p, "w").close()
                os.chmod(p, mode)
            os.chmod(os.path.join(d, "keycloak"), 0o775)
            for dirpath, dirnames, filenames in os.walk(d):
                for n in dirnames + filenames:
                    os.chown(os.path.join(dirpath, n), 1000, 1000)
            os.chown(d, 1000, 1000)
            subprocess.run(["bash", "-c", 'COMPOSE_DIR="$1"; chown -R root:root "$COMPOSE_DIR"; chmod -R go-w "$COMPOSE_DIR"; find "$COMPOSE_DIR" \\( ! -user root -o -perm /022 \\) | head -1', "_", d], check=True, capture_output=True)
            offenders = subprocess.run(["find", d, "(", "!", "-user", "root", "-o", "-perm", "/022", ")"], capture_output=True, text=True).stdout.strip()
            self.assertEqual(offenders, "")
        finally:
            shutil.rmtree(root, ignore_errors=True)


BOOTSTRAP_DOCKER_STUB = textwrap.dedent(r"""
    #!/bin/bash
    echo "$*" >> "$FAKE_ROOT/docker.calls"
    case "$*" in
      *"keycloak rm -f /tmp/kcadm-cloudgrange.config"*) exit 0 ;;
      *"kcadm.sh config credentials"*) exit 0 ;;
      *"kcadm.sh get realms/cloudgrange"*) echo '{ "realm" : "cloudgrange" }'; exit 0 ;;
      *"kcadm.sh get users -r cloudgrange"*) echo '[ ]'; exit 0 ;;
      *"kcadm.sh create users"*) cat > /dev/null; [ -f "$FAKE_ROOT/fail_create" ] && exit 1; exit 0 ;;
      *"kcadm.sh add-roles"*) exit 0 ;;
    esac
    echo "unexpected docker call: $*" >&2
    exit 99
""").lstrip()


class RealmAdminBootstrapSessionTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, "compose"))
        os.makedirs(os.path.join(self.root, "bin"))
        with open(os.path.join(self.root, "compose", ".env"), "w") as f:
            f.write("CLOUDGRANGE_REALM_ADMIN_PASSWORD=%s\nKEYCLOAK_ADMIN_USER=admin\nKEYCLOAK_ADMIN_PASSWORD=%s\n" % ("a" * 48, "b" * 48))
        with open(os.path.join(self.root, "bin", "docker"), "w") as f:
            f.write(BOOTSTRAP_DOCKER_STUB)
        os.chmod(os.path.join(self.root, "bin", "docker"), 0o755)
        self.env = dict(os.environ, FAKE_ROOT=self.root, CLOUDGRANGE_COMPOSE_DIR=os.path.join(self.root, "compose"),
                        PATH=os.path.join(self.root, "bin") + os.pathsep + os.environ.get("PATH", ""))

    def tearDown(self):
        shutil.rmtree(self.root, ignore_errors=True)

    def run_bootstrap(self):
        r = subprocess.run(["bash", os.path.join(REPO, "compose", "keycloak", "bootstrap-realm-admin.sh")], env=self.env, capture_output=True, text=True, timeout=60)
        with open(os.path.join(self.root, "docker.calls")) as f:
            return r, f.read()

    def test_session_file_is_deleted_after_a_successful_bootstrap(self):
        r, calls = self.run_bootstrap()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("kcadm.sh create users", calls)
        self.assertTrue(calls.rstrip().endswith("keycloak rm -f /tmp/kcadm-cloudgrange.config"), "session file not deleted last:\n" + calls)

    def test_session_file_is_deleted_when_the_bootstrap_fails(self):
        open(os.path.join(self.root, "fail_create"), "w").close()
        r, calls = self.run_bootstrap()
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(calls.rstrip().endswith("keycloak rm -f /tmp/kcadm-cloudgrange.config"), "session file not deleted on failure:\n" + calls)


class GateRequirementsTests(unittest.TestCase):
    CODE = "import sys; sys.path.insert(0, %r); import gate_requirements as g, unittest\n" \
           "try:\n    g.require(False, 'a prerequisite')\nexcept unittest.SkipTest:\n    sys.exit(10)\nexcept AssertionError:\n    sys.exit(20)\nsys.exit(0)\n" % HERE

    def run_code(self, **env):
        e = dict(os.environ)
        e.pop(req.ALLOW_SKIP_ENV, None)
        e.update(env)
        return subprocess.run([sys.executable, "-c", self.CODE], env=e).returncode

    def test_missing_prerequisite_fails_by_default(self):
        self.assertEqual(self.run_code(), 20)

    def test_missing_prerequisite_skips_only_with_the_explicit_flag(self):
        self.assertEqual(self.run_code(CLOUDGRANGE_TEST_ALLOW_SKIP="1"), 10)
        self.assertEqual(self.run_code(CLOUDGRANGE_TEST_ALLOW_SKIP="true"), 20)


if __name__ == "__main__":
    unittest.main()
