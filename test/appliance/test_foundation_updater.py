# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 (E3) — scripts/cloudgrange-updater-k3s.py is the FOUNDATION updater of a managed K3s host.
# Driven end to end with stub apt/apt-get/k3s/systemctl/systemd-run on PATH, a fake K3s install.sh inside
# the release, and a real openssl signing key, so the checks here exercise the shipped script:
#   - foundation-check reports apt/security counts, reboot-required, the K3s version and the channel;
#   - trust is HTTPS + digest pinning (owner decision 2026-09-18): an UNSIGNED release whose sha256
#     matches the channel (or the admin's upload sha256) is accepted when no signing key is installed;
#     a hash mismatch, an http:// source, another host and a tampered file are refused; a signature is
#     verified only when a real key is installed. Channel downloads go to a real local https server;
#   - foundation-apply refuses tampered, over-reaching or reboot-unconfirmed releases BEFORE
#     changing anything, upgrades K3s through the pinned installer, installs host files, and puts K3s
#     back automatically when the cluster does not come back healthy;
#   - foundation-rollback restores K3s and host files and says plainly that apt is not rolled back;
#   - Platform requests from an older API are refused, and status/foundation.json has exactly the
#     plan §4 fields;
#   - the trust boundary against the API-writable volume is unchanged (symlinked upload, zip traversal,
#     planted status directory).
# Runs as root: sudo python3 -m unittest discover -s test/appliance -p 'test_foundation_updater.py'
import base64
import functools
import hashlib
import http.server
import importlib.util
import io
import json
import os
import re
import shutil
import ssl
import stat
import subprocess
import sys
import tempfile
import textwrap
import threading
import unittest
import uuid
import zipfile

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UPDATER = os.path.join(REPO, "scripts", "cloudgrange-updater-k3s.py")
API_UID = 1654
OLD_K3S, NEW_K3S, NEXT_MINOR_K3S = "v1.36.4+k3s1", "v1.36.5+k3s1", "v1.37.1+k3s1"
STATUS_KEYS = {"installedVersion", "availableVersion", "k3sVersion", "targetK3sVersion", "osUpdatesAvailable",
               "rebootRequired", "state", "message", "updatedAt"}

K3S_STUB = textwrap.dedent(r"""
    #!/bin/bash
    F="$FAKE_ROOT"
    echo "k3s $*" >> "$F/calls"
    v=$(cat "$F/running_k3s" 2>/dev/null)
    case "$*" in
      "--version") echo "k3s version $v (deadbeef)"; echo "go version go1.24"; exit 0 ;;
      "kubectl get nodes --no-headers")
        if [ -f "$F/unhealthy_$v" ]; then echo "node1 NotReady control-plane 1m $v"; else echo "node1 Ready control-plane 1m $v"; fi
        exit 0 ;;
      "kubectl get pods -A --no-headers")
        echo "default cloudgrange-api-1 1/1 Running 0 1m"
        echo "default cloudgrange-secrets-bootstrap-x 0/1 Completed 0 1m"
        exit 0 ;;
    esac
    echo "unexpected k3s call: $*" >&2
    exit 99
""").lstrip()

APT_STUB = textwrap.dedent(r"""
    #!/bin/bash
    F="$FAKE_ROOT"
    echo "$(basename "$0") $*" >> "$F/calls"
    case "$(basename "$0") $1" in
      "apt-get update") [ -f "$F/offline" ] && exit 100; exit 0 ;;
      "apt-get install") exit 0 ;;
      "apt list") echo "Listing..."; cat "$F/upgradable" 2>/dev/null; exit 0 ;;
    esac
    echo "unexpected apt call: $*" >&2
    exit 99
""").lstrip()

LOG_STUB = textwrap.dedent(r"""
    #!/bin/bash
    echo "$(basename "$0") $*" >> "$FAKE_ROOT/calls"
    exit 0
""").lstrip()

