# Copyright 2026 CloudGrange Contributors
# SPDX-License-Identifier: Apache-2.0
#
# AB#9171 — scripts/release/New-FoundationRelease.sh builds exactly what the host Foundation updater
# (scripts/cloudgrange-updater-k3s.py) accepts, and Publish-FoundationRelease.sh writes the channel the
# updater reads. Everything here runs the REAL scripts: the builder with a throwaway openssl key pair and
# pre-staged K3s inputs (verified by the builder exactly as a download is), then the real updater's
# verify + apply against the bundle, with apt/k3s/systemctl stubbed at the process boundary by the
# test_foundation_updater.py harness (reused here, not copied).
#   - a signed build is applied end to end: K3s upgraded through the bundled install.sh, air-gap images
#     placed, host files (the updater itself and its unit) installed, the Foundation version recorded;
#   - a bundle altered after it was built (a pinned file, or the manifest itself) is refused before
#     anything changes;
#   - without a key (owner decision 2026-09-18: trust is HTTPS + SHA-256, signatures optional) the bundle
#     is still complete: the real updater applies it when its sha256 matches and refuses it when a file,
#     or the file and its manifest pin together, were changed; the publisher ships it;
#   - wrong inputs (install.sh or K3s not matching their pins, version not the pinned Foundation, a
#     signing key the hosts would not accept) stop the build;
#   - the publisher's dry-run channel document is read by the updater's foundation-check and the
#     release is then downloaded and applied through it; nothing is uploaded without --publish.
# Runs as root: sudo python3 -m unittest discover -s test/appliance -p 'test_foundation_release_builder.py'
import hashlib
import io
import json
import os
import shutil
import stat
import subprocess
import unittest
import zipfile

import test_foundation_updater as harness

REPO = harness.REPO
BUILDER = os.path.join(REPO, "scripts", "release", "New-FoundationRelease.sh")
PUBLISHER = os.path.join(REPO, "scripts", "release", "Publish-FoundationRelease.sh")
VERSION = "F2609.1.0"
NEW_K3S, OLD_K3S = harness.NEW_K3S, harness.OLD_K3S
AIRGAP = "k3s-airgap-images-amd64.tar.zst"
BUNDLE = "cloudgrange-foundation-%s.zip" % VERSION


def sha256(data):
    return hashlib.sha256(data).hexdigest()


