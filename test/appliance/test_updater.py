# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#8129 — compose/updater/cloudgrange-updater.py end to end with a stub `docker`: an uploaded bundle is verified,
# the running release and database are backed up, the new release is switched in and health-gated; tampered or
# gate-failing bundles change nothing; an unhealthy release is rolled back with its database; manual rollback;
# and the trust boundary against the API-writable volume (zip path traversal, symlinked uploads, a planted
# status directory).
# Runs as root: sudo python3 -m unittest discover -s test/appliance
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import textwrap
import unittest
import uuid
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UPDATER = os.environ.get("CLOUDGRANGE_UPDATER_UNDER_TEST", os.path.join(REPO, "compose", "updater", "cloudgrange-updater.py"))
API_UID = 1654
OLD, NEW = "1.0.0", "2.0.0"
DIGEST = "a" * 64

DOCKER_STUB = textwrap.dedent(r"""
    #!/bin/bash
    F="$FAKE_ROOT"
    echo "$*" >> "$F/docker.calls"
    version() { grep '^CLOUDGRANGE_VERSION=' "$STACK/.env" | cut -d= -f2; }
    case "$*" in
      "load -i "*) [ -f "$F/fail_load" ] && exit 1; exit 0 ;;
      *" exec -T postgres pg_dump "*) echo "DUMP-$(version)"; exit 0 ;;
      *" exec -T postgres pg_isready "*|*" exec -T postgres dropdb "*|*" exec -T postgres createdb "*) exit 0 ;;
      *" exec -T postgres pg_restore "*) cat > "$F/restored.dump"; exit 0 ;;
      *" config --services"*) printf 'cloudgrange-api\nhealthcheck-tools\n'; exit 0 ;;
      *" up -d --remove-orphans"*) version > "$F/running_version"; exit 0 ;;
      *" up -d "*|*" stop "*) exit 0 ;;
      *" ps -a --format json"*)
        v=$(cat "$F/running_version" 2>/dev/null)
        if [ -f "$F/unhealthy_$v" ]; then h=unhealthy; else h=healthy; fi
        echo "{\"Service\":\"cloudgrange-api\",\"State\":\"running\",\"Health\":\"$h\",\"ExitCode\":0}"
        echo '{"Service":"healthcheck-tools","State":"exited","Health":"","ExitCode":0}'
        exit 0 ;;
    esac
    echo "unexpected docker call: $*" >&2
    exit 99
""").lstrip()

