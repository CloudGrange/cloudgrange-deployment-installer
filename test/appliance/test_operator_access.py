# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — cloudgrange-operator-access.sh end to end with the real cloudgrange-kvp.py and a stub `docker`:
# publication (KVP + console banner, root-only modes), republication and rotation while setup is pending,
# and the post-setup cleanup (KVP delete, banner shred, operator key removal, API token-file removal).
# Runs as root: sudo python3 -m unittest discover -s test/appliance
# CLOUDGRANGE_OPERATOR_ACCESS_UNDER_TEST points the tests at a different copy (planted regressions).
import os
import secrets
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SCRIPT = os.environ.get("CLOUDGRANGE_OPERATOR_ACCESS_UNDER_TEST", os.path.join(REPO, "appliance", "cloudgrange-operator-access.sh"))
KVP_TOOL = os.path.join(REPO, "appliance", "cloudgrange-kvp.py")

DOCKER_STUB = textwrap.dedent(r"""
    #!/bin/bash
    # Stub for `docker compose --env-file .env ...` as used by cloudgrange-operator-access.sh.
    F="$FAKE_ROOT"
    echo "$*" >> "$F/docker.calls"
    args="$*"
    case "$args" in
      *"restart cloudgrange-api"*)
        [ -f "$F/new_token_on_restart" ] && cp "$F/new_token_on_restart" "$F/token" && touch -d '@'"$(date +%s)" "$F/token"
        exit 0 ;;
      *"cloudgrange-api curl -sf http://localhost:8080/health/ready"*) exit 0 ;;
      *"cloudgrange-api curl -sf http://localhost:8080/api/v1/setup/status"*)
        if [ -f "$F/complete" ]; then echo '{"setupComplete":true}'; else echo '{"setupComplete":false}'; fi; exit 0 ;;
      *"cloudgrange-api cat /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        [ -f "$F/token" ] && cat "$F/token"; exit 0 ;;
      *"cloudgrange-api stat -c %Y /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        [ -f "$F/token" ] && stat -c %Y "$F/token"; exit 0 ;;
      *"cloudgrange-api test -e /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        [ -f "$F/token" ]; exit $? ;;
      *"cloudgrange-api rm -f /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        rm -f "$F/token"; exit 0 ;;
      *"kcadm.sh config credentials"*) exit 0 ;;
      *"kcadm.sh get users -r cloudgrange"*) echo '[ { "id" : "u-1" } ]'; exit 0 ;;
      *"kcadm.sh get users/u-1"*) echo '{ "requiredActions" : [ "UPDATE_PASSWORD" ] }'; exit 0 ;;
      *"kcadm.sh update users/u-1/reset-password"*) cat > "$F/reset-password.json"; exit 0 ;;
    esac
    echo "unexpected docker call: $args" >&2
    exit 99
""").lstrip()

RECORD = 2560


def read_pool(path):
    items = {}
    if not os.path.exists(path):
        return items
    with open(path, "rb") as f:
        data = f.read()
    for off in range(0, len(data) - len(data) % RECORD, RECORD):
        k = data[off:off + 512].split(b"\0", 1)[0].decode()
        v = data[off + 512:off + RECORD].split(b"\0", 1)[0]
        if k:
            items[k] = v
    return items