# K3s's real install.sh with INSTALL_K3S_SKIP_DOWNLOAD=true uses the binary already in place and
# (re)starts k3s.service. This fake does the observable part: records what it was asked for and
# "starts" whatever binary is now at CLOUDGRANGE_K3S_BIN.
INSTALL_SH = textwrap.dedent(r"""
    #!/bin/sh
    echo "install.sh SKIP_DOWNLOAD=$INSTALL_K3S_SKIP_DOWNLOAD VERSION=$INSTALL_K3S_VERSION" >> "$FAKE_ROOT/calls"
    [ "$INSTALL_K3S_SKIP_DOWNLOAD" = "true" ] || exit 7
    sed -n 's/^K3S //p' "$CLOUDGRANGE_K3S_BIN" > "$FAKE_ROOT/running_k3s"
""").lstrip()


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def load_module():
    spec = importlib.util.spec_from_file_location("cg_foundation_updater", UPDATER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class VersionRangeTests(unittest.TestCase):
    def test_helm_style_kube_version_ranges(self):
        m = load_module()
        ok = m.version_satisfies
        self.assertTrue(ok("v1.36.4+k3s1", ">=1.30.0-0 <1.37.0-0"))
        self.assertFalse(ok("v1.37.1+k3s1", ">=1.30.0-0 <1.37.0-0"))
        self.assertTrue(ok("1.34.2", "~1.34"))
        self.assertFalse(ok("1.35.0", "~1.34"))
        self.assertTrue(ok("1.34.9", "1.34.x"))
        self.assertTrue(ok("1.40.0", "^1.30"))
        self.assertTrue(ok("1.29.0", "<1.30.0 || >=1.36.0") and ok("1.36.1", "<1.30.0 || >=1.36.0"))
        self.assertFalse(ok("1.31.0", "<1.30.0 || >=1.36.0"))
        with self.assertRaises(m.UpdateError):
            ok("1.30.0", "between 1.30 and 1.31")


class _QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class LocalHttpsServer:
    """A real https server on 127.0.0.1 with its own CA, reachable as https://localhost:<port> (the
    certificate also covers 127.0.0.1, which the tests use as a DIFFERENT host) and a plain http
    listener on the same directory, so an http:// refusal is the updater's policy, not a dead port."""

    def __init__(self, root, workdir):
        self.root = root
        ca_key, ca_crt = os.path.join(workdir, "ca.key"), os.path.join(workdir, "ca.crt")
        key, csr, crt = (os.path.join(workdir, n) for n in ("srv.key", "srv.csr", "srv.crt"))
        ext = os.path.join(workdir, "srv.ext")
        run = functools.partial(subprocess.run, check=True, capture_output=True)
        run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "2", "-subj", "/CN=cg-test-ca",
             "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
             "-keyout", ca_key, "-out", ca_crt])
        run(["openssl", "req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", key, "-out", csr])
        with open(ext, "w") as f:
            f.write("subjectAltName=DNS:localhost,IP:127.0.0.1\n")
        run(["openssl", "x509", "-req", "-in", csr, "-CA", ca_crt, "-CAkey", ca_key, "-CAcreateserial", "-days", "2",
             "-extfile", ext, "-out", crt])
        self.ca = ca_crt
        handler = functools.partial(_QuietHandler, directory=root)
        self.httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(crt, key)
        self.httpd.socket = ctx.wrap_socket(self.httpd.socket, server_side=True)
        self.plain = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
        for srv in (self.httpd, self.plain):
            srv.handle_error = lambda request, client_address: None  # a client refusing our cert is expected
            threading.Thread(target=srv.serve_forever, daemon=True).start()
        self.base = "https://localhost:%d" % self.httpd.server_address[1]
        self.other_host_base = "https://127.0.0.1:%d" % self.httpd.server_address[1]
        self.http_base = "http://localhost:%d" % self.plain.server_address[1]

    def close(self):
        for srv in (self.httpd, self.plain):
            srv.shutdown()
            srv.server_close()