LOG_STUB = textwrap.dedent(r"""
    #!/bin/bash
    echo "$(basename "$0") $*" >> "$FAKE_ROOT/host.calls"
    exit 0
""").lstrip()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class UpdaterTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.fail("test_updater must run as root (it checks root-owned status and chowns the API volume)")
        self.tmp = tempfile.mkdtemp(prefix="cg-updater-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        p = lambda *a: os.path.join(self.tmp, *a)  # noqa: E731
        self.fake, self.stack, self.state, self.shared = p("fake"), p("stack"), p("state"), p("shared")
        self.bin, self.systemd, self.updater_bin = p("bin"), p("systemd"), p("updater-bin")
        for d in (self.fake, self.bin, self.systemd, os.path.join(self.stack, "systemd"), os.path.join(self.stack, "updater")):
            os.makedirs(d)
        for name, body in (("docker", DOCKER_STUB), ("systemctl", LOG_STUB), ("systemd-run", LOG_STUB)):
            path = os.path.join(self.bin, name)
            with open(path, "w") as f:
                f.write(body)
            os.chmod(path, 0o755)
        with open(UPDATER, "rb") as f:
            self.updater_source = f.read()
        self.write(os.path.join(self.stack, ".env"), "POSTGRES_PASSWORD=secret\nCLOUDGRANGE_VERSION=%s\n" % OLD, 0o600)
        self.write(os.path.join(self.stack, "docker-compose.yml"), "# release %s\n" % OLD)
        self.write(os.path.join(self.stack, "systemd", "cloudgrange.service"), "unit %s\n" % OLD)
        self.write(os.path.join(self.stack, "updater", "cloudgrange-updater.py"), self.updater_source)
        self.write(self.updater_bin, self.updater_source, 0o755)
        for d in (self.shared, os.path.join(self.shared, "requests"), os.path.join(self.shared, "incoming")):
            os.makedirs(d, exist_ok=True)
            os.chown(d, API_UID, API_UID)

    # ---- helpers ----------------------------------------------------------------------------------------
    @staticmethod
    def write(path, body, mode=0o644):
        with open(path, "wb") as f:
            f.write(body.encode() if isinstance(body, str) else body)
        os.chmod(path, mode)

    def bundle(self, version=NEW, hardening_exit=0, tamper=False, extra=()):
        files = {
            "compose/docker-compose.yml": "# release %s\nimage: ghcr.io/cloudgrange/cloudgrange-api:%s@sha256:%s\n" % (version, version, DIGEST),
            "compose/systemd/cloudgrange.service": "unit %s\n" % version,
            "compose/updater/cloudgrange-updater.py": self.updater_source,
            "images.txt": "ghcr.io/cloudgrange/cloudgrange-api:%s@sha256:%s\npostgres:17@sha256:%s\n" % (version, DIGEST, DIGEST),
            "cloudgrange-images.tar": b"image layers",
            "scripts/Test-ComposeImagePins.sh": "exit 0\n",
            "scripts/Test-ComposeHardening.py": "import sys\nsys.exit(%d)\n" % hardening_exit,
        }
        files = {k: (v.encode() if isinstance(v, str) else v) for k, v in files.items()}
        sums = "".join("%s  %s\n" % (sha256(files[k]), k) for k in sorted(files))
        if tamper:
            files["compose/docker-compose.yml"] += b"privileged: true\n"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            for name, data in sorted(files.items()):
                z.writestr(name, data)
            z.writestr("SHA256SUMS", sums)
            for name, data in extra:
                z.writestr(name, data)
        return buf.getvalue()

    def upload(self, data, as_symlink_to=None):
        bundle_id = str(uuid.uuid4())
        path = os.path.join(self.shared, "incoming", bundle_id + ".zip")
        if as_symlink_to:
            os.symlink(as_symlink_to, path)
        else:
            self.write(path, data)
            os.chown(path, API_UID, API_UID)
        return bundle_id

    def request(self, body):
        request_id = str(uuid.uuid4())
        path = os.path.join(self.shared, "requests", request_id + ".json")
        self.write(path, json.dumps(body))
        os.chown(path, API_UID, API_UID)
        return request_id

    def apply(self, data):
        bundle_id = self.upload(data)
        return self.request({"action": "apply", "source": "upload", "bundleId": bundle_id, "sha256": sha256(data)})

    def run_updater(self):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE_ROOT=self.fake, STACK=self.stack,
                   CLOUDGRANGE_STACK_DIR=self.stack, CLOUDGRANGE_UPDATER_STATE=self.state,
                   CLOUDGRANGE_SYSTEMD_DIR=self.systemd, CLOUDGRANGE_UPDATER_BIN=self.updater_bin,
                   CLOUDGRANGE_UPDATES_SHARED=self.shared, CLOUDGRANGE_UPDATE_HEALTH_TIMEOUT="1",
                   CLOUDGRANGE_UPDATE_HEALTH_INTERVAL="0.1", CLOUDGRANGE_UPDATE_PROBE_URLS="")
        proc = subprocess.run([sys.executable, UPDATER, "--once"], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        with open(os.path.join(self.shared, "status", "updater.json")) as f:
            return json.load(f)

    def job(self, status, request_id):
        return next(h for h in status["history"] if h["id"] == request_id)

    def env_version(self):
        with open(os.path.join(self.stack, ".env")) as f:
            return next(l.split("=", 1)[1].strip() for l in f if l.startswith("CLOUDGRANGE_VERSION="))

    def read(self, *parts):
        with open(os.path.join(*parts)) as f:
            return f.read()

    def docker_calls(self):
        path = os.path.join(self.fake, "docker.calls")
        return self.read(path) if os.path.exists(path) else ""

    # ---- tests ------------------------------------------------------------------------------------------
    def test_apply_uploaded_bundle_switches_the_release_and_keeps_a_backup(self):
        rid = self.apply(self.bundle())
        status = self.run_updater()
        job = self.job(status, rid)
        self.assertEqual(job["state"], "succeeded", job["message"])
        self.assertEqual((job["previousVersion"], job["targetVersion"]), (OLD, NEW))
        self.assertEqual(status["currentVersion"], NEW)
        self.assertEqual(self.env_version(), NEW)
        self.assertIn("POSTGRES_PASSWORD=secret", self.read(self.stack, ".env"), ".env settings must be kept")
        self.assertEqual(stat.S_IMODE(os.stat(os.path.join(self.stack, ".env")).st_mode), 0o600)
        self.assertIn("release %s" % NEW, self.read(self.stack, "docker-compose.yml"))
        self.assertEqual(self.read(self.fake, "running_version").strip(), NEW)
        self.assertEqual(self.read(self.systemd, "cloudgrange.service"), "unit %s\n" % NEW)
        self.assertEqual(status["rollbackAvailable"]["version"], OLD)
        backups = os.listdir(os.path.join(self.state, "backups"))
        self.assertEqual(len(backups), 1)
        dump = os.path.join(self.state, "backups", backups[0], "database.dump")
        self.assertEqual(self.read(dump), "DUMP-%s\n" % OLD)
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o700)
        self.assertEqual(os.listdir(os.path.join(self.shared, "incoming")), [], "the uploaded bundle is consumed")
        self.assertEqual(os.listdir(os.path.join(self.shared, "requests")), [], "the request is consumed")
        st = os.stat(os.path.join(self.shared, "status", "updater.json"))
        self.assertEqual((st.st_uid, stat.S_IMODE(st.st_mode)), (0, 0o644))
        self.assertIn("load -i", self.docker_calls())
        self.assertIn("up -d --no-deps --force-recreate nginx", self.docker_calls())

    def test_tampered_bundle_is_rejected_before_anything_changes(self):
        rid = self.apply(self.bundle(tamper=True))
        job = self.job(self.run_updater(), rid)
        self.assertEqual(job["state"], "failed")
        self.assertEqual(job["step"], "verifying")
        self.assertIn("SHA-256 mismatch", job["message"])
        self.assertEqual(self.env_version(), OLD)
        self.assertIn("release %s" % OLD, self.read(self.stack, "docker-compose.yml"))
        self.assertNotIn("load -i", self.docker_calls())
        self.assertNotIn("pg_dump", self.docker_calls())

    def test_bundle_failing_the_hardening_gate_leaves_the_running_release_untouched(self):
        rid = self.apply(self.bundle(hardening_exit=1))
        job = self.job(self.run_updater(), rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("Test-ComposeHardening", job["message"])
        self.assertEqual(self.env_version(), OLD)
        self.assertNotIn("load -i", self.docker_calls())

    def test_unhealthy_release_is_rolled_back_with_its_database(self):
        open(os.path.join(self.fake, "unhealthy_%s" % NEW), "w").close()
        rid = self.apply(self.bundle())
        status = self.run_updater()
        job = self.job(status, rid)
        self.assertEqual(job["state"], "rolled-back", job["message"])
        self.assertIn("health-check failed", job["message"])
        self.assertEqual(self.env_version(), OLD)
        self.assertIn("release %s" % OLD, self.read(self.stack, "docker-compose.yml"))
        self.assertEqual(self.read(self.fake, "restored.dump"), "DUMP-%s\n" % OLD)
        self.assertEqual(self.read(self.fake, "running_version").strip(), OLD)
        self.assertEqual(status["currentVersion"], OLD)
        calls = self.docker_calls()
        self.assertLess(calls.index("dropdb"), calls.index("pg_restore"))

    def test_zip_path_traversal_is_rejected(self):
        rid = self.apply(self.bundle(extra=[("../escaped.txt", b"x")]))
        job = self.job(self.run_updater(), rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("unsafe path", job["message"])
        for root, _d, names in os.walk(self.tmp):
            self.assertNotIn("escaped.txt", names)
        self.assertEqual(self.env_version(), OLD)

    def test_symlinked_upload_is_refused(self):
        outside = os.path.join(self.tmp, "outside.zip")
        self.write(outside, self.bundle(), 0o600)
        bundle_id = self.upload(None, as_symlink_to=outside)
        rid = self.request({"action": "apply", "source": "upload", "bundleId": bundle_id})
        job = self.job(self.run_updater(), rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("cannot open", job["message"])
        self.assertTrue(os.path.exists(outside))
        self.assertEqual(self.env_version(), OLD)

    def test_manual_rollback_restores_the_previous_release(self):
        self.apply(self.bundle())
        self.assertEqual(self.run_updater()["currentVersion"], NEW)
        rid = self.request({"action": "rollback"})
        status = self.run_updater()
        job = self.job(status, rid)
        self.assertEqual(job["state"], "succeeded", job["message"])
        self.assertEqual(self.env_version(), OLD)
        self.assertEqual(self.read(self.fake, "restored.dump"), "DUMP-%s\n" % OLD)
        self.assertIsNone(status["rollbackAvailable"])

    def test_same_version_is_refused(self):
        rid = self.apply(self.bundle(version=OLD))
        job = self.job(self.run_updater(), rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("already installed", job["message"])
        self.assertNotIn("load -i", self.docker_calls())

    def test_status_directory_planted_by_the_api_is_replaced(self):
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        os.symlink(elsewhere, os.path.join(self.shared, "status"))
        status = self.run_updater()
        self.assertEqual(status["currentVersion"], OLD)
        st = os.lstat(os.path.join(self.shared, "status"))
        self.assertTrue(stat.S_ISDIR(st.st_mode))
        self.assertEqual(st.st_uid, 0)
        self.assertEqual(os.listdir(elsewhere), [])

    def test_install_and_generalize_ship_the_updater(self):
        deploy = self.read(REPO, "scripts", "Deploy-DockerCompose.ps1")
        self.assertIn("install -m 0755 $composeDir/updater/cloudgrange-updater.py /usr/local/sbin/cloudgrange-updater", deploy)
        self.assertIn("systemctl enable cloudgrange-updater.service", deploy)
        generalize = self.read(REPO, "appliance", "cloudgrange-generalize.sh")
        self.assertIn("rm -rf /var/lib/cloudgrange-updater", generalize)
        compose = self.read(REPO, "compose", "docker-compose.yml")
        self.assertIn("- platform_updates:/var/lib/cloudgrange/updates", compose)
        self.assertEqual(compose.count("platform_updates:"), 2, "declared once and mounted only into the API")


if __name__ == "__main__":
    unittest.main()