@unittest.skipUnless(hasattr(os, "geteuid") and os.geteuid() == 0, "requires root (KVP pool must be root-owned)")
class OperatorAccessTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        j = lambda *p: os.path.join(self.root, *p)
        for d in ("compose", "state", "bin", "issue.d", "operator", "hyperv"):
            os.makedirs(j(d))
        os.chmod(j("hyperv"), 0o755)  # as hv_kvp_daemon leaves it
        self.pool = j("hyperv", ".kvp_pool_1")
        open(self.pool, "wb").close()
        os.chmod(self.pool, 0o644)
        self.token = secrets.token_hex(32)
        self.password = secrets.token_hex(24)
        with open(j("token"), "w") as f:
            f.write(self.token)
        with open(j("compose", ".env"), "w") as f:
            f.write("KEYCLOAK_ADMIN_USER=admin\nKEYCLOAK_ADMIN_PASSWORD=%s\nCLOUDGRANGE_REALM_ADMIN_PASSWORD=%s\nCLOUDGRANGE_HOSTNAME=10.0.0.5\n"
                    % (secrets.token_hex(24), self.password))
        self.ssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n" % secrets.token_urlsafe(180)
        with open(j("operator", "operator_ed25519"), "w") as f:
            f.write(self.ssh_key)
        with open(j("bin", "docker"), "w") as f:
            f.write(DOCKER_STUB)
        with open(j("bin", "agetty"), "w") as f:
            f.write("#!/bin/sh\nexit 0\n")
        for b in ("docker", "agetty"):
            os.chmod(j("bin", b), 0o755)
        self.issue = j("issue.d", "90-cloudgrange.issue")
        self.env = dict(os.environ,
                        PATH=j("bin") + os.pathsep + os.environ.get("PATH", ""),
                        FAKE_ROOT=self.root,
                        CLOUDGRANGE_COMPOSE_DIR=j("compose"),
                        CLOUDGRANGE_STATE_DIR=j("state"),
                        CLOUDGRANGE_OPERATOR_KEYDIR=j("operator"),
                        CLOUDGRANGE_ISSUE_FILE=self.issue,
                        CLOUDGRANGE_KVP_TOOL=KVP_TOOL,
                        CLOUDGRANGE_KVP_POOL=self.pool,
                        CLOUDGRANGE_POLL_SECONDS="1")
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
        shutil.rmtree(self.root, ignore_errors=True)

    def start(self, **extra_env):
        env = dict(self.env, **extra_env)
        self.proc = subprocess.Popen(["bash", SCRIPT], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def wait_for(self, predicate, timeout=30, what="condition"):
        end = time.time() + timeout
        while time.time() < end:
            if predicate():
                return
            if self.proc and self.proc.poll() is not None and not predicate():
                self.fail("operator-access exited early (%s) while waiting for %s: %s" % (self.proc.returncode, what, self.proc.stdout.read().decode()))
            time.sleep(0.2)
        self.fail("timed out waiting for " + what)

    def finish(self):
        open(os.path.join(self.root, "complete"), "w").close()
        out, _ = self.proc.communicate(timeout=40)
        self.assertEqual(self.proc.returncode, 0, out.decode())
        return out.decode()

    def assert_published_securely(self):
        items = read_pool(self.pool)
        self.assertEqual(items.get("CloudGrange.State"), b"setup-pending")
        self.assertEqual(items.get("CloudGrange.SetupToken"), self.token.encode())
        self.assertEqual(stat.S_IMODE(os.stat(self.pool).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.pool)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.issue).st_mode), 0o600)
        with open(self.issue) as f:
            banner = f.read()
        self.assertIn(self.token, banner)

    def assert_cleared(self, output):
        items = read_pool(self.pool)
        with open(self.pool, "rb") as f:
            raw = f.read()
        self.assertEqual(sorted(items), ["CloudGrange.Address", "CloudGrange.RealmAdminUser", "CloudGrange.SetupUrl", "CloudGrange.SshUser", "CloudGrange.State"])
        self.assertEqual(items["CloudGrange.State"], b"setup-complete")
        self.assertNotIn(self.token.encode(), raw, "setup token left in the KVP pool")
        self.assertNotIn(b"OPENSSH PRIVATE KEY", raw, "SSH private key left in the KVP pool")
        self.assertFalse(os.path.exists(self.issue), "console banner not removed")
        self.assertFalse(os.path.exists(os.path.join(self.root, "operator")), "operator key directory not removed")
        self.assertFalse(os.path.exists(os.path.join(self.root, "token")), "API token file not removed")
        self.assertTrue(os.path.exists(os.path.join(self.root, "state", "operator-access-cleared")))
        self.assertNotIn(self.token, output)

    def test_publishes_root_only_then_clears_everything_after_setup(self):
        self.start()
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.State") == b"setup-pending" and os.path.exists(self.issue), what="publication")
        self.assert_published_securely()
        items = read_pool(self.pool)
        self.assertEqual(items.get("CloudGrange.RealmAdminPassword"), self.password.encode())
        self.assertIn(b"OPENSSH PRIVATE KEY", items.get("CloudGrange.SshPrivateKey", b""))
        self.assertFalse(os.path.exists(os.path.join(self.root, "operator", "operator_ed25519")), "key file must be shredded after publication")
        output = self.finish()
        self.assert_cleared(output)
        self.assertNotIn(self.password, output)
        with open(self.pool, "rb") as f:
            self.assertNotIn(self.password.encode(), f.read(), "temporary password left in the KVP pool")

    def test_republishes_a_new_setup_token_while_pending(self):
        self.start()
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == self.token.encode(), what="first token")
        new = secrets.token_hex(32)
        with open(os.path.join(self.root, "token"), "w") as f:
            f.write(new)
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == new.encode(), what="re-published token")

        def banner_has_new_token():
            try:
                with open(self.issue) as f:
                    return new in f.read()
            except FileNotFoundError:
                return False
        # The banner is rewritten right after the KVP items; wait for it instead of racing it.
        self.wait_for(banner_has_new_token, what="re-published banner")
        self.assertEqual(stat.S_IMODE(os.stat(self.issue).st_mode), 0o600)
        self.token = new
        self.assert_cleared(self.finish())

    def test_rotates_expired_token_and_temporary_password_after_the_setup_window(self):
        new = secrets.token_hex(32)
        with open(os.path.join(self.root, "new_token_on_restart"), "w") as f:
            f.write(new)
        self.start(CLOUDGRANGE_SETUP_WINDOW_SECONDS="2", CLOUDGRANGE_TOKEN_MAX_AGE_SECONDS="0")
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == new.encode(), what="rotated token")
        self.wait_for(lambda: os.path.exists(os.path.join(self.root, "reset-password.json")), what="password reset")
        with open(os.path.join(self.root, "compose", ".env")) as f:
            env_pw = [l.split("=", 1)[1].strip() for l in f if l.startswith("CLOUDGRANGE_REALM_ADMIN_PASSWORD=")][0]
        self.assertNotEqual(env_pw, self.password)
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.RealmAdminPassword") == env_pw.encode(), what="rotated password in KVP")
        with open(os.path.join(self.root, "docker.calls")) as f:
            self.assertIn("restart cloudgrange-api", f.read())
        self.token = new
        self.assert_cleared(self.finish())


if __name__ == "__main__":
    unittest.main()