class FoundationUpdaterTests(unittest.TestCase):
    def setUp(self):
        if os.geteuid() != 0:
            self.fail("test_foundation_updater must run as root (it checks the root-owned status directory)")
        self.tmp = tempfile.mkdtemp(prefix="cg-foundation-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        p = lambda *a: os.path.join(self.tmp, *a)  # noqa: E731
        self.fake, self.state, self.shared, self.bin = p("fake"), p("state"), p("shared"), p("bin")
        self.host, self.keys = p("host"), p("keys")
        for d in (self.fake, self.bin, self.host, self.keys, os.path.join(self.host, "etc", "cloudgrange")):
            os.makedirs(d)
        stubs = (("k3s", K3S_STUB), ("apt", APT_STUB), ("apt-get", APT_STUB),
                 ("systemctl", LOG_STUB), ("systemd-run", LOG_STUB))
        for name, body in stubs:
            self.write(os.path.join(self.bin, name), body, 0o755)
        self.k3s_bin = os.path.join(self.host, "usr", "local", "bin", "k3s")
        os.makedirs(os.path.dirname(self.k3s_bin))
        self.write(self.k3s_bin, "K3S %s\n" % OLD_K3S, 0o755)
        self.write(os.path.join(self.fake, "running_k3s"), OLD_K3S + "\n")
        self.www = os.path.join(self.tmp, "www")
        os.makedirs(self.www)
        self.server = LocalHttpsServer(self.www, self.tmp)
        self.addCleanup(self.server.close)
        self.version_file = os.path.join(self.host, "etc", "cloudgrange", "foundation-version")
        self.write(self.version_file, "F2609.0.0\n")
        self.reboot_file = os.path.join(self.fake, "reboot-required")
        self.channel = os.path.join(self.tmp, "channel.json")
        for d in (self.shared, os.path.join(self.shared, "requests"), os.path.join(self.shared, "incoming")):
            os.makedirs(d, exist_ok=True)
            os.chown(d, API_UID, API_UID)
        self.key = os.path.join(self.keys, "release.key")
        self.pub = os.path.join(self.keys, "release.pub")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", self.key], check=True)
        subprocess.run(["openssl", "ec", "-in", self.key, "-pubout", "-out", self.pub], check=True, capture_output=True)

    # ---- helpers ------------------------------------------------------------------------------------
    @staticmethod
    def write(path, body, mode=0o644):
        with open(path, "wb") as f:
            f.write(body.encode() if isinstance(body, str) else body)
        os.chmod(path, mode)

    def read(self, *parts):
        with open(os.path.join(*parts)) as f:
            return f.read()

    def sign(self, data, key=None, b64=False):
        msg = os.path.join(self.tmp, "msg-%s" % uuid.uuid4().hex)
        self.write(msg, data)
        proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key or self.key, msg], check=True, capture_output=True)
        os.unlink(msg)
        return base64.b64encode(proc.stdout) if b64 else proc.stdout

    def release(self, version="F2609.1.0", k3s=NEW_K3S, packages=None, security=False, host_files=None,
                requires_reboot=False, sign_with=None, b64=False, tamper=False, unpinned=None, extra_zip=(),
                manifest_extra=None, drop_signature=False):
        files = {}
        manifest = {"schema": "cg-foundation-release-v1", "version": version, "notes": "test release",
                    "requiresReboot": requires_reboot,
                    "apt": {"securityUpdates": security, "packages": packages or {}}}
        if k3s:
            files["k3s/k3s"] = ("K3S %s\n" % k3s).encode()
            files["k3s/install.sh"] = INSTALL_SH.encode()
            manifest["k3s"] = {"version": k3s, "binary": "k3s/k3s", "installScript": "k3s/install.sh"}
        manifest["hostFiles"] = []
        for i, (dest, body) in enumerate(host_files or []):
            src = "hostfiles/%d" % i
            files[src] = body.encode()
            manifest["hostFiles"].append({"source": src, "destination": dest, "mode": "0644"})
        manifest["files"] = {k: sha256(v) for k, v in files.items()}
        manifest.update(manifest_extra or {})
        body = json.dumps(manifest, indent=2).encode()
        if tamper:
            files["k3s/k3s"] = b"K3S v6.6.6+k3s1\n"
        if unpinned:
            files[unpinned] = b"not in the manifest"
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("foundation-release.json", body)
            if not drop_signature:
                z.writestr("foundation-release.json.sig", self.sign(body, sign_with, b64))
            for name, data in sorted(files.items()):
                z.writestr(name, data)
            for name, data in extra_zip:
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

    def apply(self, data, **extra):
        body = {"action": "foundation-apply", "version": extra.pop("version", None) or "F2609.1.0",
                "bundleId": self.upload(data), "sha256": sha256(data), "requestedBy": "admin@test"}
        body.update(extra)
        return self.request(body)

    def run_updater(self, **env_extra):
        env = dict(os.environ, PATH=self.bin + os.pathsep + os.environ["PATH"], FAKE_ROOT=self.fake,
                   CLOUDGRANGE_UPDATER_STATE=self.state, CLOUDGRANGE_UPDATES_SHARED=self.shared,
                   CLOUDGRANGE_FOUNDATION_PUBKEY=self.pub, CLOUDGRANGE_FOUNDATION_VERSION_FILE=self.version_file,
                   CLOUDGRANGE_FOUNDATION_CHANNEL_FILE=os.path.join(self.tmp, "no-channel"),
                   CLOUDGRANGE_REBOOT_REQUIRED_FILE=self.reboot_file, CLOUDGRANGE_HOST_ROOT=self.host,
                   CLOUDGRANGE_K3S_BIN=self.k3s_bin,
                   CLOUDGRANGE_K3S_IMAGES_DIR=os.path.join(self.host, "var/lib/rancher/k3s/agent/images"),
                   CLOUDGRANGE_UPDATE_HEALTH_TIMEOUT="1", CLOUDGRANGE_UPDATE_HEALTH_INTERVAL="0.1",
                   CLOUDGRANGE_FOUNDATION_HEADROOM_BYTES="0", SSL_CERT_FILE=self.server.ca)
        env.update(env_extra)
        proc = subprocess.run([sys.executable, UPDATER, "--once"], env=env, capture_output=True, text=True, timeout=120)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        path = os.path.join(self.shared, "status", "foundation.json")
        st = os.stat(path)
        self.assertEqual((st.st_uid, stat.S_IMODE(st.st_mode)), (0, 0o644))
        with open(path) as f:
            return json.load(f)

    def job(self, request_id):
        with open(os.path.join(self.state, "state.json")) as f:
            return next(h for h in json.load(f)["history"] if h["id"] == request_id)

    def calls(self):
        path = os.path.join(self.fake, "calls")
        return self.read(path) if os.path.exists(path) else ""

    def running_k3s(self):
        return self.read(self.fake, "running_k3s").strip()

    def assert_nothing_changed(self):
        self.assertEqual(self.running_k3s(), OLD_K3S)
        self.assertEqual(self.read(self.k3s_bin), "K3S %s\n" % OLD_K3S)
        self.assertEqual(self.read(self.version_file).strip(), "F2609.0.0")
        self.assertNotIn("apt-get install", self.calls())
        self.assertNotIn("install.sh", self.calls())

    # ---- status contract ----------------------------------------------------------------------------
    def test_status_file_has_exactly_the_contract_fields(self):
        status = self.run_updater()
        self.assertEqual(set(status), STATUS_KEYS)
        self.assertEqual(status["k3sVersion"], OLD_K3S)
        self.assertEqual(status["installedVersion"], "F2609.0.0")
        self.assertEqual(status["state"], "idle")
        self.assertFalse(status["rebootRequired"])
        self.assertNotIn("apt-get", self.calls(), "starting the service must not touch apt: an admin starts every check")

    # ---- check --------------------------------------------------------------------------------------
    def test_check_counts_os_updates_and_reads_the_channel(self):
        self.write(os.path.join(self.fake, "upgradable"),
                   "openssl/noble-updates,noble-security 3.0.13-0ubuntu3.6 amd64 [upgradable from: 3.0.13-0ubuntu3.5]\n"
                   "curl/noble-updates 8.5.0-2ubuntu10.7 amd64 [upgradable from: 8.5.0-2ubuntu10.6]\n"
                   "libc6/noble-security 2.39-0ubuntu8.6 amd64 [upgradable from: 2.39-0ubuntu8.5]\n")
        open(self.reboot_file, "w").close()
        self.write(os.path.join(self.www, "channel.json"), json.dumps({"releases": [
            {"version": "F2609.1.0", "k3sVersion": NEW_K3S, "bundleUrl": "https://example.invalid/a.zip", "sha256": "a" * 64},
            {"version": "F2609.10.0", "k3sVersion": NEXT_MINOR_K3S, "bundleUrl": "https://example.invalid/b.zip", "sha256": "b" * 64},
            {"version": "F2609.2.0", "k3sVersion": NEW_K3S, "bundleUrl": "https://example.invalid/c.zip", "sha256": "c" * 64}]}))
        rid = self.request({"action": "foundation-check"})
        status = self.run_updater(CLOUDGRANGE_FOUNDATION_CHANNEL_URL=self.server.base + "/channel.json")
        self.assertEqual(self.job(rid)["state"], "idle")
        self.assertEqual(status["osUpdatesAvailable"], 3)
        self.assertIsInstance(status["osUpdatesAvailable"], int)
        self.assertIn("2 of them security", status["message"])
        self.assertTrue(status["rebootRequired"])
        self.assertEqual((status["availableVersion"], status["targetK3sVersion"]), ("F2609.10.0", NEXT_MINOR_K3S))
        self.assertIn("apt-get update", self.calls())
        self.assertNotIn("apt-get install", self.calls(), "a check never installs anything")
        # Plan §5: the Foundation card lists the exact packages before an admin confirms.
        with open(os.path.join(self.shared, "status", "foundation-packages.json")) as f:
            listed = json.load(f)["packages"]
        self.assertIn({"name": "openssl", "version": "3.0.13-0ubuntu3.6", "security": True}, listed)
        self.assertEqual(len(listed), 3)

    def test_check_offline_still_reports(self):
        open(os.path.join(self.fake, "offline"), "w").close()
        self.request({"action": "foundation-check"})
        status = self.run_updater()
        self.assertEqual(status["state"], "idle")
        self.assertIn("could not be refreshed", status["message"])

    # ---- apply --------------------------------------------------------------------------------------
    def test_apply_upgrades_k3s_packages_and_host_files(self):
        dest = "/etc/cloudgrange/foundation.conf"
        rid = self.apply(self.release(packages={"openssl": "3.0.13-0ubuntu3.6"}, host_files=[(dest, "new\n")]))
        status = self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "succeeded", job["message"])
        self.assertEqual(status["state"], "succeeded")
        self.assertEqual(status["installedVersion"], "F2609.1.0")
        self.assertEqual(status["k3sVersion"], NEW_K3S)
        self.assertEqual(self.read(self.k3s_bin), "K3S %s\n" % NEW_K3S)
        calls = self.calls()
        self.assertIn("install.sh SKIP_DOWNLOAD=true VERSION=%s" % NEW_K3S, calls)
        self.assertRegex(calls, r"apt-get install -y -q --only-upgrade .* openssl=3\.0\.13-0ubuntu3\.6")
        self.assertLess(calls.index("apt-get install"), calls.index("install.sh"), "OS packages go in before K3s")
        self.assertEqual(self.read(self.host, dest.lstrip("/")), "new\n")
        self.assertNotIn("reboot", calls)
        self.assertEqual(os.listdir(os.path.join(self.shared, "incoming")), [], "the uploaded release is consumed")
        self.assertEqual(os.listdir(os.path.join(self.shared, "requests")), [], "the request is consumed")
        self.assertEqual(stat.S_IMODE(os.stat(self.state).st_mode), 0o700)

    def test_security_only_release_installs_just_the_security_packages(self):
        self.write(os.path.join(self.fake, "upgradable"),
                   "openssl/noble-updates,noble-security 3.0.13-0ubuntu3.6 amd64 [upgradable from: 3.0.13-0ubuntu3.5]\n"
                   "curl/noble-updates 8.5.0-2ubuntu10.7 amd64 [upgradable from: 8.5.0-2ubuntu10.6]\n")
        rid = self.apply(self.release(k3s=None, security=True))
        self.run_updater()
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])
        install = next(l for l in self.calls().splitlines() if l.startswith("apt-get install"))
        self.assertTrue(install.endswith(" openssl"), install)
        self.assertNotIn("curl", install)
        self.assertEqual(self.running_k3s(), OLD_K3S)

    def test_base64_cosign_style_signature_is_accepted(self):
        rid = self.apply(self.release(b64=True))
        self.run_updater()
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])

    def test_release_signed_by_another_key_is_refused_before_anything_changes(self):
        other = os.path.join(self.keys, "other.key")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", other], check=True)
        rid = self.apply(self.release(sign_with=other))
        self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("signature verification FAILED", job["message"])
        self.assert_nothing_changed()

    def test_unsigned_release_is_refused_when_a_signing_key_is_installed(self):
        rid = self.apply(self.release(drop_signature=True))
        self.run_updater()
        self.assertIn("has no foundation-release.json.sig", self.job(rid)["message"])
        self.assert_nothing_changed()

    # ---- trust: HTTPS + digest pinning, no signing key required (owner decision 2026-09-18) --------
    def test_unsigned_upload_with_matching_sha256_is_accepted_without_a_key(self):
        rid = self.apply(self.release(drop_signature=True))
        status = self.run_updater(CLOUDGRANGE_FOUNDATION_PUBKEY=os.path.join(self.keys, "absent.pub"))
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])
        self.assertEqual(status["k3sVersion"], NEW_K3S)

    def test_placeholder_key_means_no_key_and_does_not_block(self):
        placeholder = os.path.join(self.keys, "placeholder.pub")
        self.write(placeholder, "-----BEGIN PUBLIC KEY-----\nPLACEHOLDER\n-----END PUBLIC KEY-----\n")
        rid = self.apply(self.release(drop_signature=True))
        self.run_updater(CLOUDGRANGE_FOUNDATION_PUBKEY=placeholder)
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])

    def test_the_shipped_placeholder_key_does_not_block(self):
        rid = self.apply(self.release(drop_signature=True))
        self.run_updater(CLOUDGRANGE_FOUNDATION_PUBKEY=os.path.join(REPO, "cloudgrange-signing-key.pub"))
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])

    def test_upload_whose_sha256_does_not_match_is_refused(self):
        data = self.release(drop_signature=True)
        rid = self.request({"action": "foundation-apply", "version": "F2609.1.0", "bundleId": self.upload(data),
                            "sha256": "0" * 64})
        self.run_updater(CLOUDGRANGE_FOUNDATION_PUBKEY=os.path.join(self.keys, "absent.pub"))
        self.assertIn("sha256 mismatch", self.job(rid)["message"])
        self.assert_nothing_changed()

    def publish(self, data, bundle_url=None, sha=None, version="F2609.1.0"):
        """Put a release on the local https server and list it in an https channel; returns the channel URL."""
        self.write(os.path.join(self.www, "release.zip"), data)
        self.write(os.path.join(self.www, "channel.json"), json.dumps({"releases": [
            {"version": version, "k3sVersion": NEW_K3S, "sha256": sha or sha256(data),
             "bundleUrl": bundle_url or self.server.base + "/release.zip"}]}))
        return self.server.base + "/channel.json"

    def download_apply(self, channel_url, **env):
        rid = self.request({"action": "foundation-apply", "version": "F2609.1.0", "requestedBy": "admin@test"})
        env.setdefault("CLOUDGRANGE_FOUNDATION_PUBKEY", os.path.join(self.keys, "absent.pub"))
        status = self.run_updater(CLOUDGRANGE_FOUNDATION_CHANNEL_URL=channel_url, **env)
        return self.job(rid), status

    def test_unsigned_https_channel_release_with_matching_sha256_is_accepted(self):
        job, status = self.download_apply(self.publish(self.release(drop_signature=True)))
        self.assertEqual(job["state"], "succeeded", job["message"])
        self.assertEqual((status["installedVersion"], status["k3sVersion"]), ("F2609.1.0", NEW_K3S))

    def test_https_channel_release_whose_sha256_does_not_match_is_refused(self):
        job, _ = self.download_apply(self.publish(self.release(drop_signature=True), sha="f" * 64))
        self.assertEqual(job["state"], "failed")
        self.assertIn("sha256 mismatch", job["message"])
        self.assert_nothing_changed()

    def test_http_bundle_url_is_refused(self):
        data = self.release(drop_signature=True)
        job, _ = self.download_apply(self.publish(data, bundle_url=self.server.http_base + "/release.zip"))
        self.assertEqual(job["state"], "failed")
        self.assertIn("https://", job["message"])
        self.assert_nothing_changed()

    def test_http_channel_is_refused(self):
        self.publish(self.release(drop_signature=True))
        job, _ = self.download_apply(self.server.http_base + "/channel.json")
        self.assertEqual(job["state"], "failed")
        self.assertIn("must be https://", job["message"])
        self.assert_nothing_changed()

    def test_file_channel_is_refused(self):
        self.publish(self.release(drop_signature=True))
        job, _ = self.download_apply("file://" + os.path.join(self.www, "channel.json"))
        self.assertIn("must be https://", job["message"])
        self.assert_nothing_changed()

    def test_bundle_from_another_host_is_refused_unless_allowed(self):
        data = self.release(drop_signature=True)
        other = self.server.other_host_base + "/release.zip"
        job, _ = self.download_apply(self.publish(data, bundle_url=other))
        self.assertIn("neither the channel host", job["message"])
        self.assert_nothing_changed()
        job, _ = self.download_apply(self.publish(data, bundle_url=other),
                                     CLOUDGRANGE_FOUNDATION_ALLOWED_HOSTS=other.split("/")[2])
        self.assertEqual(job["state"], "succeeded", job["message"])

    def test_untrusted_tls_certificate_is_refused(self):
        job, _ = self.download_apply(self.publish(self.release(drop_signature=True)), SSL_CERT_FILE="/nonexistent")
        self.assertEqual(job["state"], "failed")
        self.assert_nothing_changed()

    def test_file_altered_after_signing_is_refused(self):
        rid = self.apply(self.release(tamper=True))
        self.run_updater()
        self.assertIn("checksum mismatch for k3s/k3s", self.job(rid)["message"])
        self.assert_nothing_changed()

    def test_file_the_manifest_does_not_pin_is_refused(self):
        rid = self.apply(self.release(unpinned="hostfiles/smuggled"))
        self.run_updater()
        self.assertIn("does not pin", self.job(rid)["message"])
        self.assert_nothing_changed()

    def test_host_file_outside_cloudgrange_files_is_refused(self):
        rid = self.apply(self.release(host_files=[("/etc/sudoers.d/cloudgrange", "ALL ALL=(ALL) NOPASSWD:ALL\n")]))
        self.run_updater()
        self.assertIn("outside CloudGrange's own files", self.job(rid)["message"])
        self.assertFalse(os.path.exists(os.path.join(self.host, "etc", "sudoers.d")))
        self.assert_nothing_changed()

    def test_reboot_is_refused_without_confirmation_and_scheduled_with_it(self):
        data = self.release(packages={"linux-image-virtual": "6.8.0.140.140"})
        rid = self.apply(data)
        self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("needs the host to reboot; nothing was changed", job["message"])
        self.assert_nothing_changed()
        rid = self.apply(data, confirmReboot=True)
        status = self.run_updater()
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])
        self.assertIn("reboots in", status["message"])
        self.assertIn("systemd-run --on-active=60 systemctl reboot", self.calls())

    def test_a_pending_reboot_also_needs_confirmation(self):
        open(self.reboot_file, "w").close()
        rid = self.apply(self.release(k3s=None, host_files=[("/etc/cloudgrange/x.conf", "x\n")]))
        self.run_updater()
        self.assertIn("needs the host to reboot", self.job(rid)["message"])

    def test_unhealthy_k3s_is_put_back_automatically(self):
        open(os.path.join(self.fake, "unhealthy_%s" % NEW_K3S), "w").close()
        rid = self.apply(self.release())
        status = self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "rolled-back", job["message"])
        self.assertEqual(status["state"], "rolled-back")
        self.assertIn("put back to %s" % OLD_K3S, job["message"])
        self.assertEqual(self.running_k3s(), OLD_K3S)
        self.assertEqual(self.read(self.k3s_bin), "K3S %s\n" % OLD_K3S)
        self.assertEqual(self.read(self.version_file).strip(), "F2609.0.0")

    def test_kube_range_gate_refuses_a_k3s_the_platform_cannot_run(self):
        rid = self.apply(self.release(k3s=NEXT_MINOR_K3S), supportedKubeRange=">=1.30.0-0 <1.37.0-0")
        self.run_updater()
        self.assertIn("outside the installed Platform's supported range", self.job(rid)["message"])
        self.assert_nothing_changed()

    def test_platform_range_gate(self):
        rid = self.apply(self.release(manifest_extra={"supportedPlatformVersions": ">=2610.0.0"}), platformVersion="2609.0.0")
        self.run_updater()
        self.assertIn("supports Platform", self.job(rid)["message"])
        self.assert_nothing_changed()

    def test_requested_version_must_match_the_release(self):
        rid = self.apply(self.release(version="F2609.2.0"), version="F2609.1.0")
        self.run_updater()
        self.assertIn("not the requested", self.job(rid)["message"])
        self.assert_nothing_changed()

    # ---- rollback -----------------------------------------------------------------------------------
    def test_rollback_restores_k3s_and_host_files_but_says_apt_stays(self):
        existing = os.path.join(self.host, "etc", "cloudgrange", "existing.conf")
        self.write(existing, "old\n")
        self.apply(self.release(packages={"openssl": "3.0.13-0ubuntu3.6"},
                                host_files=[("/etc/cloudgrange/existing.conf", "new\n"), ("/etc/cloudgrange/added.conf", "added\n")]))
        self.assertEqual(self.run_updater()["k3sVersion"], NEW_K3S)
        rid = self.request({"action": "foundation-rollback"})
        status = self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "rolled-back", job["message"])
        self.assertIn("OS packages are NOT rolled back", job["message"])
        self.assertEqual(status["k3sVersion"], OLD_K3S)
        self.assertEqual(status["installedVersion"], "F2609.0.0")
        self.assertEqual(self.read(existing), "old\n")
        self.assertFalse(os.path.exists(os.path.join(self.host, "etc", "cloudgrange", "added.conf")))
        rid = self.request({"action": "foundation-rollback"})
        self.run_updater()
        self.assertIn("no previous Foundation", self.job(rid)["message"])

    def test_rollback_across_a_kubernetes_minor_is_refused(self):
        self.apply(self.release(k3s=NEXT_MINOR_K3S))
        self.assertEqual(self.run_updater()["k3sVersion"], NEXT_MINOR_K3S)
        rid = self.request({"action": "foundation-rollback"})
        self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("does not support downgrading across minor versions", job["message"])
        self.assertEqual(self.running_k3s(), NEXT_MINOR_K3S)

    # ---- Platform requests are gone -----------------------------------------------------------------
    def test_platform_requests_from_an_older_api_are_refused(self):
        rid = self.request({"action": "apply", "source": "upload", "bundleId": str(uuid.uuid4()), "sha256": "a" * 64})
        rid2 = self.request({"action": "rollback"})
        self.run_updater()
        for r in (rid, rid2):
            self.assertIn("Platform updates are applied in-cluster", self.job(r)["message"])
        self.assertNotIn("helm", self.calls())
        self.assert_nothing_changed()

    def test_the_updater_contains_no_platform_machinery(self):
        source = self.read(UPDATER)
        for forbidden in ('"helm"', "pg_dump", "ctr\", \"images", "helm_upgrade", "helm_rollback"):
            self.assertNotIn(forbidden, source)

    # ---- trust boundary -----------------------------------------------------------------------------
    def test_zip_path_traversal_is_rejected(self):
        rid = self.apply(self.release(extra_zip=[("../escaped.txt", b"x")]))
        self.run_updater()
        self.assertIn("unsafe path", self.job(rid)["message"])
        for _root, _dirs, names in os.walk(self.tmp):
            self.assertNotIn("escaped.txt", names)
        self.assert_nothing_changed()

    def test_symlinked_upload_is_refused(self):
        outside = os.path.join(self.tmp, "outside.zip")
        data = self.release()
        self.write(outside, data, 0o600)
        bundle_id = self.upload(None, as_symlink_to=outside)
        rid = self.request({"action": "foundation-apply", "version": "F2609.1.0", "bundleId": bundle_id, "sha256": sha256(data)})
        self.run_updater()
        self.assertIn("cannot open the uploaded bundle", self.job(rid)["message"])
        self.assertTrue(os.path.exists(outside))
        self.assert_nothing_changed()

    def test_status_directory_planted_by_the_api_is_replaced(self):
        elsewhere = os.path.join(self.tmp, "elsewhere")
        os.makedirs(elsewhere)
        os.symlink(elsewhere, os.path.join(self.shared, "status"))
        self.run_updater()
        st = os.lstat(os.path.join(self.shared, "status"))
        self.assertTrue(stat.S_ISDIR(st.st_mode))
        self.assertEqual(st.st_uid, 0)
        self.assertEqual(os.listdir(elsewhere), [])

    def test_malformed_request_is_recorded_and_consumed(self):
        path = os.path.join(self.shared, "requests", str(uuid.uuid4()) + ".json")
        self.write(path, "{not json")
        status = self.run_updater()
        self.assertEqual(status["state"], "failed")
        self.assertIn("invalid request", status["message"])
        self.assertFalse(os.path.exists(path))