class FoundationReleaseBuilderTests(unittest.TestCase):
    def setUp(self):
        harness.FoundationUpdaterTests.setUp(self)
        # K3s inputs as the release pipeline would download them for NEW_K3S. The binary is the
        # harness's fake (the install.sh stub "starts" whatever version it names).
        self.k3s_src = os.path.join(self.tmp, "k3s-src")
        os.makedirs(self.k3s_src)
        self.k3s_body = ("K3S %s\n" % NEW_K3S).encode()
        self.airgap_body = b"fake airgap image tarball\n"
        self.write(os.path.join(self.k3s_src, "k3s"), self.k3s_body, 0o755)
        self.write(os.path.join(self.k3s_src, AIRGAP), self.airgap_body)
        self.write(os.path.join(self.k3s_src, "install.sh"), harness.INSTALL_SH)
        self.write(os.path.join(self.k3s_src, "sha256sum-amd64.txt"),
                   "%s  k3s\n%s  %s\n%s  k3s-airgap-images-amd64.tar\n"
                   % (sha256(self.k3s_body), sha256(self.airgap_body), AIRGAP, "0" * 64))
        # A pins file for this Foundation: K3S_VERSION/K3S_INSTALL_SH_SHA256 match the inputs above,
        # FOUNDATION_VERSION is the version being built. Everything else is the real pins file.
        with open(os.path.join(REPO, "release", "pins.conf")) as f:
            pins = f.read()
        repl = {"K3S_VERSION": NEW_K3S, "K3S_INSTALL_SH_SHA256": sha256(harness.INSTALL_SH.encode()),
                "FOUNDATION_VERSION": VERSION}
        lines = []
        for line in pins.splitlines():
            key = line.split("=", 1)[0]
            lines.append("%s=%s" % (key, repl[key]) if key in repl and "=" in line else line)
        self.pins = os.path.join(self.tmp, "pins.conf")
        self.write(self.pins, "\n".join(lines) + "\n")
        self.out = os.path.join(self.tmp, "out")

    # ---- helpers --------------------------------------------------------------------------------
    def build(self, *extra, key=True, expect_ok=True, pins=None, out=None):
        args = ["bash", BUILDER, "--version", VERSION, "--out", out or self.out, "--k3s-source-dir", self.k3s_src,
                "--pins", pins or self.pins, "--expect-pubkey", self.pub]
        if key:
            args += ["--signing-key", self.key]
        env = {k: v for k, v in os.environ.items() if not k.startswith("CLOUDGRANGE_FOUNDATION_SIGNING_KEY")}
        proc = subprocess.run(args + list(extra), capture_output=True, text=True, env=env, timeout=300)
        if expect_ok:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        else:
            self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def bundle_bytes(self, name=BUNDLE, out=None):
        with open(os.path.join(out or self.out, name), "rb") as f:
            return f.read()

    @staticmethod
    def rewrite(data, replace):
        """The same zip with some members' bytes replaced (as an attacker editing it would)."""
        src, buf = zipfile.ZipFile(io.BytesIO(data)), io.BytesIO()
        with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
            for info in src.infolist():
                body = src.read(info.filename)
                z.writestr(info, replace(info.filename, body))
        return buf.getvalue()

    def publish(self, *extra, expect_ok=True, env_extra=None):
        env = {k: v for k, v in os.environ.items() if not k.startswith(("CF_", "R2_", "CLOUDFLARE_"))}
        env.update(env_extra or {})
        proc = subprocess.run(["bash", PUBLISHER] + list(extra), capture_output=True, text=True, env=env, timeout=120)
        if expect_ok:
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        else:
            self.assertNotEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        return proc

    def no_key(self):
        """Updater env for a host with no Foundation signing key installed (owner decision 2026-09-18)."""
        return {"CLOUDGRANGE_FOUNDATION_PUBKEY": os.path.join(self.keys, "absent.pub")}

    # ---- the signed build -----------------------------------------------------------------------
    def test_signed_build_is_the_updater_format_and_applies_end_to_end(self):
        proc = self.build()
        self.assertIn("updater accepts the manifest", proc.stdout)
        data = self.bundle_bytes()
        with open(os.path.join(self.out, BUNDLE + ".sha256")) as f:
            self.assertEqual(f.read().split()[0], sha256(data))
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            names = z.namelist()
            manifest = json.loads(z.read("foundation-release.json"))
            self.assertTrue(all(stat.S_ISREG(i.external_attr >> 16) for i in z.infolist()), "regular files only")
        self.assertEqual(names[:2], ["foundation-release.json", "foundation-release.json.sig"])
        self.assertEqual(set(names) - {"foundation-release.json", "foundation-release.json.sig"}, set(manifest["files"]))
        self.assertEqual(manifest["schema"], "cg-foundation-release-v1")
        self.assertEqual(manifest["version"], VERSION)
        self.assertEqual(manifest["k3s"], {"version": NEW_K3S, "binary": "k3s/k3s", "installScript": "k3s/install.sh",
                                           "airgapImages": "k3s/" + AIRGAP})
        self.assertEqual(manifest["apt"], {"packages": {}, "securityUpdates": True})
        self.assertIs(manifest["requiresReboot"], False)
        self.assertEqual(manifest["supportedPlatformVersions"], ">=2609.0.0")
        self.assertEqual({h["destination"] for h in manifest["hostFiles"]},
                         {"/usr/local/sbin/cloudgrange-updater-k3s.py", "/etc/systemd/system/cloudgrange-updater-k3s.service"})

        # The real updater: signature, pins, gates (the Platform range with the installed Platform's
        # version, the chart's Kubernetes range), then apt, K3s, host files.
        rid = self.apply(data, platformVersion="2609.0.0", supportedKubeRange=">=1.33.0-0 <1.38.0-0")
        status = self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "succeeded", job["message"])
        self.assertEqual((status["installedVersion"], status["k3sVersion"]), (VERSION, NEW_K3S))
        self.assertEqual(self.running_k3s(), NEW_K3S)
        self.assertEqual(self.read(self.k3s_bin), self.k3s_body.decode())
        calls = self.calls()
        self.assertIn("install.sh SKIP_DOWNLOAD=true VERSION=%s" % NEW_K3S, calls)
        self.assertIn("systemctl daemon-reload", calls)
        self.assertIn("systemctl restart cloudgrange-updater-k3s.service", calls, "the updater replaced itself")
        self.assertNotIn("reboot", calls)
        with open(os.path.join(self.host, "var/lib/rancher/k3s/agent/images", AIRGAP), "rb") as f:
            self.assertEqual(f.read(), self.airgap_body)
        installed = os.path.join(self.host, "usr/local/sbin/cloudgrange-updater-k3s.py")
        self.assertEqual(self.read(installed), self.read(REPO, "scripts", "cloudgrange-updater-k3s.py"))
        self.assertEqual(os.stat(installed).st_mode & 0o777, 0o755)
        self.assertEqual(self.read(self.host, "etc/systemd/system/cloudgrange-updater-k3s.service"),
                         self.read(REPO, "appliance", "cloudgrange-updater-k3s.service"))

    def test_build_is_reproducible_apart_from_the_signature(self):
        # ECDSA signatures are randomized, so two signings differ; everything they sign must not.
        def members(data):
            with zipfile.ZipFile(io.BytesIO(data)) as z:
                return [(i.filename, i.date_time, i.external_attr, z.read(i.filename))
                        for i in z.infolist() if i.filename != "foundation-release.json.sig"]
        self.build()
        other = os.path.join(self.tmp, "out2")
        self.build(out=other)
        self.assertEqual(members(self.bundle_bytes(out=other)), members(self.bundle_bytes()))
        self.build(key=False, out=os.path.join(self.tmp, "u1"))
        self.build(key=False, out=os.path.join(self.tmp, "u2"))
        self.assertEqual(sha256(self.bundle_bytes(out=os.path.join(self.tmp, "u1"))),
                         sha256(self.bundle_bytes(out=os.path.join(self.tmp, "u2"))), "unsigned: byte-identical")

    # ---- tampering ------------------------------------------------------------------------------
    def test_pinned_file_altered_after_the_build_is_refused(self):
        self.build()
        data = self.rewrite(self.bundle_bytes(),
                            lambda n, b: ("K3S v6.6.6+k3s1\n").encode() if n == "k3s/k3s" else b)
        rid = self.apply(data)
        self.run_updater()
        job = self.job(rid)
        self.assertEqual(job["state"], "failed")
        self.assertIn("checksum mismatch for k3s/k3s", job["message"])
        self.assert_nothing_changed()

    def test_manifest_altered_after_signing_is_refused(self):
        self.build()
        data = self.rewrite(self.bundle_bytes(),
                            lambda n, b: b.replace(b'"requiresReboot": false', b'"requiresReboot": true ')
                            if n == "foundation-release.json" else b)
        rid = self.apply(data, confirmReboot=True)
        self.run_updater()
        self.assertIn("signature verification FAILED", self.job(rid)["message"])
        self.assert_nothing_changed()

    # ---- unsigned -------------------------------------------------------------------------------
    def test_unsigned_bundle_is_accepted_by_its_sha256_and_refused_when_tampered(self):
        # Owner decision 2026-09-18: trust is HTTPS + SHA-256 (the bundle digest the API/channel carries,
        # plus the manifest's per-file pins); a signature is optional. No key -> a normal, installable bundle.
        NO_KEY = self.no_key()
        proc = self.build(key=False)
        self.assertNotIn("UNSIGNED", proc.stdout + proc.stderr)
        self.assertIn("not signed", proc.stdout)
        data = self.bundle_bytes()
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            self.assertNotIn("foundation-release.json.sig", z.namelist())
        with open(os.path.join(self.out, "foundation-release-record.json")) as f:
            self.assertIs(json.load(f)["signed"], False)

        # A pinned file changed after the build: the manifest's per-file sha256 catches it.
        tampered = self.rewrite(data, lambda n, b: b"K3S v6.6.6+k3s1\n" if n == "k3s/k3s" else b)
        rid = self.apply(tampered)
        self.run_updater(**NO_KEY)
        self.assertEqual(self.job(rid)["state"], "failed")
        self.assertIn("checksum mismatch for k3s/k3s", self.job(rid)["message"])
        self.assert_nothing_changed()

        # A consistent forgery (file AND its manifest pin rewritten) no longer matches the bundle
        # sha256 the admin's request carries (in the channel flow: the channel entry's sha256).
        def forge(name, body):
            if name == "k3s/k3s":
                return b"K3S v6.6.6+k3s1\n"
            if name == "foundation-release.json":
                m = json.loads(body)
                m["files"]["k3s/k3s"] = sha256(b"K3S v6.6.6+k3s1\n")
                return json.dumps(m, indent=2, sort_keys=True).encode() + b"\n"
            return body
        rid = self.request({"action": "foundation-apply", "version": VERSION, "bundleId": self.upload(self.rewrite(data, forge)),
                            "sha256": sha256(data), "requestedBy": "admin@test"})
        self.run_updater(**NO_KEY)
        self.assertEqual(self.job(rid)["state"], "failed")
        self.assertIn("sha256 mismatch", self.job(rid)["message"])
        self.assert_nothing_changed()

        # The genuine bundle, with its digest: applied end to end by the real updater.
        rid = self.apply(data, platformVersion="2609.0.0")
        status = self.run_updater(**NO_KEY)
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])
        self.assertEqual((status["installedVersion"], status["k3sVersion"]), (VERSION, NEW_K3S))
        self.assertEqual(self.running_k3s(), NEW_K3S)
        self.assertIn("install.sh SKIP_DOWNLOAD=true VERSION=%s" % NEW_K3S, self.calls())

        # And the publisher ships it (dry run): unsigned is not a reason to refuse.
        proc = self.publish("--bundle", os.path.join(self.out, BUNDLE), "--pubkey", self.pub, "--channel-url",
                            "file://%s/channels/foundation-preview.json" % self.tmp)
        self.assertIn("DRY RUN", proc.stdout)

    # ---- the builder refuses bad inputs ---------------------------------------------------------
    def test_builder_refuses_inputs_that_do_not_match_their_pins(self):
        with open(os.path.join(self.k3s_src, "install.sh"), "a") as f:
            f.write("# changed\n")
        self.assertIn("K3S_INSTALL_SH_SHA256", self.build(expect_ok=False).stderr)
        self.write(os.path.join(self.k3s_src, "install.sh"), harness.INSTALL_SH)
        self.write(os.path.join(self.k3s_src, "k3s"), b"K3S something else\n", 0o755)
        self.assertIn("does not match K3s's published SHA-256", self.build(expect_ok=False).stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, BUNDLE)))

    def test_builder_refuses_a_version_that_is_not_the_pinned_foundation(self):
        proc = subprocess.run(["bash", BUILDER, "--version", "F2609.2.0", "--out", self.out, "--k3s-source-dir",
                               self.k3s_src, "--pins", self.pins, "--signing-key", self.key],
                              capture_output=True, text=True, timeout=120)
        self.assertNotEqual(proc.returncode, 0)
        self.assertIn("is not FOUNDATION_VERSION", proc.stderr)
        proc = subprocess.run(["bash", BUILDER, "--version", "2609.1.0", "--out", self.out, "--pins", self.pins],
                              capture_output=True, text=True, timeout=120)
        self.assertIn("F + YYMM.MINOR.PATCH", proc.stderr)

    def test_builder_refuses_a_key_the_hosts_would_not_accept(self):
        other_key, other_pub = os.path.join(self.keys, "host.key"), os.path.join(self.keys, "host.pub")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", other_key], check=True)
        subprocess.run(["openssl", "ec", "-in", other_key, "-pubout", "-out", other_pub], check=True, capture_output=True)
        proc = self.build("--expect-pubkey", other_pub, expect_ok=False)
        self.assertIn("installed hosts would refuse this release", proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.out, BUNDLE)))

    # ---- publish (dry run) -> channel -> the updater ----------------------------------------------
    def test_publish_dry_run_writes_the_channel_the_updater_reads_and_uploads_nothing(self):
        # The channel and bundle are served by the harness's real https server (its own CA), exactly
        # the way a host reads them: https only, the bundle on the channel host, sha256 from the channel.
        self.build(key=False)
        www = self.www
        channel = os.path.join(www, "channels", "foundation-preview.json")
        channel_url = self.server.base + "/channels/foundation-preview.json"
        os.makedirs(os.path.dirname(channel))
        older = {"version": "F2609.0.0", "bundleUrl": "https://example.invalid/old.zip", "sha256": "a" * 64,
                 "k3sVersion": OLD_K3S}
        self.write(channel, json.dumps({"releases": [older]}))
        out = os.path.join(self.tmp, "channel.out.json")
        tls = {"CURL_CA_BUNDLE": self.server.ca}
        proc = self.publish("--bundle", os.path.join(self.out, BUNDLE), "--pubkey", self.pub,
                            "--channel-url", channel_url, "--channel-out", out, env_extra=tls)
        self.assertIn("DRY RUN", proc.stdout)
        self.assertEqual(json.loads(self.read(channel)), {"releases": [older]}, "a dry run changes nothing")
        doc = json.loads(self.read(out))
        self.assertEqual(doc["releases"][0], older, "other releases are kept")
        entry = doc["releases"][1]
        data = self.bundle_bytes()
        bundle_url = "%s/foundation/%s/%s" % (self.server.base, VERSION, BUNDLE)
        self.assertEqual({k: entry[k] for k in ("version", "bundleUrl", "sha256", "k3sVersion")},
                         {"version": VERSION, "bundleUrl": bundle_url, "sha256": sha256(data), "k3sVersion": NEW_K3S})

        # Stand the dry-run output up where --publish would put it, then drive the updater through it.
        env = dict(self.no_key(), CLOUDGRANGE_FOUNDATION_CHANNEL_URL=channel_url)
        self.write(channel, self.read(out))
        hosted = os.path.join(www, "foundation", VERSION, BUNDLE)
        os.makedirs(os.path.dirname(hosted))
        self.request({"action": "foundation-check"})
        status = self.run_updater(**env)
        self.assertEqual((status["availableVersion"], status["targetK3sVersion"]), (VERSION, NEW_K3S))
        # A different file at the bundle URL (a swapped or corrupted download) fails the channel sha256.
        self.write(hosted, self.rewrite(data, lambda n, b: b + b"# extra\n"
                                        if n == "hostfiles/cloudgrange-updater-k3s.service" else b))
        rid = self.request({"action": "foundation-apply", "version": VERSION, "confirmReboot": False})
        self.run_updater(**env)
        self.assertIn("sha256 mismatch", self.job(rid)["message"])
        self.assert_nothing_changed()
        shutil.copy(os.path.join(self.out, BUNDLE), hosted)
        rid = self.request({"action": "foundation-apply", "version": VERSION, "confirmReboot": False})
        status = self.run_updater(**env)
        self.assertEqual(self.job(rid)["state"], "succeeded", self.job(rid)["message"])
        self.assertEqual((status["installedVersion"], status["k3sVersion"]), (VERSION, NEW_K3S))

        # Re-publishing different bytes under the same version is refused (immutability).
        self.write(hosted + ".sha256", "%s  %s\n" % ("b" * 64, BUNDLE))
        proc = self.publish("--bundle", os.path.join(self.out, BUNDLE), "--pubkey", self.pub,
                            "--channel-url", channel_url, expect_ok=False, env_extra=tls)
        self.assertIn("already published", proc.stderr)

    def test_publish_refuses_a_bad_signature_and_needs_credentials_to_upload(self):
        self.build()
        other_key, other_pub = os.path.join(self.keys, "o.key"), os.path.join(self.keys, "o.pub")
        subprocess.run(["openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", other_key], check=True)
        subprocess.run(["openssl", "ec", "-in", other_key, "-pubout", "-out", other_pub], check=True, capture_output=True)
        bundle = os.path.join(self.out, BUNDLE)
        channel = "file://%s/channels/foundation-preview.json" % self.tmp
        proc = self.publish("--bundle", bundle, "--pubkey", other_pub, "--channel-url", channel, expect_ok=False)
        self.assertIn("does not verify", proc.stderr)
        proc = self.publish("--bundle", bundle, "--pubkey", self.pub, "--publish", expect_ok=False)
        self.assertIn("CF_ACCOUNT_ID", proc.stderr)

