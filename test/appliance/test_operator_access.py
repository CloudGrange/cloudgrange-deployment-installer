# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — cloudgrange-operator-access.sh end to end with the real cloudgrange-kvp.py and a stub `docker`:
# publication (KVP + console banner, root-only modes), token freshness (an expired token is never published),
# temporary-password rotation and its UPDATE_PASSWORD guard, the rotation ceiling (setup-stale), kcadm session
# cleanup, and the post-setup cleanup (KVP delete, banner shred, operator key removal, API token-file removal).
# Runs as root: sudo python3 -m unittest discover -s test/appliance  (missing root FAILS; see gate_requirements)
# CLOUDGRANGE_OPERATOR_ACCESS_UNDER_TEST points the tests at a different copy (planted regressions).
import hashlib
import os
import secrets
import shutil
import stat
import subprocess
import tempfile
import textwrap
import time
import unittest

import gate_requirements as req

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
        if [ -f "$F/new_token_on_restart" ]; then cp "$F/new_token_on_restart" "$F/token"; touch "$F/token"; fi
        exit 0 ;;
      *"cloudgrange-api curl -sf http://localhost:8080/health/ready"*) exit 0 ;;
      *"cloudgrange-api curl -sf http://localhost:8080/api/v1/setup/status"*)
        if [ -f "$F/token_required" ]; then req=true; else req=false; fi
        if [ -f "$F/complete" ]; then echo '{"setupComplete":true,"setupTokenRequired":false}'; else echo "{\"setupComplete\":false,\"setupTokenRequired\":$req}"; fi; exit 0 ;;
      *"cloudgrange-api cat /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        [ -f "$F/token" ] && cat "$F/token"; exit 0 ;;
      *"cloudgrange-api stat -c %Y /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        [ -f "$F/token" ] && stat -c %Y "$F/token"; exit 0 ;;
      *"cloudgrange-api test -e /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        [ -f "$F/token" ]; exit $? ;;
      *"cloudgrange-api rm -f /etc/cloudgrange/secrets/cloudgrange-initial-admin-token.txt"*)
        rm -f "$F/token"; exit 0 ;;
      *"keycloak rm -f /tmp/kcadm-cloudgrange.config"*) exit 0 ;;
      *"kcadm.sh config credentials"*) exit 0 ;;
      *"kcadm.sh get users -r cloudgrange"*)
        if [ -f "$F/user_missing" ]; then echo '[ ]'; else echo '[ { "id" : "u-1" } ]'; fi; exit 0 ;;
      *"kcadm.sh get users/u-1"*)
        if [ -f "$F/required_actions" ]; then cat "$F/required_actions"; else echo '{ "requiredActions" : [ "UPDATE_PASSWORD" ] }'; fi; exit 0 ;;
      *"kcadm.sh update users/u-1/reset-password"*) cat > "$F/reset-password.json"; exit 0 ;;
    esac
    echo "unexpected docker call: $args" >&2
    exit 99
""").lstrip()

# Wraps the real KVP tool and records, for every `set`, the key and a SHA-256 of the value, so tests can prove
# which values were ever published (not just the final state).
KVP_WRAPPER = textwrap.dedent(r"""
    #!/bin/bash
    if [ "$1" = set ]; then
        tmp=$(mktemp); cat > "$tmp"
        printf '%s %s\n' "$2" "$(sha256sum < "$tmp" | cut -c1-64)" >> "$FAKE_ROOT/kvp.sets"
        python3 "$REAL_KVP_TOOL" "$@" < "$tmp"; rc=$?; rm -f "$tmp"; exit $rc
    fi
    exec python3 "$REAL_KVP_TOOL" "$@"
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


def sha(value):
    return hashlib.sha256(value.encode()).hexdigest()


class OperatorAccessTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        req.require(req.is_root(), "root (the KVP pool must be root-owned)")

    def setUp(self):
        self.root = tempfile.mkdtemp()
        j = self.j = lambda *p: os.path.join(self.root, *p)
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
        # Most tests model a platform configured to require the token; the default (no token) has its own tests.
        open(j("token_required"), "w").close()
        with open(j("compose", ".env"), "w") as f:
            f.write("KEYCLOAK_ADMIN_USER=admin\nKEYCLOAK_ADMIN_PASSWORD=%s\nCLOUDGRANGE_REALM_ADMIN_PASSWORD=%s\nCLOUDGRANGE_HOSTNAME=10.0.0.5\n"
                    % (secrets.token_hex(24), self.password))
        self.ssh_key = "-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n-----END OPENSSH PRIVATE KEY-----\n" % secrets.token_urlsafe(180)
        with open(j("operator", "operator_ed25519"), "w") as f:
            f.write(self.ssh_key)
        for name, content in (("docker", DOCKER_STUB), ("agetty", "#!/bin/sh\nexit 0\n"), ("kvp", KVP_WRAPPER)):
            with open(j("bin", name), "w") as f:
                f.write(content)
            os.chmod(j("bin", name), 0o755)
        self.issue = j("issue.d", "90-cloudgrange.issue")
        self.env = dict(os.environ,
                        PATH=j("bin") + os.pathsep + os.environ.get("PATH", ""),
                        FAKE_ROOT=self.root,
                        REAL_KVP_TOOL=KVP_TOOL,
                        CLOUDGRANGE_COMPOSE_DIR=j("compose"),
                        CLOUDGRANGE_STATE_DIR=j("state"),
                        CLOUDGRANGE_OPERATOR_KEYDIR=j("operator"),
                        CLOUDGRANGE_ISSUE_FILE=self.issue,
                        CLOUDGRANGE_KVP_TOOL=j("bin", "kvp"),
                        CLOUDGRANGE_KVP_POOL=self.pool,
                        CLOUDGRANGE_POLL_SECONDS="1")
        self.proc = None

    def tearDown(self):
        if self.proc and self.proc.poll() is None:
            self.proc.kill()
        shutil.rmtree(self.root, ignore_errors=True)

    # --- helpers -----------------------------------------------------------------------------------
    def start(self, **extra_env):
        env = dict(self.env, **extra_env)
        self.proc = subprocess.Popen(["bash", SCRIPT], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def wait_for(self, predicate, timeout=40, what="condition"):
        end = time.time() + timeout
        while time.time() < end:
            if predicate():
                return
            if self.proc and self.proc.poll() is not None and not predicate():
                self.fail("operator-access exited early (%s) while waiting for %s: %s" % (self.proc.returncode, what, self.proc.stdout.read().decode()))
            time.sleep(0.2)
        self.fail("timed out waiting for " + what)

    def finish(self):
        open(self.j("complete"), "w").close()
        out, _ = self.proc.communicate(timeout=40)
        self.assertEqual(self.proc.returncode, 0, out.decode())
        return out.decode()

    def calls(self):
        try:
            with open(self.j("docker.calls")) as f:
                return f.read()
        except FileNotFoundError:
            return ""

    def published_hashes(self, key):
        try:
            with open(self.j("kvp.sets")) as f:
                return [line.split()[1] for line in f if line.split()[0] == key]
        except FileNotFoundError:
            return []

    def banner_contains(self, text):
        try:
            with open(self.issue) as f:
                return text in f.read()
        except FileNotFoundError:
            return False

    def make_token_old(self, seconds=100000):
        old = time.time() - seconds
        os.utime(self.j("token"), (old, old))

    def assert_published_securely(self):
        items = read_pool(self.pool)
        self.assertEqual(items.get("CloudGrange.State"), b"setup-pending")
        self.assertEqual(items.get("CloudGrange.SetupToken"), self.token.encode())
        self.assertEqual(stat.S_IMODE(os.stat(self.pool).st_mode), 0o600)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.pool)).st_mode), 0o700)
        self.assertEqual(stat.S_IMODE(os.stat(self.issue).st_mode), 0o600)
        self.assertTrue(self.banner_contains(self.token))

    def assert_withdrawn(self, state):
        items = read_pool(self.pool)
        with open(self.pool, "rb") as f:
            raw = f.read()
        self.assertEqual(sorted(items), ["CloudGrange.Address", "CloudGrange.RealmAdminUser", "CloudGrange.SetupUrl", "CloudGrange.SshUser", "CloudGrange.State"])
        self.assertEqual(items["CloudGrange.State"], state.encode())
        self.assertNotIn(self.token.encode(), raw, "setup token left in the KVP pool")
        self.assertNotIn(b"OPENSSH PRIVATE KEY", raw, "SSH private key left in the KVP pool")
        self.assertFalse(os.path.exists(self.issue), "console banner not removed")
        self.assertFalse(os.path.exists(self.j("operator")), "operator key directory not removed")

    def assert_cleared(self, output):
        self.assert_withdrawn("setup-complete")
        self.assertFalse(os.path.exists(self.j("token")), "API token file not removed")
        self.assertTrue(os.path.exists(self.j("state", "operator-access-cleared")))
        self.assertNotIn(self.token, output)

    # --- publication and cleanup -------------------------------------------------------------------
    def test_publishes_root_only_then_clears_everything_after_setup(self):
        self.start()
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.State") == b"setup-pending" and os.path.exists(self.issue), what="publication")
        self.assert_published_securely()
        items = read_pool(self.pool)
        self.assertEqual(items.get("CloudGrange.RealmAdminPassword"), self.password.encode())
        self.assertIn(b"OPENSSH PRIVATE KEY", items.get("CloudGrange.SshPrivateKey", b""))
        self.assertFalse(os.path.exists(self.j("operator", "operator_ed25519")), "key file must be shredded after publication")
        output = self.finish()
        self.assert_cleared(output)
        self.assertNotIn(self.password, output)
        with open(self.pool, "rb") as f:
            self.assertNotIn(self.password.encode(), f.read(), "temporary password left in the KVP pool")

    def test_republishes_a_new_setup_token_while_pending(self):
        self.start()
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == self.token.encode(), what="first token")
        new = secrets.token_hex(32)
        with open(self.j("token"), "w") as f:
            f.write(new)
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == new.encode(), what="re-published token")
        self.wait_for(lambda: self.banner_contains(new), what="re-published banner")
        self.assertEqual(stat.S_IMODE(os.stat(self.issue).st_mode), 0o600)
        self.token = new
        self.assert_cleared(self.finish())

    # --- default platform: no setup token ---------------------------------------------------------
    def test_without_a_required_token_publishes_the_url_only_and_never_restarts_the_api(self):
        os.remove(self.j("token_required"))
        os.remove(self.j("token"))
        self.start()
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.State") == b"setup-pending" and os.path.exists(self.issue), what="publication")
        items = read_pool(self.pool)
        self.assertNotIn("CloudGrange.SetupToken", items)
        self.assertEqual(items.get("CloudGrange.SetupUrl"), b"https://10.0.0.5/setup")
        with open(self.issue) as f:
            banner = f.read()
        self.assertIn("https://10.0.0.5/setup", banner)
        self.assertNotIn("setup token", banner.lower())
        time.sleep(3)  # several poll cycles
        self.assertNotIn("restart cloudgrange-api", self.calls())
        self.assert_cleared(self.finish())

    # --- token freshness ---------------------------------------------------------------------------
    def test_an_expired_token_is_rotated_before_it_is_ever_published(self):
        new = secrets.token_hex(32)
        with open(self.j("new_token_on_restart"), "w") as f:
            f.write(new)
        self.make_token_old()
        expired = self.token
        self.start(CLOUDGRANGE_TOKEN_MAX_AGE_SECONDS="3600")
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == new.encode(), what="fresh token published")
        self.assertIn("restart cloudgrange-api", self.calls())
        self.assertNotIn(sha(expired), self.published_hashes("CloudGrange.SetupToken"), "an expired token was published")
        self.assertFalse(self.banner_contains(expired), "an expired token reached the banner")
        self.token = new
        self.assert_cleared(self.finish())

    def test_a_token_that_expires_while_pending_is_withdrawn_when_no_new_token_is_issued(self):
        self.start(CLOUDGRANGE_TOKEN_MAX_AGE_SECONDS="3600", CLOUDGRANGE_TOKEN_RESTART_BACKOFF_SECONDS="3600")
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.SetupToken") == self.token.encode(), what="first token")
        self.make_token_old()  # the API does not re-issue (no new_token_on_restart)
        self.wait_for(lambda: "CloudGrange.SetupToken" not in read_pool(self.pool), what="expired token withdrawn")
        self.wait_for(lambda: self.banner_contains("being re-issued") and not self.banner_contains(self.token), what="banner without the expired token")
        self.assert_cleared(self.finish())

    # --- rotation, guard, ceiling ------------------------------------------------------------------
    def test_rotates_the_temporary_password_after_the_setup_window_and_logs_kcadm_out(self):
        self.start(CLOUDGRANGE_SETUP_WINDOW_SECONDS="2", CLOUDGRANGE_MAX_ROTATIONS="5")
        self.wait_for(lambda: os.path.exists(self.j("reset-password.json")), what="password reset")
        with open(self.j("compose", ".env")) as f:
            env_pw = [l.split("=", 1)[1].strip() for l in f if l.startswith("CLOUDGRANGE_REALM_ADMIN_PASSWORD=")][0]
        self.assertNotEqual(env_pw, self.password)
        self.wait_for(lambda: read_pool(self.pool).get("CloudGrange.RealmAdminPassword") == env_pw.encode(), what="rotated password in KVP")
        self.wait_for(lambda: "keycloak rm -f /tmp/kcadm-cloudgrange.config" in self.calls(), what="kcadm session removed")
        calls = self.calls()
        self.assertLess(calls.index("reset-password"), calls.index("keycloak rm -f /tmp/kcadm-cloudgrange.config"))
        self.assert_cleared(self.finish())

    def test_rotation_never_overwrites_a_password_the_operator_chose(self):
        with open(self.j("required_actions"), "w") as f:
            f.write('{ "requiredActions" : [ ] }')
        self.start(CLOUDGRANGE_SETUP_WINDOW_SECONDS="2", CLOUDGRANGE_MAX_ROTATIONS="5")
        self.wait_for(lambda: "kcadm.sh get users/u-1" in self.calls(), what="guard evaluated")
        self.wait_for(lambda: "CloudGrange.RealmAdminPassword" not in read_pool(self.pool), what="temporary password withdrawn")
        # The banner is rewritten right after the KVP items; wait for it instead of racing it.
        self.wait_for(lambda: os.path.exists(self.issue) and not self.banner_contains(self.password), what="banner without the temporary password")
        self.assertFalse(os.path.exists(self.j("reset-password.json")), "rotation reset an operator-chosen password")
        with open(self.j("compose", ".env")) as f:
            self.assertIn("CLOUDGRANGE_REALM_ADMIN_PASSWORD=%s" % self.password, f.read())
        self.assert_cleared(self.finish())

    def test_rotation_with_the_user_missing_withdraws_the_password_without_a_reset(self):
        open(self.j("user_missing"), "w").close()
        self.start(CLOUDGRANGE_SETUP_WINDOW_SECONDS="2", CLOUDGRANGE_MAX_ROTATIONS="5")
        self.wait_for(lambda: "CloudGrange.RealmAdminPassword" not in read_pool(self.pool), what="temporary password withdrawn")
        self.assertFalse(os.path.exists(self.j("reset-password.json")))
        self.wait_for(lambda: "keycloak rm -f /tmp/kcadm-cloudgrange.config" in self.calls(), what="kcadm session removed")
        self.assert_cleared(self.finish())

    def test_publishing_stops_after_the_rotation_ceiling(self):
        self.start(CLOUDGRANGE_SETUP_WINDOW_SECONDS="2", CLOUDGRANGE_MAX_ROTATIONS="1")
        out, _ = self.proc.communicate(timeout=60)
        self.assertEqual(self.proc.returncode, 0, out.decode())
        self.assert_withdrawn("setup-stale")
        self.assertTrue(os.path.exists(self.j("state", "operator-access-stale")))
        self.assertIn("stopped publishing", out.decode())
        # A restart of the service must not publish again.
        self.proc = None
        r = subprocess.run(["bash", SCRIPT], env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("stale", r.stdout)
        self.assert_withdrawn("setup-stale")


if __name__ == "__main__":
    unittest.main()