class NothingRunsOnItsOwnTests(unittest.TestCase):
    """Owner decision 1 (2026-09-18): an admin always clicks. No timer applies anything and
    unattended-upgrades stays off on every managed foundation."""

    def read(self, *parts):
        with open(os.path.join(REPO, *parts), encoding="utf-8") as f:
            return f.read()

    def test_no_updater_timer_ships(self):
        timers = []
        for root, _dirs, names in os.walk(REPO):
            if ".git" in root.split(os.sep) or "archive" in root.split(os.sep):
                continue
            timers += [n for n in names if n.endswith(".timer")]
        self.assertEqual(timers, [], "a systemd timer would let the host act without an admin request")
        unit = self.read("appliance", "cloudgrange-updater-k3s.service")
        self.assertNotRegex(unit, r"(?m)^\s*(OnCalendar|OnBootSec|OnUnitActiveSec)=")
        self.assertRegex(unit, r"(?m)^ExecStart=/usr/bin/python3 /usr/local/sbin/cloudgrange-updater-k3s\.py\s*$")

    def test_every_managed_foundation_path_disables_unattended_upgrades(self):
        installer = self.read("scripts", "Install-CloudGrangeK3s.sh")
        self.assertIn("disable_automatic_updates", installer)
        self.assertRegex(installer, r"(?m)^\s*disable_automatic_updates\s*$", "defined but never called")
        for text, where in ((installer, "Install-CloudGrangeK3s.sh"),
                            (self.read("appliance", "cloudgrange-generalize-k3s.sh"), "cloudgrange-generalize-k3s.sh")):
            self.assertIn('APT::Periodic::Unattended-Upgrade "0"', text, where)
            self.assertIn("apt-daily-upgrade.timer", text, where)
            self.assertIn("unattended-upgrades.service", text, where)
        cloud_init = self.read("scripts", "New-CloudGrangeVm.ps1")
        self.assertIn("package_upgrade: false", cloud_init)
        self.assertIn("APT::Periodic::Unattended-Upgrade", cloud_init)
        self.assertIn("apt-daily-upgrade.timer", cloud_init)

    def test_the_chart_does_not_use_system_upgrade_controller(self):
        for root, _dirs, names in os.walk(os.path.join(REPO, "charts")):
            for name in names:
                if name.endswith((".yaml", ".yml", ".tpl")):
                    with open(os.path.join(root, name), encoding="utf-8", errors="replace") as f:
                        self.assertNotIn("upgrade.cattle.io", f.read(), os.path.join(root, name))


if __name__ == "__main__":
    unittest.main()
