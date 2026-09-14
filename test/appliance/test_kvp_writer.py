# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — cloudgrange-kvp.py: record format, overwrite-on-delete and guest-side pool permissions.
# Runs as root (the tool requires root-owned pool paths): sudo python3 -m unittest discover -s test/appliance
# CLOUDGRANGE_KVP_TOOL_UNDER_TEST points the tests at a different copy (used to prove planted regressions fail).
import os
import secrets
import shutil
import stat
import subprocess
import tempfile
import unittest

import gate_requirements as req

REPO =os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
TOOL = os.environ.get("CLOUDGRANGE_KVP_TOOL_UNDER_TEST", os.path.join(REPO, "appliance", "cloudgrange-kvp.py"))
RECORD = 2560


def mode(path):
    return stat.S_IMODE(os.lstat(path).st_mode)


class KvpWriterTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # Missing root FAILS the run (gate_requirements); local developers may set CLOUDGRANGE_TEST_ALLOW_SKIP=1.
        req.require(req.is_root(), "root (pool paths must be root-owned)")

    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.dir = os.path.join(self.tmp, "hyperv")
        self.pool = os.path.join(self.dir, ".kvp_pool_1")
        self.env = dict(os.environ, CLOUDGRANGE_KVP_POOL=self.pool)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def kvp(self, *args, value=None):
        return subprocess.run(["python3", TOOL, *args], input=value, capture_output=True, env=self.env)

    def daemon_created_pool(self):
        """Reproduce what hv_kvp_daemon does under the default umask: dir 0755, pool files 0644."""
        os.makedirs(self.dir)
        os.chmod(self.dir, 0o755)
        for n in range(5):
            p = os.path.join(self.dir, ".kvp_pool_%d" % n)
            open(p, "wb").close()
            os.chmod(p, 0o644)

    def test_daemon_created_world_readable_pool_is_made_root_only_before_a_secret_is_written(self):
        self.daemon_created_pool()
        token = secrets.token_hex(32).encode()
        r = self.kvp("set", "CloudGrange.SetupToken", value=token)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(mode(self.dir), 0o700)
        for n in range(5):
            self.assertEqual(mode(os.path.join(self.dir, ".kvp_pool_%d" % n)), 0o600, "pool %d" % n)
        with open(self.pool, "rb") as f:
            self.assertIn(token, f.read())

    def test_refuses_to_write_when_owner_is_not_root(self):
        self.daemon_created_pool()
        os.chown(self.pool, 65534, 65534)
        r = self.kvp("set", "CloudGrange.SetupToken", value=b"a" * 64)
        self.assertEqual(r.returncode, 3, r.stderr)
        self.assertIn(b"refusing to write a value", r.stderr)
        self.assertEqual(os.path.getsize(self.pool), 0, "nothing may be written to an insecure pool")

    def test_refuses_to_follow_a_symlinked_pool(self):
        os.makedirs(self.dir, mode=0o700)
        target = os.path.join(self.tmp, "elsewhere")
        open(target, "wb").close()
        os.chmod(target, 0o644)
        os.symlink(target, self.pool)
        r = self.kvp("set", "CloudGrange.SetupToken", value=b"b" * 64)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(os.path.getsize(target), 0)

    def test_record_format_and_delete_overwrites_old_bytes(self):
        token = secrets.token_hex(32).encode()
        self.assertEqual(self.kvp("set", "CloudGrange.SetupToken", value=token).returncode, 0)
        self.assertEqual(self.kvp("set", "CloudGrange.State", value=b"setup-pending").returncode, 0)
        self.assertEqual(os.path.getsize(self.pool), 2 * RECORD)
        self.assertEqual(self.kvp("delete", "CloudGrange.SetupToken").returncode, 0)
        self.assertEqual(os.path.getsize(self.pool), RECORD)
        with open(self.pool, "rb") as f:
            data = f.read()
        self.assertNotIn(token, data)
        self.assertEqual(self.kvp("keys").stdout.decode().split(), ["CloudGrange.State"])

    def test_oversize_value_rejected(self):
        r = self.kvp("set", "Too.Large", value=b"a" * 2100)
        self.assertEqual(r.returncode, 1)


if __name__ == "__main__":
    unittest.main()