class UpdaterUserAgentTests(unittest.TestCase):
    def test_downloads_do_not_use_python_urllibs_user_agent(self):
        # Cloudflare's r2.dev (the download host) answers "Python-urllib/x" with HTTP 403, which made the
        # channel and every bundle download fail on a real host. https_open must identify itself.
        m = harness.load_module()
        seen = []

        class Opener:
            def open(self, req, timeout=None):
                seen.append(req)
                return io.BytesIO(b"{}")
        real = m.urllib.request.build_opener
        m.urllib.request.build_opener = lambda *a: Opener()
        try:
            m.https_open("https://pub-example.r2.dev/channels/foundation-preview.json", 5)
        finally:
            m.urllib.request.build_opener = real
        ua = seen[0].get_header("User-agent")
        self.assertTrue(ua and not ua.startswith("Python-urllib"), ua)


# The harness's helpers (stub apt/k3s/systemctl, fake host root, openssl key pair, upload/request/
# run_updater/job/calls), borrowed rather than copied so the two suites cannot drift apart.
for _name in ("write", "read", "upload", "request", "apply", "run_updater", "job", "calls", "running_k3s",
              "assert_nothing_changed"):
    setattr(FoundationReleaseBuilderTests, _name, harness.FoundationUpdaterTests.__dict__[_name])
del _name


if __name__ == "__main__":
    unittest.main()
